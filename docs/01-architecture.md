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
    Funded --> Rejected: reject()\n[evaluator only]\n↩️ client refunded
    Funded --> Expired: claimRefund()\n[after expiry]\n↩️ client refunded

    Submitted --> Completed: complete(reason)\n[evaluator only]\n💸 provider paid
    Submitted --> Rejected: reject(reason)\n[evaluator only]\n↩️ client refunded
    Submitted --> Expired: claimRefund()\n[after expiry + grace]\n↩️ client refunded

    Completed --> [*]
    Rejected --> [*]
    Expired --> [*]
```

After expiry, `claimRefund` is callable by anyone. For `Submitted` jobs, it is gated by an additional `EVALUATION_GRACE_PERIOD` (1 hour) so that an evaluator who is mid-review cannot be censored by a third-party refund call.

## Sequence — Typical Job Flow (No Hook)

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant P as Provider
    participant E as Evaluator

    Note over AC: Status: Open
    C->>AC: createJob(provider, evaluator, expiry, desc, address(0), address(0), agentId)
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

## Sequence — Job with Hook

`createJob` is not hookable in the reference implementation — the hook is stored on the job but no callbacks fire on creation. Hooks begin firing on `setBudget`.

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant H as Hook (IERC8183Hook)
    participant P as Provider
    participant E as Evaluator

    C->>AC: createJob(provider, evaluator, expiry, desc, hook, address(0), agentId)
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

## Sequence — Job with Payout Receiver

`payoutReceiver` separates provider authorization from provider-side payout custody. If unset, ACP pays the provider. If set, ACP pays the receiver.

- Receivers can be EOAs, smart accounts, or contracts.
- Contracts advertising `IDisburser` via ERC-165 receive `onDisbursement` after payout.
- The provider can update the receiver while the job is `Open`; it is locked once `Funded`.
- Refunds and platform/evaluator fee routing are unchanged.

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant P as Provider
    participant E as Evaluator
    participant R as PayoutReceiver

    C->>AC: createJob(..., hook, receiver, agentId)
    Note over AC: receiver stored, callback support checked at payout
    P->>AC: setBudget(jobId, token, amount, "0x")
    P->>AC: setPayoutReceiver(jobId, newReceiver)
    Note over AC: provider-only, Open only —<br/>locked once Funded
    C->>AC: fund(jobId, expectedBudget, "0x")
    Note over AC: Status: Funded

    P->>AC: submit(jobId, deliverable, "0x")
    Note over AC: Status: Submitted

    E->>AC: complete(jobId, reason, optParams)
    Note over AC: 💸 platform fee → treasury<br/>💸 evaluator fee → evaluator
    AC->>R: transfer(net) [ERC-20]
    alt Receiver advertises IDisburser
        AC->>R: onDisbursement(jobId, complete.selector, token, net, optParams)
        Note over R: CAN revert → rolls back complete
    else EOA or plain receiver contract
        Note over R: No callback
    end
    Note over AC: Status: Completed
```

When supported, `onDisbursement` runs after the ERC-20 transfer, so receiver contracts can split funds they already control without `transferFrom` allowances.
