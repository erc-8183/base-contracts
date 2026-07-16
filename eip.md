---
eip: 8183
title: Agentic Commerce
description: Job escrow with evaluator attestation for agent commerce.
author: Davide Crapis (@dcrapis), Bryan Lim (@ai-virtual-b), Tay Weixiong (@twx-virtuals), Chooi Zuhwa (@Zuhwa)
discussions-to: https://ethereum-magicians.org/t/erc-8183-agentic-commerce/27902
status: Draft
type: Standards Track
category: ERC
created: 2026-02-25
requires: 20
---

## Abstract

This specification defines the **Agentic Commerce Protocol**: a **job** with escrowed budget, four states (Open → Funded → Submitted → Terminal), and an **evaluator** who alone may mark the job completed. The client funds the job; the provider submits work; the evaluator attests completion or rejection once submitted (or the evaluator rejects while Funded before submission, or the client rejects while Open, or the job expires and the client is refunded). While Funded, the client may also settle partial amounts to the provider directly, or approve provider-submitted **claims**, with cumulative settlement accounting ensuring total payouts never exceed the escrowed budget. Optional attestation **reason** (e.g. hash) on complete/reject enables audit and composition with reputation (e.g. [ERC-8004](./eip-8004.md)).

## Motivation

Many use cases need only: client locks funds, provider submits work, one attester (evaluator) signals "done" and triggers payment—or client rejects or timeout triggers refund. The Agentic Commerce Protocol specifies that minimal surface so implementations stay small and composable. The evaluator can be the client (e.g. `evaluator = client` at creation) when there is no third-party attester.

Agentic work is often metered or delivered in milestones — pay-per-call inference, streaming data, staged deliverables. Such work needs to be paid as it progresses, not only at terminal completion. This specification therefore includes an incremental **claim settlement** ledger over the escrowed budget: the client may settle partial amounts at any time while the job is Funded, and the provider may file claims for the client or evaluator to approve. The one-shot escrow remains the degenerate case — a job whose claim-settlement functions are never called behaves exactly as the minimal flow above.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### State Machine

A **job** has exactly one of six states:


