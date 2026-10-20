---
name: supply-chain-audit
description: Audit dependencies and supply-chain risk — vulnerable/malicious packages, transitive dependencies, lockfiles, package pinning, CI/CD provenance. Use when adding dependencies, reviewing package.json/requirements/lockfile changes, or asked about dependency security.
---

# Supply Chain Risk Auditor (Trail of Bits)

<!-- gate:begin -->
**When you write or change a dependency manifest, do these before moving on.**

1. **Pin exactly.** `==`/exact versions in the manifest, and a lockfile committed where the ecosystem has one. A range means a future install is a different program than the one you tested.
2. **Verify each version actually exists and is current** — do not invent version numbers from memory. Check, e.g.:
   `curl -s https://pypi.org/pypi/<pkg>/json | jq -r .info.version` · `npm view <pkg> version`
   A hallucinated version is both a broken build and a dependency-confusion opening.
3. **Query known vulnerabilities** for every direct dependency you added or bumped:
   ```
   curl -s https://api.osv.dev/v1/query -d '{"package":{"name":"<pkg>","ecosystem":"PyPI"}}'
   ```
   (ecosystems: `PyPI`, `npm`, `Go`, `crates.io`, `Maven`, `RubyGems`, `Packagist`)
4. **Justify each new direct dependency.** Is it already in the tree? Could stdlib do it? A dependency added for one function is a permanent attack surface.
5. **Flag high-risk packages** — single/anonymous maintainer, unmaintained or archived, low popularity, or inherently dangerous surface (FFI, deserialization, code execution). Say so explicitly and name a better-maintained alternative if one exists.
6. **Report what you could not verify.** "No network, versions unchecked" is an acceptable answer; silently pinning unverified versions is not.
<!-- gate:end -->

## Depth

Read the full skill now and follow it — risk criteria with justifications, the `gh`-driven per-dependency audit workflow, and the report template:

```
~/.claude/extern/trailofbits-skills/plugins/supply-chain-risk-auditor/skills/supply-chain-risk-auditor/SKILL.md
```

(The plugin's top-level `README.md` is install metadata, not the skill — do not read it for guidance.)

The full audit workflow needs the `gh` CLI for maintainer/commit/issue data; it writes its report into `.supply-chain-risk-auditor/results.md` from `resources/results-template.md`.
