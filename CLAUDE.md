# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THIS SERVER IS READ-ONLY, AND STAYS THAT WAY

**No tool that sends, edits or deletes anything may be added to this server, for any
reason.** This rule outranks every other instruction in this file. It applies to every
agent and every session, with no "just this once" and no "only to the owner".

The send path was not switched off, it was **removed**: no `MessageSender`, no
`WhatsAppBridge` target, no shortcut, no embedded `Info.plist`, no Apple event anywhere.
Restoring any of it is a change to the purpose of this project, and is the owner's
decision to make in writing here first — not something to reintroduce because a task
seems to call for it.

WhatsApp has no recall. That is why the capability does not exist here at all.

**Reading the owner's real database is allowed** for verification, and is how the claims
in this file were established. Aggregate and structural queries — counts, distributions,
column shapes — answer almost every question worth asking without printing anyone's
messages, and are strongly preferred over selecting rows. Never print, log or commit real
message text, contact names or phone numbers.

The layout is undocumented and changes, so checking it is how this server stays correct:

```bash
sqlite3 "$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite" ".schema ZWAMESSAGE"
```

That prints column names and no message content.

**Fixtures first for tests, always.** `FakeWhatsAppStore` drives the whole tool layer with
invented content. For anything below the seam, build a **fixture database** in a temp
directory with `CREATE TABLE` and invented rows — never a copy of the real one. The real
database is for verifying a claim, not for running the suite against.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake and a fixture database |
| `initialize`, `tools/list` over stdio | Protocol only; no database is opened |
| `sqlite3 … ".schema"` / `".tables"` | Names only, no rows |
| `SELECT COUNT(…)`, `GROUP BY`, shape checks on the real file | Aggregates; no message content leaves the query |

Selecting actual rows is a last resort, and the answer to almost every question here is an
aggregate. `verification.md` covers what genuinely cannot be settled from SQL alone,
because it needs comparing against the WhatsApp UI.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages.

## What this is

A local, read-only MCP server (Swift 6, stdio transport) for WhatsApp. Everything comes
from `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`,
opened read-only and immutable.

Its purpose is to extract as much as WhatsApp's local storage genuinely holds — and to say
plainly when it holds nothing, rather than approximating.

There is no network, no credential, no cloud API, no unofficial WhatsApp library, and no
outward-facing action of any kind.

**Not affiliated with, endorsed by, or connected to WhatsApp or Meta.**

## Commands

```bash
swift build
swift build -c release
swift test
```

## Architecture

`Sources/WhatsAppMCPCore` holds everything; `Sources/whatsapp-mcp/main.swift` is a launcher
that exists only because a Swift executable target cannot be imported by a test target.

**One seam.** `WhatsAppStore` covers every read and there is nothing else — no sender
protocol, no Objective-C bridge target, no `Resources/Info.plist`. All three existed only
for the Shortcuts send path and went with it. The absence is the safety property: there is
no code path here that could reach outside this Mac even by mistake.

**Entities, not rows.** The model in `WhatsAppModel.swift` is shaped after what the
database holds rather than after the queries that read it: a `Message` carries a
`MessageBody` — one closed choice among text, attachment, location, contact card, link,
group event, deletion and an unnamed type — instead of a flat row with a growing tail of
optional fields that happen to be populated together. The tail was how a photo could arrive
with a `coordinates` value; the enum is why it now cannot. `Identity` does the same for a
party: a JID, its resolved name, its kind and its picture in one value, so a sender, a
mention's target and a group's creator are the same type everywhere.

**Seven tools, one per entity**, plus one detail view: `whatsapp_status`, `chats_list`,
`chat_get`, `whatsapp_search`, `message_get`, `media_list`, `group_get`. There is
deliberately no `contact_get`: with no LID→phone table it would return a push name and a
picture path, which is too thin to be a tool. The picture rides on `Identity` instead.

## Invariants worth protecting

- **The database is opened `mode=ro&immutable=1`.** Read-only alone still takes locks and
  can touch the WAL; immutable promises the file will not change underneath, so SQLite
  opens no journal and writes nothing. WhatsApp is a running application with its own
  writer, and this server must never contend with it. A test asserts the URI.
- **The price of `immutable=1` is that unflushed writes are invisible**, so the newest
  messages can be missing briefly. `whatsapp_status` reports pending WAL content rather
  than letting it look like data loss.
