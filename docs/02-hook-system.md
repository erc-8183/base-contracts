# Hook System Design

## Overview

The hook system allows external contracts to intercept and extend ERC-8183 state transitions without modifying the core contract. Each job can optionally attach a hook contract that receives `beforeAction`/`afterAction` callbacks on state transitions.

The interface is intentionally minimal (two functions) so it remains stable as the protocol evolves — new hookable functions simply produce new selector values without changing the interface.

## IERC8183Hook Interface

```solidity
interface IERC8183Hook is IERC165 {
    /// @dev Called before the core function executes. MAY revert to block the action.
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    /// @dev Called after the core function completes. MAY revert to roll back the transaction.
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
```

- `selector` identifies which core function triggered the callback (e.g. `ERC8183.fund.selector`)
- `data` contains function-specific parameters ABI-encoded as bytes (see table below)

## Hookable Functions

| Core function | Hooked? | Notes |
|---------------|---------|-------|
| `createJob`   | **No**  | Hook is stored on the job, but no callbacks fire on creation. |
| `setProvider` | **No**  | Client-only assignment of the provider. |
| `setBudget`   | Yes     | before + after |
| `fund`        | Yes     | before + after |
| `submit`      | Yes     | before + after |
| `submitClaim` | Yes     | before + after |
| `approveClaim` | Yes   | before + after |
| `rejectClaim` | Yes    | before + after |
| `complete`    | Yes     | before + after |
| `reject`      | Yes     | before + after |
| `claimRefund` | **No**  | Permissionless safety mechanism — never hookable. |

## Data Encoding per Selector

As produced by `ERC8183`:

| Selector    | `data` encoding                                                              |
|-------------|------------------------------------------------------------------------------|
| `setBudget` | `abi.encode(address caller, address token, uint256 amount, bytes optParams)` |
| `fund`      | `abi.encode(address caller, bytes optParams)`                                |
| `submit`    | `abi.encode(address caller, bytes32 deliverable, bytes optParams)`           |
| `submitClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `approveClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `rejectClaim` | `abi.encode(address caller, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes optParams)` |
| `complete`  | `abi.encode(address caller, bytes32 reason, bytes optParams)`                |
| `reject`    | `abi.encode(address caller, bytes32 reason, bytes optParams)`                |

All payloads include `address caller` so the hook knows who initiated the transition.

## How Hooks Attach to Jobs

Each job stores its own hook address, set at creation time:

```solidity
struct Job {
    // ... other fields ...
    address hook; // address(0) means no hook
}
```

When `hook == address(0)`, the contract operates as standalone job escrow with no callbacks.

Hooks must be whitelisted by an admin before a client can attach one to a new job:

```solidity
function setHookWhitelist(address hook, bool status) external onlyRole(ADMIN_ROLE);
```

Whitelist membership has two effects:

1. The hook may be set on new jobs (checked in `createJob`).
2. The hook can call `beforeAction` / `afterAction` on other whitelisted hooks (typically enforced via a `BaseACPHook.onlyACP` modifier on hook implementations). This enables routers that fan out to sub-hooks, but it also means every whitelisted address gains cross-invocation power over all other hooks. Only whitelist contracts you fully trust and have audited.

In addition, `createJob` calls `ERC165Checker.supportsInterface(hook, type(IERC8183Hook).interfaceId)` for non-zero hooks; a hook that does not advertise support for the interface is rejected with `InvalidHook`.

### Detaching hooks (admin tool)

If a hook is later removed from the whitelist, in-flight jobs that already attached it continue to call it. The admin can sever those references with:

```solidity
function batchDetachHook(uint256[] calldata jobIds) external onlyRole(ADMIN_ROLE);
```

Each detached job emits `HookDetached(jobId, oldHook)` and afterwards behaves like vanilla ERC-8183 (no gating, no bookkeeping).

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

Each hookable function follows the same pattern (illustrated for `fund`):

```solidity
function fund(
    uint256 jobId,
    uint256 expectedBudget,
    bytes calldata optParams
) external whenNotPaused nonReentrant {
    Job storage job = jobs[jobId];
    // ... validation (status, caller, expiry, expectedBudget == budget) ...

    bytes memory data = abi.encode(msg.sender, optParams);
    _beforeHook(job.hook, jobId, msg.sig, data);   // CAN revert to gate the transition

    job.status = JobStatus.Funded;
    if (job.budget > 0) {
        IERC20 token = IERC20(job.paymentToken);
        // Snapshot balance and assert the delta matches the budget — rejects
        // fee-on-transfer and rebasing tokens that would silently leave escrow short.
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(job.client, address(this), job.budget);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != job.budget) revert UnexpectedFundedAmount();
    }
    emit JobFunded(jobId, job.client, job.budget);

    _afterHook(job.hook, jobId, msg.sig, data);    // for bookkeeping / side effects
}
```

## Hook Safety

- Hooks MUST NOT be able to steal escrowed funds — only the core moves escrowed payment tokens.
- Hooks MUST NOT be able to change job state outside of defined transitions — they observe and gate, they do not write to `jobs[jobId]`.
- `beforeAction` can revert to gate transitions — this is intentional and by design.
- `afterAction` reverts roll back the whole transaction — hook state must stay consistent with core state.
- `claimRefund` is intentionally not hookable — refunds cannot be blocked or delayed by hook logic.
- A `Submitted` job cannot be force-refunded for `EVALUATION_GRACE_PERIOD` (1 hour) past `expiredAt`, giving the evaluator a censorship-resistant window to call `complete` or `reject`.
