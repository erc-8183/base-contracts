# ERC-8001 + ERC-8183 Integration

This document describes how ERC-8001 (Agent Coordination Framework) can be composed with ERC-8183 (Agentic Commerce Protocol) to create multi-party job settlement with decentralized coordination.

## Overview

**ERC-8001** provides a minimal primitive for multi-party coordination using EIP-712 attestations.
**ERC-8183** provides a job escrow protocol with evaluator-attested settlement.

By combining these standards, we create a powerful pattern:

- **ERC-8001** = Coordination Layer (who must agree)
- **ERC-8183** = Settlement Layer (escrow, payment, state machine)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Coordination Layer                        │
│                         (ERC-8001)                               │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              MultiPartyEvaluator Contract               │   │
│  │  - Proposes coordination intents                        │   │
│  │  - Collects acceptances from required parties           │   │
│  │  - Executes action when consensus reached                 │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ calls complete() / reject()
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Settlement Layer                        │
│                         (ERC-8183)                               │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              AgenticCommerce Contract                     │   │
│  │  - Holds escrowed funds                                   │   │
│  │  - Manages job state machine                              │   │
│  │  - Releases payments on completion                        │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Flow: Multi-Party Job Completion

### Step 1: Job Creation

The client creates a job in `AgenticCommerce` with `MultiPartyEvaluator` as the evaluator:

```solidity
// Client creates job
agenticCommerce.createJob(
    provider,
    address(multiPartyEvaluator), // evaluator is the coordination contract
    expiry,
    description,
    hook
);
```

### Step 2: Provider Submits Work

The provider submits deliverables:

```solidity
// Provider submits
agenticCommerce.submit(jobId, deliverableHash, "");
```

### Step 3: Coordination Proposed

The evaluator owner proposes a coordination intent for completion:

```solidity
// Build ERC-8001 intent
AgentIntent memory intent = AgentIntent({
    payloadHash: keccak256(abi.encode(payload)),
    expiry: block.timestamp + 1 days,
    nonce: multiPartyEvaluator.getAgentNonce(address(this)) + 1,
    agentId: address(this),
    coordinationType: keccak256("COMPLETE_JOB"),
    coordinationValue: 0,
    participants: [client, provider, arbiter] // sorted, unique
});

// Propose coordination
multiPartyEvaluator.proposeJobCoordination(
    intent,
    signature,
    payload,
    JobConfig({
        erc8183JobId: jobId,
        agenticCommerce: address(agenticCommerce),
        actionType: 1, // complete
        reason: keccak256("Work approved")
    })
);
```

### Step 4: Participants Accept

Each required party accepts the coordination:

```solidity
// Client accepts
AcceptanceAttestation memory attestation = AcceptanceAttestation({
    intentHash: intentHash,
    participant: client,
    nonce: 0,
    expiry: block.timestamp + 12 hours,
    conditionsHash: bytes32(0),
    signature: clientSignature
});

multiPartyEvaluator.acceptCoordination(intentHash, attestation);
```

### Step 5: Execution

Once all participants accept, anyone can execute:

```solidity
// Execute coordination
multiPartyEvaluator.executeJobCoordination(intentHash, payload, "");
```

This calls `complete()` on `AgenticCommerce`, releasing payment to the provider.

## Flow: Multi-Party Job Rejection

The same pattern applies for rejection:

1. Propose coordination with `actionType: 2` (reject)
2. Required parties accept
3. Execute calls `reject()` on `AgenticCommerce`
4. Funds refunded to client

## Code Example

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import {MultiPartyEvaluator} from "./examples/MultiPartyEvaluator.sol";
import {IERC8001} from "./erc8001/interfaces/IERC8001.sol";

