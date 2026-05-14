// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../IERC8183Hook.sol";

contract MockHook is ERC165, IERC8183Hook {
    event BeforeAction(uint256 indexed jobId, bytes4 selector, bytes data);
    event AfterAction(uint256 indexed jobId, bytes4 selector, bytes data);

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        emit BeforeAction(jobId, selector, data);
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        emit AfterAction(jobId, selector, data);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || super.supportsInterface(interfaceId);
    }
}
