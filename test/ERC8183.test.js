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

    // Deploy core (ERC8183)
    const Core = await ethers.getContractFactory("ERC8183");
    const core = await upgrades.deployProxy(Core, [deployer.address, deployer.address], { kind: 'uups' });

    // Allowlist USDC as a payment token (admin action)
    await core.connect(deployer).setPaymentTokenAllowed(await usdc.getAddress(), true);

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

    // Allowlist cbBTC as a payment token
    await core.connect(deployer).setPaymentTokenAllowed(cbbtcAddr, true);

    // Mint cbBTC to client and approve
    await cbbtc.mint(client.address, ONE_CBBTC);
    await cbbtc.connect(client).approve(coreAddr, ONE_CBBTC);

    const expiry = (await time.latest()) + 3600;
    const hookAddr = ethers.ZeroAddress;

    // Job 1: paid in USDC
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "Job paid in USDC", hookAddr, ethers.ZeroAddress, 0);
    const jobId1 = 1n;

    await core.connect(provider).setBudget(jobId1, usdcAddr, TWENTY_USDC_AMT, "0x");
    expect((await core.getJob(jobId1)).paymentToken).to.equal(usdcAddr);

    // Job 2: paid in cbBTC
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "Job paid in cbBTC", hookAddr, ethers.ZeroAddress, 0);
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
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "Job with agentId", hookAddr, ethers.ZeroAddress, AGENT_ID);
    const jobId1 = 1n;
    expect((await core.getJob(jobId1)).providerAgentId).to.equal(AGENT_ID);

    // createJob without provider, then setProvider with agentId
    await core.connect(client).createJob(ethers.ZeroAddress, evaluator.address, expiry, "Job without provider", hookAddr, ethers.ZeroAddress, 99);
    const jobId2 = 2n;
    // agentId should be 0 when provider is zero at creation
    expect((await core.getJob(jobId2)).providerAgentId).to.equal(0n);

    const AGENT_ID_2 = 7n;
    await expect(core.connect(client).setProvider(jobId2, provider.address, AGENT_ID_2))
      .to.emit(core, "ProviderSet")
      .withArgs(jobId2, provider.address, AGENT_ID_2);

    expect((await core.getJob(jobId2)).providerAgentId).to.equal(AGENT_ID_2);

    // agentId = 0 is valid (no ERC-8004 identity)
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "No agentId", hookAddr, ethers.ZeroAddress, 0);
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
        ethers.ZeroAddress, // no payout receiver
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

  it("claimRefund: reverts during grace period when job is Submitted", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const coreAddr = await core.getAddress();
    const usdcAddr = await usdc.getAddress();
    const expiry = (await time.latest()) + 3600;

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "grace period test", ethers.ZeroAddress, ethers.ZeroAddress, 0);
    const jobId = 1n;

    await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(jobId, TWENTY_USDC, "0x");

    // Provider submits right before expiry
    await time.increaseTo(expiry - 60);
    await core.connect(provider).submit(jobId, ethers.encodeBytes32String("work"), "0x");

    // Move past expiry but within grace period
    await time.increaseTo(expiry + 1);
    await expect(
      core.claimRefund(jobId)
    ).to.be.revertedWithCustomError(core, "GracePeriodActive");

    // Evaluator can still complete during grace period
    await core.connect(evaluator).complete(jobId, ethers.encodeBytes32String("ok"), "0x");
    expect((await core.getJob(jobId)).status).to.equal(3n); // Completed
    expect(await usdc.balanceOf(provider.address)).to.equal(TWENTY_USDC);
  });

  it("claimRefund: succeeds after grace period expires on Submitted job", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const usdcAddr = await usdc.getAddress();
    const expiry = (await time.latest()) + 3600;

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "grace expiry test", ethers.ZeroAddress, ethers.ZeroAddress, 0);
    const jobId = 1n;

    await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(jobId, TWENTY_USDC, "0x");
    await core.connect(provider).submit(jobId, ethers.encodeBytes32String("work"), "0x");

    // Move past expiry + grace period (1 hour)
    await time.increaseTo(expiry + 3601);
    await core.claimRefund(jobId);
    expect((await core.getJob(jobId)).status).to.equal(5n); // Expired
    expect(await usdc.balanceOf(client.address)).to.equal(TWENTY_USDC);
  });

  it("setBudget: reverts with PaymentTokenNotAllowed when token is not on allowlist", async function () {
    const { core, client, provider, evaluator } = await loadFixture(deployFixture);

    // Deploy a separate ERC-20 that we deliberately do NOT allowlist
    const MockCBBTC = await ethers.getContractFactory("MockCBBTC");
    const notAllowed = await MockCBBTC.deploy();

    const expiry = (await time.latest()) + 3600;
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "test", ethers.ZeroAddress, ethers.ZeroAddress, 0);
    const jobId = 1n;

    await expect(
      core.connect(provider).setBudget(jobId, await notAllowed.getAddress(), 1n, "0x")
    ).to.be.revertedWithCustomError(core, "PaymentTokenNotAllowed");
  });

  it("setPaymentTokenAllowed: only admin, emits event, ZeroAddress reverts", async function () {
    const { core, deployer, client } = await loadFixture(deployFixture);

    const MockCBBTC = await ethers.getContractFactory("MockCBBTC");
    const tok = await MockCBBTC.deploy();
    const tokAddr = await tok.getAddress();

    // Non-admin reverts with AccessControl error
    await expect(
      core.connect(client).setPaymentTokenAllowed(tokAddr, true)
    ).to.be.reverted;

    // ZeroAddress reverts
    await expect(
      core.connect(deployer).setPaymentTokenAllowed(ethers.ZeroAddress, true)
    ).to.be.revertedWithCustomError(core, "ZeroAddress");

    // Admin can allow and revoke, both emit event
    await expect(core.connect(deployer).setPaymentTokenAllowed(tokAddr, true))
      .to.emit(core, "PaymentTokenAllowlistUpdated")
      .withArgs(tokAddr, true);
    expect(await core.allowedPaymentTokens(tokAddr)).to.equal(true);

    await expect(core.connect(deployer).setPaymentTokenAllowed(tokAddr, false))
      .to.emit(core, "PaymentTokenAllowlistUpdated")
      .withArgs(tokAddr, false);
    expect(await core.allowedPaymentTokens(tokAddr)).to.equal(false);
  });

  it("fund: reverts with UnexpectedFundedAmount for fee-on-transfer tokens", async function () {
    const { core, deployer, client, provider, evaluator } = await loadFixture(deployFixture);

    const MockFOT = await ethers.getContractFactory("MockFeeOnTransferToken");
    const fot = await MockFOT.deploy();
    const fotAddr = await fot.getAddress();
    const coreAddr = await core.getAddress();

    const AMOUNT = 1_000_000n;
    await fot.mint(client.address, AMOUNT);
    await fot.connect(client).approve(coreAddr, AMOUNT);
    await core.connect(deployer).setPaymentTokenAllowed(fotAddr, true);

    const expiry = (await time.latest()) + 3600;
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "fot", ethers.ZeroAddress, ethers.ZeroAddress, 0);
    const jobId = 1n;

    // setBudget passes (interface probe + allowlist OK)
    await core.connect(provider).setBudget(jobId, fotAddr, AMOUNT, "0x");

    // fund must revert because received < budget (fee burned 1%)
    await expect(
      core.connect(client).fund(jobId, AMOUNT, "0x")
    ).to.be.revertedWithCustomError(core, "UnexpectedFundedAmount");

    // Escrow stayed empty; client keeps the post-fee remainder
    expect(await fot.balanceOf(coreAddr)).to.equal(0n);
  });

  it("claimRefund: no grace period for Funded (not Submitted) jobs", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const usdcAddr = await usdc.getAddress();
    const expiry = (await time.latest()) + 3600;

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "no grace test", ethers.ZeroAddress, ethers.ZeroAddress, 0);
    const jobId = 1n;

    await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(jobId, TWENTY_USDC, "0x");
    // NOT submitted - stays Funded

    await time.increaseTo(expiry + 1);
    await core.claimRefund(jobId);
    expect((await core.getJob(jobId)).status).to.equal(5n); // Expired
    expect(await usdc.balanceOf(client.address)).to.equal(TWENTY_USDC);
  });

  describe("payoutReceiver", function () {
    async function runJobToSubmitted({ core, usdc, client, provider, evaluator, payoutReceiver }) {
      const expiry = (await time.latest()) + 3600;
      const usdcAddr = await usdc.getAddress();
      await core.connect(client).createJob(
        provider.address,
        evaluator.address,
        expiry,
        "receiver job",
        ethers.ZeroAddress,
        payoutReceiver,
        0
      );
      const jobId = 1n;
      await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
      await core.connect(client).fund(jobId, TWENTY_USDC, "0x");
      await core.connect(provider).submit(jobId, ethers.encodeBytes32String("done"), "0x");
      return { jobId };
    }

    it("createJob: address(0) keeps existing pay-provider-directly behavior", async function () {
      const { usdc, core, client, provider, evaluator } = await loadFixture(deployFixture);
      const { jobId } = await runJobToSubmitted({ core, usdc, client, provider, evaluator, payoutReceiver: ethers.ZeroAddress });

      expect((await core.getJob(jobId)).payoutReceiver).to.equal(ethers.ZeroAddress);

      await expect(core.connect(evaluator).complete(jobId, ethers.encodeBytes32String("ok"), "0x"))
        .to.emit(core, "PaymentReleased")
        .withArgs(jobId, provider.address, TWENTY_USDC);
      expect(await usdc.balanceOf(provider.address)).to.equal(TWENTY_USDC);
    });

    it("createJob: EOA receiver routes funds without disburser callback", async function () {
      const { usdc, core, client, provider, evaluator } = await loadFixture(deployFixture);
      const [, , , , eoaReceiver] = await ethers.getSigners();
      const { jobId } = await runJobToSubmitted({
        core, usdc, client, provider, evaluator, payoutReceiver: eoaReceiver.address,
      });

      expect((await core.getJob(jobId)).payoutReceiver).to.equal(eoaReceiver.address);

      const tx = core.connect(evaluator).complete(jobId, ethers.encodeBytes32String("ok"), "0x");
      await expect(tx)
        .to.emit(core, "PaymentReleased")
        .withArgs(jobId, eoaReceiver.address, TWENTY_USDC);
      // No Disbursed event for EOA recipients
      await expect(tx).to.not.emit(core, "Disbursed");
      expect(await usdc.balanceOf(eoaReceiver.address)).to.equal(TWENTY_USDC);
      expect(await usdc.balanceOf(provider.address)).to.equal(0n);
    });

    it("createJob: contract receiver receives funds and onDisbursement is invoked", async function () {
      const { usdc, core, client, provider, evaluator } = await loadFixture(deployFixture);
      const Disburser = await ethers.getContractFactory("MockDisburser");
      const disburser = await Disburser.deploy();
      const disburserAddr = await disburser.getAddress();
      const usdcAddr = await usdc.getAddress();

      const { jobId } = await runJobToSubmitted({
        core, usdc, client, provider, evaluator, payoutReceiver: disburserAddr,
      });

      const completeSelector = core.interface.getFunction("complete").selector;

      await expect(core.connect(evaluator).complete(jobId, ethers.encodeBytes32String("ok"), "0xdeadbeef"))
        .to.emit(core, "PaymentReleased")
        .withArgs(jobId, disburserAddr, TWENTY_USDC)
        .to.emit(core, "Disbursed")
        .withArgs(jobId, disburserAddr, completeSelector, TWENTY_USDC);

      expect(await usdc.balanceOf(disburserAddr)).to.equal(TWENTY_USDC);
      expect(await disburser.callCount()).to.equal(1n);
      expect(await disburser.lastJobId()).to.equal(jobId);
      expect(await disburser.lastSelector()).to.equal(completeSelector);
      expect(await disburser.lastToken()).to.equal(usdcAddr);
      expect(await disburser.lastAmount()).to.equal(TWENTY_USDC);
      expect(await disburser.lastData()).to.equal("0xdeadbeef");
    });

    it("createJob: contract not advertising IDisburser via ERC-165 reverts", async function () {
      const { core, client, provider, evaluator } = await loadFixture(deployFixture);
      const NotADisburser = await ethers.getContractFactory("NotADisburser");
      const bad = await NotADisburser.deploy();
      const expiry = (await time.latest()) + 3600;

      await expect(
        core.connect(client).createJob(
          provider.address,
          evaluator.address,
          expiry,
          "bad receiver",
          ethers.ZeroAddress,
          await bad.getAddress(),
          0
        )
      ).to.be.revertedWithCustomError(core, "InvalidPayoutReceiver");
    });

    it("setPayoutReceiver: client-only, Open-only, validates ERC-165, locks after fund", async function () {
      const { usdc, core, client, provider, evaluator } = await loadFixture(deployFixture);
      const Disburser = await ethers.getContractFactory("MockDisburser");
      const disburser = await Disburser.deploy();
      const NotADisburser = await ethers.getContractFactory("NotADisburser");
      const bad = await NotADisburser.deploy();
      const expiry = (await time.latest()) + 3600;
      const usdcAddr = await usdc.getAddress();

      await core.connect(client).createJob(
        provider.address,
        evaluator.address,
        expiry,
        "setter test",
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        0
      );
      const jobId = 1n;

      // Non-client cannot set
      await expect(
        core.connect(provider).setPayoutReceiver(jobId, await disburser.getAddress())
      ).to.be.revertedWithCustomError(core, "Unauthorized");

      // ERC-165 validation rejects non-IDisburser contracts
      await expect(
        core.connect(client).setPayoutReceiver(jobId, await bad.getAddress())
      ).to.be.revertedWithCustomError(core, "InvalidPayoutReceiver");

      // Client sets receiver while Open
      await expect(core.connect(client).setPayoutReceiver(jobId, await disburser.getAddress()))
        .to.emit(core, "PayoutReceiverSet")
        .withArgs(jobId, await disburser.getAddress());
      expect((await core.getJob(jobId)).payoutReceiver).to.equal(await disburser.getAddress());

      // Fund -> Open transitions to Funded; setter is now locked
      await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
      await core.connect(client).fund(jobId, TWENTY_USDC, "0x");
      await expect(
        core.connect(client).setPayoutReceiver(jobId, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(core, "WrongStatus");
    });

    it("complete: reverts when receiver disburser reverts (strict)", async function () {
      const { usdc, core, client, provider, evaluator } = await loadFixture(deployFixture);
      const Disburser = await ethers.getContractFactory("MockDisburser");
      const disburser = await Disburser.deploy();

      const { jobId } = await runJobToSubmitted({
        core, usdc, client, provider, evaluator, payoutReceiver: await disburser.getAddress(),
      });

      await disburser.setShouldRevert(true);

      await expect(
        core.connect(evaluator).complete(jobId, ethers.encodeBytes32String("ok"), "0x")
      ).to.be.revertedWith("MockDisburser: forced revert");

      // Job still Submitted, escrow untouched
      expect((await core.getJob(jobId)).status).to.equal(2n);
      expect(await usdc.balanceOf(await core.getAddress())).to.equal(TWENTY_USDC);
    });
  });
});
