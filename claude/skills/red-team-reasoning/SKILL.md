---
name: red-team-reasoning
description: Adversarial reasoning and logic audit — stress-test proposals, detect logical fallacies, expose hidden assumptions, and identify catastrophic failure modes before execution. Use BEFORE approving or synthesizing high-stakes architectural, security, or strategic decisions.
---

# Red Team Reasoning & Logic Audit
<!-- dev-agent-kit native skill -->

Adversarial stress-testing and critical logic examination for high-stakes proposals, designs, and decisions.

<!-- gate:begin -->
1. Classify the decision: Type-1 (irreversible / high rollback cost) or Type-2 (reversible / low cost to pivot). Apply 3x scrutiny and demand proof of reversibility for Type-1.
2. Name the unstated assumption: state the exact premise being taken for granted, and specify what breaks if it is false.
3. State the primary failure mode in one sentence: `[Initial State] + [Trigger / Input] -> [Catastrophic / Unintended Outcome]`. If no credible failure mode exists, explicitly state "No fatal failure mode identified" rather than manufacturing trivia.
4. Flag logical fallacies: identify appeals to authority ("everyone uses Redis / industry standard"), sunk cost fallacy, premature consensus, or false dichotomies.
5. Demand evidence or mark unverified: label any claim lacking a reproducible metric, empirical benchmark, or primary source citation as `[UNVERIFIED]`.
<!-- gate:end -->

## Operating Principles

### 1. Type-1 vs Type-2 Discipline
- **Type-1 (One-Way Doors):** Data migrations, public API contracts, fundamental data store choices, auth architecture. Require explicit rollback plan and failure-mode analysis.
- **Type-2 (Two-Way Doors):** Internal refactors, UI component tweaks, local configuration. Do not block progress with pedantic red-teaming if the rollback cost is trivial.

### 2. The Adversarial Stance
- Look for what is *missing*, not just what is said: unhandled edge cases, burst loads, network partitions, dependency abandonment.
- Test the boundary: "Does this scale down to 1 item? Does it scale up to 10M? What if the network latency spikes to 2000ms?"