| State         | Meaning                                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| **Open**      | Created; budget not yet set or not yet funded. Provider may propose a budget via `setBudget`; client may then fund, and either party may reject. |
| **Funded**    | Budget escrowed. Provider may submit work or file a settlement claim; client may settle partial amounts directly or approve/reject a pending claim; evaluator may approve/reject a pending claim or reject the job. After `expiredAt`, anyone may trigger refund of the unsettled remainder (`budget - settledAmount`, see [Job Data](#job-data)), provided no claim is pending. |
| **Submitted** | Provider has submitted work. Only evaluator may complete or reject. After `expiredAt + EVALUATION_GRACE_PERIOD`, anyone may trigger refund. |
| **Completed** | Terminal. Unsettled remainder released to provider (minus optional fees).                                         |
| **Rejected**  | Terminal. Unsettled remainder refunded to client.                                                                 |
| **Expired**   | Terminal. Same as Rejected; unsettled remainder refunded to client.                                               |


Allowed transitions:

- **Open → Funded**: Provider calls `setBudget(jobId, token, amount)` to propose the price and payment token, then client accepts by calling `fund(jobId, expectedToken, expectedBudget)`; contract pulls `job.budget` of the job's payment token from client into escrow.
- **Open → Rejected**: Client or provider calls `reject(jobId, reason?)`.
- **Open → Expired**: When `block.timestamp >= job.expiredAt`, anyone may call `claimRefund(jobId)`; contract sets state to Expired. No refund to client as job has not been funded yet.
- **Open → Submitted**: zero-budget jobs only (`budget == 0`, no escrow): provider calls `submit(jobId, deliverable)` directly from Open (see `submit` under [Core Functions](#core-functions)).
- **Funded → Submitted**: Provider calls `submit(jobId, deliverable)`; signals that work has been completed and is ready for evaluation.
- **Funded → Rejected**: Evaluator calls `reject(jobId, reason?)`; contract refunds client.
- **Funded → Expired**: When `block.timestamp >= job.expiredAt`, anyone may call `claimRefund(jobId)`; contract sets state to Expired and refunds client.
- **Submitted → Completed**: Evaluator calls `complete(jobId, reason?)`; contract distributes escrow to provider / payout receiver (and optional platform/evaluator fees).
- **Submitted → Rejected**: Evaluator calls `reject(jobId, reason?)`; contract refunds client.
- **Submitted → Expired**: When `block.timestamp >= job.expiredAt + EVALUATION_GRACE_PERIOD`, anyone may call `claimRefund(jobId)`; contract sets state to Expired and refunds client. The grace period (e.g. 1 hour in the reference implementation) protects an evaluator who is mid-review from being censored by a third-party refund call. Implementations MAY set the grace period length or omit it entirely.

No other transitions are valid.

Settlement claims (see [Claim Settlement](#claim-settlement) below) do not introduce job states: all claim activity occurs while the job is Funded, and at most one claim is pending per job at any time.

### Roles

- **Client**: Creates job (with description), may set provider via `setProvider(jobId, provider, agentId?)` when job was created with no provider, funds escrow with `fund(jobId, expectedToken, expectedBudget)`, may reject when status is Open. While Funded, may settle partial amounts directly via `settleClaim` and may approve or reject a pending provider claim. Receives refund of the unsettled remainder on Rejected/Expired. **MUST NOT be the provider** — an address cannot hold both client and provider roles on the same job.
- **Provider**: Set at creation or later via `setProvider`. Calls `setBudget(jobId, token, amount)` to propose a price and payment token. Calls `submit(jobId, deliverable)` when work is done to move the job from Funded to Submitted for evaluation. While Funded, may file a settlement claim via `submitClaim` and may withdraw their own pending claim via `rejectClaim`. May reject when status is Open (e.g. to decline the engagement before any escrow is locked). Receives payment on each settlement and the remainder when the job is Completed. Does not call `complete` or job-level `reject` once the job has been funded.
- **Evaluator**: Single address per job, set at creation. When status is Submitted, **only** the evaluator MAY call `complete(jobId, reason?)` or `reject(jobId, reason?)`. When status is Funded, the evaluator MAY call `reject(jobId, reason?)` (before submission) and MAY approve or reject a pending provider claim — but MUST NOT be able to settle amounts the provider did not claim. MAY be the client (e.g. `evaluator = client`) so the client can complete or reject the job without a third party, or MAY be a **smart contract** that performs arbitrary checks (e.g. verifying a zero‑knowledge proof or aggregating off‑chain signals) before deciding whether to call `complete` or `reject` on the job. **MUST NOT be the provider** — an address cannot hold both roles on the same job.

### Job Data

Each job SHALL have at least:

- `client`, `provider`, `evaluator` (addresses). **Provider MAY be zero at creation** (see [Optional provider](#optional-provider-set-later) below).
- `description` (string) — set at creation (e.g. job brief, scope reference).
- `budget` (uint256)
- `expiredAt` (uint48 timestamp)
- `status` (Open | Funded | Submitted | Completed | Rejected | Expired)
- `submittedAt` (uint48 timestamp) — OPTIONAL for the core protocol; SHOULD be recorded on `submit` for grace-period accounting, REQUIRED when implementing Signed Authorizations (which bind it). Default `0` (not submitted).
- `paymentToken` (address) — the [ERC-20](./eip-20.md) token used for payment on this job, set via `setBudget`.
- `hook` (address) — OPTIONAL. External hook contract called before and after core functions (see [Hooks](#hooks-optional) below). MAY be `address(0)` (no hook).
- `payoutReceiver` (address) — OPTIONAL. Provider-managed payout recipient. MAY be `address(0)` to pay the provider directly. Set via `setPayoutReceiver`.
- `providerAgentId` (uint256) — OPTIONAL. When non-zero, references an agent identity in an [ERC-8004](./eip-8004.md) registry, enabling on-chain identity binding for reputation. Set via `setProvider` (or at creation if provider is known). Default `0` (unset).
- `settledAmount` (uint256) — cumulative gross amount already released through claim settlements (see [Claim Settlement](#claim-settlement) below). Initially `0`. MUST be strictly monotonically increasing and MUST NOT exceed `budget`.

All payout and refund computations in this specification are defined over the **unsettled remainder** `budget - settledAmount`. For jobs that never use claim settlement, `settledAmount` remains `0` and every formula reduces to the full budget.

Each job has its own [ERC-20](./eip-20.md) payment token. The token address is set alongside the amount when `setBudget` is called. This allows different jobs on the same contract to use different tokens.

### Optional provider (set later)

Jobs MAY be created **without a provider** by passing `provider = address(0)` to `createJob`. In that case the client SHALL set the provider later via `setProvider(jobId, provider, agentId?)` before funding. This supports flows such as bidding or assignment after creation.

- **setProvider(jobId, provider, agentId?)**
Called by **client** only. SHALL revert if job is not Open, the job has expired, the current `job.provider != address(0)`, `provider == address(0)`, `provider == job.client`, or `provider == job.evaluator`. SHALL set `job.provider = provider`. `agentId` is the provider's [ERC-8004](./eip-8004.md) agent identity; if non-zero, the contract MAY verify that `provider` is the owner or operator of that agentId on the ERC-8004 registry, and SHALL set `job.providerAgentId = agentId`. SHALL emit an event (e.g. ProviderSet) including the agentId. Implementations MAY allow an operator role to call setProvider in the future; this specification only requires client-only for the minimal protocol.
- **fund(jobId, expectedToken, expectedBudget)**
SHALL revert if `job.provider == address(0)` (provider MUST be set before funding), if `job.paymentToken != expectedToken`, or if `job.budget != expectedBudget` (front-running protection).

### Core Functions

- **createJob(provider, evaluator, expiredAt, description, hook?, providerAgentId?)**
Called by client. Creates job in Open with `client = msg.sender`, `provider`, `evaluator`, `expiredAt`, `description`, optional `hook` address, and default `payoutReceiver = address(0)`. SHALL revert if `evaluator` is zero, if `expiredAt <= block.timestamp + 5 minutes`, if `provider == evaluator`, or if `msg.sender == provider`. **Provider MAY be zero**; if so, client MUST call `setProvider` before `fund`. `hook` MAY be `address(0)` (no hook); if non-zero, the hook MUST be admin-whitelisted and SHOULD advertise support for the `IERC8183Hook` interface via ERC-165. `providerAgentId` is the provider's [ERC-8004](./eip-8004.md) agent identity; if `provider` is non-zero and `providerAgentId` is non-zero, SHALL set `job.providerAgentId = providerAgentId`; the contract MAY verify that `provider` is the owner or operator of that `providerAgentId` on the ERC-8004 registry. Returns `jobId`.
- **setPayoutReceiver(jobId, payoutReceiver)**
Called by provider. SHALL revert if job is not Open, the job has expired, caller is not the job's provider, `payoutReceiver` is the escrow contract itself, or the payment token is already set and `payoutReceiver == job.paymentToken`. SHALL set the provider-side payout recipient for the job. `payoutReceiver` MAY be `address(0)` to pay the provider directly. Implementations SHOULD emit `PayoutReceiverSet`.
- **setProvider(jobId, provider, agentId?)**
Called by client. SHALL revert if job is not Open, has expired, current `job.provider != address(0)`, `provider == address(0)`, `provider == job.client`, or `provider == job.evaluator`. SHALL set `job.provider = provider`. `agentId` is the provider's [ERC-8004](./eip-8004.md) agent identity; if non-zero, SHALL set `job.providerAgentId = agentId`; the contract MAY verify that `provider` is the owner or operator of that agentId on the ERC-8004 registry.
- **setBudget(jobId, token, amount, optParams?)**
Called by the job's provider. Sets `job.paymentToken = token` and `job.budget = amount`. SHALL revert if job is not Open, has expired, caller is not the provider, `token` is the zero address, or a nonzero `payoutReceiver` already equals `token`. Implementations SHOULD restrict `token` to an admin-managed allowlist of tokens with vetted ERC-20 semantics, to reject tokens that would break escrow accounting (e.g. fee-on-transfer, rebasing, transfer-hooked, pausable, or blacklist tokens); the reference implementation reverts with `PaymentTokenNotAllowed` for tokens not on the allowlist. `optParams` forwarded to hook if set.
- **fund(jobId, expectedToken, expectedBudget, optParams?)**
Called by client. SHALL revert if job is not Open, caller is not client, **provider is not set** (`job.provider == address(0)`), `job.paymentToken != expectedToken`, `job.budget != expectedBudget` (front-running protection), or job has expired (`block.timestamp >= expiredAt`). SHALL transfer `job.budget` of the job's payment token (`job.paymentToken`) from client to the contract (escrow) and set status to Funded. Implementations SHOULD verify that the contract's balance increased by exactly `job.budget` and revert otherwise, to defend against fee-on-transfer and rebasing tokens that would silently leave the escrow short; the reference implementation reverts with `UnexpectedFundedAmount` in that case. `optParams` forwarded to hook if set.
- **submit(jobId, deliverable, optParams?)**
Called by provider only. SHALL revert if caller is not the job's provider, or if `job.expiredAt > 0` and the job has expired. SHALL revert if job is not Funded, unless the job is Open with `budget == 0` (zero-budget job, no escrow needed). SHALL set status to Submitted and SHOULD record `submittedAt = block.timestamp` for grace-period accounting. `deliverable` (`bytes32`) is a reference to submitted work (e.g. hash of off-chain deliverable, IPFS CID, attestation commitment). SHALL emit an event including `deliverable` (e.g. JobSubmitted). `optParams` forwarded to hook if set.
- **complete(jobId, reason, optParams?)**
Called by evaluator only. SHALL revert if job is not Submitted or caller is not the job's evaluator. SHALL set status to Completed. SHALL transfer the unsettled remainder (`budget - settledAmount`) to the provider-side payout recipient, minus optional platform fee to a configurable treasury and optional evaluator fee paid to the evaluator address. `reason` MAY be `bytes32(0)` or an attestation hash (OPTIONAL). SHALL emit an event including `reason` if provided. `optParams` forwarded to hook if set.
- **reject(jobId, reason, optParams?)**
Called by **client or provider when job is Open**, or by **evaluator when job is Funded or Submitted**. SHALL revert if job is not Open, Funded, or Submitted, or if the caller is not authorised for the current status. SHALL set status to Rejected. If Funded or Submitted, SHALL refund the unsettled remainder (`budget - settledAmount`) to client. If a settlement claim is pending, SHALL clear it (see [Claim interactions](#claim-interactions) below). `reason` OPTIONAL. SHALL emit an event including `reason` and the caller (rejector) if provided. `optParams` forwarded to hook if set.
- **claimRefund(jobId, optParams)**
Callable by anyone when status is Open, Funded, or Submitted. SHALL revert if status is Open or Funded and `block.timestamp < job.expiredAt`. SHALL revert if status is Submitted and `block.timestamp < job.expiredAt + EVALUATION_GRACE_PERIOD` (see the grace-period rationale under [State Machine](#state-machine)). SHALL revert if a settlement claim is pending on a non-Submitted job (claims can only arise while Funded) — pending claims MUST be resolved (approved, rejected, or withdrawn) before an expiry refund. SHALL set status to Expired. If the prior status was Funded or Submitted, SHALL transfer the unsettled remainder (`budget - settledAmount`), if non-zero, to the client. MAY be hookable; a reverting hook can then block the refund (see the liveness caveat under [**Hook security**](#hook-security)). Implementations requiring an unconditional post-expiry refund SHALL keep `claimRefund` non-hookable.

> **Design rationale — refund forwarding for contract clients.** `claimRefund` is
> intentionally hookable *and* its callbacks are intentionally **blocking**, to support a
> `job.client` that is a contract standing in for the ultimate beneficiary (for example a
> smart account, custodial vault, or routing contract that fans funds out to an off-protocol
> recipient). The refund is paid to `job.client`, and `claimRefund`'s `afterAction` callback
> runs **after** that transfer (the ordering is normative: pay the client, then call
> `afterAction`). This lets the client contract observe the freshly received refund and
> **atomically forward it onward** to the rightful end-client within the same transaction.
>
> Because the forward and the refund must be all-or-nothing, the callback MUST be able to
> revert the entire `claimRefund`: a forward that fails (e.g. the downstream recipient
> reverts, or the client contract is misconfigured) MUST roll the refund back rather than
> leave funds stranded in the intermediary contract with no way to reach the beneficiary.
> A non-blocking (fail-open) callback would be unsafe here, since it would complete the
> refund into the intermediary while silently dropping the forward.
>
> The accepted cost is that the post-expiry refund is no longer *unconditionally* live: a
> buggy or fail-closed hook can revert and block it (see [**Hook security**](#hook-security)). Deployments that
> do not need contract-client forwarding SHOULD attach no hook (or a hook that never reverts
> on the `claimRefund` selector) so the refund stays unconditional.

#### Claim Settlement

While a job is Funded, escrow MAY be released incrementally through **claim settlement**, ahead of (or instead of) terminal completion. The four claim-settlement functions are core entry points like the lifecycle functions above; they are specified together because two settlement paths share one ledger:

- the **client-initiated path**: the client unilaterally settles an amount to the provider (`settleClaim`);
- the **provider-initiated path**: the provider files a pending claim (`submitClaim`) which the client or evaluator approves (`approveClaim`) or any of the three parties rejects (`rejectClaim`).

All settlement functions take a **cumulative amount** — the total gross amount the caller asserts should have been released to date — never a delta. Each settlement SHALL release exactly `cumulativeAmount - settledAmount`, then set `settledAmount = cumulativeAmount`. A settlement SHALL revert if `cumulativeAmount <= settledAmount` (no new settlement) or `cumulativeAmount > budget` (exceeds escrow). Because both paths write the same strictly-increasing `settledAmount`, no interleaving of client-initiated settlements, claim approvals, completion, rejection, and refund can release more than `budget` in total. The delta paid by a claim approval can only shrink between submission and approval, never grow.

At most one claim is pending per job. Implementations SHALL bind the pending claim by a hash over `(cumulativeAmount, deliverable, optParams)` so that approval and rejection require presenting the exact claim contents. As with `submit`, `deliverable` is a `bytes32` reference (e.g. hash of an off-chain deliverable, IPFS CID, attestation commitment); in a claim it identifies the milestone or phase being settled rather than the full work.

- **submitClaim(jobId, cumulativeAmount, deliverable, optParams?)**
Called by **provider** only. Files a pending claim against a Funded job; moves no funds. SHALL revert if the job is not Funded, has expired, `deliverable == bytes32(0)`, a claim is already pending, `cumulativeAmount <= settledAmount`, `cumulativeAmount > budget`, or an identical claim tuple `(cumulativeAmount, deliverable, optParams)` was previously filed on this job (replay protection; implementations SHOULD track consumed claim hashes). SHALL emit ClaimSubmitted including `optParams` so the exact claim preimage can be propagated to observers. `optParams` forwarded to hook if set.
- **settleClaim(jobId, cumulativeAmount, deliverable, optParams?)**
Called by **client** only. Immediate unilateral settlement: SHALL revert if the job is not Funded, has expired, `cumulativeAmount <= settledAmount`, or `cumulativeAmount > budget`. SHALL set `settledAmount = cumulativeAmount` and distribute the delta to the provider-side payout recipient (minus optional platform/evaluator fees). `deliverable` is the client's settlement attestation, not a verified provider claim. A pending claim SHALL NOT block this function (streaming settlement); settling reduces the delta any subsequent approval of that claim would pay. SHALL emit Settled and ClaimSettled. `optParams` forwarded to hook if set.
- **approveClaim(jobId, cumulativeAmount, deliverable, optParams?)**
Called by **client or evaluator**. SHALL revert if the job is not Funded, no claim is pending, or the arguments do not exactly match the pending claim — the evaluator MUST NOT be able to release amounts the provider did not claim. SHALL revert if `cumulativeAmount <= settledAmount` (e.g. the claim was already covered by a client-initiated settlement) or `cumulativeAmount > budget`. SHALL consume the pending claim, set `settledAmount = cumulativeAmount`, and distribute the delta to the provider-side payout recipient (minus optional fees). Approval is NOT subject to an expiry check: a claim filed before expiry remains approvable, for the same reason the evaluation grace period exists — a review in flight when the job expires may still finish. SHALL emit Settled and ClaimApproved. `optParams` forwarded to hook if set.
- **rejectClaim(jobId, cumulativeAmount, deliverable, reason, optParams?)**
Called by **client, evaluator, or provider** (the provider withdrawing their own stale claim, e.g. to file a corrected one). SHALL revert if the job is not Funded, no claim is pending, or the arguments do not exactly match the pending claim. SHALL consume the pending claim without moving funds. The consumed claim tuple SHALL remain unfilable — a corrected claim must differ in `cumulativeAmount`, `deliverable`, or `optParams`. SHALL emit ClaimRejected. `optParams` forwarded to hook if set.

##### Claim interactions

- **submit** SHALL supersede any pending claim — the provider is electing the full-completion path for the entire remainder — and SHOULD emit ClaimRejected with a supersession reason so hooks and indexers observe a closed claim lifecycle.
- **complete** requires no supersession logic: claims can only be filed while the job is Funded, and `complete` is callable only once the job is Submitted — by which point `submit` has already superseded any pending claim, so `complete` can never encounter one.
- Job-level **reject** SHALL also clear any pending claim (emitting ClaimRejected) before transitioning the job to Rejected.
- **claimRefund** SHALL revert while a claim is pending (claims can only arise while Funded); the claim must be approved, rejected, or withdrawn first. For non-hooked jobs the client can always unblock a refund in two transactions (`rejectClaim`, then `claimRefund`); for hooked jobs, a reverting `rejectClaim` hook can block this path (see [Hook security](#hook-security)).
- Implementations SHALL update `settledAmount` and clear the pending claim **before** any token transfers (checks-effects-interactions).

### Attestation

- **complete(jobId, reason, optParams?)**: `reason` is an optional attestation commitment (e.g. `bytes32` hash of off-chain evidence). Implementations MAY use `string` and hash it internally. Events SHOULD include `reason` for indexing and composition with reputation systems. `optParams` forwarded to hook if set.
- **reject(jobId, reason, optParams?)**: Optional `reason` for audit; same treatment as above. `optParams` forwarded to hook if set.

### Fees

Implementations MAY charge a **platform fee** and/or an **evaluator fee** (both in basis points). The platform fee is paid to a configurable treasury; the evaluator fee is paid to the job's evaluator address. The specification does not require either fee. If present, fees SHALL be computed independently on each settlement delta and on the completion remainder. Fees SHALL NOT be taken on refunds.

### Payout Receivers

`payoutReceiver` separates provider authorization from provider-side payout custody. If unset, provider-side net payouts go to `provider`. If set by the provider before funding, provider-side net payouts from `complete`, `settleClaim`, and `approveClaim` SHALL go to `payoutReceiver`. This does not change who may act as provider, who receives platform/evaluator fees, or who receives refunds. `payoutReceiver` MUST NOT be the escrow contract itself or the job's payment token, because either case would release funds to an address without a job accounting path for the provider.

Implementations MAY support `IDisburser` receivers. If the payout recipient is a contract that advertises `IDisburser` via ERC-165 at payout time, the implementation SHALL transfer the provider-side net amount first, then call `onDisbursement(jobId, selector, token, amount, optParams)`. Callback detection is dynamic: a receiver with no code when set can later deploy or delegate code and receive callbacks if it advertises `IDisburser` when paid. A revert from `onDisbursement` SHALL revert the parent action, including any platform or evaluator fee transfers made in that action. EOAs and contracts that do not advertise `IDisburser` are plain recipients. Implementations SHOULD skip the callback when the net provider-side amount is zero.

Dynamic callback detection adds ERC-165 probing cost to each nonzero payout routed to a contract receiver. This preserves payout-time behavior for receivers whose code appears or changes after the job is created; implementations SHOULD NOT cache receiver interface support unless they also change the documented dynamic semantics.

### Hooks (OPTIONAL)

Implementations MAY support an optional **hook contract** per job to extend the core protocol without modifying it. The hook address is set at job creation (or `address(0)` for no hook) and stored on the job. A **non-hooked implementation** that ignores the `hook` field (or always sets it to `address(0)`) is fully compliant with this specification. The reference `ERC8183` contract supports both modes in a single contract: jobs with `hook == address(0)` skip all callbacks, and jobs with a whitelisted hook receive `beforeAction` / `afterAction` callbacks on the hookable functions listed below.

A hook contract SHALL implement the `IERC8183Hook` interface — just two functions:

```solidity
interface IERC8183Hook {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
```

The `selector` parameter identifies which core function is being called (e.g. the function selector for `fund`). The `data` parameter contains function-specific parameters encoded as bytes (see [Data encoding](#data-encoding) below). The hook uses the selector to route internally:

```solidity
function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
    if (selector == FUND_SELECTOR) {
        // custom pre-fund logic using data (optParams)
    } else if (selector == COMPLETE_SELECTOR) {
        // custom pre-complete logic using data (reason, optParams)
    }
}
```

When a job has a hook set, the core contract SHALL call `hook.beforeAction(...)` and `hook.afterAction(...)` around each hookable function. `createJob` is `afterAction`-only — no hook is attached before the job exists — so the after-callback is where a hook initializes per-job bookkeeping or reverts to reject the job. Non-hooked implementations simply ignore the field.

| Core function  | Hookable |
| -------------- | -------- |
| `createJob`    | **Yes (`afterAction` only)** |
| `setPayoutReceiver` | Yes |
| `setProvider`  | Yes      |
| `setBudget`    | Yes      |
| `fund`         | Yes      |
| `submit`       | Yes      |
| `complete`     | Yes      |
| `reject`       | Yes      |
| `submitClaim`  | Yes      |
| `settleClaim`  | Yes      |
| `approveClaim` | Yes      |
| `rejectClaim`  | Yes      |
| `claimRefund`  | Yes — but see the liveness caveat under [**Hook security**](#hook-security) (a reverting hook can block the permissionless refund) |

#### Data encoding

The `data` parameter passed to hooks contains the core function's parameters encoded as bytes. The encoding per selector:

| Core function  | `data` encoding                                      |
| -------------- | ---------------------------------------------------- |
| `createJob`    | `abi.encode(address actor, address provider, address evaluator, uint48 expiredAt, address hook, uint256 providerAgentId, bytes optParams)` |
| `setProvider`  | `abi.encode(address actor, address provider, uint256 agentId, bytes optParams)` |
| `setPayoutReceiver` | `abi.encode(address actor, address payoutReceiver, bytes optParams)` |
| `setBudget`    | `abi.encode(address actor, address token, uint256 amount, bytes optParams)` |
| `fund`         | `abi.encode(address actor, bytes optParams)`         |
| `submit`       | `abi.encode(address actor, bytes32 deliverable, bytes optParams)` |
| `complete`     | `abi.encode(address actor, bytes32 reason, bytes optParams)` |
| `reject`       | `abi.encode(address actor, bytes32 reason, bytes optParams)` |
| `submitClaim`  | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `settleClaim`  | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `approveClaim` | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes optParams)` |
| `rejectClaim`  | `abi.encode(address actor, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes optParams)` |
| `claimRefund`  | `abi.encode(address actor, bytes optParams)` |

`actor` is the principal who authorized the action: `msg.sender` for direct calls, the EIP-712 signer for `*WithAuthorization` calls, and `msg.sender` (whoever triggered the refund) for the permissionless `claimRefund`. For `createJob`, `providerAgentId` is the value stored on the job (zero for a providerless job), so it always agrees with `jobs[jobId]`.

When `submit` or `reject` supersedes a pending claim, no claim-specific hook callback fires for the supersession itself; hooks observe the post-supersession claim state in the `submit`/`reject` callbacks.

#### Hook behaviour

- The `optParams` field (`bytes`, OPTIONAL) on each hookable core function is an opaque payload forwarded to the hook via the `data` parameter. Callers that do not use hooks MAY pass empty bytes. The core contract SHALL NOT interpret `optParams`.
- **Before hooks** (`beforeAction`) are called before the core logic executes. A before hook MAY revert to block the action (e.g. enforce custom validation, allowlists, or preconditions).
- **After hooks** (`afterAction`) are called after the core logic completes (including state changes and token transfers). An after hook MAY perform side effects (e.g. emit events, update external state, trigger notifications) or revert to roll back the entire transaction.
- If `job.hook == address(0)`, the core contract SHALL skip hook calls and execute normally.

#### Hook security

- Hooks are **trusted** contracts chosen by the client at job creation. A malicious or buggy hook can revert valid actions or execute arbitrary logic in callbacks. Clients SHOULD audit or use well-known hook implementations.
- **Liveness:** a reverting hook can block every hookable action, including the post-expiry refund; a hook that consumes unbounded gas blocks identically, so gas exhaustion counts as a revert throughout this section. The contract does not verify that a forwarded refund moved onward. See the design rationale under `claimRefund` in [Core Functions](#core-functions).
- **Audit obligations:** a whitelisted hook MUST NOT revert on `claimRefund` (except for a genuine forward failure), consume unbounded gas on any hooked selector, derive routing or authorization from the caller-supplied `optParams` on that permissionless path, or no-op a refund it is expected to forward.
- **Break-glass:** under `pause()`, admin `forceRefund` applies `claimRefund`'s eligibility with hook callbacks skipped, pays the client (or an admin-chosen recipient when the client contract cannot receive funds), and expires the job atomically — a rescued job cannot be refunded twice. Implementations SHOULD emit a dedicated event (`ForceRefunded(jobId, admin, recipient, amount)` in the reference implementation). `batchDetachHook` suits non-forwarding hooks; `emergencyWithdraw` is reserved for funds not attributed to any job. Deployments that need an unconditional post-expiry refund SHOULD attach no hook (or a non-reverting hook).
- **Atomicity:** After-callbacks run after state changes but within the same transaction. If an after-callback reverts, the entire transaction (including the core state change) is rolled back. This is intentional — it enables atomic multi-step flows (e.g. escrow funding + side token transfer must both succeed or both revert).
- `onlyERC8183` modifiers on hooks are RECOMMENDED so that hook functions cannot be called directly by external actors.
- Hooks SHOULD NOT be upgradeable after a job is created, as this would allow the hook to change behaviour mid-job.
- Implementations MAY maintain an allowlist or registry of audited hook contracts to reduce risk for clients.

#### Convenience base contract (non-normative)

Implementations MAY provide a `BaseERC8183Hook` that routes the generic `beforeAction`/`afterAction` calls to named virtual functions (e.g. `_preFund`, `_postComplete`) so hook developers only override what they need. This is NOT part of the standard — only `IERC8183Hook` is normative.

#### Example use cases

- Pre-fund validation (e.g. KYC check, allowlist gate)
- Post-complete reputation updates (e.g. writing attestations to ERC-8004)
- Custom fee logic or payment splitting
- Atomic side transfers (e.g. fund transfer hook)
- Provider bidding (e.g. bidding hook)

---

#### Example 1 — Fund Transfer Hook (two-phase escrow)

**Problem:** A client hires an agent to convert/bridge/swap tokens (e.g. USDC → DAI). The client provides capital to the provider, who uses it to produce output tokens. The hook must ensure the provider deposits the output tokens before the job completes, then release them to the designated buyer.

**Solution:** A `FundTransferHook` that (a) stores a transfer commitment at `setBudget`, (b) forwards capital to the provider at `fund`, (c) pulls output tokens from the provider at `submit`, and (d) releases them to the buyer at `complete`.

```
Step 1 — createJob
  Client → createJob(provider, evaluator, expiredAt, desc, hook=FundTransferHook, providerAgentId=0)
  Job created (Open), hook address stored.

Step 2 — setBudget
  Provider → setBudget(jobId, USDC, serviceFee, optParams=abi.encode(buyer, transferAmount))
    → hook.beforeAction: decode optParams, store {buyer, transferAmount} as commitment.
    → core: job.paymentToken = USDC, job.budget = serviceFee

Step 3 — fund
  Client approves: core contract for serviceFee, hook for transferAmount.
  Client → fund(jobId, USDC, serviceFee, "")
    → hook.beforeAction: verify client approved hook for transferAmount. Revert if not.
    → core: pull serviceFee into escrow, set Funded.
    → hook.afterAction: pull transferAmount from client, forward to provider (capital).

Step 4 — provider uses capital to produce output tokens

Step 5 — submit
  Provider approves hook for transferAmount (output tokens).
  Provider → submit(jobId, deliverable, "")
    → hook.beforeAction: pull transferAmount from provider into hook (escrow).
    → core: set Submitted.

Step 6 — complete
  Evaluator → complete(jobId, reason, "")
    → core: release serviceFee to provider / payout receiver (minus platform fee).
    → hook.afterAction: release transferAmount from hook to buyer.

Recovery:
  - reject: hook.afterAction returns escrowed tokens to provider (if deposited).
  - expiry: claimRefund refunds serviceFee to client.
    Provider calls recoverTokens(jobId) on hook to recover deposited tokens.
```

**Key properties:** (1) The provider cannot submit without depositing output tokens. (2) The buyer only receives tokens when the evaluator completes the job. (3) On rejection or expiry, tokens are returned to the provider.

---

#### Example 2 — Bidding Hook

**Problem:** A client wants to hire the cheapest (or best) agent for a job but does not know upfront who to assign. The selection should be determined by an open bidding process, not unilaterally by the client after the fact.

**Solution:** A `BiddingHook` that verifies off-chain signed bids. Providers sign bid commitments off-chain; the client collects bids, selects the winner, and submits the winning bid's signature via `setProvider`. The hook's `beforeAction` callback recovers the signer and verifies it matches the chosen provider — proving the provider actually committed to that price.

Zero direct calls to the hook. All interactions flow through the core contract → hook callbacks.

> Note: this example assumes an implementation that permits the client to call `setBudget` while the provider is unset (to open bidding). The reference implementation restricts `setBudget` to the job's provider, so a bidding deployment would relax that restriction or coordinate the bidding window off-chain.

```
Step 1 — createJob
  Client → createJob(provider=0, evaluator, expiredAt, desc, hook=BiddingHook, providerAgentId=0)
  Job created (Open), provider = address(0).

Step 2 — setBudget (opens bidding via hook callback)
  Client → setBudget(jobId, USDC, maxBudget, optParams=abi.encode(biddingDeadline))
    → hook.beforeAction: store deadline for this jobId.

Step 3 — bidding happens OFF-CHAIN
  Providers sign: keccak256(abi.encode(chainId, hookAddress, jobId, bidAmount))
  Client collects signed bids and selects the winner.
  Core contract is unaware of bids.

Step 4 — setProvider + setBudget (hook verifies winning bid signature and enforces budget)
  Client → setProvider(jobId, winnerAddress, agentId=0, optParams=abi.encode(bidAmount, signature))
    → hook.beforeAction: verify deadline passed, recover signer from signature,
      validate signer == provider, store committed bidAmount. Revert if invalid.
    → core: job.provider = winnerAddress
    → hook.afterAction: mark bidding finalised (no further setProvider possible).
  Client → setBudget(jobId, USDC, bidAmount, "")
    → hook.beforeAction: enforce budget == committedAmount. Revert if mismatch.

Step 5 — job continues normally
  Client → fund(jobId, USDC, bidAmount, "")
  Provider → submit(jobId, deliverable, "")
  Evaluator → complete(jobId, reason, "")
```

**Key property:** The client cannot fabricate a provider commitment. The hook verifies the chosen provider actually signed a bid at the claimed price. The client is incentivised to pick the lowest bidder since they are the one paying.

---

### Events

Implementations SHOULD emit at least:

- **JobCreated**(jobId, client, provider, evaluator, expiredAt, hook) — includes the hook address (`address(0)` if no hook)
- **ProviderSet**(jobId, actor, provider, agentId) — when provider is set on a job that was created without one; `actor` is the caller (or authorizing signer); `agentId` is 0 if not specified
- **BudgetSet**(jobId, actor, token, amount) — `actor` is the caller (or authorizing signer); includes the payment token address
- **JobFunded**(jobId, client, amount)
- **JobSubmitted**(jobId, provider, deliverable) — when provider submits work for evaluation
- **PayoutReceiverSet**(jobId, actor, payoutReceiver) — when a provider-side payout receiver is set or updated; `actor` is the caller (or authorizing signer)
- **JobCompleted**(jobId, evaluator, reason)
- **JobRejected**(jobId, rejector, reason)
- **JobExpired**(jobId)
- **PaymentReleased**(jobId, recipient, amount) — net provider-side amount paid to the provider or payout receiver on completion or on each settlement
- **Disbursed**(jobId, receiver, selector, amount) — emitted after `IDisburser.onDisbursement` is invoked
- **PlatformFeePaid**(jobId, platformTreasury, amount) — only emitted when a non-zero platform fee is taken
- **EvaluatorFeePaid**(jobId, evaluator, amount) — only emitted when a non-zero evaluator fee is taken
- **Refunded**(jobId, recipient, amount) — recipient is the client, except under a `forceRefund` destination override (see `ForceRefunded` below)
- **Settled**(jobId, cumulativeAmount, delta) — emitted on every settlement regardless of path
- **ClaimSubmitted**(jobId, provider, cumulativeAmount, delta, deliverable, optParams) — provider files a pending claim; `optParams` is emitted so the exact claim preimage can be propagated to observers
- **ClaimSettled**(jobId, settler, cumulativeAmount, delta, deliverable) — client-initiated settlement; `deliverable` is the settler's attestation, not a verified provider claim
- **ClaimApproved**(jobId, approver, cumulativeAmount, delta, deliverable) — pending claim approved by client or evaluator
- **ClaimRejected**(jobId, rejector, reason) — pending claim rejected, withdrawn, or superseded

Note that `PaymentReleased`, `PlatformFeePaid`, and `EvaluatorFeePaid` fire on each settlement, not only on completion.

Implementations that add admin tooling SHOULD also emit operational events (e.g. `HookWhitelistUpdated`, `PaymentTokenAllowlistUpdated`, `HookDetached`, `PlatformFeeUpdated`, `EvaluatorFeeUpdated`, `ForceRefunded`, `EmergencyWithdraw`) so off-chain indexers can track configuration changes.

## Rationale

- **Single attester after submission**: Once Submitted, only the evaluator can complete or reject; the client cannot pull funds back unilaterally, so the provider is protected after starting work. Evaluator = client covers the "no third party" case.
- **Explicit submission**: The Submitted state gives the evaluator (and indexers/UIs) a clear signal that the provider considers work done and ready for evaluation, separating "funded and in progress" from "work delivered".
- **Minimal surface**: Attestation is the optional `reason` on complete/reject; no additional ledger is required.
- **Four states**: Open, Funded, Submitted, and Terminal (Completed, Rejected, or Expired) are enough for "fund → work → submit → evaluate or refund".
- **Expiry**: Refund after `expiredAt` gives client a way to reclaim funds without an explicit reject.
- **Cumulative amounts, not deltas**: Settlement functions take the cumulative total released to date, making them idempotent under replay and benign under races — a re-submitted or stale settlement reverts (no new settlement) instead of double-paying.
- **Two settlement paths, one ledger**: Unilateral client settlement (`settleClaim`) and attested claim approval (`approveClaim`) carry different authorization semantics — who may call, expiry behaviour, and what is being consented to — and deliberately remain separate functions with distinct selectors, keeping caller intent explicit on-chain and immune to front-running between paths. They share one monotone `settledAmount`, which is the cross-path double-payment defense.
- **Single pending claim, hash-bound**: Storing only a hash of the pending claim keeps storage minimal and forces approvers to present (and, in the Signed Authorizations extension, sign over) the full claim contents they are approving.
- **Payout receivers**: A provider may route provider-side net payouts through a receiver contract or custody address without changing who controls the job lifecycle. Optional `IDisburser` callbacks let receivers split or forward funds they already received while keeping escrow accounting in the core contract.
- **Hooks over inheritance**: Optional hook contracts let integrators extend the protocol (validation, reputation, fees) without modifying or inheriting from the core contract. The core stays minimal; complexity lives in the hook.
- **Generic hook interface**: The `IERC8183Hook` interface uses just two functions (`beforeAction`/`afterAction`) with a selector parameter rather than named functions per action. This keeps the interface stable as the core protocol evolves — new hookable functions simply produce new selector values without changing the interface.

### Extensions (OPTIONAL)

The following extensions are OPTIONAL and do not modify the core protocol. Implementations MAY adopt them independently.

#### Reputation / Attestation Interop (ERC-8004)
 
Agentic Commerce is intentionally minimal and does not embed a reputation system. For on-chain reputation and trust relationships between agents, implementations are RECOMMENDED to integrate with [ERC-8004](./eip-8004.md) (Trustless Agents).

The following patterns are RECOMMENDED:

- **Outcome‑based trust signals**
  - Each job outcome SHOULD be mapped into a trust signal for the participants:
    - `Completed`: positive signal for provider (and optionally evaluator) based on successful delivery.
    - `Rejected`: negative or neutral signal, depending on the reason and who rejected (client vs evaluator).
    - `Expired`: neutral or mildly negative signal for client (for not evaluating) or for provider (for not submitting), depending on higher‑level policy.
  - Implementations MAY emit ERC‑8004 compatible events or call ERC‑8004 registries when a job reaches a terminal state.

- **Evaluator attestations**
  - On `complete(jobId, reason, optParams?)` and `reject(jobId, reason, optParams?)`, the evaluator (which MAY be a contract) SHOULD:
    - produce an attestation or structured log that can be added to the ERC‑8004 **reputation registry** as feedback (e.g. "provider successfully completed job", "job rejected for reason X"). Attestations MAY reference the job, parties, and `reason` (e.g. a hash of off‑chain evidence).
    - and/or post a proof to the ERC‑8004 **validation registry**, which a hook (or evaluator contract) then reads in order to decide whether to mark the job as `Completed` or `Rejected`.
  - Hooks MAY be used to call into ERC‑8004 registries in `afterAction` for `complete`/`reject`, keeping the core ERC-8183 contract unaware of the registry details.

- **Reputation‑aware policy via hooks**
  - Hooks MAY consult ERC‑8004 data before allowing certain actions, for example:
    - preventing `setProvider` from assigning providers below a reputation threshold,
    - enforcing higher budgets or additional safeguards for low‑reputation agents,
    - dynamically selecting evaluators based on reputation.
  - Such checks belong in policy‑oriented `beforeAction` hooks so they can safely revert and block actions that violate reputation policies.

- **On-chain identity binding via agentId**
  - When `setProvider` (or `createJob`) is called with a non-zero `agentId`, the job stores `providerAgentId` on-chain. This enables direct identity binding: hooks and evaluator contracts can look up the provider's ERC‑8004 agent record without off-chain mapping.
  - Reputation writes (e.g. on `complete` or `reject`) can reference the stored `providerAgentId` to attribute outcomes to the correct agent identity in the ERC‑8004 registry.

- **Separation of concerns**
  - ERC-8183 remains the **payment and escrow** layer; ERC‑8004 is the **identity and reputation** layer.
  - Interop is achieved by:
    - storing the provider's `agentId` on the job for direct identity lookup,
    - emitting events that ERC‑8004 indexers can consume, and/or
    - calling ERC‑8004 contracts from hooks or evaluator contracts.

---

#### Signed Authorizations ([EIP-712](./eip-712.md))

To support gasless execution — where a client, provider, or evaluator signs an intent off-chain and a **facilitator** submits the transaction on their behalf — implementations SHOULD support signed authorizations: per-call [EIP-712](./eip-712.md) inner signatures in the style of [ERC-3009](./eip-3009.md). Unlike an [ERC-2771](./eip-2771.md) trusted-forwarder relay (which implementations MAY support instead), an inner signature binds the exact call parameters and requires no privileged forwarder contract in the trust base.

**How it works:**

1. A participant signs an EIP-712 authorization off-chain for a specific action (e.g. `fund`, `submit`, `approveClaim`), binding all of that action's parameters plus a nonce and deadline.
2. Any facilitator submits the signed payload to the corresponding `*WithAuthorization` entry point.
3. The contract verifies the signature and executes the core function with the **signer** as the acting party.

**Implementation requirements:**

- Each actor-authorized core function (all except the permissionless `claimRefund`) SHALL have a `*WithAuthorization` variant accepting the original parameters plus an `Authorization { address signer; uint72 nonce; uint256 deadline; bytes sig; }`. The reference implementation wraps `createJob`'s parameters in a `CreateJobAuthorizationParams` struct to stay within stack limits.
- Each action SHALL have a distinct EIP-712 typehash binding `signer`, all call parameters (dynamic values such as `description` and `optParams` bound by their `keccak256` hash), `nonce`, and `deadline`, so a signature for one action can never execute another.
- `completeWithAuthorization` and `rejectWithAuthorization` SHALL additionally bind the job's stored `submittedAt` value in the signed payload. The value is `0` for an Open or Funded job that has not been submitted, and the actual stored timestamp for a Submitted job.
- Nonces SHALL be unordered (random-nonce style, as in ERC-3009) and single-use across all action types. The reference implementation packs them as `bytes32((uint256(uint160(signer)) << 96) | uint256(nonce))` in a single used-nonce mapping.
- The nonce SHALL be marked used before external signature verification, and verification SHALL support [ERC-1271](./eip-1271.md) contract signers in addition to EOAs.
- Authorizations SHALL expire after `deadline`.
- **cancelAuthorization(nonce)**: the signer (and only the signer — cancellation is deliberately not relayable) SHALL be able to burn an unused nonce so an outstanding signature can never be executed. Cancellation SHALL remain callable while the contract is paused, so signers can revoke outstanding authorizations during incidents. SHALL revert if the nonce was already used or cancelled.
- The contract SHALL emit an event on use and on cancellation — the reference implementation emits `AuthorizationUsed(address indexed signer, bytes32 indexed nonce)` on use and `AuthorizationCanceled(address indexed signer, bytes32 indexed nonce)` on cancellation, both with the packed nonce — and SHOULD expose `DOMAIN_SEPARATOR()`. The reference implementation uses the EIP-712 domain `{ name: "ERC8183", version: "1" }`.

**Token approvals:** For functions that pull tokens (e.g. `fundWithAuthorization`), the signer SHOULD use [ERC-2612](./eip-2612.md) (`permit`) to approve token spending via signature. The facilitator can then call `permit` and `fundWithAuthorization` in a single transaction — no on-chain approval tx needed from the signer.

**x402 compatibility:** This extension enables compatibility with HTTP-native payment protocols such as x402, where an AI agent signs payment intents off-chain and a payment facilitator handles on-chain execution. The agent needs only a private key and tokens; the facilitator pays gas and submits the transactions.

---

## Backwards Compatibility

No backward compatibility issues found. Claim settlement is additive over earlier drafts: a job whose claim-settlement functions are never called has `settledAmount = 0`, so every payout and refund formula reduces to the original full-budget behaviour. The Signed Authorizations extension adds entry points only and does not change job semantics. Implementations retrofitting signed authorizations onto a live proxy MUST note that (re)initializing the EIP-712 domain invalidates any authorization signed under a previous domain; this is intentional signature revocation.

## Reference Implementation

The reference implementation consists of `IERC8183Hook`, the optional and minimal hook interface that developers implement; `IDisburser`, the optional payout receiver callback interface; `ERC8183`, the core Job primitive with escrow and optional hook extension points; and `ERC8183WithAuthorization`, the Signed Authorizations extension.

### IERC8183Hook.sol

```solidity
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC8183Hook is IERC165 {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
```

### IDisburser.sol

```solidity
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IDisburser is IERC165 {
    function onDisbursement(uint256 jobId, bytes4 selector, address token, uint256 amount, bytes calldata data) external;
}
```

### Core and Authorization Interfaces

The interfaces below summarize the core job escrow with claim settlement, payout receivers, hooks, and the Signed Authorizations extension.

```solidity
interface IERC8183 {
    // ── Job lifecycle ──
    function createJob(address provider, address evaluator, uint48 expiredAt, string calldata description, address hook, uint256 providerAgentId, bytes calldata optParams) external returns (uint256 jobId);
    function setPayoutReceiver(uint256 jobId, address payoutReceiver, bytes calldata optParams) external;
    function setProvider(uint256 jobId, address provider, uint256 agentId, bytes calldata optParams) external;
    function setBudget(uint256 jobId, address token, uint256 amount, bytes calldata optParams) external;
    function fund(uint256 jobId, address expectedToken, uint256 expectedBudget, bytes calldata optParams) external;
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function claimRefund(uint256 jobId, bytes calldata optParams) external;

    // ── Claim settlement ──
    function submitClaim(uint256 jobId, uint256 cumulativeAmount, bytes32 deliverable, bytes calldata optParams) external;
    function settleClaim(uint256 jobId, uint256 cumulativeAmount, bytes32 deliverable, bytes calldata optParams) external;
    function approveClaim(uint256 jobId, uint256 cumulativeAmount, bytes32 deliverable, bytes calldata optParams) external;
    function rejectClaim(uint256 jobId, uint256 cumulativeAmount, bytes32 deliverable, bytes32 reason, bytes calldata optParams) external;
}
```

The Signed Authorizations extension adds, for each actor-authorized function above (all except the permissionless `claimRefund`), a `*WithAuthorization` variant taking the same parameters plus the `Authorization` struct below. `completeWithAuthorization` and `rejectWithAuthorization` also bind the job's stored `submittedAt` value in the signed payload, and `createJobWithAuthorization` wraps the job parameters in a `CreateJobAuthorizationParams` struct:

```solidity
struct Authorization {
    address signer;
    uint72 nonce;
    uint256 deadline;
    bytes sig;
}

function cancelAuthorization(uint72 nonce) external;
function DOMAIN_SEPARATOR() external view returns (bytes32);
```

## Security Considerations

- Evaluator is trusted for completion and rejection once the job is Submitted; a malicious evaluator can complete or reject arbitrarily. Use reputation (e.g. [ERC-8004](./eip-8004.md)) or staking for high-value jobs.
- Once Funded, only the evaluator can reject, and only the provider can submit; the client cannot unilaterally withdraw, which protects the provider after they start work.
- **Evaluator settlement scope:** the evaluator can approve only the exact pending claim the provider filed, never originate or alter amounts; the client can settle freely but only toward the job's provider out of their own escrow. Widening either authority breaks the trust model — in particular, allowing the evaluator to settle arbitrary amounts would escalate the evaluator from attestor to spender of client escrow.
- **Provider-controlled payout receiver:** `payoutReceiver` controls where provider-side net payouts are sent and is therefore set by the provider while the job is Open. The reference design locks the receiver once the job is Funded so funded jobs cannot be rerouted away from a receiver that downstream custody, financing, or disbursement flows may rely on. Providers SHOULD choose receiver contracts carefully: a receiver that advertises `IDisburser` and reverts (or consumes unbounded gas) in `onDisbursement` will roll back completion or settlement, including platform and evaluator fee transfers, at the cost of blocking the provider's own payout. Evaluators can reject a Funded or Submitted job rather than complete into a reverting receiver, which refunds the client and pays no one.
- **Dynamic receiver code:** `IDisburser` detection happens at payout time. A plain EOA receiver can later gain delegated code through mechanisms such as [EIP-7702](./eip-7702.md), and a counterfactual receiver can later deploy code at the selected address. These changes can make callbacks begin firing after the job was funded; because only the provider can select the receiver, this is provider-controlled risk.
- **Pending-claim refund blocking is bounded griefing:** a provider's pending claim blocks `claimRefund` on a Funded job past expiry, but on non-hooked jobs the client can always clear it with `rejectClaim` and refund in the next transaction. On hooked jobs a reverting `rejectClaim` hook can keep the claim pinned; clients accepting a hook accept this as part of the job's policy.
- **Consumed claim hashes:** rejected or withdrawn claim tuples remain consumed, so a rejected claim cannot be silently refiled and later approved; a refile must visibly differ in `cumulativeAmount`, `deliverable`, or `optParams`.
- **Authorization liveness:** a signed authorization is live until its deadline, use, or cancellation. `cancelAuthorization` remaining callable while paused is a deliberate incident-response property — pausing the contract must not trap signers with outstanding signatures.
- **Terminal authorization context:** `completeWithAuthorization` and `rejectWithAuthorization` bind the stored `submittedAt` value in addition to the action parameters, nonce, and deadline. This prevents a pre-signed terminal action for a non-submitted job (`submittedAt = 0`) from applying after the provider submits work, because the signed status snapshot no longer matches the stored job state.
- No dispute resolution or arbitration; reject/expire is final.
- Per-job payment tokens increase flexibility but also expand the attack surface; implementations SHOULD validate that payment token addresses are legitimate ERC-20 contracts (e.g. via an allowlist or registry check) to mitigate risks from malicious token contracts.
- **Reentrancy:** Functions that transfer tokens SHALL be protected (e.g. reentrancy guard). Claim settlement transfers tokens mid-lifecycle (not only terminally), so effects-before-transfers ordering (update `settledAmount`, clear the pending claim, then transfer) is mandatory, not advisory.
- **Tokens:** Use SafeERC-20 or equivalent for [ERC-20](./eip-20.md).
- **Evaluator:** MUST be set at creation; if "client completes", pass `evaluator = client`.
- **Hook gas** (for hooked implementations): Implementations MAY impose a per-call gas limit on hook calls. The reference implementation instead relies on the whitelist audit — a hook that consumes unbounded gas is treated as blocking, per the audit obligations under [Hook security](#hook-security).
- Hook contracts are client-supplied and trusted by the client; implementations MUST NOT allow hooks to modify core escrow state directly. Where `claimRefund` is hookable (as in the reference implementation), a reverting hook can block refunds after expiry; see [Hook security](#hook-security) for the whitelist-audit and break-glass mitigations. Any rescue path MUST close the job's accounting atomically with the payout so a rescued job cannot be refunded twice; a free-form escape hatch like `emergencyWithdraw` SHOULD be reserved for funds not attributed to any job. Implementations requiring an unconditional, trust-minimized post-expiry refund SHALL keep `claimRefund` non-hookable.
- Jobs that use **advanced hooks** (e.g. two‑phase escrow / fund‑transfer hooks that custody additional tokens) are expected to have **more revert paths and tighter coupling** to external logic than plain, non‑hooked Agentic Commerce jobs. Such hooks SHOULD be reserved for agents and users who understand and accept this trade‑off; for most simple jobs, a non‑hooked or policy‑only hook is RECOMMENDED.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
