// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @dev Test-only ERC20 with 6 decimals (matches real USDC).
 *      Public mint — no access control, for test fixtures only.
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint any amount to any address. Test use only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
