# ERC-8183: Agentic Commerce Protocol

Reference implementation of [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) — a job escrow protocol with evaluator attestation and an optional hook system for extensibility.

## Quick Start

```shell
npm install
npx hardhat compile
npx hardhat test
```

## Overview

ERC-8183 defines a minimal on-chain job escrow between three roles:

- **Client** — creates and funds jobs
- **Provider** — delivers work
- **Evaluator** — attests to completion or rejects

The core state machine:

```
Open → Funded → Submitted → Completed | Rejected | Expired
```

Each transition enforces role-based access control, and funds are held in escrow until the evaluator completes or the job is rejected/expired.

## Hook System

Jobs can optionally attach a **hook contract** (`IACPHook`) to extend behavior without modifying the core:

- `beforeAction` — called before state changes, can revert to gate transitions
- `afterAction` — called after state changes, for bookkeeping and side effects

When `hook == address(0)`, the contract operates as a standalone job escrow with no callbacks. See [docs/02-hook-system.md](docs/02-hook-system.md) for the full design.

## Contracts

```
contracts/
├── AgenticCommerce.sol    # Core state machine, escrow, fees, hooks
├── IACPHook.sol           # Hook interface (beforeAction/afterAction)
└── mocks/
    ├── MockUSDC.sol        # Test ERC20, 6 decimals
    └── MockCBBTC.sol       # Test ERC20, 8 decimals
```

## Architecture

- **Upgradeable** — UUPS proxy pattern via OpenZeppelin
- **Access control** — role-based admin for fees and hook whitelisting
- **CEI pattern** — checks, effects, interactions throughout
- **Reentrancy protection** — transient storage guard on all state-changing functions
- **Hook safety** — `claimRefund` is intentionally not hookable so refunds cannot be blocked

See [docs/01-architecture.md](docs/01-architecture.md) for state machine and sequence diagrams.

## Documentation

- [Architecture & Diagrams](docs/01-architecture.md) — state machine, sequence flows
- [Hook System Design](docs/02-hook-system.md) — IACPHook interface, safety model, invocation pattern
- [Demo Flows](docs/03-demo-flows.md) — end-to-end example scenarios

## Contributing

This is the reference implementation for ERC-8183. Contributions, feedback, and discussion are welcome - please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to get started.

## License

MIT
