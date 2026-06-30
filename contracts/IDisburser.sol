// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IDisburser
 * @notice Optional payout receiver hook for ERC-8183.
 *         When a job's payoutReceiver is a contract, the escrow transfers
 *         the provider-side net amount to the receiver and then invokes
 *         onDisbursement so the receiver can split or forward funds it
 *         already controls. Reverts here cause the parent call to revert.
 */
interface IDisburser is IERC165 {
    /// @notice Called after the escrow has transferred amount of token to this receiver.
    /// @param jobId    The job that triggered the disbursement
    /// @param selector The logical ERC8183 action selector that triggered it;
    ///                 authorization wrappers report the underlying action selector
    /// @param token    ERC-20 payment token transferred
    /// @param amount   Provider-side net amount transferred
    /// @param data     Pass-through optParams from the triggering call
    function onDisbursement(uint256 jobId, bytes4 selector, address token, uint256 amount, bytes calldata data) external;
}
