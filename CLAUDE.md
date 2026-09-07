# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete, and no send capability exists. Do not print, log, or commit real message text, contact names, or phone numbers; prefer aggregate/structural queries over selecting rows.

## HARD RULE — TESTS NEVER RUN AGAINST THE OWNER'S REAL DATA

**Every test runs against fakes: in-memory doubles, fixtures, and data invented for the
test.** Never against real data the owner created. This rule outranks every other
instruction in this file — there is no "just this once", no "it is only a read so it is
harmless", and no putting-it-back-afterwards.

That covers the whole suite, a manual run of the built binary, and any check an agent does
on its own initiative "just to see". A test that reaches the owner's real store has stopped
testing this server and started using it.

**If you believe live data is genuinely needed, stop and ask before doing anything.** The
owner can grant an exception, but only for a specific check they have seen in full. Put it
to them in chat as an explicit choice — a question with options, not a remark inside a
longer message — and state:

1. exactly what you intend to run;
2. exactly which live data it would touch, named rather than summarised;
3. what it would create, change or delete, and whether that is reversible.

Go ahead only once the owner has chosen the option that allows it. An unrelated "go ahead",
a general permission from earlier in the session, or silence is not that consent — and the
exception covers only the run that was described, not the next one.

## What this is

A local, read-only MCP server (Swift 6, stdio transport) for WhatsApp. Reads come from `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`, opened read-only and immutable. No network, no credential, no cloud API, no outward-facing action of any kind.

Not affiliated with, endorsed by, or connected to WhatsApp or Meta.

## Commands

```bash
swift build
swift build -c release
swift test
```
