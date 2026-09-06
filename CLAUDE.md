# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete, and no send capability exists. Do not print, log, or commit real message text, contact names, or phone numbers; prefer aggregate/structural queries over selecting rows.

## What this is

A local, read-only MCP server (Swift 6, stdio transport) for WhatsApp. Reads come from `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`, opened read-only and immutable. No network, no credential, no cloud API, no outward-facing action of any kind.

Not affiliated with, endorsed by, or connected to WhatsApp or Meta.

## Commands

```bash
swift build
swift build -c release
swift test
```