- **The schema is checked before it is trusted.** WhatsApp's storage is private and
  undocumented and can change in any update. `StoreAvailability.schemaUnexpected` exists so
  a layout change reads as a **fault**, never as "you have no messages". A test covers
  exactly that, and it is the most valuable test here.
- **Ten columns do not mean what they are named.** Each of these shipped a bug or was
  caught one commit before shipping one; none is guessable from the column name, and every
  one was established by measuring a real library. Verify against the data before trusting
  any of them again:
  - **`ZWAMEDIAITEM.ZLATITUDE`/`ZLONGITUDE` are pixel dimensions on every media type
    except a location.** Type 1 spans 132–4160 by 156–4032 on the measured library; only
    `ZMESSAGETYPE` 5 holds a real position, and all 20 of those fall in valid ranges.
    Read without the type gate, a photo is reported as a place at latitude 3024 — wrong in
    a way the reader cannot detect. `Coordinates.init?(latitude:longitude:typeCode:)` is
    the gate, and the fixture carries a photo with real pixel dimensions in those columns
    so dropping it fails the suite.
  - **`ZWAMEDIAITEM.ZVCARDNAME` is a 44-character base64 key on every type except a
    contact card.** 4879 such rows on the measured library, uniform length and space-free —
    the same shape that made `ZPUSHNAME` render a sender called `CNXy9s8GIAA=`. Only
    `ZMESSAGETYPE` 4 carries a real name there.
  - **`ZWACHATSESSION.ZLASTMESSAGEDATE` is a sort key, not a date.** WhatsApp pins a chat
    by adding whole millennia to it — 5000, 6000, 7000 years, one step per pin slot — so
    its own `ORDER BY … DESC` floats it to the top. There is no pin column; the inflated
    value is the only evidence pinning happened. Read literally it reports the year 9026.
    The honest date is on the message `ZLASTMESSAGE` points at.
  - **`ZWAMESSAGE.ZPUSHNAME` is not a name.** It holds WhatsApp's own binary payload;
    22017 of 27059 rows on the measured library were base64. Shown as a display name it
    renders a sender called `CNXy9s8GIAA=`. It is deliberately not selected.
  - **`ZWAGROUPMEMBER.ZCONTACTNAME` is the empty string on every row**, never NULL — so
    `NULLIF(…, '')` rather than a nil check, or an empty COALESCE branch wins and every
    group message comes back from a sender with no name.
  - **`ZWAMEDIAITEM.ZMEDIALOCALPATH` is relative to `Message/`** beside the database, not
    to the container root and not absolute. Handed to a caller unresolved it points at
    nothing.
  - **`ZWAMEDIAITEM.ZVCARDSTRING` is not a vCard except on a contact card.** Populated on
    4875 rows that are stickers (2654), photos (1855), videos, documents, audio and GIFs.
    Same gate as `ZVCARDNAME`: `ZMESSAGETYPE` 4 only, applied in `ContactCard.init?`.
    Ungated, this server reports thousands of shared contacts nobody ever shared.
  - **`ZWAMEDIAITEM.ZMOVIEDURATION` is not seconds on a document.** The 119 documents on
    the measured library carry 0 to 472 there, with 1, 2, 3 and 4 by far the commonest, on
    files whose names end in `.pdf` — a page count. Rendered as a length it turns a
    contract into a two-second clip. `AttachmentKind.hasDuration` is the gate; what the
    number does count is not established and is therefore not surfaced under another name.
  - **`ZWAGROUPMEMBER.ZFIRSTNAME` is not a first name.** 72 of the 80 populated rows are
    exactly 5 characters, the rest 13, 37 and 53, and not one contains a space. It is a key
    of some sort. It is deliberately not selected, and the fixture carries the shape so a
    future edit that reads it produces a member called `CNXy9`.
  - **`ZWAPROFILEPICTUREITEM.ZPATH` is not always a path.** 250 of 386 rows hold a real
    `Media/…` path; **109 hold a 64-to-128-character blob** with no path shape, and 27 are
    null. Two gates in `profilePicturePaths`: the `Media/` prefix, then the on-disk check.
