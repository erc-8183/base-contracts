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
    Funded --> Funded: submitClaim(bytes32(0))\n[client direct or client authorization]\n💸 delta released
    Funded --> Funded: submitClaim(nonzero deliverable)\n[client direct or client authorization]\npending claim
    Funded --> Funded: approveClaim()\n[client/evaluator direct or authorization]\n💸 delta released
    Funded --> Funded: rejectClaim()\n[client/evaluator direct or authorization]\npending cleared
    Funded --> Rejected: reject()\n[evaluator only]\n↩️ client refunded
    Funded --> Expired: claimRefund()\n[after expiry]\n↩️ client refunded

    Submitted --> Completed: complete(reason)\n[evaluator only]\n💸 provider paid
    Submitted --> Rejected: reject(reason)\n[evaluator only]\n↩️ client refunded
    Submitted --> Expired: claimRefund()\n[after expiry + grace]\n↩️ client refunded

    Completed --> [*]
    Rejected --> [*]
    Expired --> [*]
```

`submitClaim` is an incremental settlement path while the job remains `Funded`. In the direct flow, the client sends the transaction, so no voucher signature is required. In the relayed flow, `ERC8183WithAuthorization.submitClaimWithAuthorization` carries the client's EIP-712 authorization signature for the same claim parameters. A zero deliverable releases the new delta immediately. A nonzero deliverable records a pending claim hash; the client or evaluator then approves or rejects it, directly or through `approveClaimWithAuthorization` / `rejectClaimWithAuthorization`.

After expiry, `claimRefund` is callable by anyone. For `Submitted` jobs, it is gated by an additional `EVALUATION_GRACE_PERIOD` (1 hour) so that an evaluator who is mid-review cannot be censored by a third-party refund call. Refunds and final completion only use the unsettled escrow balance, so funds released by claims are not double-paid or double-refunded.

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
    participant E as Evaluator

    Note over AC: Status: Funded
    C->>AC: submitClaim(jobId, cumulativeAmount, deliverable, optParams)

    alt deliverable == bytes32(0)
        Note over AC: 💸 delta released
    else deliverable != bytes32(0)
        Note over AC: pending claim hash stored
        E->>AC: approveClaim(jobId, cumulativeAmount, deliverable, optParams)
        Note over AC: 💸 delta released
    end

    Note over C,AC: Relayed variant: client signs SubmitClaimAuthorization,<br/>relayer calls submitClaimWithAuthorization(...)
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
