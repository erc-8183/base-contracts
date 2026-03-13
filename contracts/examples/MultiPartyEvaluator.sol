// SPDX-License-Identifier: CC0-1.0
// ERC-8001 + ERC-8183 Integration Example: Multi-Party Evaluator
pragma solidity ^0.8.28;

import {ERC8001} from "../erc8001/ERC8001.sol";
import {IERC8001} from "../erc8001/interfaces/IERC8001.sol";

/**
 * @title MultiPartyEvaluator
 * @dev Example implementation showing ERC-8001 coordination layered on ERC-8183 settlement.
 *
 * This contract acts as an ERC-8183 evaluator that requires multi-party coordination
 * before completing or rejecting jobs. It demonstrates the compositional pattern:
 *
 *      ERC-8001 = Coordination Layer (who must agree)
 *      ERC-8183 = Settlement Layer (escrow, payment, state machine)
 *
 * Flow:
 *   1. Job created in AgenticCommerce with this contract as evaluator
 *   2. Provider submits work
 *   3. This contract proposes coordination intent (completion or rejection)
 *   4. Required parties (client, provider, optional arbiter) accept via ERC-8001
 *   5. Once all accept, anyone can execute coordination
 *   6. Execution calls complete() or reject() on AgenticCommerce
 *
 * See docs/04-erc8001-integration.md for full documentation.
 */
