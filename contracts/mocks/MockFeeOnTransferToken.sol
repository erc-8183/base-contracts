// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeOnTransferToken
 * @dev Test-only ERC20 that burns 1% of every transfer. Used to verify that
 *      ERC8183.fund() rejects tokens whose received amount differs
 *      from the requested amount.
 */
contract MockFeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BP = 100; // 1%

    constructor() ERC20("Fee On Transfer", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BP) / 10000;
        uint256 sendAmount = value - fee;
        super._update(from, address(0), fee);
        super._update(from, to, sendAmount);
    }
}
