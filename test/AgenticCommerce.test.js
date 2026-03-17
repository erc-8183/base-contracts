const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

/**
 * Image Generation — E2E flow (no hook, core-only payment)
 *
 * Scenario: A client requests an AI-generated image. The provider proposes
 * a budget of 20 USDC. The client funds, the provider delivers, and the
 * evaluator completes. Core handles all USDC escrow/payment natively.
 *
 * Flow:
 *   1. Client creates job (no hook)
 *   2. Provider sets budget (20 USDC)
 *   3. Client funds — 20 USDC escrowed in core
 *   4. Provider submits deliverable
 *   5. Evaluator completes — provider receives 20 USDC
 */
describe("Image Generation", function () {
  const TWENTY_USDC = 20_000_000n; // 20 USDC (6 decimals)

  async function deployFixture() {
    const [deployer, client, provider, evaluator] = await ethers.getSigners();

    // Deploy MockUSDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();

    // Deploy core (AgenticCommerce)
    const Core = await ethers.getContractFactory("AgenticCommerce");
    const core = await upgrades.deployProxy(Core, [deployer.address], { kind: 'uups' });

    // Mint USDC to client
    await usdc.mint(client.address, TWENTY_USDC);

    // Client approves core to spend USDC
    await usdc
      .connect(client)
      .approve(await core.getAddress(), TWENTY_USDC);

    return { usdc, core, deployer, client, provider, evaluator };
  }

  it("e2e: two jobs on the same contract using different tokens (USDC and cbBTC)", async function () {
    const { usdc, core, deployer, client, provider, evaluator } =
      await loadFixture(deployFixture);

    // Deploy a second token (cbBTC)
    const MockCBBTC = await ethers.getContractFactory("MockCBBTC");
    const cbbtc = await MockCBBTC.deploy();

    const coreAddr = await core.getAddress();
    const usdcAddr = await usdc.getAddress();
    const cbbtcAddr = await cbbtc.getAddress();

    const TWENTY_USDC_AMT = TWENTY_USDC;
    const ONE_CBBTC = 100_000_000n; // 1 cbBTC (8 decimals)

    // Mint cbBTC to client and approve
    await cbbtc.mint(client.address, ONE_CBBTC);
    await cbbtc.connect(client).approve(coreAddr, ONE_CBBTC);

    const expiry = (await time.latest()) + 3600;
    const hookAddr = ethers.ZeroAddress;

    // Job 1: paid in USDC
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "Job paid in USDC", hookAddr, 0);
    const jobId1 = 1n;

    await core.connect(provider).setBudget(jobId1, usdcAddr, TWENTY_USDC_AMT, "0x");
    expect((await core.getJob(jobId1)).paymentToken).to.equal(usdcAddr);

    // Job 2: paid in cbBTC
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "Job paid in cbBTC", hookAddr, 0);
    const jobId2 = 2n;

    await core.connect(provider).setBudget(jobId2, cbbtcAddr, ONE_CBBTC, "0x");
    expect((await core.getJob(jobId2)).paymentToken).to.equal(cbbtcAddr);

    // Fund both
    await core.connect(client).fund(jobId1, TWENTY_USDC_AMT, "0x");
    await core.connect(client).fund(jobId2, ONE_CBBTC, "0x");

    // Both escrowed correctly
    expect(await usdc.balanceOf(coreAddr)).to.equal(TWENTY_USDC_AMT);
    expect(await cbbtc.balanceOf(coreAddr)).to.equal(ONE_CBBTC);

    // Submit and complete both
    const deliverable = ethers.encodeBytes32String("done");
    const reason = ethers.encodeBytes32String("approved");

    await core.connect(provider).submit(jobId1, deliverable, "0x");
    await core.connect(provider).submit(jobId2, deliverable, "0x");
    await core.connect(evaluator).complete(jobId1, reason, "0x");
    await core.connect(evaluator).complete(jobId2, reason, "0x");

    // Provider received both tokens
    expect(await usdc.balanceOf(provider.address)).to.equal(TWENTY_USDC_AMT);
    expect(await cbbtc.balanceOf(provider.address)).to.equal(ONE_CBBTC);
  });

  it("agentId: stored on job via createJob and setProvider, emitted in events", async function () {
    const { core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const expiry = (await time.latest()) + 3600;
    const hookAddr = ethers.ZeroAddress;
    const AGENT_ID = 42n;

    // createJob with agentId when provider is known
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "Job with agentId", hookAddr, AGENT_ID);
    const jobId1 = 1n;
    expect((await core.getJob(jobId1)).providerAgentId).to.equal(AGENT_ID);

    // createJob without provider, then setProvider with agentId
    await core.connect(client).createJob(ethers.ZeroAddress, evaluator.address, expiry, "Job without provider", hookAddr, 99);
    const jobId2 = 2n;
    // agentId should be 0 when provider is zero at creation
    expect((await core.getJob(jobId2)).providerAgentId).to.equal(0n);

    const AGENT_ID_2 = 7n;
    await expect(core.connect(client).setProvider(jobId2, provider.address, AGENT_ID_2))
      .to.emit(core, "ProviderSet")
      .withArgs(jobId2, provider.address, AGENT_ID_2);

    expect((await core.getJob(jobId2)).providerAgentId).to.equal(AGENT_ID_2);

    // agentId = 0 is valid (no ERC-8004 identity)
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "No agentId", hookAddr, 0);
    const jobId3 = 3n;
    expect((await core.getJob(jobId3)).providerAgentId).to.equal(0n);
  });

  it("e2e: client requests image, provider delivers, evaluator approves", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const coreAddr = await core.getAddress();

    // ──────────────────────────────────────────────────────────
    // Step 1: Client creates a job requesting image generation
    // ──────────────────────────────────────────────────────────
    const expiry = (await time.latest()) + 3600; // 1 hour from now
    const hookAddr = ethers.ZeroAddress; // no hook

    await core
      .connect(client)
      .createJob(
        provider.address,
        evaluator.address,
        expiry,
        "Generate a beautiful landscape wallpaper image",
        hookAddr,
        0 // no ERC-8004 agentId
      );

    const jobId = 1n;

    // Verify job created
    const job = await core.getJob(jobId);
    expect(job.client).to.equal(client.address);
    expect(job.provider).to.equal(provider.address);
    expect(job.evaluator).to.equal(evaluator.address);
    expect(job.status).to.equal(0n); // Open

    // ──────────────────────────────────────────────────────────
    // Step 2: Provider sets budget to 20 USDC
    // ──────────────────────────────────────────────────────────
    const usdcAddr = await usdc.getAddress();
    await expect(core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x"))
      .to.emit(core, "BudgetSet")
      .withArgs(jobId, usdcAddr, TWENTY_USDC);

    expect((await core.getJob(jobId)).budget).to.equal(TWENTY_USDC);

    // ──────────────────────────────────────────────────────────
    // Step 3: Client funds the job — 20 USDC escrowed in core
    // ──────────────────────────────────────────────────────────
    expect(await usdc.balanceOf(client.address)).to.equal(TWENTY_USDC);

    await expect(core.connect(client).fund(jobId, TWENTY_USDC, "0x"))
      .to.emit(core, "JobFunded")
      .withArgs(jobId, client.address, TWENTY_USDC);

    expect(await usdc.balanceOf(client.address)).to.equal(0n);
    expect(await usdc.balanceOf(coreAddr)).to.equal(TWENTY_USDC);
    expect((await core.getJob(jobId)).status).to.equal(1n); // Funded

    // ──────────────────────────────────────────────────────────
    // Step 4: Provider submits the deliverable
    // ──────────────────────────────────────────────────────────
    const IMAGE_URL =
      "https://png.pngtree.com/background/20250111/original/pngtree-nice-background-beautiful-h5-wallpaper-imag-picture-image_15708053.jpg";
    const deliverableHash = ethers.keccak256(ethers.toUtf8Bytes(IMAGE_URL));

    await expect(
      core.connect(provider).submit(jobId, deliverableHash, "0x")
    )
      .to.emit(core, "JobSubmitted")
      .withArgs(jobId, provider.address, deliverableHash);

    expect((await core.getJob(jobId)).status).to.equal(2n); // Submitted

    // ──────────────────────────────────────────────────────────
    // Step 5: Evaluator completes — provider gets 20 USDC
    // ──────────────────────────────────────────────────────────
    const completionReason = ethers.encodeBytes32String("approved");

    await expect(
      core.connect(evaluator).complete(jobId, completionReason, "0x")
    )
      .to.emit(core, "JobCompleted")
      .withArgs(jobId, evaluator.address, completionReason)
      .to.emit(core, "PaymentReleased")
      .withArgs(jobId, provider.address, TWENTY_USDC);

    // Final state
    expect((await core.getJob(jobId)).status).to.equal(3n); // Completed
    expect(await usdc.balanceOf(provider.address)).to.equal(TWENTY_USDC);
    expect(await usdc.balanceOf(coreAddr)).to.equal(0n);
  });
});
