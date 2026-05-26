const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("ERC8183WithAuthorization", function () {
  const TWENTY_USDC = 20_000_000n;
  const TEN_USDC = 10_000_000n;
  const MAX_UINT72 = (1n << 72n) - 1n;

  async function deployFixture() {
    const [deployer, client, provider, evaluator, relayer] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();

    const Core = await ethers.getContractFactory("ERC8183WithAuthorization");
    const core = await upgrades.deployProxy(Core, [deployer.address, deployer.address], { kind: "uups" });
    const coreAddr = await core.getAddress();

    await core.connect(deployer).setPaymentTokenAllowed(await usdc.getAddress(), true);
    await usdc.mint(client.address, TWENTY_USDC);
    await usdc.connect(client).approve(coreAddr, TWENTY_USDC);

    return { usdc, core, deployer, client, provider, evaluator, relayer };
  }

  async function signAuthorization(core, signerWallet, typeName, value) {
    const domain = {
      name: "ERC8183WithAuthorization",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: await core.getAddress(),
    };
    const types = {
      CreateJobAuthorization: [
        { name: "signer", type: "address" },
        { name: "provider", type: "address" },
        { name: "evaluator", type: "address" },
        { name: "expiredAt", type: "uint48" },
        { name: "descriptionHash", type: "bytes32" },
        { name: "hook", type: "address" },
        { name: "providerAgentId", type: "uint256" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      SetProviderAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "provider", type: "address" },
        { name: "agentId", type: "uint256" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      SetBudgetAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      FundAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "expectedBudget", type: "uint256" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      SubmitAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "deliverable", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      CompleteAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "reason", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      RejectAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "reason", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      SubmitClaimAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "cumulativeAmount", type: "uint256" },
        { name: "deliverable", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      ApproveClaimAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "cumulativeAmount", type: "uint256" },
        { name: "deliverable", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
      RejectClaimAuthorization: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "cumulativeAmount", type: "uint256" },
        { name: "deliverable", type: "bytes32" },
        { name: "reason", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "uint72" },
        { name: "deadline", type: "uint256" },
      ],
    };
    return signerWallet.signTypedData(domain, { [typeName]: types[typeName] }, value);
  }

  function packedNonce(signer, value) {
    const nonceValue = ethers.zeroPadValue(ethers.toBeHex(value), 12);
    return ethers.concat([signer, nonceValue]);
  }

  function hashBytes(value) {
    return ethers.keccak256(value);
  }

  function hashString(value) {
    return ethers.keccak256(ethers.toUtf8Bytes(value));
  }

  const claimBindingHash = (amount, deliverable, optParams = "0x") =>
    ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "bytes32", "bytes32"],
        [amount, deliverable, ethers.keccak256(optParams)]
      )
    );

  it("relays a full signed job flow", async function () {
    const { usdc, core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);

    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const description = "authorization image job";
    const hook = ethers.ZeroAddress;
    const optParams = "0x";
    const usdcAddr = await usdc.getAddress();

    const createParams = {
      provider: provider.address,
      evaluator: evaluator.address,
      expiredAt: expiry,
      description,
      hook,
      providerAgentId: 0,
    };
    const createSig = await signAuthorization(
      core,
      client,
      "CreateJobAuthorization",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString(description),
        hook,
        providerAgentId: 0,
        nonce: 1n,
        deadline,
      },
    );

    await expect(
      core.connect(relayer).createJobWithAuthorization(createParams, {
        signer: client.address,
        nonce: 1n,
        deadline,
        sig: createSig,
      }),
    ).to.emit(core, "AuthorizationUsed").withArgs(client.address, packedNonce(client.address, 1n));

    const jobId = 1n;
    expect((await core.getJob(jobId)).client).to.equal(client.address);

    const setBudgetSig = await signAuthorization(
      core,
      provider,
      "SetBudgetAuthorization",
      {
        signer: provider.address,
        jobId,
        token: usdcAddr,
        amount: TWENTY_USDC,
        optParamsHash: hashBytes(optParams),
        nonce: 2n,
        deadline,
      },
    );
    await core.connect(relayer).setBudgetWithAuthorization(jobId, usdcAddr, TWENTY_USDC, optParams, {
      signer: provider.address,
      nonce: 2n,
      deadline,
      sig: setBudgetSig,
    });

    const fundSig = await signAuthorization(core, client, "FundAuthorization", {
      signer: client.address,
      jobId,
      expectedBudget: TWENTY_USDC,
      optParamsHash: hashBytes(optParams),
      nonce: 3n,
      deadline,
    });
    await core.connect(relayer).fundWithAuthorization(jobId, TWENTY_USDC, optParams, {
      signer: client.address,
      nonce: 3n,
      deadline,
      sig: fundSig,
    });

    const deliverable = ethers.encodeBytes32String("done");
    const submitSig = await signAuthorization(core, provider, "SubmitAuthorization", {
      signer: provider.address,
      jobId,
      deliverable,
      optParamsHash: hashBytes(optParams),
      nonce: 4n,
      deadline,
    });
    await core.connect(relayer).submitWithAuthorization(jobId, deliverable, optParams, {
      signer: provider.address,
      nonce: 4n,
      deadline,
      sig: submitSig,
    });

    const reason = ethers.encodeBytes32String("approved");
    const completeSig = await signAuthorization(core, evaluator, "CompleteAuthorization", {
      signer: evaluator.address,
      jobId,
      reason,
      optParamsHash: hashBytes(optParams),
      nonce: 5n,
      deadline,
    });
    await core.connect(relayer).completeWithAuthorization(jobId, reason, optParams, {
      signer: evaluator.address,
      nonce: 5n,
      deadline,
      sig: completeSig,
    });

    expect((await core.getJob(jobId)).status).to.equal(3n);
    expect(await usdc.balanceOf(provider.address)).to.equal(TWENTY_USDC);
  });

  it("relays a client-authorized nonzero claim into pending state and approval", async function () {
    const { usdc, core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);
    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const optParams = "0x1234";
    const deliverable = ethers.encodeBytes32String("milestone-1");
    const usdcAddr = await usdc.getAddress();

    await core.connect(client).createJob(provider.address, evaluator.address, expiry, "claim auth job", ethers.ZeroAddress, 0);
    const jobId = 1n;
    await core.connect(provider).setBudget(jobId, usdcAddr, TWENTY_USDC, "0x");
    await core.connect(client).fund(jobId, TWENTY_USDC, "0x");

    const submitClaimSig = await signAuthorization(core, client, "SubmitClaimAuthorization", {
      signer: client.address,
      jobId,
      cumulativeAmount: TEN_USDC,
      deliverable,
      optParamsHash: hashBytes(optParams),
      nonce: 21n,
      deadline,
    });

    await expect(core.connect(relayer).submitClaimWithAuthorization(
      jobId,
      TEN_USDC,
      deliverable,
      optParams,
      {
        signer: client.address,
        nonce: 21n,
        deadline,
        sig: submitClaimSig,
      },
    ))
      .to.emit(core, "AuthorizationUsed").withArgs(client.address, packedNonce(client.address, 21n))
      .to.emit(core, "ClaimSubmitted").withArgs(jobId, client.address, TEN_USDC, TEN_USDC, deliverable);

    expect((await core.getJob(jobId)).settledAmount).to.equal(0n);
    expect(await core.pendingClaimHash(jobId)).to.equal(claimBindingHash(TEN_USDC, deliverable, optParams));
    expect(await usdc.balanceOf(provider.address)).to.equal(0n);

    const approveClaimSig = await signAuthorization(core, evaluator, "ApproveClaimAuthorization", {
      signer: evaluator.address,
      jobId,
      cumulativeAmount: TEN_USDC,
      deliverable,
      optParamsHash: hashBytes(optParams),
      nonce: 22n,
      deadline,
    });

    await expect(core.connect(relayer).approveClaimWithAuthorization(
      jobId,
      TEN_USDC,
      deliverable,
      optParams,
      {
        signer: evaluator.address,
        nonce: 22n,
        deadline,
        sig: approveClaimSig,
      },
    ))
      .to.emit(core, "AuthorizationUsed").withArgs(evaluator.address, packedNonce(evaluator.address, 22n))
      .to.emit(core, "ClaimApproved").withArgs(jobId, evaluator.address, TEN_USDC, TEN_USDC, deliverable);

    expect((await core.getJob(jobId)).settledAmount).to.equal(TEN_USDC);
    expect(await core.pendingClaimHash(jobId)).to.equal(ethers.ZeroHash);
    expect(await usdc.balanceOf(provider.address)).to.equal(TEN_USDC);
  });

  it("rejects replayed, expired, and tampered authorizations", async function () {
    const { core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);
    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const description = "replay test";
    const authNonce = 11n;
    const params = {
      provider: provider.address,
      evaluator: evaluator.address,
      expiredAt: expiry,
      description,
      hook: ethers.ZeroAddress,
      providerAgentId: 0,
    };
    const sig = await signAuthorization(
      core,
      client,
      "CreateJobAuthorization",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString(description),
        hook: ethers.ZeroAddress,
        providerAgentId: 0,
        nonce: authNonce,
        deadline,
      },
    );
    const auth = { signer: client.address, nonce: authNonce, deadline, sig };

    await core.connect(relayer).createJobWithAuthorization(params, auth);
    expect(await core.authorizationNonceUsed(packedNonce(client.address, authNonce))).to.equal(true);
    await expect(core.connect(relayer).createJobWithAuthorization(params, auth))
      .to.be.revertedWithCustomError(core, "AuthorizationNonceUsed");

    const expiredDeadline = (await time.latest()) - 1;
    const expiredNonce = 12n;
    const expiredSig = await signAuthorization(
      core,
      client,
      "CreateJobAuthorization",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString("expired"),
        hook: ethers.ZeroAddress,
        providerAgentId: 0,
        nonce: expiredNonce,
        deadline: expiredDeadline,
      },
    );
    await expect(
      core.connect(relayer).createJobWithAuthorization(
        { ...params, description: "expired" },
        { signer: client.address, nonce: expiredNonce, deadline: expiredDeadline, sig: expiredSig },
      ),
    ).to.be.revertedWithCustomError(core, "AuthorizationExpired");

    const tamperedNonce = 13n;
    const tamperedSig = await signAuthorization(
      core,
      client,
      "CreateJobAuthorization",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString("signed"),
        hook: ethers.ZeroAddress,
        providerAgentId: 0,
        nonce: tamperedNonce,
        deadline,
      },
    );
    await expect(
      core.connect(relayer).createJobWithAuthorization(
        { ...params, description: "tampered" },
        { signer: client.address, nonce: tamperedNonce, deadline, sig: tamperedSig },
      ),
    ).to.be.revertedWithCustomError(core, "InvalidAuthorizationSignature");
    expect(await core.authorizationNonceUsed(packedNonce(client.address, tamperedNonce))).to.equal(false);
  });

  it("reserves the packed nonce before ERC-1271 signature validation", async function () {
    const { core, provider, evaluator, relayer } = await loadFixture(deployFixture);
    const ContractSigner = await ethers.getContractFactory("MockERC1271NonceObserver");
    const contractSigner = await ContractSigner.deploy();
    const signerAddress = await contractSigner.getAddress();
    const coreAddress = await core.getAddress();
    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const nonce = 31n;
    const packed = packedNonce(signerAddress, nonce);
    const description = "erc1271 nonce reservation";
    const params = {
      provider: provider.address,
      evaluator: evaluator.address,
      expiredAt: expiry,
      description,
      hook: ethers.ZeroAddress,
      providerAgentId: 0,
    };
    const sig = ethers.AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [coreAddress, packed]);

    await expect(
      core.connect(relayer).createJobWithAuthorization(params, {
        signer: signerAddress,
        nonce,
        deadline,
        sig,
      }),
    ).to.emit(core, "AuthorizationUsed").withArgs(signerAddress, packed);

    expect(await core.authorizationNonceUsed(packed)).to.equal(true);
    expect((await core.getJob(1n)).client).to.equal(signerAddress);
  });

  it("accepts the maximum uint72 nonce and stores its packed key", async function () {
    const { core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);
    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const description = "max nonce";
    const params = {
      provider: provider.address,
      evaluator: evaluator.address,
      expiredAt: expiry,
      description,
      hook: ethers.ZeroAddress,
      providerAgentId: 0,
    };
    const sig = await signAuthorization(
      core,
      client,
      "CreateJobAuthorization",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString(description),
        hook: ethers.ZeroAddress,
        providerAgentId: 0,
        nonce: MAX_UINT72,
        deadline,
      },
    );
    const packed = packedNonce(client.address, MAX_UINT72);

    await expect(
      core.connect(relayer).createJobWithAuthorization(
        params,
        { signer: client.address, nonce: MAX_UINT72, deadline, sig },
      ),
    ).to.emit(core, "AuthorizationUsed").withArgs(client.address, packed);
    expect(await core.authorizationNonceUsed(packed)).to.equal(true);
  });

  it("allows different signers to use the same numeric nonce", async function () {
    const { usdc, core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);
    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const description = "shared nonce";
    const sharedNonce = 42n;
    const params = {
      provider: provider.address,
      evaluator: evaluator.address,
      expiredAt: expiry,
      description,
      hook: ethers.ZeroAddress,
      providerAgentId: 0,
    };
    const createSig = await signAuthorization(
      core,
      client,
      "CreateJobAuthorization",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString(description),
        hook: ethers.ZeroAddress,
        providerAgentId: 0,
        nonce: sharedNonce,
        deadline,
      },
    );
    await core.connect(relayer).createJobWithAuthorization(params, {
      signer: client.address,
      nonce: sharedNonce,
      deadline,
      sig: createSig,
    });

    const jobId = 1n;
    const usdcAddr = await usdc.getAddress();
    const setBudgetSig = await signAuthorization(
      core,
      provider,
      "SetBudgetAuthorization",
      {
        signer: provider.address,
        jobId,
        token: usdcAddr,
        amount: TWENTY_USDC,
        optParamsHash: hashBytes("0x"),
        nonce: sharedNonce,
        deadline,
      },
    );

    await expect(
      core.connect(relayer).setBudgetWithAuthorization(jobId, usdcAddr, TWENTY_USDC, "0x", {
        signer: provider.address,
        nonce: sharedNonce,
        deadline,
        sig: setBudgetSig,
      }),
    ).to.emit(core, "AuthorizationUsed").withArgs(provider.address, packedNonce(provider.address, sharedNonce));
    expect(await core.authorizationNonceUsed(packedNonce(client.address, sharedNonce))).to.equal(true);
    expect(await core.authorizationNonceUsed(packedNonce(provider.address, sharedNonce))).to.equal(true);
  });

});
