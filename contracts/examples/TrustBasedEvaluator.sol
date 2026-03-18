// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title TrustBasedEvaluator
 * @notice Example evaluator that uses an external trust oracle to verify
 *         job deliverables. Demonstrates how to build an ERC-8183 evaluator
 *         that goes beyond simple approve/reject.
 *
 * @dev This is a REFERENCE IMPLEMENTATION — adapt for your use case.
 *
 * Pattern:
 *   1. Provider submits deliverable
 *   2. AgenticCommerce calls evaluator.evaluate(jobId)
 *   3. Evaluator checks provider trust score from oracle
 *   4. Evaluator checks deliverable quality (delegated to off-chain)
 *   5. Returns complete() or reject() to AgenticCommerce
 *
 * Trust oracle interface:
 *   getUserData(address) → { reputationScore, initialized, ... }
 */

/// @notice Minimal trust oracle interface
interface ITrustOracle {
    struct UserReputation {
        uint256 reputationScore;
        uint256 totalReviews;
        bool initialized;
        uint256 lastUpdated;
    }
    function getUserData(address user) external view returns (UserReputation memory);
}

/// @notice Minimal AgenticCommerce interface for evaluation
interface IAgenticCommerce {
    enum JobStatus { Open, Funded, Submitted, Completed, Rejected, Expired }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        address hook;
    }

    function getJob(uint256 jobId) external view returns (Job memory);
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
}

contract TrustBasedEvaluator is OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    ITrustOracle public oracle;
    IAgenticCommerce public agenticCommerce;

    /// @notice Minimum trust score (0-100) to auto-approve
    uint256 public minTrustScore;

    /// @notice Tracks evaluated jobs to prevent double-evaluation
    mapping(uint256 => bool) public evaluated;

    /// @notice Stats
    uint256 public totalEvaluated;
    uint256 public totalApproved;
    uint256 public totalRejected;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event JobEvaluated(
        uint256 indexed jobId,
        address indexed provider,
        bool approved,
        uint256 trustScore,
        bytes32 reason
    );

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error TrustBasedEvaluator__AlreadyEvaluated(uint256 jobId);
    error TrustBasedEvaluator__NotSubmitted(uint256 jobId);
    error TrustBasedEvaluator__NotAssignedEvaluator(uint256 jobId);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address oracle_,
        address agenticCommerce_,
        uint256 minTrustScore_,
        address owner_
    ) external initializer {
        __Ownable_init(owner_);
        oracle = ITrustOracle(oracle_);
        agenticCommerce = IAgenticCommerce(agenticCommerce_);
        minTrustScore = minTrustScore_;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE: EVALUATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Evaluate a submitted job. Called by anyone (typically off-chain keeper).
     * @param jobId The job to evaluate
     *
     * Flow:
     *   1. Verify job is in Submitted status
     *   2. Verify this contract is the assigned evaluator
     *   3. Check provider trust score
     *   4. Auto-approve if score >= minTrustScore, reject otherwise
     *   5. Call complete() or reject() on AgenticCommerce
     */
    function evaluate(uint256 jobId) external {
        if (evaluated[jobId]) revert TrustBasedEvaluator__AlreadyEvaluated(jobId);

        IAgenticCommerce.Job memory job = agenticCommerce.getJob(jobId);

        if (job.status != IAgenticCommerce.JobStatus.Submitted) {
            revert TrustBasedEvaluator__NotSubmitted(jobId);
        }
        if (job.evaluator != address(this)) {
            revert TrustBasedEvaluator__NotAssignedEvaluator(jobId);
        }

        evaluated[jobId] = true;
        totalEvaluated++;

        // Check provider trust
        ITrustOracle.UserReputation memory rep = oracle.getUserData(job.provider);
        uint256 score = rep.initialized ? rep.reputationScore : 0;

        bool approved = score >= minTrustScore;
        bytes32 reason = approved
            ? bytes32("trust_approved")
            : bytes32("trust_too_low");

        if (approved) {
            totalApproved++;
            agenticCommerce.complete(jobId, reason, "");
        } else {
            totalRejected++;
            agenticCommerce.reject(jobId, reason, "");
        }

        emit JobEvaluated(jobId, job.provider, approved, score, reason);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN
    //////////////////////////////////////////////////////////////*/

    function setMinTrustScore(uint256 score) external onlyOwner {
        minTrustScore = score;
    }

    function setOracle(address oracle_) external onlyOwner {
        oracle = ITrustOracle(oracle_);
    }
}
