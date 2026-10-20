---
name: first-principles
description: Deconstruct problems to fundamental computer science and business truths. Strip away vendor/framework nouns, challenge artificial constraints, and enforce simplicity. Use BEFORE choosing architectures, frameworks, or designing system components.
---

# First-Principles Problem Solver
<!-- dev-agent-kit native skill -->

Deconstruct complex proposals down to irreducible physical and computational constraints, removing cargo-cult patterns and artificial complexity.

<!-- gate:begin -->
1. Strip all brand/framework nouns from the problem statement: restate the core problem purely in terms of data structures, throughput, latency, durability, and business rules.
2. Identify irreducible physical constraints: compute (CPU cycles), memory (RAM), storage (I/O, disk), network (bandwidth, round-trips), and human maintenance cost.
3. Challenge artificial requirements: ask "who mandated this constraint, and what happens if we simply delete it?"
4. Cross-reference simplicity: enforce `karpathy-guidelines` (minimum viable diff, boring proven tools, no speculative abstractions).
<!-- gate:end -->

## Depth & Cross-Reference

This skill is the architectural decision companion to:
- `karpathy-guidelines`: simplicity on code diffs; this skill applies the same discipline to architecture and system design.

## Operating Principles

### 1. Form Follows Constraints
- Before introducing a new system component (message broker, cache, distributed store), prove that the existing database or in-process memory cannot satisfy the physical throughput and durability requirements.
- Calculate back-of-the-envelope numbers: 1,000 requests/sec with 2KB payload is 2MB/s network and well within a single standard PostgreSQL instance.
