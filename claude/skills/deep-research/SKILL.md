---
name: deep-research
description: Rigorous primary-source research and evidence gathering. Enforces verifiable documentation checks, benchmark validation, and structured citation. Use when investigating unfamiliar technologies, protocols, RFCs, APIs, or disputed architectural facts.
---

# Deep Research & Evidence Investigator
<!-- dev-agent-kit native skill -->

Rigorous investigation of technical claims against authoritative primary sources.

<!-- gate:begin -->
1. Primary Source Hierarchy: Only accept RFCs, official vendor specs/documentation, source code, or reproducible benchmarks. Secondary blog posts and forum discussions are strictly supplementary context, never authoritative proof.
2. Tool Retrieval vs Training Data Transparency: If running with live retrieval/web access, verify and cite exact URLs/files. If running without tool access (pure model context), do NOT fabricate URLs, RFC numbers, or quotes — explicitly prefix claims with `[NO SOURCE ACCESS — reasoning from training data, unverified]`.
3. Benchmark Validation: When citing performance, verify: hardware spec, dataset size, concurrency level, and p99/p95 latency—never average throughput alone.
4. Markdown Output: Structure findings into a single, clean markdown artifact citing exact source URLs or file paths for every factual assertion.
<!-- gate:end -->

## Operating Principles

### 1. The Verification Discipline
- When evaluating a protocol, read the RFC or official spec, not someone's medium post explaining it.
- When claiming an API behavior, verify against the language/framework reference or actual source code.
- If a source cannot be verified or reached, explicitly flag the gap rather than asserting plausible defaults.
