# ERC-8183 Flow Diagrams

## State Machine

```mermaid
stateDiagram-v2
    [*] --> Open: createJob()

    Open --> Open: setBudget()\nsetProvider()
    Open --> Funded: fund()\n💰 budget escrowed
    Open --> Rejected: reject()\n[client or provider]
    Open --> Expired: claimRefund()\n[after expiry]\n(no escrow to refund)

    Funded --> Submitted: submit(deliverable)\n[provider only]
    Funded --> Funded: submitClaim()\n[provider direct or authorization]\npending claim
    Funded --> Funded: settleClaim()\n[client direct or authorization]\n💸 delta released
    Funded --> Funded: approveClaim()\n[client/evaluator direct or authorization]\n💸 delta released
    Funded --> Funded: rejectClaim()\n[client/evaluator direct or authorization]\npending cleared
    Funded --> Rejected: reject()\n[evaluator only]\n↩️ client refunded
    Funded --> Expired: claimRefund()\n[after expiry]\n[after claim grace if pending]\n↩️ client refunded

    Submitted --> Completed: complete(reason)\n[evaluator only]\n💸 provider paid
    Submitted --> Rejected: reject(reason)\n[evaluator only]\n↩️ client refunded
    Submitted --> Expired: claimRefund()\n[after expiry + grace]\n↩️ client refunded

    Completed --> [*]
    Rejected --> [*]
    Expired --> [*]
```

Claims have separate slow and fast paths while the job remains `Funded`. In the slow path, the provider calls `submitClaim` or signs `submitClaimWithAuthorization` before expiry to record a pending nonzero-deliverable claim. The client or evaluator then approves or rejects it, directly or through `approveClaimWithAuthorization` / `rejectClaimWithAuthorization`. In the fast path, the client calls `settleClaim` or signs `settleClaimWithAuthorization` before expiry to release the new cumulative delta immediately. Both paths settle only `cumulativeAmount - settledAmount`. If the provider later calls `submit` for the final deliverable, that submission supersedes any pending claim and clears it because the provider is requesting the full remaining escrow through the normal completion path.

After expiry, `claimRefund` is callable by anyone. For `Submitted` jobs, it is gated by an additional `EVALUATION_GRACE_PERIOD` (1 hour) so that an evaluator who is mid-review cannot be censored by a third-party refund call. For pending provider claims, refund is gated by `CLAIM_RESOLUTION_GRACE_PERIOD` (1 hour); during that window no new claims can be opened, but the existing claim can still be approved or rejected. Refunds, claim settlements, and final completion only use the unsettled escrow balance, so funds released by claims are not double-paid or double-refunded.

`ERC8183WithAuthorization` uses the same EIP-712 domain as the base protocol: name `ERC8183`, version `1`. The authorization contract extends ERC8183 entrypoints rather than creating a separate signing domain; upgraded proxies can call `initializeAuthorizationV2()` during `upgradeToAndCall` to initialize EIP-712 storage when the prior implementation did not already do so.

## Sequence — Typical Job Flow (No Hook)

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant P as Provider
    participant E as Evaluator

    Note over AC: Status: Open
    C->>AC: createJob(provider, evaluator, expiry, desc, address(0), agentId)
    P->>AC: setBudget(jobId, token, amount, "0x")
    C->>AC: fund(jobId, expectedBudget, "0x")
    Note over AC: 💰 Budget escrowed (balance delta == budget)
    Note over AC: Status: Funded

    P->>AC: submit(jobId, deliverable, "0x")
    Note over AC: Status: Submitted

    E->>AC: complete(jobId, reason, "0x")
    Note over AC: 💸 platform fee → treasury<br/>💸 evaluator fee → evaluator<br/>💸 net → provider
    Note over AC: Status: Completed
```

## Sequence — Claim Settlement

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant P as Provider
    participant E as Evaluator

    Note over AC: Status: Funded

    alt Slow path: provider claim request
        P->>AC: submitClaim(jobId, cumulativeAmount, deliverable, optParams)
        Note over AC: pending claim hash stored
        C->>AC: approveClaim(jobId, cumulativeAmount, deliverable, optParams)
        Note over AC: 💸 delta released
    else Fast path: client-authorized settlement
        C->>AC: settleClaim(jobId, cumulativeAmount, deliverable, optParams)
        Note over AC: 💸 delta released immediately
    end

    Note over C,AC: Relayed fast path: client signs SettleClaimAuthorization,<br/>relayer calls settleClaimWithAuthorization(...)
    Note over P,AC: Relayed slow path: provider signs SubmitClaimAuthorization,<br/>relayer calls submitClaimWithAuthorization(...)
```

## Sequence — Job with Hook

`createJob` is not hookable in the reference implementation — the hook is stored on the job but no callbacks fire on creation. Hooks begin firing on `setBudget`.

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant H as Hook (IERC8183Hook)
    participant P as Provider
    participant E as Evaluator

    C->>AC: createJob(provider, evaluator, expiry, desc, hook, agentId)
    Note over AC: Status: Open (hook stored, no callback)

    P->>AC: setBudget(jobId, token, amount, optParams)
    AC->>H: beforeAction(jobId, setBudget.selector, data)
    Note over H: CAN revert to block
    AC->>H: afterAction(jobId, setBudget.selector, data)

    C->>AC: fund(jobId, expectedBudget, optParams)
    AC->>H: beforeAction(jobId, fund.selector, data)
    Note over AC: 💰 Budget escrowed
    AC->>H: afterAction(jobId, fund.selector, data)

    P->>AC: submit(jobId, deliverable, optParams)
    AC->>H: beforeAction(jobId, submit.selector, data)
    AC->>H: afterAction(jobId, submit.selector, data)

    E->>AC: complete(jobId, reason, optParams)
    AC->>H: beforeAction(jobId, complete.selector, data)
    Note over AC: 💸 Funds released
    AC->>H: afterAction(jobId, complete.selector, data)
```
