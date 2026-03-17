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

    await expect(core.connect(client).fund(jobId, "0x"))
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
