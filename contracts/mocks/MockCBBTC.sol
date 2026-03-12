// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockCBBTC
 * @dev Test-only ERC20 with 8 decimals (matches real cbBTC).
 *      Public mint — no access control, for test fixtures only.
 */
contract MockCBBTC is ERC20 {
    constructor() ERC20("Coinbase Wrapped BTC", "cbBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @notice Mint any amount to any address. Test use only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
