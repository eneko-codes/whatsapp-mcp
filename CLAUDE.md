# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete, and no send capability exists. Do not print, log or commit real message text, contact names or phone numbers; prefer aggregate or structural queries over selecting rows.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real chat store, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

The read path takes a database path, so the gentle route is a copy of the store under a temporary directory you made yourself — never the live file — deleted in the same session.

## What this is

A local, read-only MCP server (Swift 6, stdio transport) for WhatsApp. Reads come from `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`, opened read-only and immutable. No network, no credential, no cloud API, no outward-facing action of any kind.

Not affiliated with, endorsed by, or connected to WhatsApp or Meta.

## Commands

```bash
swift build
swift build -c release
swift test
```
