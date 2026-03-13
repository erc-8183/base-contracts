const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

/**
 * MultiPartyEvaluator Integration Tests
 * 
 * Tests the ERC-8001 + ERC-8183 integration pattern where a MultiPartyEvaluator
 * coordinates multi-party acceptance before completing or rejecting ERC-8183 jobs.
 */
describe("MultiPartyEvaluator", function () {
  const TEN_USDC = 10_000_000n; // 10 USDC (6 decimals)

  async function deployFixture() {
    const [deployer, client, provider, arbiter] = await ethers.getSigners();

    // Deploy MockUSDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();

    // Deploy AgenticCommerce (ERC-8183)
    const AgenticCommerce = await ethers.getContractFactory("AgenticCommerce");
    const agenticCommerce = await upgrades.deployProxy(
      AgenticCommerce,
      [await usdc.getAddress(), deployer.address],
      { kind: 'uups' }
    );

    // Deploy MultiPartyEvaluator (ERC-8001)
    const MultiPartyEvaluator = await ethers.getContractFactory("MultiPartyEvaluator");
    const evaluator = await MultiPartyEvaluator.deploy();

    // Mint USDC to client
    await usdc.mint(client.address, TEN_USDC);

    // Client approves AgenticCommerce to spend USDC
    await usdc.connect(client).approve(await agenticCommerce.getAddress(), TEN_USDC);

    return { usdc, agenticCommerce, evaluator, deployer, client, provider, arbiter };
  }

  describe("Coordination Lifecycle", function () {
    it("should complete job after all participants accept", async function () {
      const { usdc, agenticCommerce, evaluator, deployer, client, provider, arbiter } =
        await loadFixture(deployFixture);

      const agenticCommerceAddr = await agenticCommerce.getAddress();
      const evaluatorAddr = await evaluator.getAddress();

      // Step 1: Create job with evaluator as the decision maker
      const expiry = (await time.latest()) + 3600; // 1 hour from now
      await agenticCommerce
        .connect(client)
        .createJob(
          provider.address,
          evaluatorAddr,
          expiry,
          "Build dApp frontend",
          ethers.ZeroAddress
        );

      const jobId = 1n;

      // Step 2: Provider sets budget and client funds
      await agenticCommerce.connect(provider).setBudget(jobId, TEN_USDC, "0x");
      await agenticCommerce.connect(client).fund(jobId, "0x");

      // Step 3: Provider submits work
      const deliverableHash = ethers.keccak256(ethers.toUtf8Bytes("frontend code"));
      await agenticCommerce.connect(provider).submit(jobId, deliverableHash, "0x");

      // Step 4: Build ERC-8001 coordination intent
      // Participants MUST include agentId (deployer) per ERC-8001 spec
      const participants = [deployer.address, client.address, provider.address, arbiter.address]
        .sort((a, b) => (BigInt(a) > BigInt(b) ? 1 : -1));

      const coordinationType = ethers.keccak256(ethers.toUtf8Bytes("COMPLETE_JOB"));
      
      // Build payload
      const payload = {
        version: ethers.keccak256(ethers.toUtf8Bytes("v1")),
        coordinationType: coordinationType,
        coordinationData: ethers.toUtf8Bytes(JSON.stringify({ jobId: Number(jobId) })),
        conditionsHash: ethers.ZeroHash,
        timestamp: await time.latest(),
        metadata: "0x"
      };

      // Get payload hash (must match contract's _hashPayload)
      // Contract hashes coordinationData and metadata first, then encodes all fields
      const coordinationDataHash = ethers.keccak256(payload.coordinationData);
      const metadataHash = ethers.keccak256(payload.metadata);
      const payloadHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "bytes32"],
          [payload.version, payload.coordinationType, coordinationDataHash, payload.conditionsHash, payload.timestamp, metadataHash]
        )
      );

      // Build intent
      const intent = {
        payloadHash: payloadHash,
        expiry: (await time.latest()) + 1800, // 30 minutes
        nonce: 1n,
        agentId: deployer.address,
        coordinationType: coordinationType,
        coordinationValue: 0n,
        participants: participants
      };

      // Sign intent
      const domain = {
        name: "ERC-8001",
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: evaluatorAddr
      };

      const intentTypes = {
        AgentIntent: [
          { name: "payloadHash", type: "bytes32" },
          { name: "expiry", type: "uint64" },
          { name: "nonce", type: "uint64" },
          { name: "agentId", type: "address" },
          { name: "coordinationType", type: "bytes32" },
          { name: "coordinationValue", type: "uint256" },
          { name: "participants", type: "address[]" }
        ]
      };

      const intentSignature = await deployer.signTypedData(domain, intentTypes, intent);

      // Step 5: Propose coordination
      const jobConfig = {
        erc8183JobId: jobId,
        agenticCommerce: agenticCommerceAddr,
        actionType: 1, // complete
        reason: ethers.keccak256(ethers.toUtf8Bytes("Work approved"))
      };

      // Call proposeJobCoordination and capture return value
      const intentHash = await evaluator.proposeJobCoordination.staticCall(
        intent,
        intentSignature,
        payload,
        jobConfig
      );
      
      // Execute the transaction
      const tx = await evaluator.proposeJobCoordination(
        intent,
        intentSignature,
        payload,
        jobConfig
      );
      await tx.wait();

      // Verify coordination is Proposed
      const statusBefore = await evaluator.getCoordinationStatus(intentHash);
      expect(statusBefore.status).to.equal(1n); // Proposed

      // Step 6: Participants accept (deployer auto-accepted as proposer)
      // Client accepts
      const clientAttestation = await createAcceptanceAttestation(
        intentHash,
        client.address,
        domain,
        evaluator,
        participants
      );
      await evaluator.connect(client).acceptCoordination(intentHash, clientAttestation);

      // Provider accepts
      const providerAttestation = await createAcceptanceAttestation(
        intentHash,
        provider.address,
        domain,
        evaluator,
        participants
      );
      await evaluator.connect(provider).acceptCoordination(intentHash, providerAttestation);

      // Arbiter accepts
      const arbiterAttestation = await createAcceptanceAttestation(
        intentHash,
        arbiter.address,
        domain,
        evaluator,
        participants
      );
      await evaluator.connect(arbiter).acceptCoordination(intentHash, arbiterAttestation);

      // Verify coordination is Ready
      const statusAfter = await evaluator.getCoordinationStatus(intentHash);
      expect(statusAfter.status).to.equal(2n); // Ready

      // Step 7: Execute coordination
      await expect(evaluator.executeJobCoordination(intentHash, payload, "0x"))
        .to.emit(agenticCommerce, "JobCompleted")
        .withArgs(jobId, evaluatorAddr, jobConfig.reason);

      // Verify job is completed
      const job = await agenticCommerce.getJob(jobId);
      expect(job.status).to.equal(3n); // Completed

      // Verify provider received payment
      const providerBalance = await usdc.balanceOf(provider.address);
      expect(providerBalance).to.be.gt(0n);
    });

    it("should reject job after all participants accept", async function () {
      const { usdc, agenticCommerce, evaluator, deployer, client, provider, arbiter } =
        await loadFixture(deployFixture);

      const agenticCommerceAddr = await agenticCommerce.getAddress();
      const evaluatorAddr = await evaluator.getAddress();

      // Create and fund job
      const expiry = (await time.latest()) + 3600;
      await agenticCommerce
        .connect(client)
        .createJob(provider.address, evaluatorAddr, expiry, "Build dApp", ethers.ZeroAddress);

      const jobId = 1n;
      await agenticCommerce.connect(provider).setBudget(jobId, TEN_USDC, "0x");
      await agenticCommerce.connect(client).fund(jobId, "0x");
      await agenticCommerce.connect(provider).submit(jobId, ethers.randomBytes(32), "0x");

      // Build rejection coordination
      // Participants MUST include agentId (deployer) per ERC-8001 spec
      const participants = [deployer.address, client.address, provider.address, arbiter.address]
        .sort((a, b) => (BigInt(a) > BigInt(b) ? 1 : -1));

      const coordinationType = ethers.keccak256(ethers.toUtf8Bytes("REJECT_JOB"));
      
      const payload = {
        version: ethers.keccak256(ethers.toUtf8Bytes("v1")),
        coordinationType: coordinationType,
        coordinationData: ethers.toUtf8Bytes(JSON.stringify({ jobId: Number(jobId) })),
        conditionsHash: ethers.ZeroHash,
        timestamp: await time.latest(),
        metadata: "0x"
      };

      // Get payload hash (must match contract's _hashPayload)
      const coordinationDataHash = ethers.keccak256(payload.coordinationData);
      const metadataHash = ethers.keccak256(payload.metadata);
      const payloadHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "bytes32"],
          [payload.version, payload.coordinationType, coordinationDataHash, payload.conditionsHash, payload.timestamp, metadataHash]
        )
      );

      const intent = {
        payloadHash: payloadHash,
        expiry: (await time.latest()) + 1800,
        nonce: 1n,
        agentId: deployer.address,
        coordinationType: coordinationType,
        coordinationValue: 0n,
        participants: participants
      };

      const domain = {
        name: "ERC-8001",
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: evaluatorAddr
      };

      const intentTypes = {
        AgentIntent: [
          { name: "payloadHash", type: "bytes32" },
          { name: "expiry", type: "uint64" },
          { name: "nonce", type: "uint64" },
          { name: "agentId", type: "address" },
          { name: "coordinationType", type: "bytes32" },
          { name: "coordinationValue", type: "uint256" },
          { name: "participants", type: "address[]" }
        ]
      };

      const intentSignature = await deployer.signTypedData(domain, intentTypes, intent);

      const jobConfig = {
        erc8183JobId: jobId,
        agenticCommerce: agenticCommerceAddr,
        actionType: 2, // reject
        reason: ethers.keccak256(ethers.toUtf8Bytes("Work rejected"))
      };

      // Call proposeJobCoordination and capture return value
      const intentHash = await evaluator.proposeJobCoordination.staticCall(intent, intentSignature, payload, jobConfig);
      const tx = await evaluator.proposeJobCoordination(intent, intentSignature, payload, jobConfig);
      await tx.wait();

      // All participants accept
      for (const participant of [client, provider, arbiter]) {
        const attestation = await createAcceptanceAttestation(
          intentHash,
          participant.address,
          domain,
          evaluator,
          participants
        );
        await evaluator.connect(participant).acceptCoordination(intentHash, attestation);
      }

      // Get client balance before rejection
      const clientBalanceBefore = await usdc.balanceOf(client.address);

      // Execute rejection
      await expect(evaluator.executeJobCoordination(intentHash, payload, "0x"))
        .to.emit(agenticCommerce, "JobRejected");

      // Verify job is rejected
      const job = await agenticCommerce.getJob(jobId);
      expect(job.status).to.equal(4n); // Rejected

      // Verify client got refund
      const clientBalanceAfter = await usdc.balanceOf(client.address);
      expect(clientBalanceAfter).to.equal(clientBalanceBefore + TEN_USDC);
    });

    it("should not allow execution before all participants accept", async function () {
      const { agenticCommerce, evaluator, deployer, client, provider } =
        await loadFixture(deployFixture);

      const evaluatorAddr = await evaluator.getAddress();

      // Create job
      const expiry = (await time.latest()) + 3600;
      await agenticCommerce
        .connect(client)
        .createJob(provider.address, evaluatorAddr, expiry, "Build dApp", ethers.ZeroAddress);

      const jobId = 1n;
      await agenticCommerce.connect(provider).setBudget(jobId, TEN_USDC, "0x");
      await agenticCommerce.connect(client).fund(jobId, "0x");
      await agenticCommerce.connect(provider).submit(jobId, ethers.randomBytes(32), "0x");

      // Build coordination
      // Participants MUST include agentId (deployer) per ERC-8001 spec
      const participants = [deployer.address, client.address, provider.address].sort((a, b) => (BigInt(a) > BigInt(b) ? 1 : -1));
      const coordinationType = ethers.keccak256(ethers.toUtf8Bytes("COMPLETE_JOB"));
      
      const payload = {
        version: ethers.keccak256(ethers.toUtf8Bytes("v1")),
        coordinationType: coordinationType,
        coordinationData: "0x",
        conditionsHash: ethers.ZeroHash,
        timestamp: await time.latest(),
        metadata: "0x"
      };

      // Get payload hash (must match contract's _hashPayload)
      const coordinationDataHash = ethers.keccak256(payload.coordinationData);
      const metadataHash = ethers.keccak256(payload.metadata);
      const payloadHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "bytes32"],
          [payload.version, payload.coordinationType, coordinationDataHash, payload.conditionsHash, payload.timestamp, metadataHash]
        )
      );

      const intent = {
        payloadHash: payloadHash,
        expiry: (await time.latest()) + 1800,
        nonce: 1n,
        agentId: deployer.address,
        coordinationType: coordinationType,
        coordinationValue: 0n,
        participants: participants
      };

      const domain = {
        name: "ERC-8001",
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: evaluatorAddr
      };

      const intentTypes = {
        AgentIntent: [
          { name: "payloadHash", type: "bytes32" },
          { name: "expiry", type: "uint64" },
          { name: "nonce", type: "uint64" },
          { name: "agentId", type: "address" },
          { name: "coordinationType", type: "bytes32" },
          { name: "coordinationValue", type: "uint256" },
          { name: "participants", type: "address[]" }
        ]
      };

      const intentSignature = await deployer.signTypedData(domain, intentTypes, intent);

      const jobConfig = {
        erc8183JobId: jobId,
        agenticCommerce: await agenticCommerce.getAddress(),
        actionType: 1,
        reason: ethers.keccak256(ethers.toUtf8Bytes("Complete"))
      };

      // Call proposeJobCoordination and capture return value
      const intentHash = await evaluator.proposeJobCoordination.staticCall(intent, intentSignature, payload, jobConfig);
      const tx = await evaluator.proposeJobCoordination(intent, intentSignature, payload, jobConfig);
      await tx.wait();

      // Only client accepts (deployer auto-accepted, client accepts, provider hasn't)
      const clientAttestation = await createAcceptanceAttestation(
        intentHash,
        client.address,
        domain,
        evaluator,
        participants
      );
      await evaluator.connect(client).acceptCoordination(intentHash, clientAttestation);

      // Verify status is still Proposed (not Ready)
      const status = await evaluator.getCoordinationStatus(intentHash);
      expect(status.status).to.equal(1n); // Proposed

      // Try to execute - should fail
      await expect(
        evaluator.executeJobCoordination(intentHash, payload, "0x")
      ).to.be.revertedWithCustomError(evaluator, "ERC8001_NotReady");
    });
  });

  // Helper function to create acceptance attestations
  async function createAcceptanceAttestation(intentHash, participant, domain, evaluator, participants) {
    const attestationTypes = {
      AcceptanceAttestation: [
        { name: "intentHash", type: "bytes32" },
        { name: "participant", type: "address" },
        { name: "nonce", type: "uint64" },
        { name: "expiry", type: "uint64" },
        { name: "conditionsHash", type: "bytes32" }
      ]
    };

    const attestation = {
      intentHash: intentHash,
      participant: participant,
      nonce: 0n,
      expiry: (await time.latest()) + 3600,
      conditionsHash: ethers.ZeroHash
    };

    const signer = await ethers.getSigner(participant);
    const signature = await signer.signTypedData(domain, attestationTypes, attestation);

    return {
      ...attestation,
      signature: signature
    };
  }
});
