// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IACPHook.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title TrustGateACPHook
 * @notice Example IACPHook that gates job lifecycle based on trust scores.
 *         Demonstrates how hooks can enforce pre-conditions and record outcomes.
 *
 * @dev This is a REFERENCE IMPLEMENTATION for the ERC-8183 hook system.
 *
 * Hook points:
 *   - beforeAction(fund)    → Check client trust score
 *   - beforeAction(submit)  → Check provider trust score
 *   - afterAction(complete) → Record positive outcome
 *   - afterAction(reject)   → Record negative outcome
 *
 * Revert in beforeAction to block the transition.
 * afterAction should NOT revert (would block legitimate state changes).
 */

/// @notice Minimal trust oracle interface
interface ITrustOracle {
    struct UserReputation {
        uint256 reputationScore;
        bool initialized;
    }
    function getUserData(address user) external view returns (UserReputation memory);
}

contract TrustGateACPHook is IACPHook, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    ITrustOracle public oracle;
    uint256 public clientThreshold;
    uint256 public providerThreshold;

    /// @dev Well-known selectors from AgenticCommerce
    bytes4 public constant FUND_SEL = bytes4(keccak256("fund(uint256,bytes)"));
    bytes4 public constant SUBMIT_SEL = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SEL = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 public constant REJECT_SEL = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event TrustGated(uint256 indexed jobId, address indexed agent, uint256 score, bool allowed);
    event OutcomeRecorded(uint256 indexed jobId, bool completed);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error TrustGateACPHook__TrustTooLow(uint256 jobId, address agent, uint256 score, uint256 threshold);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address oracle_,
        uint256 clientThreshold_,
        uint256 providerThreshold_,
        address owner_
    ) external initializer {
        __Ownable_init(owner_);
        oracle = ITrustOracle(oracle_);
        clientThreshold = clientThreshold_;
        providerThreshold = providerThreshold_;
    }

    /*//////////////////////////////////////////////////////////////
                    IACPHook: beforeAction
    //////////////////////////////////////////////////////////////*/

    /// @notice Called before state transitions. Reverts to block.
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override {
        if (selector == FUND_SEL) {
            // data = abi.encode(caller, optParams)
            (address caller,) = abi.decode(data, (address, bytes));
            _checkTrust(jobId, caller, clientThreshold);
        } else if (selector == SUBMIT_SEL) {
            // data = abi.encode(caller, reason, optParams)
            (address caller,,) = abi.decode(data, (address, bytes32, bytes));
            _checkTrust(jobId, caller, providerThreshold);
        }
        // Other selectors: pass through
    }

    /*//////////////////////////////////////////////////////////////
                    IACPHook: afterAction
    //////////////////////////////////////////////////////////////*/

    /// @notice Called after state transitions. Records outcomes (never reverts).
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override {
        if (selector == COMPLETE_SEL) {
            emit OutcomeRecorded(jobId, true);
        } else if (selector == REJECT_SEL) {
            emit OutcomeRecorded(jobId, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-165
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IACPHook).interfaceId
            || interfaceId == 0x01ffc9a7; // IERC165
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _checkTrust(uint256 jobId, address agent, uint256 threshold) internal {
        ITrustOracle.UserReputation memory rep = oracle.getUserData(agent);
        uint256 score = rep.initialized ? rep.reputationScore : 0;

        if (score < threshold) {
            emit TrustGated(jobId, agent, score, false);
            revert TrustGateACPHook__TrustTooLow(jobId, agent, score, threshold);
        }

        emit TrustGated(jobId, agent, score, true);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN
    //////////////////////////////////////////////////////////////*/

    function setThresholds(uint256 client_, uint256 provider_) external onlyOwner {
        clientThreshold = client_;
        providerThreshold = provider_;
    }

    function setOracle(address oracle_) external onlyOwner {
        oracle = ITrustOracle(oracle_);
    }
}
