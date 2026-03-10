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
