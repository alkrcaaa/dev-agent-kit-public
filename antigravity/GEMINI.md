# Global Rules — Antigravity CLI (agy)

The working rules live in `AGENTS.md` next to your config. This file holds only what is
specific to Antigravity itself.

- Don't assert how this CLI works (config format, precedence, hook events) from memory;
  check `agy help`, `~/.gemini/antigravity-cli/` or the official docs.
- Some Antigravity builds fire hooks unreliably for some events. If a gate never seems to
  fire, treat it as a platform issue to verify, not as the rule not applying.
- This file and `AGENTS.md` are deployed by dev-agent-kit's `install.sh` from
  `antigravity/` in that repo. When the user corrects your approach or confirms a
  non-obvious choice, edit the repo copy; the next install overwrites the live file.