contract MultiPartyEvaluator is ERC8001 {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidJobConfig();
    error CoordinationTypeMismatch();
    error ExecutionNotAuthorized();
    error InvalidAction();
    error CoordinationAlreadyExists();
    error JobExpired();
    error CoordinationNotCancellable();
    error NotProposer();

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Configuration for a job coordination.
     * @param erc8183JobId The job ID in AgenticCommerce
     * @param agenticCommerce The ERC-8183 contract address
     * @param actionType What action to take: 1=complete, 2=reject
     * @param reason Reason for completion/rejection
     */
    struct JobConfig {
        uint256 erc8183JobId;
        address agenticCommerce;
        uint8 actionType; // 1=complete, 2=reject
        bytes32 reason;
    }

    /**
     * @dev Coordination info for query purposes.
     * @param intentHash The coordination intent hash
     * @param status Current coordination status
     * @param config Job configuration
     * @param createdAt Block timestamp when coordination was created
     */
    struct CoordinationInfo {
        bytes32 intentHash;
        Status status;
        JobConfig config;
        uint256 createdAt;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Coordination intent hash => job configuration
    mapping(bytes32 => JobConfig) public jobConfigs;

    /// @dev ERC-8183 job ID => list of coordination intent hashes
    mapping(uint256 => bytes32[]) public jobCoordinations;

    /// @dev ERC-8183 job ID => agenticCommerce address => has active coordination
    mapping(uint256 => mapping(address => bool)) public hasActiveCoordination;

    /// @dev Coordination intent hash => creation timestamp
    mapping(bytes32 => uint256) public coordinationCreatedAt;

    /// @dev Coordination type identifiers
    bytes32 public constant COORDINATION_COMPLETE = keccak256("COMPLETE_JOB");
    bytes32 public constant COORDINATION_REJECT = keccak256("REJECT_JOB");

    /// @dev Interface for checking job status
    bytes4 private constant GET_JOB_SELECTOR = bytes4(keccak256("getJob(uint256)"));

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Propose a coordination for completing or rejecting an ERC-8183 job.
     * @dev Only the contract owner/admin should call this to initiate coordination.
     * @param intent The ERC-8001 intent structure
     * @param signature EIP-712 signature from the proposer
     * @param payload The coordination payload
     * @param config Job configuration (which job, what action)
     * @return intentHash The coordination intent hash
     */
    function proposeJobCoordination(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload,
        JobConfig calldata config
    ) external returns (bytes32 intentHash) {
        // Validate configuration
        if (config.agenticCommerce == address(0)) revert InvalidJobConfig();
        if (config.actionType != 1 && config.actionType != 2) revert InvalidAction();

        // Validate coordination type matches action
        bytes32 expectedType = config.actionType == 1 ? COORDINATION_COMPLETE : COORDINATION_REJECT;
        if (intent.coordinationType != expectedType) revert CoordinationTypeMismatch();

        // Check if job already has an active coordination
        if (hasActiveCoordination[config.erc8183JobId][config.agenticCommerce]) {
            revert CoordinationAlreadyExists();
        }

        // Call parent proposeCoordination
        intentHash = proposeCoordination(intent, signature, payload);

        // Store job configuration
        jobConfigs[intentHash] = config;
        coordinationCreatedAt[intentHash] = block.timestamp;

        // Track coordination for this job
        jobCoordinations[config.erc8183JobId].push(intentHash);
        hasActiveCoordination[config.erc8183JobId][config.agenticCommerce] = true;

        emit JobCoordinationProposed(
            intentHash,
            config.erc8183JobId,
            config.agenticCommerce,
            intent.agentId,
            config.actionType,
            intent.coordinationType,
            intent.expiry
        );

        return intentHash;
    }

    /**
     * @notice Execute a ready coordination, completing or rejecting the ERC-8183 job.
     * @dev Can be called by anyone once all participants have accepted.
     * @param intentHash The coordination intent hash
     * @param payload The coordination payload
     * @param executionData Optional execution data (unused in this implementation)
     */
    function executeJobCoordination(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData
    ) external returns (bool success, bytes memory result) {
        JobConfig memory config = jobConfigs[intentHash];

        // Call parent executeCoordination
        (success, result) = executeCoordination(intentHash, payload, executionData);

        // Clear active coordination flag
        hasActiveCoordination[config.erc8183JobId][config.agenticCommerce] = false;

        emit JobCoordinationExecuted(
            intentHash,
            config.erc8183JobId,
            config.agenticCommerce,
            config.actionType,
            success
        );

        return (success, result);
    }

    /**
     * @notice Cancel a coordination intent.
     * @dev Only the proposer can cancel before expiry. After expiry, anyone can cancel.
     * @param intentHash The coordination intent hash
     * @param reason Human-readable cancellation reason
     */
    function cancelJobCoordination(
        bytes32 intentHash,
        string calldata reason
    ) external {
        // Get coordination status
        (Status status, address proposer,,, uint256 expiry) = getCoordinationStatus(intentHash);

        // Can only cancel if not already executed or cancelled
        if (status == Status.Executed || status == Status.Cancelled) {
            revert CoordinationNotCancellable();
        }

        // Before expiry: only proposer can cancel
        // After expiry: anyone can cancel
        if (expiry > block.timestamp && msg.sender != proposer) {
            revert NotProposer();
        }

        // Call parent cancelCoordination
        cancelCoordination(intentHash, reason);

        // Clear active coordination flag
        JobConfig memory config = jobConfigs[intentHash];
        hasActiveCoordination[config.erc8183JobId][config.agenticCommerce] = false;

        emit JobCoordinationCancelled(
            intentHash,
            config.erc8183JobId,
            config.agenticCommerce,
            reason
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the current coordination status with job-specific info.
     * @param intentHash The coordination intent hash
     * @return status Current status
     * @return config Job configuration
     * @return createdAt Creation timestamp
     */
    function getJobCoordinationStatus(bytes32 intentHash)
        external
        view
        returns (Status status, JobConfig memory config, uint256 createdAt)
    {
        (status,,,,) = getCoordinationStatus(intentHash);
        config = jobConfigs[intentHash];
        createdAt = coordinationCreatedAt[intentHash];
    }

    /**
     * @notice Get all coordinations for a specific ERC-8183 job.
     * @param erc8183JobId The job ID
     * @param agenticCommerce The AgenticCommerce contract address
     * @return count Number of coordinations
     * @return coordinations Array of coordination info
     */
    function getCoordinationsByJob(
        uint256 erc8183JobId,
        address agenticCommerce
    ) external view returns (uint256 count, CoordinationInfo[] memory coordinations) {
        bytes32[] storage hashes = jobCoordinations[erc8183JobId];
        count = hashes.length;

        coordinations = new CoordinationInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes32 intentHash = hashes[i];
            JobConfig memory config = jobConfigs[intentHash];

            // Only include coordinations for the specified agenticCommerce
            if (config.agenticCommerce == agenticCommerce) {
                (Status status,,,,) = getCoordinationStatus(intentHash);
                coordinations[i] = CoordinationInfo({
                    intentHash: intentHash,
                    status: status,
                    config: config,
                    createdAt: coordinationCreatedAt[intentHash]
                });
            }
        }
    }

    /**
     * @notice Check if a job has an active coordination.
     * @param erc8183JobId The job ID
     * @param agenticCommerce The AgenticCommerce contract address
     * @return hasActive True if there's an active coordination
     * @return intentHash The active coordination hash (if any)
     */
    function getActiveCoordination(
        uint256 erc8183JobId,
        address agenticCommerce
    ) external view returns (bool hasActive, bytes32 intentHash) {
        hasActive = hasActiveCoordination[erc8183JobId][agenticCommerce];

        if (hasActive) {
            // Find the active coordination hash
            bytes32[] storage hashes = jobCoordinations[erc8183JobId];
            for (uint256 i = 0; i < hashes.length; i++) {
                JobConfig memory config = jobConfigs[hashes[i]];
                if (config.agenticCommerce == agenticCommerce) {
                    (Status status,,,,) = getCoordinationStatus(hashes[i]);
                    if (status == Status.Proposed || status == Status.Ready) {
                        intentHash = hashes[i];
                        break;
                    }
                }
            }
        }
    }

    /**
     * @notice Get the number of coordinations for a job.
     * @param erc8183JobId The job ID
     * @return count Number of coordinations
     */
    function getCoordinationCount(uint256 erc8183JobId) external view returns (uint256) {
        return jobCoordinations[erc8183JobId].length;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Hook called by executeCoordination to perform the actual ERC-8183 action.
     * @param intentHash The coordination intent hash
     * @param executionData Optional execution data
     * @return success Whether the execution succeeded
     * @return result Return data from execution
     */
    function _executeCoordinationHook(
        bytes32 intentHash,
        CoordinationPayload calldata /* payload */,
        bytes calldata executionData
    ) internal override returns (bool success, bytes memory result) {
        JobConfig memory config = jobConfigs[intentHash];

        // Build calldata for AgenticCommerce
        bytes memory callData;
        if (config.actionType == 1) {
            // complete(jobId, reason, optParams)
            callData = abi.encodeWithSignature(
                "complete(uint256,bytes32,bytes)",
                config.erc8183JobId,
                config.reason,
                executionData
            );
        } else if (config.actionType == 2) {
            // reject(jobId, reason, optParams)
            callData = abi.encodeWithSignature(
                "reject(uint256,bytes32,bytes)",
                config.erc8183JobId,
                config.reason,
                executionData
            );
        } else {
            revert InvalidAction();
        }

        // Call AgenticCommerce
        (success, result) = config.agenticCommerce.call(callData);

        return (success, result);
    }

    /**
     * @dev Check if an ERC-8183 job has expired.
     * @param agenticCommerce The AgenticCommerce contract address
     * @param jobId The job ID
     * @return expired True if job has expired
     */
    function _isJobExpired(address agenticCommerce, uint256 jobId) internal view returns (bool) {
        // Call getJob on AgenticCommerce
        (bool success, bytes memory result) = agenticCommerce.staticcall(
            abi.encodeWithSelector(GET_JOB_SELECTOR, jobId)
        );

        if (!success || result.length < 256) {
            return false; // Assume not expired if we can't check
        }

        // Decode expiredAt from result
        // Job struct layout: id (32), client (32), provider (32), evaluator (32), 
        // description offset (32), budget (32), expiredAt (32), status (32), hook (32)
        // Total minimum: 9 slots * 32 = 288 bytes
        // expiredAt is at offset 192 (6th slot)
        uint256 expiredAt;
        assembly {
            expiredAt := mload(add(result, 224)) // 192 + 32 (length prefix)
        }
        
        return expiredAt < block.timestamp;
    }
}
