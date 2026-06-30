// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";

interface IAuthorizationNonceViewer {
    function authorizationNonceUsed(bytes32 nonce) external view returns (bool);
}

contract MockERC1271NonceObserver is IERC1271 {
    bytes4 private constant INVALID_SIGNATURE = 0xffffffff;

    function isValidSignature(bytes32, bytes calldata signature) external view returns (bytes4) {
        (address verifier, bytes32 nonce) = abi.decode(signature, (address, bytes32));
        if (IAuthorizationNonceViewer(verifier).authorizationNonceUsed(nonce)) {
            return IERC1271.isValidSignature.selector;
        }
        return INVALID_SIGNATURE;
    }
}

contract MockERC1271Rejector is IERC1271 {
    bytes4 private constant INVALID_SIGNATURE = 0xffffffff;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return INVALID_SIGNATURE;
    }
}
