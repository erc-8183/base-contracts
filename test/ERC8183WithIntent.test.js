const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("ERC8183WithIntent", function () {
  const TWENTY_USDC = 20_000_000n;

  async function deployFixture() {
    const [deployer, client, provider, evaluator, relayer] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();

    const Core = await ethers.getContractFactory("ERC8183WithIntent");
    const core = await upgrades.deployProxy(Core, [deployer.address, deployer.address], { kind: "uups" });
    const coreAddr = await core.getAddress();

    await core.connect(deployer).setPaymentTokenAllowed(await usdc.getAddress(), true);
    await usdc.mint(client.address, TWENTY_USDC);
    await usdc.connect(client).approve(coreAddr, TWENTY_USDC);

    return { usdc, core, deployer, client, provider, evaluator, relayer };
  }

  async function signIntent(core, signerWallet, typeName, value) {
    const domain = {
      name: "ERC8183WithIntent",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: await core.getAddress(),
    };
    const types = {
      CreateJobIntent: [
        { name: "signer", type: "address" },
        { name: "provider", type: "address" },
        { name: "evaluator", type: "address" },
        { name: "expiredAt", type: "uint48" },
        { name: "descriptionHash", type: "bytes32" },
        { name: "hook", type: "address" },
        { name: "providerAgentId", type: "uint256" },
        { name: "nonce", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
      SetBudgetIntent: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
      FundIntent: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "expectedBudget", type: "uint256" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
      SubmitIntent: [
        { name: "signer", type: "address" },
        { name: "jobId", type: "uint256" },
        { name: "deliverable", type: "bytes32" },
        { name: "optParamsHash", type: "bytes32" },
        { name: "nonce", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
    };
    return signerWallet.signTypedData(domain, { [typeName]: types[typeName] }, value);
  }

  function nonce(value) {
    return ethers.zeroPadValue(ethers.toBeHex(value), 32);
  }

  function hashBytes(value) {
    return ethers.keccak256(value);
  }

  function hashString(value) {
    return ethers.keccak256(ethers.toUtf8Bytes(value));
  }

  it("relays a full signed job flow", async function () {
    const { usdc, core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);

    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const description = "intent image job";
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
    const createSig = await signIntent(
      core,
      client,
      "CreateJobIntent",
      {
        signer: client.address,
        provider: provider.address,
        evaluator: evaluator.address,
        expiredAt: expiry,
        descriptionHash: hashString(description),
        hook,
        providerAgentId: 0,
        nonce: nonce(1),
        deadline,
      },
    );

    await expect(
      core.connect(relayer).createJobWithIntent(createParams, {
        signer: client.address,
        nonce: nonce(1),
        deadline,
        sig: createSig,
      }),
    ).to.emit(core, "IntentExecuted").withArgs(client.address, nonce(1));

    const jobId = 1n;
    expect((await core.getJob(jobId)).client).to.equal(client.address);

    const setBudgetSig = await signIntent(
      core,
      provider,
      "SetBudgetIntent",
      {
        signer: provider.address,
        jobId,
        token: usdcAddr,
        amount: TWENTY_USDC,
        optParamsHash: hashBytes(optParams),
        nonce: nonce(2),
        deadline,
      },
    );
    await core.connect(relayer).setBudgetWithIntent(jobId, usdcAddr, TWENTY_USDC, optParams, {
      signer: provider.address,
      nonce: nonce(2),
      deadline,
      sig: setBudgetSig,
    });

    const fundSig = await signIntent(core, client, "FundIntent", {
      signer: client.address,
      jobId,
      expectedBudget: TWENTY_USDC,
      optParamsHash: hashBytes(optParams),
      nonce: nonce(3),
      deadline,
    });
    await core.connect(relayer).fundWithIntent(jobId, TWENTY_USDC, optParams, {
      signer: client.address,
      nonce: nonce(3),
      deadline,
      sig: fundSig,
    });

    const deliverable = ethers.encodeBytes32String("done");
    const submitSig = await signIntent(core, provider, "SubmitIntent", {
      signer: provider.address,
      jobId,
      deliverable,
      optParamsHash: hashBytes(optParams),
      nonce: nonce(4),
      deadline,
    });
    await core.connect(relayer).submitWithIntent(jobId, deliverable, optParams, {
      signer: provider.address,
      nonce: nonce(4),
      deadline,
      sig: submitSig,
    });

    const reason = ethers.encodeBytes32String("approved");
    await core.connect(evaluator).complete(jobId, reason, optParams);

    expect((await core.getJob(jobId)).status).to.equal(3n);
    expect(await usdc.balanceOf(provider.address)).to.equal(TWENTY_USDC);
  });

  it("rejects replayed, expired, and tampered intents", async function () {
    const { core, client, provider, evaluator, relayer } = await loadFixture(deployFixture);
    const expiry = (await time.latest()) + 3600;
    const deadline = (await time.latest()) + 7200;
    const description = "replay test";
    const authNonce = nonce(11);
    const params = {
      provider: provider.address,
      evaluator: evaluator.address,
      expiredAt: expiry,
      description,
      hook: ethers.ZeroAddress,
      providerAgentId: 0,
    };
    const sig = await signIntent(
      core,
      client,
      "CreateJobIntent",
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

    await core.connect(relayer).createJobWithIntent(params, auth);
    await expect(core.connect(relayer).createJobWithIntent(params, auth))
      .to.be.revertedWithCustomError(core, "IntentNonceUsed");

    const expiredDeadline = (await time.latest()) - 1;
    const expiredNonce = nonce(12);
    const expiredSig = await signIntent(
      core,
      client,
      "CreateJobIntent",
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
      core.connect(relayer).createJobWithIntent(
        { ...params, description: "expired" },
        { signer: client.address, nonce: expiredNonce, deadline: expiredDeadline, sig: expiredSig },
      ),
    ).to.be.revertedWithCustomError(core, "IntentExpired");

    const tamperedNonce = nonce(13);
    const tamperedSig = await signIntent(
      core,
      client,
      "CreateJobIntent",
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
      core.connect(relayer).createJobWithIntent(
        { ...params, description: "tampered" },
        { signer: client.address, nonce: tamperedNonce, deadline, sig: tamperedSig },
      ),
    ).to.be.revertedWithCustomError(core, "InvalidIntentSignature");
  });
});
