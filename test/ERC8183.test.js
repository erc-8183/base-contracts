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
  const TEN_USDC = 10_000_000n;
  const FIVE_USDC = 5_000_000n;
  const ONE_USDC = 1_000_000n;
  const EMPTY_DELIVERABLE = "0x";

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

  async function createFundedJob({ core, usdc, client, provider, evaluator, amount = TWENTY_USDC }) {
    const expiry = (await time.latest()) + 3600;
    const usdcAddr = await usdc.getAddress();

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "partial settlement job", ethers.ZeroAddress, 0);
    const jobId = 1n;
    await core.connect(provider).setBudget(jobId, usdcAddr, amount, "0x");
    await core.connect(client).fund(jobId, amount, "0x");

    return { jobId, expiry };
  }

  async function signClaim({ core, signer, jobId, cumulativeAmount, deliverable = EMPTY_DELIVERABLE, optParams = "0x" }) {
    const { chainId } = await ethers.provider.getNetwork();
    return signer.signTypedData(
      {
        name: "ERC8183",
        version: "1",
        chainId,
        verifyingContract: await core.getAddress(),
      },
      {
        ClaimVoucher: [
          { name: "jobId", type: "uint256" },
          { name: "cumulativeAmount", type: "uint256" },
          { name: "deliverable", type: "bytes" },
          { name: "optParams", type: "bytes" },
        ],
      },
      { jobId, cumulativeAmount, deliverable, optParams }
    );
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

  it("claimRefund: reverts during grace period when job is Submitted", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const coreAddr = await core.getAddress();
    const usdcAddr = await usdc.getAddress();
    const expiry = (await time.latest()) + 3600;

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "grace period test", ethers.ZeroAddress, 0);
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

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "grace expiry test", ethers.ZeroAddress, 0);
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
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "test", ethers.ZeroAddress, 0);
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
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "fot", ethers.ZeroAddress, 0);
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

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "no grace test", ethers.ZeroAddress, 0);
    const jobId = 1n;

    await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(jobId, TWENTY_USDC, "0x");
    // NOT submitted - stays Funded

    await time.increaseTo(expiry + 1);
    await core.claimRefund(jobId);
    expect((await core.getJob(jobId)).status).to.equal(5n); // Expired
    expect(await usdc.balanceOf(client.address)).to.equal(TWENTY_USDC);
  });

  it("submitClaim fast path: charges platform and evaluator fees on each settlement delta", async function () {
    const { usdc, core, deployer, client, provider, evaluator } =
      await loadFixture(deployFixture);
    const coreAddr = await core.getAddress();

    await core.connect(deployer).setPlatformFee(1000, deployer.address);
    await core.connect(deployer).setEvaluatorFee(500);

    const { jobId } = await createFundedJob({ core, usdc, client, provider, evaluator });
    const voucherSig = await signClaim({
      core,
      signer: client,
      jobId,
      cumulativeAmount: TEN_USDC,
    });

    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, voucherSig, "0x"))
      .to.emit(core, "Settled")
      .withArgs(jobId, TEN_USDC, TEN_USDC)
      .to.emit(core, "PlatformFeePaid")
      .withArgs(jobId, deployer.address, ONE_USDC)
      .to.emit(core, "EvaluatorFeePaid")
      .withArgs(jobId, evaluator.address, 500_000n)
      .to.emit(core, "PaymentReleased")
      .withArgs(jobId, provider.address, 8_500_000n);

    expect((await core.getJob(jobId)).settledAmount).to.equal(TEN_USDC);
    expect(await usdc.balanceOf(deployer.address)).to.equal(ONE_USDC);
    expect(await usdc.balanceOf(evaluator.address)).to.equal(500_000n);
    expect(await usdc.balanceOf(provider.address)).to.equal(8_500_000n);
    expect(await usdc.balanceOf(coreAddr)).to.equal(TEN_USDC);
  });

  it("submitClaim fast path: only pays the new delta for increasing cumulative claims", async function () {
    const { usdc, core, deployer, client, provider, evaluator } =
      await loadFixture(deployFixture);
    const coreAddr = await core.getAddress();

    await core.connect(deployer).setPlatformFee(1000, deployer.address);
    await core.connect(deployer).setEvaluatorFee(500);

    const { jobId } = await createFundedJob({ core, usdc, client, provider, evaluator });
    const firstSig = await signClaim({
      core,
      signer: client,
      jobId,
      cumulativeAmount: FIVE_USDC,
    });
    const secondSig = await signClaim({
      core,
      signer: client,
      jobId,
      cumulativeAmount: TEN_USDC,
    });

    await core.connect(provider).submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, firstSig, "0x");

    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, secondSig, "0x"))
      .to.emit(core, "Settled")
      .withArgs(jobId, TEN_USDC, FIVE_USDC)
      .to.emit(core, "PlatformFeePaid")
      .withArgs(jobId, deployer.address, 500_000n)
      .to.emit(core, "EvaluatorFeePaid")
      .withArgs(jobId, evaluator.address, 250_000n)
      .to.emit(core, "PaymentReleased")
      .withArgs(jobId, provider.address, 4_250_000n);

    expect((await core.getJob(jobId)).settledAmount).to.equal(TEN_USDC);
    expect(await usdc.balanceOf(deployer.address)).to.equal(ONE_USDC);
    expect(await usdc.balanceOf(evaluator.address)).to.equal(500_000n);
    expect(await usdc.balanceOf(provider.address)).to.equal(8_500_000n);
    expect(await usdc.balanceOf(coreAddr)).to.equal(TEN_USDC);
  });

  it("submitClaim fast path: rejects stale cumulative amounts and invalid signatures", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const { jobId } = await createFundedJob({ core, usdc, client, provider, evaluator });
    const firstSig = await signClaim({
      core,
      signer: client,
      jobId,
      cumulativeAmount: FIVE_USDC,
    });
    await core.connect(provider).submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, firstSig, "0x");

    await expect(
      core.connect(provider).submitClaim(jobId, FIVE_USDC, EMPTY_DELIVERABLE, firstSig, "0x")
    ).to.be.revertedWithCustomError(core, "NoNewSettlement");

    const providerSig = await signClaim({
      core,
      signer: provider,
      jobId,
      cumulativeAmount: TEN_USDC,
    });
    await expect(
      core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, providerSig, "0x")
    ).to.be.revertedWithCustomError(core, "InvalidVoucherSignature");
  });

  it("complete: releases only unsettled escrow after partial settlement", async function () {
    const { usdc, core, deployer, client, provider, evaluator } =
      await loadFixture(deployFixture);
    const coreAddr = await core.getAddress();

    await core.connect(deployer).setPlatformFee(1000, deployer.address);
    await core.connect(deployer).setEvaluatorFee(500);

    const { jobId } = await createFundedJob({ core, usdc, client, provider, evaluator });
    const voucherSig = await signClaim({
      core,
      signer: client,
      jobId,
      cumulativeAmount: TEN_USDC,
    });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY_DELIVERABLE, voucherSig, "0x");
    await core.connect(provider).submit(jobId, ethers.encodeBytes32String("work"), "0x");

    await expect(core.connect(evaluator).complete(jobId, ethers.encodeBytes32String("ok"), "0x"))
      .to.emit(core, "PaymentReleased")
      .withArgs(jobId, provider.address, 8_500_000n);

    expect(await usdc.balanceOf(deployer.address)).to.equal(2_000_000n);
    expect(await usdc.balanceOf(evaluator.address)).to.equal(1_000_000n);
    expect(await usdc.balanceOf(provider.address)).to.equal(17_000_000n);
    expect(await usdc.balanceOf(coreAddr)).to.equal(0n);
  });

  it("reject and claimRefund: refund only unsettled escrow after partial settlement", async function () {
    const { usdc, core, client, provider, evaluator } =
      await loadFixture(deployFixture);

    const first = await createFundedJob({ core, usdc, client, provider, evaluator });
    const firstSig = await signClaim({
      core,
      signer: client,
      jobId: first.jobId,
      cumulativeAmount: TEN_USDC,
    });
    await core.connect(provider).submitClaim(first.jobId, TEN_USDC, EMPTY_DELIVERABLE, firstSig, "0x");
    await core.connect(evaluator).reject(first.jobId, ethers.encodeBytes32String("no"), "0x");
    expect(await usdc.balanceOf(client.address)).to.equal(TEN_USDC);

    await usdc.mint(client.address, TWENTY_USDC);
    await usdc.connect(client).approve(await core.getAddress(), TWENTY_USDC);

    const expiry = (await time.latest()) + 3600;
    const usdcAddr = await usdc.getAddress();
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "partial refund job", ethers.ZeroAddress, 0);
    const secondJobId = 2n;
    await core.connect(provider).setBudget(secondJobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(secondJobId, TWENTY_USDC, "0x");
    const secondSig = await signClaim({
      core,
      signer: client,
      jobId: secondJobId,
      cumulativeAmount: TEN_USDC,
    });
    await core.connect(provider).submitClaim(secondJobId, TEN_USDC, EMPTY_DELIVERABLE, secondSig, "0x");

    await time.increaseTo(expiry + 1);
    await core.claimRefund(secondJobId);
    expect(await usdc.balanceOf(client.address)).to.equal(2n * TEN_USDC);
  });
});

