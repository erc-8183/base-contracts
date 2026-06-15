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
| `createJob`   | **Yes (afterAction only)** | Hook is attached during creation, so only `afterAction` fires — the hook can initialize per-job bookkeeping or revert to reject the job. No `beforeAction`: no attached hook exists before creation, and attachment is already gated by the whitelist + ERC-165 check. |
| `setPayoutReceiver` | Yes | before + after |
| `setProvider` | Yes     | before + after |
| `setBudget`   | Yes     | before + after |
| `fund`        | Yes     | before + after |
| `submit`      | Yes     | before + after |
| `submitClaim` | Yes     | before + after |
| `settleClaim` | Yes     | before + after |
| `approveClaim` | Yes   | before + after |
| `rejectClaim` | Yes    | before + after |
| `complete`    | Yes     | before + after |
| `reject`      | Yes     | before + after |
| `claimRefund` | Yes     | before + after. Permissionless refund path — see the fund-lock caveat below. |

## Data Encoding per Selector

As produced by `ERC8183`:

| Selector    | `data` encoding                                                              |
|-------------|------------------------------------------------------------------------------|
| `createJob` | `abi.encode(address actor, address provider, address evaluator, uint48 expiredAt, address hook, uint256 providerAgentId, bytes optParams)` |
| `setProvider` | `abi.encode(address actor, address provider, uint256 agentId, bytes optParams)` |
| `setPayoutReceiver` | `abi.encode(address actor, address payoutReceiver, bytes optParams)` |
| `setBudget` | `abi.encode(address actor, address token, uint256 amount, bytes optParams)` |
| `fund`      | `abi.encode(address actor, bytes optParams)`                                |
| `submit`    | `abi.encode(address actor, bytes32 deliverable, bytes optParams)`           |
| `submitClaim` | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `settleClaim` | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `approveClaim` | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `rejectClaim` | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes optParams)` |
| `complete`  | `abi.encode(address actor, bytes32 reason, bytes optParams)`                |
| `reject`    | `abi.encode(address actor, bytes32 reason, bytes optParams)`                |
| `claimRefund` | `abi.encode(address actor, bytes optParams)`                              |

All payloads begin with `address actor` so the hook knows who authorized the transition.
For direct calls `actor` is `msg.sender`; for `*WithAuthorization` calls it is the EIP-712
signer; for the permissionless `claimRefund` it is `msg.sender` (whoever triggered the refund).

> **Fund-lock caveat for `claimRefund`.** `claimRefund` is the permissionless escrow
> recovery path, and it is fully hookable — a hook's `beforeAction`/`afterAction` MAY revert.
> A misbehaving hook that reverts can therefore block the refund and lock escrowed funds.
> Mitigations: hooks are admin-whitelisted and ERC-165-checked at attach time, and an admin
> can sever a bad hook from in-flight jobs via `batchDetachHook` (after which `claimRefund`
> succeeds). Only whitelist hooks you fully trust and have audited.

### Signed-authorization note

The `optParams` for `createJob`, `setProvider`, and `setPayoutReceiver` are bound into their
EIP-712 authorization typehashes via an `optParamsHash` field (matching `setBudget`/`fund`/etc.).
Adding `optParams` changed these three typehashes, so any authorization signatures produced
against the previous typehashes are no longer valid.

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
2. Hook implementations may choose to trust whitelisted addresses as cross-hook callers. This enables routers that fan out to sub-hooks, but it also means every whitelisted address can gain cross-invocation power if hooks opt into that trust model. Only whitelist contracts you fully trust and have audited.

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
    address expectedToken,
    uint256 expectedBudget,
    bytes calldata optParams
) external whenNotPaused nonReentrant {
    Job storage job = jobs[jobId];
    // ... validation (status, caller, expiry, expectedToken == paymentToken, expectedBudget == budget) ...

    bytes memory data = abi.encode(msg.sender, optParams);
    _beforeHook(job.hook, jobId, this.fund.selector, data);   // CAN revert to gate the transition

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

    _afterHook(job.hook, jobId, this.fund.selector, data);    // for bookkeeping / side effects
}
```

The core passes canonical base-function selectors such as `this.fund.selector`, including when a relayed `*WithAuthorization` wrapper calls the same internal transition.

## Hook Safety

- Hooks MUST NOT be able to steal escrowed funds — only the core moves escrowed payment tokens.
- Hooks MUST NOT be able to change job state outside of defined transitions — they observe and gate, they do not write to `jobs[jobId]`.
- `beforeAction` can revert to gate transitions — this is intentional and by design.
- `afterAction` reverts roll back the whole transaction — hook state must stay consistent with core state.
- `claimRefund` is hookable (before + after), but because it is the permissionless escrow recovery path, a reverting hook can block the refund and lock escrowed funds — mitigate via the whitelist/ERC-165 attach checks and `batchDetachHook` (see the fund-lock caveat above). It still requires pending provider claims to be resolved first.
- `settleClaim` can run while a provider claim is pending; it updates cumulative settlement but does not close the pending claim lifecycle.
- `approveClaim` and `rejectClaim` are hookable resolution actions; trusted hooks can gate them like other business transitions.
- When `submit` supersedes a pending claim, the pending claim is cleared before submit hooks run so hooks observe the post-supersede state.
- A `Submitted` job cannot be force-refunded for `EVALUATION_GRACE_PERIOD` (1 hour) past `expiredAt`, giving the evaluator a censorship-resistant window to call `complete` or `reject`.
- A `Funded` job with a pending provider claim cannot be force-refunded until the claim is approved or rejected; if all parties stay idle, escrow remains parked.
