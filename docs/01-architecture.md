# ERC-8183 Flow Diagrams

## State Machine

```mermaid
stateDiagram-v2
    [*] --> Open: createJob()

    Open --> Open: setBudget()\nsetProvider()
    Open --> Funded: fund()\n💰 budget escrowed
    Open --> Rejected: reject()\n[client or provider]
    Open --> Expired: claimRefund()\n[after expiry]\n(no escrow to refund)

    Funded --> Funded: settle(voucher)\n[provider, with client voucher]\n💸 delta released
    Funded --> Submitted: submit(deliverable)\n[provider only]
    Funded --> Rejected: reject()\n[evaluator only]\n↩️ unsettled escrow refunded
    Funded --> Expired: claimRefund()\n[after expiry]\n↩️ unsettled escrow refunded

    Submitted --> Submitted: settle(voucher)\n[provider, with client voucher]\n💸 delta released
    Submitted --> Completed: complete(reason)\n[evaluator only]\n💸 unsettled remainder paid
    Submitted --> Rejected: reject(reason)\n[evaluator only]\n↩️ unsettled escrow refunded
    Submitted --> Expired: claimRefund()\n[after expiry + grace]\n↩️ unsettled escrow refunded

    Completed --> [*]
    Rejected --> [*]
    Expired --> [*]
```

After expiry, `claimRefund` is callable by anyone. For `Submitted` jobs, it is gated by an additional `EVALUATION_GRACE_PERIOD` (1 hour) so that an evaluator who is mid-review cannot be censored by a third-party refund call.

`settle` is an in-place self-transition: it releases an incremental portion of the escrow against a client-signed voucher without changing the job's status. The cumulative amount released is tracked in `Job.settledAmount`. `complete`, `reject`, and `claimRefund` always net `settledAmount` out of the budget, so already-released funds are never double-paid or double-refunded.

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

## Sequence — Partial Settlement (Voucher)

`settle` lets the provider draw client-authorized incremental payments while a job is still active (`Funded` or `Submitted`). The client signs an EIP-712 `Voucher` off-chain that authorizes a **monotonically increasing cumulative amount**; on-chain the contract releases only the delta against the prior `settledAmount`. The job stays in its current status — settlement does not finalize the job.

```mermaid
sequenceDiagram
    participant C as Client
    participant AC as ERC8183
    participant P as Provider
    participant E as Evaluator

    C->>AC: createJob(provider, evaluator, expiry, ...)
    P->>AC: setBudget(jobId, token, budget, "0x")
    C->>AC: fund(jobId, budget, "0x")
    Note over AC: settledAmount = 0

    C-->>P: signs Voucher(jobId, cumulativeAmount, optParams)
    P->>AC: settle(jobId, cumulativeAmount, voucherSig, optParams)
    Note over AC: verify voucher
    Note over AC: delta = cumulativeAmount - settledAmount
    AC->>P: transfer provider net amount
    Note over AC: settledAmount = cumulativeAmount
    Note over AC: job remains active

    P->>AC: submit(jobId, deliverable, "0x")
    E->>AC: complete(jobId, reason, "0x")
    Note over AC: releases only budget - settledAmount
```

Provider can `settle` repeatedly with successively larger `cumulativeAmount` values until either:

- the cumulative reaches `budget` (job is fully drawn), or
- the evaluator finalizes via `complete` — which then releases only `budget − settledAmount` (with fees on that remainder), or
- the job ends via `reject` / `claimRefund` — which refund only `budget − settledAmount` to the client.

**Reverts**

| Condition | Error |
| --- | --- |
| Caller is not `job.provider` | `Unauthorized` |
| Job not in `Funded` or `Submitted` | `WrongStatus` |
| `block.timestamp >= job.expiredAt` | `WrongStatus` |
| `cumulativeAmount <= settledAmount` | `NoNewSettlement` |
| `cumulativeAmount > job.budget` | `ExceedsBudget` |
| Voucher signature does not recover to `job.client` | `InvalidVoucherSignature` |

**Hook interaction.** When a hook is attached, `settle` fires `beforeAction` / `afterAction` with `selector = settle.selector` and `data = abi.encode(provider, delta, optParams)`. Because the client signs over `optParams`, hooks can rely on those parameters being client-authorized.

**Voucher encoding.** The voucher binds `(jobId, cumulativeAmount, optParams)` under the EIP-712 domain `("ERC8183", "1", chainId, verifyingContract)`. Signature verification goes through `SignatureChecker`, so both EOA signatures and ERC-1271 smart-wallet signatures are supported.