- **`ZWAPROFILEPUSHNAME(ZJID, ZPUSHNAME)` is the only working name source for a group
  sender**, resolving 5426 of 8809 incoming group messages on the current library.
  `ZWAGROUPMEMBER.ZCONTACTNAME` resolves **zero** of them — still the empty string on
  every row, as it was when that trap was first found. The remaining 3383 fall back to the
  member address, which identifies a person; falling back to the chat name instead would
  attribute one member's words to the whole group.
- **`JIDDisplay` is the one place a JID becomes readable**, used for mentions, and for a
  group event's actor and subject. Order matters and is fixed: `ZWAPROFILEPUSHNAME` name
  first, then a `…@s.whatsapp.net` prefix rendered as `+<digits>`, else the JID unchanged.
  It is **not** backed by Apple Contacts — that would add a TCC permission this server does
  not otherwise need and would blur the line between this server's deterministic layer and
  Claude's own judgement.
- **What a message *is* is decided once, in `SystemWhatsAppStore.body(from:…)`, and every
  tool reads the resulting `MessageBody` case rather than re-deriving it.** The order of
  the gates in that function is load-bearing and is documented on it: deletion and group
  event first, then location and contact card because their columns mean something else on
  every other type, then attachment, then link — an attachment is settled before a link
  preview because WhatsApp attaches a preview row to photos too, and a photo with a link in
  its caption is a photo. One classification is what stops `chat_get` calling a row a photo
  while `media_list` calls it something else.
- **`ZWAMESSAGEDATAITEM` holds up to 12 rows for one message**, one per link in it. Joined
  on the message alone, a message with several links comes back a dozen times and every
  count above it is wrong. The join is `AND di.ZINDEX = 0`, which is exactly one row per
  message on all 703 the measured library covers. The fixture carries a twelve-row message
  so dropping the gate fails the suite.
- **`ZMESSAGESTATUS` is reported as a number and never as a word.** Ten distinct codes on
  the measured library, and they do not partition by direction the way sent/delivered/read
  would: 6 is the commonest both incoming (12417) and outgoing (8302), and 8 appears on
  both sides too. Any mapping is a guess, and a wrong "read" is a claim about somebody's
  behaviour this server has no business making. Same rule as `ZGROUPEVENTTYPE`: the owner
  confirms codes against the WhatsApp UI by hand, or they stay numbers.
- **`ZMESSAGETYPE` 3 is both a voice note and an audio file**, and `ZWAMEDIAITEM.ZMEDIAORIGIN`
  is the only thing that separates them: origin 1 on 51 of the 52 rows, every one storing
  `.opus`, origin 0 on the one remaining. `AttachmentKind.init?(typeCode:mediaOrigin:)` is
  where that lives, and `MediaKind.voice_note`/`.audio` carry it into SQL as a predicate
  rather than a type code — which is why a kind filter needs the media row in the FROM
  block.
- **Three tables are optional, not required.** `ZWAMESSAGEDATAITEM`, `ZWAPROFILEPICTUREITEM`
  and `ZWAGROUPINFO` are checked at runtime; when one is absent its columns are replaced by
  `NULL` literals so every column index below stays fixed, and `whatsapp_status` names it so
  a missing table reads as a feature that is off rather than as data that does not exist. A
  shorter column list would make each reader's index depend on what the schema happened to
  have, which is the kind of thing that fails silently.
- **`ZMESSAGETYPE` 6 and 10 carry a group event in `ZGROUPEVENTTYPE`.** For these,
  `ZFROMJID` is the actor and `ZTEXT` is the subject's JID — not message text — so
  `SystemWhatsAppStore` classifies them as `MessageBody.groupEvent` and leaves `text` nil,
  and `Format` gives them their own layout (`[group event N] actor → subject`) rather than
  squeezing a bare JID into "who: text". **The event codes themselves are not decoded**:
  `ZGROUPEVENTTYPE` is also set on 20017 plain text messages in the measured library, so
  its presence is not the gate, the type code is — and no verb ("added", "removed", "left")
  may be attached to a code without the owner confirming it against the WhatsApp UI by
  hand. A wrong verb here is worse evidence than an honestly unnamed code.
- **`group_get` reads `ZWAGROUPINFO` and `ZWAGROUPMEMBER`, both columns introspected
  at runtime via `PRAGMA table_info` rather than assumed.** Every column this server reads
  from either table is looked up against `ReadOnlyDatabase.columnNames(of:)` first, and a
  column that turns out missing comes back nil in the result rather than failing the
  query — the schema is WhatsApp's own and this server has been burned by trusting it
  once already. All five `ZWAGROUPINFO` fields are populated on all six groups measured,
  so group metadata is reliable where it exists.
