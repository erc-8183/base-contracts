# Evaluator Patterns

The evaluator role in ERC-8183 is a critical trust primitive. This document describes common patterns for building evaluators and an optional discovery mechanism.

## Overview

Every job in AgenticCommerce has a mandatory `evaluator` address. The evaluator is responsible for calling `complete()` or `reject()` after reviewing the provider's deliverable. This document covers:

1. **Trust-Based Evaluator** — Uses an on-chain trust oracle to auto-evaluate
2. **Trust Gate Hook** — Pre-screens participants via trust scores
3. **Evaluator Registry** — Optional on-chain discovery for evaluators

## Pattern 1: Trust-Based Evaluator

The simplest production evaluator checks the provider's reputation score and auto-approves above a threshold.

**Contract:** [`examples/TrustBasedEvaluator.sol`](../contracts/examples/TrustBasedEvaluator.sol)

```
Job Submitted
    → Evaluator reads provider trust score from oracle
    → Score >= threshold? → complete(jobId)
    → Score < threshold?  → reject(jobId)
```

**Key design decisions:**
- Uses an external trust oracle (any contract implementing `getUserData(address)`)
- Double-evaluation prevention via `evaluated` mapping
- Configurable threshold allows operators to tune strictness
- Emits `JobEvaluated` events for off-chain indexing

**When to use:** When you have an on-chain reputation system and want fully automated evaluation.

## Pattern 2: Trust Gate Hook

Hooks intercept state transitions *before* they happen. A trust gate hook blocks untrusted agents from funding or submitting jobs.

**Contract:** [`examples/TrustGateACPHook.sol`](../contracts/examples/TrustGateACPHook.sol)

```
Client calls fund()
    → Hook: beforeAction(FUND_SEL)
    → Check client trust score
    → Score < threshold? → revert (blocks the fund)

Provider calls submit()
    → Hook: beforeAction(SUBMIT_SEL)
    → Check provider trust score
    → Score < threshold? → revert (blocks the submission)

Evaluator calls complete/reject
    → Hook: afterAction(COMPLETE_SEL / REJECT_SEL)
    → Record outcome event (never reverts)
```

**Key design decisions:**
- `beforeAction` can revert to block transitions — use for gating
- `afterAction` should NEVER revert — it records outcomes for indexing
- Both read from the same trust oracle, sharing reputation data

**When to use:** When you want to prevent low-trust agents from participating at all (before evaluation).

## Pattern 3: Evaluator Registry

For ecosystems with multiple evaluator providers, an on-chain registry enables discovery by domain.

**Contract:** [`extensions/EvaluatorRegistry.sol`](../contracts/extensions/EvaluatorRegistry.sol)

```solidity
// Register an evaluator for a domain
registry.register("trust", 0xMaiatEvaluator);
registry.register("code-review", 0xCodeReviewEvaluator);

// Look up evaluator when creating a job
address evaluator = registry.getEvaluator("trust");
agenticCommerce.createJob(..., evaluator, ...);
```

**When to use:** When your ecosystem has multiple evaluators and agents need to discover them dynamically.

## Combining Patterns

The most robust setup combines all three:

1. **Registry** finds the right evaluator for the domain
2. **Hook** pre-screens participants before they enter
3. **Evaluator** makes the final approve/reject decision

```
Client → Registry.getEvaluator("trust") → evaluator address
Client → createJob(evaluator: addr, hook: trustGateHook)
    → Hook gates fund/submit by trust score
    → Evaluator auto-evaluates deliverable quality
    → Outcome recorded on-chain for future trust updates
```

## Building Your Own Evaluator

1. Implement the evaluation logic (on-chain or hybrid)
2. Call `complete()` or `reject()` on AgenticCommerce
3. Emit events for off-chain indexing
4. Consider registering in EvaluatorRegistry for discoverability

## Security Considerations

- **Evaluators are trusted** — they control fund release. Audit thoroughly.
- **Double-evaluation** — Use a `evaluated` mapping to prevent re-evaluation.
- **Hooks should not revert in afterAction** — this would block legitimate transitions.
- **Trust scores are only as good as the oracle** — ensure the oracle has sufficient data.