describe("submitClaim (unified fast/slow by deliverable length)", function () {
  const TWENTY_USDC = 20_000_000n;
  const TEN_USDC = 10_000_000n;
  const FIVE_USDC = 5_000_000n;

  async function deployFixture() {
    const [deployer, client, provider, evaluator, outsider] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();

    const Core = await ethers.getContractFactory("ERC8183");
    const core = await upgrades.deployProxy(Core, [deployer.address, deployer.address], { kind: 'uups' });

    await core.connect(deployer).setPaymentTokenAllowed(await usdc.getAddress(), true);

    await usdc.mint(client.address, TWENTY_USDC);
    await usdc.connect(client).approve(await core.getAddress(), TWENTY_USDC);

    const expiry = (await time.latest()) + 3600;
    const usdcAddr = await usdc.getAddress();
    await core.connect(client).createJob(
      provider.address, evaluator.address, expiry, "claim job", ethers.ZeroAddress, 0
    );
    const jobId = 1n;
    await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(jobId, TWENTY_USDC, "0x");

    return { usdc, core, deployer, client, provider, evaluator, outsider, jobId };
  }

  // Both paths require a client-signed ClaimVoucher. Empty deliverable = fast.
  async function signClaim({ core, signer, jobId, cumulativeAmount, deliverable, optParams = "0x" }) {
    const { chainId } = await ethers.provider.getNetwork();
    return signer.signTypedData(
      {
        name: "ERC8183",
        version: "1",
        chainId,
        verifyingContract: await core.getAddress(),
      },
      {
        ClaimVoucher: [
          { name: "jobId", type: "uint256" },
          { name: "cumulativeAmount", type: "uint256" },
          { name: "deliverable", type: "bytes" },
          { name: "optParams", type: "bytes" },
        ],
      },
      { jobId, cumulativeAmount, deliverable, optParams }
    );
  }

  const DELIVERABLE_A = "0xdeadbeefcafef00d";
  const DELIVERABLE_B = "0xfeedfacebabe1234";
  const OPT_PARAMS_A = "0x1234";
  const OPT_PARAMS_B = "0xabcd";
  const EMPTY = "0x";

  // Compute the on-chain pending-claim binding hash.
  const claimBindingHash = (amount, deliverable, optParams = "0x") =>
    ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "bytes32", "bytes32"],
        [amount, ethers.keccak256(deliverable), ethers.keccak256(optParams)]
      )
    );

  it("ABI: legacy settle entry point is removed", async function () {
    const { core } = await loadFixture(deployFixture);

    expect(core.interface.hasFunction("settle(uint256,uint256,bytes,bytes)")).to.equal(false);
  });

  it("fast path (empty deliverable): unconditional voucher, settles in same tx", async function () {
    const { usdc, core, client, provider, jobId } = await loadFixture(deployFixture);

    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: EMPTY });

    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY, sig, "0x"))
      .to.emit(core, "Settled").withArgs(jobId, TEN_USDC, TEN_USDC)
      .and.to.emit(core, "ClaimSubmitted").withArgs(jobId, provider.address, TEN_USDC, TEN_USDC, EMPTY);

    expect(await usdc.balanceOf(provider.address)).to.equal(TEN_USDC);
    expect(await core.pendingClaimHash(jobId)).to.equal(ethers.ZeroHash);
  });

  it("slow path (non-empty deliverable): stored as hash, evaluator approves with preimage", async function () {
    const { usdc, core, client, provider, evaluator, jobId } = await loadFixture(deployFixture);

    const sig = await signClaim({
      core,
      signer: client,
      jobId,
      cumulativeAmount: TEN_USDC,
      deliverable: DELIVERABLE_A,
      optParams: OPT_PARAMS_A,
    });

    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, OPT_PARAMS_A))
      .to.emit(core, "ClaimSubmitted")
      .withArgs(jobId, provider.address, TEN_USDC, TEN_USDC, DELIVERABLE_A);

    expect(await usdc.balanceOf(provider.address)).to.equal(0n);
    expect(await core.pendingClaimHash(jobId)).to.equal(claimBindingHash(TEN_USDC, DELIVERABLE_A, OPT_PARAMS_A));

    const dHash = ethers.keccak256(DELIVERABLE_A);
    await expect(
      core.connect(evaluator).approveClaim(jobId, TEN_USDC, dHash, OPT_PARAMS_B)
    ).to.be.revertedWithCustomError(core, "NoPendingClaim");
    await expect(core.connect(evaluator).approveClaim(jobId, TEN_USDC, dHash, OPT_PARAMS_A))
      .to.emit(core, "ClaimApproved").withArgs(jobId, evaluator.address, TEN_USDC, TEN_USDC, dHash);
    expect(await usdc.balanceOf(provider.address)).to.equal(TEN_USDC);
    expect(await core.pendingClaimHash(jobId)).to.equal(ethers.ZeroHash);
  });

  it("approveClaim: reverts if preimage doesn't match stored hash", async function () {
    const { core, client, provider, evaluator, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x");

    // Wrong deliverableHash
    await expect(
      core.connect(evaluator).approveClaim(jobId, TEN_USDC, ethers.keccak256(DELIVERABLE_B), "0x")
    ).to.be.revertedWithCustomError(core, "NoPendingClaim");
    // Wrong amount
    await expect(
      core.connect(evaluator).approveClaim(jobId, FIVE_USDC, ethers.keccak256(DELIVERABLE_A), "0x")
    ).to.be.revertedWithCustomError(core, "NoPendingClaim");
  });

  it("submitClaim: only provider can submit (slow path)", async function () {
    const { core, client, provider, outsider, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await expect(core.connect(outsider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x"))
      .to.be.revertedWithCustomError(core, "Unauthorized");
    await expect(core.connect(client).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x"))
      .to.be.revertedWithCustomError(core, "Unauthorized");
  });

  it("submitClaim: invalid signature reverts (any path)", async function () {
    const { core, provider, evaluator, jobId } = await loadFixture(deployFixture);
    const badSig = await signClaim({ core, signer: evaluator, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, badSig, "0x"))
      .to.be.revertedWithCustomError(core, "InvalidVoucherSignature");
  });

  it("approveClaim: client OR evaluator only; provider self-approve reverts", async function () {
    const { core, client, provider, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x");

    const dHash = ethers.keccak256(DELIVERABLE_A);
    await expect(core.connect(provider).approveClaim(jobId, TEN_USDC, dHash, "0x"))
      .to.be.revertedWithCustomError(core, "Unauthorized");
    await expect(core.connect(client).approveClaim(jobId, TEN_USDC, dHash, "0x"))
      .to.emit(core, "ClaimApproved");
  });

  it("approveClaim: random third party reverts", async function () {
    const { core, client, provider, outsider, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x");
    await expect(core.connect(outsider).approveClaim(jobId, TEN_USDC, ethers.keccak256(DELIVERABLE_A), "0x"))
      .to.be.revertedWithCustomError(core, "Unauthorized");
  });

  it("approveClaim: NoPendingClaim when nothing pending", async function () {
    const { core, evaluator, jobId } = await loadFixture(deployFixture);
    await expect(core.connect(evaluator).approveClaim(jobId, TEN_USDC, ethers.keccak256(DELIVERABLE_A), "0x"))
      .to.be.revertedWithCustomError(core, "NoPendingClaim");
  });

  it("slow path: latest claim replaces pending hash and invalidates old approvals", async function () {
    const { core, client, provider, jobId } = await loadFixture(deployFixture);
    const sig1 = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig1, "0x");

    const sig2 = await signClaim({ core, signer: client, jobId, cumulativeAmount: TWENTY_USDC, deliverable: DELIVERABLE_B });
    await expect(core.connect(provider).submitClaim(jobId, TWENTY_USDC, DELIVERABLE_B, sig2, "0x"))
      .to.emit(core, "ClaimSubmitted")
      .withArgs(jobId, provider.address, TWENTY_USDC, TWENTY_USDC, DELIVERABLE_B);

    expect(await core.pendingClaimHash(jobId)).to.equal(claimBindingHash(TWENTY_USDC, DELIVERABLE_B));
    await expect(
      core.connect(client).approveClaim(jobId, TEN_USDC, ethers.keccak256(DELIVERABLE_A), "0x")
    ).to.be.revertedWithCustomError(core, "NoPendingClaim");
  });

  it("slow path: exact submitted claim hash cannot be submitted again after rejection", async function () {
    const { core, client, provider, evaluator, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });

    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x");
    await core.connect(evaluator).rejectClaim(
      jobId,
      TEN_USDC,
      ethers.keccak256(DELIVERABLE_A),
      ethers.encodeBytes32String("rework"),
      "0x"
    );

    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x"))
      .to.be.revertedWithCustomError(core, "ClaimAlreadySubmitted");
  });

  it("submitClaim hook data follows caller, cumulativeAmount, deliverable, optParams pattern", async function () {
    const { usdc, core, deployer, client, provider, evaluator } = await loadFixture(deployFixture);

    const MockHook = await ethers.getContractFactory("MockHook");
    const hook = await MockHook.deploy();
    await core.connect(deployer).setHookWhitelist(await hook.getAddress(), true);

    await usdc.mint(client.address, TWENTY_USDC);
    await usdc.connect(client).approve(await core.getAddress(), TWENTY_USDC);

    const expiry = (await time.latest()) + 3600;
    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "hook claim job", await hook.getAddress(), 0);
    const hookJobId = 2n;
    await core.connect(provider).setBudget(hookJobId, await usdc.getAddress(), TWENTY_USDC, "0x");
    await core.connect(client).fund(hookJobId, TWENTY_USDC, "0x");

    const fastSig = await signClaim({ core, signer: client, jobId: hookJobId, cumulativeAmount: FIVE_USDC, deliverable: EMPTY });
    await core.connect(provider).submitClaim(hookJobId, FIVE_USDC, EMPTY, fastSig, "0x");

    const cumulativeAmount = TEN_USDC;
    const slowSig = await signClaim({
      core,
      signer: client,
      jobId: hookJobId,
      cumulativeAmount,
      deliverable: DELIVERABLE_A,
      optParams: OPT_PARAMS_A,
    });
    const expectedData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256", "bytes", "bytes"],
      [provider.address, cumulativeAmount, DELIVERABLE_A, OPT_PARAMS_A]
    );

    await expect(core.connect(provider).submitClaim(hookJobId, cumulativeAmount, DELIVERABLE_A, slowSig, OPT_PARAMS_A))
      .to.emit(hook, "BeforeAction")
      .withArgs(hookJobId, core.interface.getFunction("submitClaim").selector, expectedData);
  });

  it("rejectClaim: clears pending, provider can resubmit with revised deliverable", async function () {
    const { core, client, provider, evaluator, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x");

    const reason = ethers.encodeBytes32String("rework");
    const dHashA = ethers.keccak256(DELIVERABLE_A);
    await expect(core.connect(evaluator).rejectClaim(jobId, TEN_USDC, dHashA, reason, "0x"))
      .to.emit(core, "ClaimRejected").withArgs(jobId, evaluator.address, reason);
    expect(await core.pendingClaimHash(jobId)).to.equal(ethers.ZeroHash);

    const sig2 = await signClaim({ core, signer: client, jobId, cumulativeAmount: FIVE_USDC, deliverable: DELIVERABLE_B });
    await expect(core.connect(provider).submitClaim(jobId, FIVE_USDC, DELIVERABLE_B, sig2, "0x"))
      .to.emit(core, "ClaimSubmitted");
  });

  it("rejectClaim: provider self-reject reverts", async function () {
    const { core, client, provider, jobId } = await loadFixture(deployFixture);
    const sig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, DELIVERABLE_A, sig, "0x");
    await expect(
      core.connect(provider).rejectClaim(jobId, TEN_USDC, ethers.keccak256(DELIVERABLE_A), ethers.ZeroHash, "0x")
    ).to.be.revertedWithCustomError(core, "Unauthorized");
  });

  it("fast path does not mutate pending slow claim", async function () {
    const { usdc, core, client, provider, jobId } = await loadFixture(deployFixture);

    const slowSig = await signClaim({ core, signer: client, jobId, cumulativeAmount: FIVE_USDC, deliverable: DELIVERABLE_A });
    await core.connect(provider).submitClaim(jobId, FIVE_USDC, DELIVERABLE_A, slowSig, "0x");
    expect(await core.pendingClaimHash(jobId)).to.equal(claimBindingHash(FIVE_USDC, DELIVERABLE_A));

    const fastSig = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: EMPTY });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY, fastSig, "0x");

    expect(await core.pendingClaimHash(jobId)).to.equal(claimBindingHash(FIVE_USDC, DELIVERABLE_A));
    expect(await usdc.balanceOf(provider.address)).to.equal(TEN_USDC);
  });

  it("monotonic: second claim must exceed settledAmount", async function () {
    const { core, client, provider, jobId } = await loadFixture(deployFixture);
    const sig1 = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC, deliverable: EMPTY });
    await core.connect(provider).submitClaim(jobId, TEN_USDC, EMPTY, sig1, "0x");

    const stale = await signClaim({ core, signer: client, jobId, cumulativeAmount: FIVE_USDC, deliverable: EMPTY });
    await expect(core.connect(provider).submitClaim(jobId, FIVE_USDC, EMPTY, stale, "0x"))
      .to.be.revertedWithCustomError(core, "NoNewSettlement");

    const sig2 = await signClaim({ core, signer: client, jobId, cumulativeAmount: TEN_USDC + FIVE_USDC, deliverable: EMPTY });
    await expect(core.connect(provider).submitClaim(jobId, TEN_USDC + FIVE_USDC, EMPTY, sig2, "0x"))
      .to.emit(core, "ClaimSubmitted");
  });
});
