---
name: mcp-builder
description: Build or modify MCP servers — FastMCP (Python), TypeScript SDK, tool schema design, transports (stdio/HTTP), testing MCP tools. Use when creating a new MCP server, adding tools to an existing one, or debugging MCP registration/protocol issues.
---

# MCP Builder (Anthropic)

<!-- gate:begin -->
**Designing tools is the hard part; the transport is boilerplate.**

- **Model workflows, not the API surface.** One tool per useful task beats one tool per endpoint. Ten well-named tools an agent can choose between are worth more than sixty thin wrappers.
- **Name for discoverability:** `<service>_<verb>_<object>`, unambiguous across the whole registered set.
- **Schemas do the teaching.** Every parameter typed, described, and constrained (enums, ranges); the tool description states when to use it and when not to. Declare an output schema when the shape is stable.
- **Budget the context.** Tools return summaries with paging/filter parameters and sane limits — never a raw dump that eats the caller's window. Truncate with an explicit marker.
- **Errors must be actionable:** what failed, which argument caused it, what to try next. Never leak a stack trace as the tool result.
- **Annotate side effects** (`readOnlyHint` / `destructiveHint`) so hosts can gate the dangerous ones.
- **Transport:** stdio for local servers, streamable HTTP (stateless JSON) for remote.
- **Test by actually calling every tool** through a client before declaring it done — registration succeeding is not the same as the tool working.
<!-- gate:end -->

## Depth

Read the full skill now and follow it (research → implementation → review phases, schema and
description guidance, testing):

```
~/.claude/extern/skills/skills/mcp-builder/SKILL.md
```

Read its `reference/mcp_best_practices.md` and, for the SDK you're using, fetch the official
SDK README as the skill instructs. Existing in-repo example: `mcp-infra/local-model-mcp/server.py`
(FastMCP, stdio).
