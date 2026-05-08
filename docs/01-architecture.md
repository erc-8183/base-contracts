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

`payoutReceiver` decouples the operational provider from the wallet that actually receives the provider-side net payout. Use it to route payouts to a treasury, multisig, or a splitter contract that performs custom downstream disbursement (e.g. when ACP platform/evaluator fees are set to zero and all fee logic lives downstream).

- The receiver **must be a contract that advertises `IDisburser` via ERC-165**. EOAs and contracts that don't implement the interface are rejected at `createJob` / `setPayoutReceiver`.
- Set initially by the client at `createJob`. The **provider** can update it via `setPayoutReceiver` while the job is `Open`; once `Funded` the receiver is locked.
- When `payoutReceiver == address(0)` (default), behavior is unchanged: ACP pays the provider directly and no callback fires.
- When `payoutReceiver != address(0)`, ACP transfers the provider-side net to the receiver and **strictly** invokes `onDisbursement(jobId, msg.sig, token, amount, optParams)`. A revert in the receiver propagates and rolls back the entire `complete` call.
- Refunds (`reject`, `claimRefund`) and platform/evaluator fee routing are unaffected.

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant P as Provider
    participant E as Evaluator
    participant R as PayoutReceiver (IDisburser)

    C->>AC: createJob(..., hook, receiver, agentId)
    Note over AC: receiver validated via ERC-165
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
    AC->>R: onDisbursement(jobId, complete.selector, token, net, optParams)
    Note over R: CAN revert → rolls back complete
    Note over AC: Status: Completed
```

`onDisbursement` is invoked **after** the ERC-20 transfer settles, so the receiver already controls the funds when its callback runs. This lets a splitter contract forward funds it already holds rather than pulling via `transferFrom`, removing the allowance-management overhead a hook-based splitter would require.
