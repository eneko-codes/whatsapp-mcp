<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="whatsapp-mcp icon">
</p>

# whatsapp-mcp

A local MCP server, written in Swift, that gives Claude **read-only** access to WhatsApp on
this Mac.

Reads come from WhatsApp's own local SQLite store, opened read-only and immutable. There is
no tool here that sends, edits or deletes anything — no shortcut, no Apple event, and no
route to WhatsApp's network. The goal is the opposite one: to get as much out of what
WhatsApp already keeps on this Mac as the database allows.

Seven tools, one per thing the database holds: `whatsapp_status`, `chats_list`, `chat_get`,
`whatsapp_search`, `message_get`, `media_list`, `group_get`.

A message reads as what it is — text with its mentions resolved, a photo, a voice note with
its length, a sticker, a document, a shared location with its coordinates, a shared contact
with its vCard, a link with its preview, a group event, or a message deleted for everyone.
Where WhatsApp keeps nothing, these tools say so instead of approximating.

Not affiliated with or endorsed by WhatsApp or Meta.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- WhatsApp for Mac, installed and signed in — this server reads its local database and never
  talks to WhatsApp's own servers

There is no code signing identity to obtain first. Unlike the EventKit-based siblings, there
is no TCC permission to anchor a signature to — see [Install](#install).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `whatsapp_status` | read | Reports whether WhatsApp's local database can be read, how much is in it, what WhatsApp does not store locally at all, and what to do about anything missing. Reads no messages. |
| `chats_list` | read | Lists conversations with their id, kind, unread count, how many messages are stored, and when the last one arrived. |
| `chat_get` | read | A page of messages from one chat, newest first by default, each line saying who sent it and what the message is. |
| `whatsapp_search` | read | Finds messages whose text contains a phrase, across every chat or within one. Ignores case and accents, so "angel" finds "Ángel". |
| `message_get` | read | Everything the database holds about one message: mentions, both timestamps, an attachment's path/size/length/author, a shared contact's full vCard, a link preview, a group event's actor and subject, and the raw delivery and error codes. |
| `media_list` | read | What was shared rather than said — photos, videos, GIFs, stickers, voice notes, audio, documents, locations, contact cards — with the message id each belongs to and the file's path on this Mac when it's here. |
| `group_get` | read | A group's own metadata (created when, by whom, name last changed) and every member row with its address, resolved name and admin flag. |

Every tool is read-only, and a test in this repository walks the whole catalogue to prove
it. There is deliberately no `contact_get`: with no LID→phone table it would return only a
push name and a picture path, too thin to be its own tool.

## The rules worth knowing before you use it

**No macOS permission is needed at all.** WhatsApp's group container
(`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`) is not
protected by TCC the way Apple's own Calendar, Reminders or Contacts stores are — there is no
consent dialog, no grant to check, and nothing to configure.

**The newest messages can be briefly invisible.** The database is opened
`mode=ro&immutable=1`: read-only alone still takes locks and can touch the write-ahead log,
and WhatsApp is a running app with its own writer this server must never contend with.
Immutable means SQLite promises never to look at unflushed writes, so a message that just
arrived can be missing for a moment. `whatsapp_status` reports pending WAL content rather
than letting that look like data loss — call it again after a moment if a message you expect
is not there yet.

**The schema is undocumented, and checked rather than assumed.** WhatsApp's local storage is
private and free to change shape in any update. If it ever stops matching what these tools
expect, `whatsapp_status` reports that as a fault — never as "you have no messages". A
schema change reading as an empty inbox would be the wrong kind of quiet failure.

**What genuinely is not in this database, and will not be guessed:**

- No LID→phone-number mapping. A `…@lid` address WhatsApp has never resolved for you stays a
  LID — cross-referencing it to a name is Claude's job via the Contacts server, not this
  one's.
- No disappearing-message or expiration setting, under any name, anywhere in the schema.
- A message deleted for everyone shows only that a deletion happened, with its sender and
  date. The original text is not recoverable, and the row it replaced cannot even be
  identified — WhatsApp clears it in place with no second copy and no link back.
- Delivery/read status is reported as a raw number, never as a word. Ten distinct codes exist
  in the wild and none has been confirmed against WhatsApp's own interface, so no tool here
  will claim a message was "read" on the strength of a guess.

## Install

### 1. Build the bundle

```bash
./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary and writes
`dist/whatsapp-mcp.mcpb`. Unlike the EventKit-based servers, there is no `Info.plist` to
embed and no TCC identity to anchor a signature to — the signing step here is about
distribution, not permission. An ad-hoc signature (the default) is enough to run on this
Mac; set `MCPB_SIGN_IDENTITY` only if the bundle is meant to run on another one.

### 2. Install it

Open `dist/whatsapp-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and reopen
it** — reinstalling does not replace a server process that is already running, and the old
one keeps answering.

### 3. Nothing to grant

Call `whatsapp_status`. There is no permission dialog to expect and no grant to check —
reading works immediately, because WhatsApp's group container is not TCC-protected. If
`whatsapp_status` cannot find the database, the fix is opening WhatsApp for Mac at least
once, not a setting in System Settings.

## Tool switches

Every tool can be turned on or off individually in Claude Desktop's extension settings,
because the manifest declares them all. Since all seven tools are read-only, there is no
switch that can turn on anything destructive — flipping one only changes how much of what is
already on this Mac Claude can read.

Plug and play otherwise: there is nothing to configure.

## Manual registration instead

```json
{
  "mcpServers": {
    "WhatsApp": {
      "command": "/absolute/path/to/whatsapp-mcp/.build/release/whatsapp-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide.

## Known limits

- **No LID→phone-number mapping exists in this schema.** A `…@lid` sender this server cannot
  name stays a LID.
- **No disappearing-message setting is exposed**, because none exists in WhatsApp's local
  storage to expose.
- **A message deleted for everyone cannot be recovered.** Its text and the row it replaced
  are both gone, not merely hidden.
- **Delivery/read status is a raw number.** No code has been confirmed against WhatsApp's own
  UI, so none is translated to a word.
- **A media path is only ever reported when the file is genuinely still on this Mac.**
  WhatsApp keeps the database row long after evicting old files; an absent path means the
  file is gone, not that the message is.
- **Group membership is not a live snapshot.** A member who has left most likely still
  appears, marked inactive — the schema does not say exactly what "inactive" means beyond
  that flag, and this server does not guess further.
- **Some group events carry no subject.** WhatsApp's own schema does not always record who or
  what an event was about, and no correlation is attempted to recover one that is not there.

## Development

```bash
swift build
swift test
```

70 tests across two suites, all against an in-memory fake store or a fixture SQLite database
built with invented rows — never a copy of the real one. See `CLAUDE.md`, whose hard rule at
the top is what makes that non-negotiable.

Manual verification against a real WhatsApp database is the owner's job; `verification.md`
is the script for it.

## Licence

MIT.
