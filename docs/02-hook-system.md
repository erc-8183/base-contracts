# Hook System Design

## Overview

The hook system allows external contracts to intercept and extend ERC-8183 state transitions without modifying the core contract. Each job can optionally attach a hook contract that receives `beforeAction`/`afterAction` callbacks on every state transition.

The interface is intentionally minimal (two functions) so it remains stable as the protocol evolves — new hookable functions simply produce new selector values without changing the interface.

## IERC8183Hook Interface

```solidity
interface IERC8183Hook {
    /// @dev Called before the core function executes. MAY revert to block the action.
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    /// @dev Called after the core function completes. MAY revert to roll back the transaction.
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
```

- `selector` identifies which core function triggered the callback (e.g. `AgenticCommerce.fund.selector`)
- `data` contains function-specific parameters ABI-encoded as bytes (see table below)

## Data Encoding per Selector

As produced by `AgenticCommerce`:

| Selector | Data encoding | Notes |
|----------|--------------|-------|
| createJob | `abi.encode(client, provider, evaluator)` | afterAction only |
| setBudget | `abi.encode(caller, amount, optParams)` | before + after |
| fund | `abi.encode(caller, optParams)` | before + after |
| submit | `abi.encode(caller, deliverable, optParams)` | before + after |
| complete | `abi.encode(caller, reason, optParams)` | before + after |
| reject | `abi.encode(caller, reason, optParams)` | before + after |

All data includes `address caller` so the hook knows who initiated the transition.

## How Hooks Attach to Jobs

Each job can have its own hook address, set at creation time:

```solidity
struct Job {
    // ... existing fields ...
    address hook;  // optional — address(0) means no hook
}
```

When `hook == address(0)`, the contract operates as standalone job escrow with no callbacks.

Hooks must be whitelisted by an admin before they can be used:

```solidity
function setHookWhitelist(address hook, bool status) external onlyRole(ADMIN_ROLE);
```

## Hook Invocation Pattern in Core

The core uses two internal helpers:

```solidity
function _beforeHook(address hook, uint256 jobId, bytes4 selector, bytes memory data) internal {
    if (hook != address(0)) {
        IERC8183Hook(hook).beforeAction(jobId, selector, data);
    }
}

function _afterHook(address hook, uint256 jobId, bytes4 selector, bytes memory data) internal {
    if (hook != address(0)) {
        IERC8183Hook(hook).afterAction(jobId, selector, data);
    }
}
```

Each hookable function follows the same pattern:

```solidity
function fund(uint256 jobId, bytes calldata optParams) external nonReentrant {
    Job storage job = jobs[jobId];
    // ... validation ...
    bytes memory data = abi.encode(msg.sender, optParams);
    _beforeHook(job.hook, jobId, msg.sig, data);   // CAN revert to gate the transition
    job.status = JobStatus.Funded;
    paymentToken.safeTransferFrom(job.client, address(this), job.budget);
    emit JobFunded(jobId, job.client, job.budget);
    _afterHook(job.hook, jobId, msg.sig, data);    // for bookkeeping / side effects
}
```

### Special cases

- **createJob** — `afterAction` only (no `beforeAction`).
- **claimRefund** — NOT hookable (no `beforeAction`, no `afterAction`). This is a deliberate safety mechanism so hooks cannot block or interfere with expiry refunds.

## Hook Safety

- Hooks MUST NOT be able to steal escrowed funds
- Hooks MUST NOT be able to change job state outside of defined transitions
- `beforeAction` can revert to gate transitions — this is intentional and by design
- `afterAction` reverts also roll back the whole transaction — hook state must stay consistent with core state
- `claimRefund` is intentionally not hookable — refunds cannot be blocked or delayed by hook logic