contract UsageExample {
    MultiPartyEvaluator public evaluator;
    AgenticCommerce public agenticCommerce;
    
    function createMultiPartyJob(
        address provider,
        address arbiter,
        uint256 expiry
    ) external returns (uint256 jobId) {
        // Create job with evaluator as the decision maker
        jobId = agenticCommerce.createJob(
            provider,
            address(evaluator),
            expiry,
            "Build dApp frontend",
            address(0)
        );
        
        // Fund the job
        agenticCommerce.fund(jobId, "");
        
        return jobId;
    }
    
    function coordinateCompletion(
        uint256 jobId,
        address client,
        address provider,
        address arbiter
    ) external {
        // Build participants array (must be sorted)
        address[] memory participants = new address[](3);
        participants[0] = client;
        participants[1] = provider;
        participants[2] = arbiter;
        
        // Build payload
        IERC8001.CoordinationPayload memory payload = IERC8001.CoordinationPayload({
            version: keccak256("v1"),
            coordinationType: keccak256("COMPLETE_JOB"),
            coordinationData: abi.encode(jobId),
            conditionsHash: bytes32(0),
            timestamp: block.timestamp,
            metadata: ""
        });
        
        // Build intent
        IERC8001.AgentIntent memory intent = IERC8001.AgentIntent({
            payloadHash: evaluator.getIntentHash(payload),
            expiry: block.timestamp + 2 days,
            nonce: evaluator.getAgentNonce(address(this)) + 1,
            agentId: address(this),
            coordinationType: keccak256("COMPLETE_JOB"),
            coordinationValue: 0,
            participants: participants
        });
        
        // Propose coordination
        bytes32 intentHash = evaluator.proposeJobCoordination(
            intent,
            signature,
            payload,
            MultiPartyEvaluator.JobConfig({
                erc8183JobId: jobId,
                agenticCommerce: address(agenticCommerce),
                actionType: 1, // complete
                reason: keccak256("All parties satisfied")
            })
        );
    }
}
```

## Benefits

1. **Decentralized Coordination**: No single party controls the outcome
2. **Flexible Requirements**: Configure which parties must agree (client + provider, or + arbiter, etc.)
3. **Composable**: Works with any ERC-8183 implementation
4. **Standardized**: Uses EIP-712 for wallet compatibility
5. **Extensible**: Can add reputation, bonding, privacy modules per ERC-8001 spec

## Security Considerations

- **Expiry Management**: Both ERC-8001 intent and ERC-8183 job have expiry; ensure coordination completes before job expires
- **Participant Sorting**: ERC-8001 requires participants be strictly ascending by uint160(address)
- **Signature Verification**: All acceptances must be valid EIP-712 signatures or ERC-1271 contract signatures
- **Reentrancy**: The MultiPartyEvaluator uses the same reentrancy protection patterns as the base ERC-8001 implementation

## Future Extensions

- **ERC-8004 Reputation**: Track evaluator performance
- **Threshold Policies**: Require only subset of participants (e.g., 2-of-3)
- **Privacy**: Use commit-reveal for sensitive coordination data
- **Cross-Chain**: Bridge coordination across chains while settling on primary chain

## Usage Guide

### Deployment

Deploy the `MultiPartyEvaluator` contract:

```bash
npx hardhat run scripts/deployMultiPartyEvaluator.js --network baseSepolia
```

### Query Functions

The `MultiPartyEvaluator` provides several view functions for off-chain integration:

#### Get Coordination Status

```solidity
(Status status, JobConfig memory config, uint256 createdAt) = 
    evaluator.getJobCoordinationStatus(intentHash);
```

Returns the current status, job configuration, and creation timestamp.

#### Get Coordinations by Job

```solidity
(uint256 count, CoordinationInfo[] memory coordinations) = 
    evaluator.getCoordinationsByJob(erc8183JobId, agenticCommerceAddress);
```

Returns all coordinations for a specific job, useful for UI displays.

#### Check Active Coordination

```solidity
(bool hasActive, bytes32 intentHash) = 
    evaluator.getActiveCoordination(erc8183JobId, agenticCommerceAddress);
```

Quick check if a job has an active coordination and get its hash.

### Edge Cases Handled

1. **Duplicate Coordination Prevention**: Cannot propose multiple coordinations for the same job
2. **Job Expiry Check**: Validates ERC-8183 job hasn't expired before proposing or executing
3. **Coordination Cancellation**: Proposer can cancel before expiry; anyone can cancel after expiry
4. **Active Coordination Tracking**: Automatically clears active flag when coordination is executed or cancelled

### Gas Costs

Approximate gas costs for key operations:

- `proposeJobCoordination`: ~150,000 gas
- `acceptCoordination`: ~80,000 gas per participant
- `executeJobCoordination`: ~100,000 gas (includes ERC-8183 call)
- `cancelJobCoordination`: ~50,000 gas

### Events

Monitor these events for off-chain indexing:

```solidity
event JobCoordinationProposed(
    bytes32 indexed intentHash,
    uint256 indexed erc8183JobId,
    address indexed agenticCommerce,
    address proposer,
    uint8 actionType,
    bytes32 coordinationType,
    uint256 expiry
);

event JobCoordinationExecuted(
    bytes32 indexed intentHash,
    uint256 indexed erc8183JobId,
    address indexed agenticCommerce,
    uint8 actionType,
    bool success
);

event JobCoordinationCancelled(
    bytes32 indexed intentHash,
    uint256 indexed erc8183JobId,
    address indexed agenticCommerce,
    string reason
);
```

## Reference Implementation

See `contracts/examples/MultiPartyEvaluator.sol` for the full implementation.

See `test/MultiPartyEvaluator.test.js` for integration tests.

See `scripts/deployMultiPartyEvaluator.js` for deployment script.
