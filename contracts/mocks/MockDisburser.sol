// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../IDisburser.sol";

interface IReentrantERC8183 {
    function settleClaim(uint256 jobId, uint256 cumulativeAmount, bytes32 deliverable, bytes calldata optParams)
        external;
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function claimRefund(uint256 jobId, bytes calldata optParams) external;
}

contract MockDisburser is IDisburser, ERC165 {
    uint256 public callCount;
    uint256 public lastJobId;
    bytes4 public lastSelector;
    address public lastToken;
    uint256 public lastAmount;
    bytes public lastData;
    bool public shouldRevert;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function onDisbursement(uint256 jobId, bytes4 selector, address token, uint256 amount, bytes calldata data)
        external
        override
    {
        if (shouldRevert) revert("MockDisburser: forced revert");
        callCount++;
        lastJobId = jobId;
        lastSelector = selector;
        lastToken = token;
        lastAmount = amount;
        lastData = data;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IDisburser).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @notice Contract that does not advertise IDisburser via ERC-165.
contract NotADisburser {
    function answer() external pure returns (uint256) {
        return 42;
    }
}

contract ReentrantDisburser is IDisburser, ERC165 {
    enum Action {
        None,
        SettleClaim,
        Complete,
        ClaimRefund
    }

    IReentrantERC8183 public core;
    uint256 public targetJobId;
    uint256 public targetAmount;
    Action public action;
    bool public attempted;
    bool public reentered;
    bool public reentryReverted;
    bytes public revertData;

    function setReentry(IReentrantERC8183 core_, uint256 targetJobId_, uint256 targetAmount_, Action action_) external {
        core = core_;
        targetJobId = targetJobId_;
        targetAmount = targetAmount_;
        action = action_;
        attempted = false;
        reentered = false;
        reentryReverted = false;
        delete revertData;
    }

    function onDisbursement(uint256, bytes4, address, uint256, bytes calldata) external override {
        if (action == Action.None) return;

        attempted = true;
        (bool ok, bytes memory data) = _attemptReentry();
        reentered = ok;
        reentryReverted = !ok;
        revertData = data;
    }

    function _attemptReentry() internal returns (bool ok, bytes memory data) {
        if (action == Action.SettleClaim) {
            return address(core)
                .call(
                    abi.encodeCall(
                        IReentrantERC8183.settleClaim,
                        (targetJobId, targetAmount, bytes32("reentrant-settle"), bytes(""))
                    )
                );
        }
        if (action == Action.Complete) {
            return address(core)
                .call(
                    abi.encodeCall(IReentrantERC8183.complete, (targetJobId, bytes32("reentrant-complete"), bytes("")))
                );
        }
        if (action == Action.ClaimRefund) {
            return address(core).call(abi.encodeCall(IReentrantERC8183.claimRefund, (targetJobId, bytes(""))));
        }
        return (true, "");
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IDisburser).interfaceId || super.supportsInterface(interfaceId);
    }
}