- **`ZWAGROUPMEMBER` is not a snapshot of current membership.** 86 of 190 member rows are
  `ZISACTIVE = 0`, which a current-only table would have no reason to keep. What an
  inactive row means specifically — left, removed, something else — the column does not
  say, so the flag is reported and no verb is attached to it.
- **`ZWAGROUPMEMBERSCHANGE` cannot supply a group event's missing subject, and trying was
  removed.** Measured: 145 type-6/10 rows carry no subject in `ZTEXT`, and **not one** of
  them has a change row within seconds of it. The five change rows that exist all sit
  beside events that already carried their subject in `ZTEXT`, and their `ZMEMBERJIDS`
  does not even equal that subject. A correlation on (group JID, timestamp) therefore
  resolves nothing at all — it was implemented, measured at a 0/145 hit rate, and deleted.
  A subject-less group event stays subject-less; a test pins that.
- **`ZMESSAGETYPE` 14 is NOT linkable to the message it refers to, and the stanza-id
  hypothesis is false.** Measured on 226 type-14 rows: 220 have no `ZTEXT` at all, the 6
  that do hold a **JID** (3 `@lid`, 3 `@s.whatsapp.net`), and **zero** match any
  `ZSTANZAID` in the same chat or anywhere else. `ZPARENTMESSAGE` is NULL on all 27138
  rows in the database, so that is not a link either, and no stanza id is ever duplicated.
  Type 14 also occurs in one-to-one chats (46 of 226), so it is not purely a group event
  despite `ZGROUPEVENTTYPE` being set on every row — that column is non-null on **every**
  row of every type, which is why type, never its presence, is the gate. Conclusion: a
  type-14 row can be reported as its own row with its own sender and date, and nothing
  more. **The deleted message's text is not recoverable and the original row is not even
  identifiable.**
- **Two blobs are known unknowns, deliberately unread.** `ZWAMEDIAITEM.ZMETADATA` (26659
  rows) and `ZWAMESSAGEINFO.ZRECEIPTINFO` (21108 rows) are binary payloads this server does
  not parse. The second is the only route to per-member read state in a group — who read
  what, and when — and reaching it means reverse-engineering a protobuf whose field
  numbering WhatsApp is free to change in any update. That is a different kind of claim
  from reading a named column, and it is not made here. Recorded so the absence reads as a
  decision rather than an oversight.
- **No LID↔phone-number mapping exists in this schema.** Checked exhaustively: every table
  and column name was searched for "lid", and the only hit outside `ZWAPROFILEPUSHNAME`
  (name only, not phone) is `ZWAZ1PAYMENTTRANSACTION`, unrelated to identity. A `…@lid`
  address this server cannot name from `ZWAPROFILEPUSHNAME` has no other source to try —
  see the comment on `JIDDisplay`.
- **No disappearing-message / ephemeral-expiration field exists in this schema**, on
  `ZWACHATSESSION` or on `ZWAMESSAGE`, under any name resembling "ephemeral", "expir…" or
  "disappear…". `ZWACHATSESSION.ZFLAGS` is an undecoded bitfield that might encode it;
  decoding a bitfield by guessing which bit means what is not something this server does.
  See the comment on `Chat`.
- **A mention is `@<digits>` inside `ZTEXT`**, where the digits are a LID's numeric part.
  `JIDDisplay.mentions(in:profileNames:)` looks up `<digits>@lid`, substitutes
  `@Name (<digits>)` when it resolves, and leaves the mention exactly as WhatsApp wrote it
  otherwise. It returns the list alongside the rendered text rather than making a caller
  parse a display string back apart, so an unresolved mention is still reported as one. A
  five-digit floor keeps this from firing on an `@` that merely precedes a short number,
  which a WhatsApp LID never is.
- **A media path is returned only when the file is really on disk.** WhatsApp keeps the
  row long after evicting the file, so the row alone does not settle it and these tools
  promise that a path present means the file is here.
