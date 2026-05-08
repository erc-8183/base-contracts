// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../IDisburser.sol";

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

    function onDisbursement(
        uint256 jobId,
        bytes4 selector,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override {
        if (shouldRevert) revert("MockDisburser: forced revert");
        callCount++;
        lastJobId = jobId;
        lastSelector = selector;
        lastToken = token;
        lastAmount = amount;
        lastData = data;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IDisburser).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}

/// @notice A contract that does NOT advertise IDisburser via ERC-165 — used to test plain receiver behavior.
contract NotADisburser {
    function answer() external pure returns (uint256) {
        return 42;
    }
}
