# ERC-8183: Agentic Commerce

Reference implementation of [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) — a Job primitive for trustless agent commerce. Its core features are a job escrow protocol with evaluator attestation and an optional hook system for extensibility.

## Quick Start

Requires [Foundry](https://getfoundry.sh/).

```shell
forge install
forge build
forge test
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

Jobs can optionally attach a **hook contract** (`IERC8183Hook`) to extend behavior without modifying the core:

- `beforeAction` — called before state changes, can revert to gate transitions
- `afterAction` — called after state changes, for bookkeeping and side effects

When `hook == address(0)`, the contract operates as a standalone job escrow with no callbacks. See [docs/02-hook-system.md](docs/02-hook-system.md) for the full design.

## Contracts

```
contracts/
├── ERC8183.sol                 # Core state machine, escrow, fees, hooks
├── IERC8183Hook.sol            # Hook interface (beforeAction/afterAction)
└── mocks/
    ├── MockUSDC.sol            # Test ERC20, 6 decimals
    ├── MockCBBTC.sol           # Test ERC20, 8 decimals
    └── MockFeeOnTransferToken.sol  # Test ERC20 that takes a transfer fee (used to verify rejection)
```

## Architecture

- **Upgradeable** — UUPS proxy pattern via OpenZeppelin
- **Access control** — role-based admin for fees, hook whitelisting, and payment token allowlisting
- **Pausable** — admin can pause user-facing lifecycle functions and use `emergencyWithdraw` while paused
- **CEI pattern** — checks, effects, interactions throughout
- **Reentrancy protection** — transient storage guard on all state-changing functions
- **Payment token allowlist** — only admin-vetted ERC-20s can be used as payment tokens
- **Fee-on-transfer / rebasing rejection** — `fund` snapshots the contract balance and reverts if the received amount differs from the budget
- **Evaluator grace period** — after expiry, a Submitted job cannot be force-refunded for `EVALUATION_GRACE_PERIOD` (1 hour), giving the evaluator time to complete or reject
- **Hook safety** — `claimRefund` is intentionally not hookable so refunds cannot be blocked

See [docs/01-architecture.md](docs/01-architecture.md) for state machine and sequence diagrams.

## Documentation

- [Architecture & Diagrams](docs/01-architecture.md) — state machine, sequence flows
- [Hook System Design](docs/02-hook-system.md) — IERC8183Hook interface, safety model, invocation pattern
- [Demo Flows](docs/03-demo-flows.md) — end-to-end example scenarios

## Contributing

This is the reference implementation for ERC-8183. Contributions, feedback, and discussion are welcome - please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to get started.

## License

MIT
