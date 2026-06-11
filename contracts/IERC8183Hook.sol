// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IERC8183Hook
 * @dev Interface for ERC-8183 hook contracts. Implementations receive before/after
 *      callbacks on core job functions.
 *
 *      The `selector` identifies which core function is being called (e.g.
 *      ERC8183.fund.selector). The `data` parameter contains
 *      function-specific parameters encoded as bytes (see documentation for
 *      encoding per selector).
 *
 *      This interface is intentionally minimal (two functions) so that it remains
 *      stable as the core protocol evolves — new hookable functions simply produce
 *      new selector values without changing this interface.
 *
 *      Implementations can route selectors to named internal handlers and decode
 *      `data` according to the hook encoding documented for each selector.
 */
interface IERC8183Hook is IERC165 {
    /// @dev Called before the core function executes. MAY revert to block the action.
    /// @param jobId The job ID.
    /// @param selector The function selector of the core function being called.
    /// @param data Encoded function-specific parameters (see protocol documentation for decoding).
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    /// @dev Called after the core function completes. MAY revert to roll back the transaction.
    /// @param jobId The job ID.
    /// @param selector The function selector of the core function being called.
    /// @param data Encoded function-specific parameters (see protocol documentation for decoding).
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
