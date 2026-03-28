# Demo Flow Diagrams

## Demo 1: Image Generation (No Hook)

A client requests an AI-generated image. No hook is used — the core handles all USDC escrow and payment natively.

```mermaid
sequenceDiagram
    participant C as Client
    participant Core as AgenticCommerce
    participant P as Provider
    participant E as Evaluator

    Note over C,E: -- Job Creation --
    C->>Core: createJob(provider, evaluator, expiry,<br/>"Generate landscape wallpaper", address(0))
    Note over Core: Status: Open (no hook)

    Note over C,E: -- Budget --
    P->>Core: setBudget(jobId, 20 USDC, "0x")

    Note over C,E: -- Funding --
    rect rgb(255, 243, 224)
        C->>Core: fund(jobId, "0x")
        Note over C,Core: 20 USDC: Client -> Core (escrowed)<br/>Open -> Funded
    end

    Note over C,E: -- Submit --
    P->>Core: submit(jobId, keccak256(imageURL), "0x")
    Note over Core: Funded -> Submitted

    Note over C,E: -- Complete --
    rect rgb(232, 245, 233)
        E->>Core: complete(jobId, "approved", "0x")
        Note over Core,P: 20 USDC -> Provider<br/>Submitted -> Completed
    end

    Note over C,E: -- Final State --
    Note over C: Balance: 0 USDC
    Note over P: Balance: +20 USDC
```

No hook involved. Pure core escrow flow.

---

## Demo 2: Consent-Gated Completion (Hook-Based)

An evaluator needs multiple independent approvals before settlement. A **ConsentGateHook** collects off-chain verification results and gates the `complete()` transition — the evaluator can only finalize once enough approvals are recorded.

This is a *non-normative* example showing one possible integration pattern for builders who need multi-party agreement before funds are released.

### Why use this pattern?

- **Quality assurance** — multiple reviewers must agree before payment settles
- **Dispute reduction** — consensus is established *before* the terminal `complete()` call, not after
- **Evaluator accountability** — the evaluator's attestation is backed by recorded verification signals
- **Composability** — the hook is a separate contract; swap it for a different consent mechanism without touching the core

### Hook behavior

| Selector | `beforeAction` | `afterAction` |
|----------|---------------|---------------|
| `complete` | ✅ Reverts unless approval threshold is met | Records finalization metadata |
| `reject` | ✅ Reverts unless rejection threshold is met | Records rejection metadata |
| All others | No-op (passes through) | No-op |

The hook only gates terminal transitions (`complete`/`reject`). All other lifecycle steps (budget, fund, submit) pass through unchanged.

### Sequence

```mermaid
sequenceDiagram
    participant C as Client
    participant Core as AgenticCommerce
    participant H as ConsentGateHook
    participant P as Provider
    participant V1 as Verifier 1
    participant V2 as Verifier 2
    participant E as Evaluator

    Note over C,E: -- Setup --
    C->>Core: createJob(provider, evaluator, expiry,<br/>"Translate legal document EN→DE", hook)
    Core->>H: afterAction(jobId, createJob.selector, data)
    Note over H: Hook registers job, sets threshold=2

    Note over C,E: -- Budget & Funding --
    P->>Core: setBudget(jobId, 50 USDC, "0x")
    C->>Core: fund(jobId, "0x")
    Note over Core: 50 USDC escrowed. Status: Funded

    Note over C,E: -- Delivery --
    P->>Core: submit(jobId, keccak256(docHash), "0x")
    Note over Core: Status: Submitted

    Note over C,E: -- Off-chain Verification --
    rect rgb(232, 245, 253)
        Note over V1,V2: Verifiers independently review the deliverable
        V1->>H: approve(jobId)
        Note over H: Approvals: 1/2
        V2->>H: approve(jobId)
        Note over H: Approvals: 2/2 ✓ Threshold met
    end

    Note over C,E: -- Settlement --
    rect rgb(232, 245, 233)
        E->>Core: complete(jobId, reason, "0x")
        Core->>H: beforeAction(jobId, complete.selector, data)
        Note over H: ✓ 2/2 approvals — allows transition
        Note over Core,P: 50 USDC → Provider
        Core->>H: afterAction(jobId, complete.selector, data)
        Note over Core: Status: Completed
    end
```

### Key design points

1. **Hook gates, evaluator attests.** The hook enforces the consent threshold; the evaluator retains the on-chain authority to call `complete()`. Separation of verification logic from settlement authority.

2. **Verifiers are off-chain roles.** They interact only with the hook contract, not with the core. The core never needs to know how many verifiers exist or what threshold applies.

3. **`claimRefund` bypasses the hook.** Per the ERC-8183 safety model, expiry refunds are intentionally not hookable — a misbehaving hook can never trap client funds.

4. **Rejection follows the same pattern.** If verifiers flag issues, the evaluator calls `reject()`, and the hook's `beforeAction` checks that rejection evidence was recorded before allowing the refund.

### When to use this

- AI agent output verification (multiple models cross-check results)
- Multi-stakeholder approval workflows (legal review, compliance sign-off)
- Decentralized quality assurance (independent reviewers, no single point of trust)