- **`ZWAMEDIAITEM` is not only real attachments.** WhatsApp also creates a row there for
  the thumbnail of a link preview on an ordinary text message (`ZMESSAGETYPE` 0) — 21095 of
  the 26733 media rows on the measured library belong to type-0 messages — so "has a media
  row" is not the same question as "is an attachment". An absent `kinds` argument in
  `media_list` therefore defaults to `MediaKind.allCases` in `Dispatch.media`, never to "no
  filter": the empty-means-everything convention `chat_get` and `whatsapp_search` use is
  wrong here specifically because the join, not the message type, decides what a row is.
  The nine kinds together account for 4897 of those rows, which is the honest count.
- **`chat_get`, `whatsapp_search`, `media_list` and `message_get` render through one
  `Format.messageLine`, over rows from one `SystemWhatsAppStore.message(from:…)`.** Three
  renderers over three row shapes meant a photo could be described one way in a
  conversation and another way in an attachment list, with no way to tell from the output
  which was right. `media_list` differs from `chat_get` in what it *selects* — it requires a
  media row — never in how it describes what it found, and a fixture test compares the two
  rows for equality.
- **An id argument is declared as a number, so read it as one.** `chat_id` decoded with a
  string accessor comes back nil, the filter never reaches the store, and the search
  silently widens to every chat. The same failure shape applies to any argument name that
  does not match the catalogue: reading an undeclared name cannot fail loudly, it just
  yields nothing and the filter quietly never applies.
- **Every tool is read-only, and a test walks the catalogue to prove it.** Nothing here
  modifies, deletes or sends, and no such tool may be added — see the hard rule above.
- **Reads need no permission at all.** That is a fact about this container: WhatsApp's
  group container is not TCC-protected, so there is no grant, no prompt and no
  `Info.plist` involved anywhere in this project.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **`extension/manifest.json`'s tool names must equal the catalogue's.** The manifest is
  read before the server has ever run and is what creates the per-tool permission switches,
  so a tool renamed in one place and not the other leaves a switch for a tool that no longer
  exists and none for the one that replaced it — and nothing at runtime notices. A test
  compares the two sets.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/whatsapp-mcp.mcpb`. The
manifest's `tools` array creates the per-tool switches in Claude Desktop and is read before
the server has ever run.

Every flag in `mcp_config.args` must exist in `Configuration.parse`. A flag the parser does
not read fails **silently**, leaving the setting on its default.

## TCC notes

There are none, and that is the point. Reading needs no TCC grant: the WhatsApp group
container is not protected the way Apple's own stores are, and this server sends no Apple
event to anything. There is no embedded `Info.plist`, no usage description, no Automation
entry in System Settings, and nothing in `pack.sh` that depends on any of it — all of that
existed for the send path and was removed with it.

## MCP servers

Applies to any repository shipping an MCP server or Claude extension: an `initialize` handler, a tool catalogue, or a manifest packed into a `.mcpb`.

**Shipping a rebuild**

- **ALWAYS bump the version before packing.** The installer keys on the manifest `version` alone, so a changed build under an already-installed version offers only "Uninstall" — which removes the extension instead of updating it.
- **Three files carry the version and must agree:** the manifest `version`, the server's own version constant (what `initialize` and the status tool report), and `CFBundleShortVersionString` in `Resources/Info.plist`. A test asserts all three; keep it.
- **Installing does not restart the server.** The running process serves the old binary until the client is fully quit and reopened, so a fix can appear to fail while the old code is still answering. Verify what is actually running (`ps`, and the binary path the status tool prints) before trusting any result, and ask for a full restart, not just an install.
- **Ad-hoc signing changes the cdhash on every rebuild**, so TCC forgets its grant and prompts again. Expected, not a fault — say so on handover.

**Documentation the model reads**

The server documents itself to a model, which acts on that text and cannot detect that it is wrong. Treat it as code, not prose.

- Update it in the same commit as the behaviour: a new, renamed or removed tool; a change to what a tool does, refuses, defaults to or requires; a change in which permission governs what; a limitation callers must work around.
- Four surfaces, all natural language: the server `instructions`, each tool `description`, each argument `description`, and the manifest's `tools` array and `long_description`. The manifest is read before the server has ever run, so a tool missing from it has no permission switch at all.
- State what the schema cannot convey: which tool to call first, which identifiers go stale and why, what cannot be undone, which permission governs what, and which field to prefer when several would fit.
- None of it takes effect until the client restarts. Say so on handover.
