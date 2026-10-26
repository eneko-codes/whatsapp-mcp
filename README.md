<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="whatsapp-mcp icon">
</p>

# whatsapp-mcp

A local MCP server, written in Swift, that gives Claude **read access** to WhatsApp on this
Mac. It never changes WhatsApp's data.

Reads come from WhatsApp's own local SQLite databases, opened read-only and read through
their write-ahead log, and
from the media files under WhatsApp's `Message/` folder. There is no tool here that sends,
edits or deletes anything — no shortcut, no Apple event, and no route to WhatsApp's network
or to any other. The goal is the opposite one: to get as much out of what WhatsApp already
keeps on this Mac as it allows.

The tools. The chat store: `whatsapp_status`, `chats_list`, `chat_get`,
`whatsapp_search`, `message_get`, `media_list`, `group_get`. Attachments: `media_get`,
`media_view`, `audio_transcribe`. The rest of the container: `calls_list`,
`location_sharing_list`, `labels_list`, `address_book_list`, `lid_lookup`, `channels_list`.
And a read-only escape hatch over any allow-listed database: `db_tables`, `db_schema`,
`db_query`.

**It writes in exactly one place**: `~/Library/Caches/whatsapp-mcp/`, its own cache — see
[The cache](#the-cache). Nothing is ever written into WhatsApp's container.

A message reads as what it is — text with its mentions resolved, a photo, a voice note with
its length, a sticker, a document, a shared location with its coordinates, a shared contact
with its vCard, a link with its preview, a group event, or a message deleted for everyone. A
reply shows the message it quotes, and a message shows who reacted to it and with which emoji.
Where WhatsApp keeps nothing, these tools say so instead of approximating.

Not affiliated with or endorsed by WhatsApp or Meta.

## Requirements

- macOS 15 or later to run it. Transcription (`audio_transcribe`) needs macOS 26 or later;
  everything else works on 15.
- Xcode 26 or later to build it: the transcription code uses the macOS 26 SDK, so an older
  SDK does not compile, even though the result runs on macOS 15. Swift 6.0 or later.
- WhatsApp for Mac, installed and signed in — this server reads its local database and never
  talks to WhatsApp's own servers

Reading WhatsApp's data needs **Full Disk Access** for this server's program on recent macOS,
and macOS ties that grant to the exact program: every rebuilt or updated copy needs it again
— see [Permissions](#permissions).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `whatsapp_status` | read | Reports whether WhatsApp's local database can be read, how much is in it, what WhatsApp does not store locally at all, and what to do about anything missing. Reads no messages. |
| `chats_list` | read | Lists conversations with their id, kind, unread count, how many messages are stored, and when the last one arrived. |
| `chat_get` | read | A page of messages from one chat, newest first by default, each line saying who sent it and what the message is. `↩N` marks a reply to message N, `[❤️ 😮]` the reactions on a message, `★` a starred one; `message_get` opens them up. |
| `whatsapp_search` | read | Finds messages whose text contains a phrase, across every chat or within one. Ignores case and accents, so "angel" finds "Ángel". With `starred_only` the phrase can be left out, which lists every starred message in every chat. |
| `message_get` | read | Everything the database holds about one message: mentions, both timestamps, an attachment's path/size/length/author, a shared contact's full vCard, a link preview, a group event's actor and subject, the message it replies to (with the quoted words), who reacted with which emoji and when, and the raw delivery and error codes. |
| `media_list` | read | What was shared rather than said — photos, videos, GIFs, stickers, voice notes, audio, documents, locations, contact cards — with the message id each belongs to and the file's path on this Mac when it's here. |
| `group_get` | read | A group's own metadata (created when, by whom, name last changed) and every member row with its address, resolved name and admin flag. |
| `media_get` | read | The facts about the file behind an attachment: real path under `Message/`, MIME type, exact size, SHA-256, chat, sender and date. Says so when the file is not on this Mac. |
| `media_view` | read | What is inside an attachment: a photo, sticker or GIF as an image reduced to 1568 px, a PDF or text document as text (a scan says it has no text layer), a video as still frames. |
| `audio_transcribe` | **writes its cache** | A voice note, audio file or a video's sound as text with times, using macOS's on-device speech recognition. Needs the language as a full tag; Basque and Catalan are not supported and are refused, not guessed. |
| `calls_list` | read | Calls from `CallHistory`: when, how long, direction, missed, video or voice, group, participants. The outcome is the stored number, not a guessed word. |
| `location_sharing_list` | read | Live-location sharing sessions you started and who they went to. Coordinates are not decoded. |
| `labels_list` | read | WhatsApp Business labels, and what carries each. |
| `address_book_list` | read | WhatsApp's own copy of your address book, searched ignoring case and accents. |
| `lid_lookup` | read | Every LID↔phone pairing and name WhatsApp recorded for a value, each labelled with its table. Coverage is not measured. |
| `channels_list` | read | Channels this Mac knows about. |
| `db_tables`, `db_schema`, `db_query` | read | Tables, structure, and one `SELECT` against any allow-listed database. Rows and time are capped; key material and raw protocol queues are refused. |

No tool changes WhatsApp. Several do write the cache, and the `readOnlyHint` they declare is
about WhatsApp and the files it keeps, not about the cache: `audio_transcribe` declares itself
not read-only because storing its result is the point; every tool that reads a database
through a private copy (`db_*`, `calls_list`, `location_sharing_list`, `labels_list`,
`address_book_list`, `lid_lookup`, `channels_list`) writes that copy, and says when it was
taken; `media_view` on a video writes a transcript when it is given a `language`. A test walks
the catalogue and fails if any tool other than `audio_transcribe` stops declaring itself
read-only; it does not check which tools write the cache, so this paragraph is what says so.

Not covered: WhatsApp **status updates** — the structure of that database could not be
verified, so there is no tool for it (`db_query` can reach it). There is deliberately no
`contact_get`: `address_book_list` and `lid_lookup` cover what the databases hold.

## Frameworks and APIs

Reading WhatsApp's container needs Full Disk Access (see [Permissions](#permissions)). The
Apple frameworks used here have needed no other grant: the speech engine ran without a prompt
from the unsigned release binary launched from a terminal. Whether Claude Desktop shows a
Speech Recognition prompt for the installed bundle has not been checked on a clean install; if
macOS asks, grant it.

| Used | For | Reference |
|---|---|---|
| SQLite C API — `sqlite3_open_v2`, prepared statements, `sqlite3_create_function_v2` | Every read, over `file:…?mode=ro`, inside one read transaction, with `PRAGMA query_only` on; `wa_contains` does accent- and case-insensitive matching | [SQLite C API](https://www.sqlite.org/c3ref/intro.html), [URI filenames](https://www.sqlite.org/uri.html) |
| `sqlite3_backup_*` | The cache copies, read through the source's log into a file this server owns | [Online backup API](https://www.sqlite.org/backup.html) |
| `sqlite3_set_authorizer`, progress handler, `SQLITE_LIMIT_LENGTH` | Keeping `db_query` away from key material and bounding its cost | [Authorizer](https://www.sqlite.org/c3ref/set_authorizer.html) |
| `Speech` — `SpeechAnalyzer`, `SpeechTranscriber` (macOS 26+) | On-device transcription; no server path, no model download | [Speech](https://developer.apple.com/documentation/speech) |
| Protocol-buffers wire format, read by hand (`ProtobufWire`; no library) | A message's reactions (`ZWAMESSAGEINFO.ZRECEIPTINFO`) and the quote inside a reply (`ZWAMEDIAITEM.ZMETADATA`). WhatsApp publishes no schema, so an unrecognised shape yields nothing rather than a guess | [Encoding](https://protobuf.dev/programming-guides/encoding/) |
| `AVFoundation`, `ImageIO`, `PDFKit` | Video frames, image reduction, PDF text | — |
| `CryptoKit`, `UniformTypeIdentifiers` | SHA-256 and MIME types | — |
| `ffmpeg` (subprocess, one local file, format pinned by its first bytes) | A video's sound track and containers macOS cannot open; not Ogg Opus voice notes, MP3 or M4A, which `AVAudioFile` opens itself (checked on macOS 27 only) | [ffmpeg](https://ffmpeg.org/) |

Not used: FTS or `MATCH`, SQLite's incremental blob API, busy handlers, and any network access.

## Databases `db_*` can read

A fixed list, by name — the caller never supplies a path: `ChatStorage`, `ContactsV2`,
`CallHistory`, `Labels`, `Location`, `Sticker`, `LID`, `emoji`, `LocalKeyValue`,
`BackedUpKeyValue`, `ExtChatDB`, `statusDB`, `MessagingInfraDB_v2`, `fts` and `channels-fts`.
Encryption keys (`enc-key.dat`, `Axolotl*`), `BotPKICRL*`, lock files and logs are not on it
and cannot be reached by any name or path.

## The cache

`~/Library/Caches/whatsapp-mcp/` holds copies of WhatsApp's databases (refreshed when the
source file or its `-wal` changes), saved transcripts, and a scratch folder deleted after each conversion.
It is **real message data in plaintext**, readable only by your user, and it stays until you
delete it — remove the folder to remove it all. `--cache-directory` moves it. A copy is
emptied, as it is made, of the key material `db_query` refuses to return (feature keys, media
keys, the key-value blobs and the protocol queues) and rebuilt so that nothing WhatsApp had
already deleted survives in it; the rest of each database is copied as it is. This server
writes nowhere else: SQLite and the Apple frameworks it calls may use the system's temporary
files for their own transient work.

## Logs

The server writes one line per event to stderr, which Claude Desktop captures in
`~/Library/Logs/Claude/mcp-server-<name>.log`: the start, and each failed tool call with the
kind of its error and its duration. A line never carries an argument, a result, a message,
a path or an id; it names only the tool that failed. Nothing in the logging API accepts free
text, so none can be added by accident. Look there first when a tool misbehaves; `whatsapp_status` covers whether
the database can be read.

## Prerequisites for transcription

- macOS 26 or later, and the speech model for your language installed (System Settings →
  Keyboard → Dictation). A language that is supported but not installed is reported; nothing is
  downloaded.
- `ffmpeg`, only for a video's sound track and containers macOS cannot open (on macOS 27
  WhatsApp's own Ogg Opus voice notes, MP3 and M4A open without it; older versions are untested): `brew install ffmpeg`, or
  `--ffmpeg /path/to/ffmpeg`. It is run on one file whose format is decided here from its first
  bytes and passed with `-f`; a playlist or any other file is refused, because a playlist can
  name other files for ffmpeg to read.
- Basque and Catalan were not in the engine's list when this was written, and macOS does not
  detect the language, so `audio_transcribe` requires one; the error lists what the engine
  offers. A bare language (`es`) is accepted only when there is a single model for it, never
  picked for you from several.

## Permissions

On recent macOS (observed on macOS 27) another app's data folder is protected:
`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared` can be seen but not opened by
a program that has not been granted **Full Disk Access**. macOS answers that with a refusal
(`EPERM`), and this server reports it as one — `ACCESS DENIED` in `whatsapp_status` and the
same steps in every tool — and not as "not found".

1. System Settings → Privacy & Security → **Full Disk Access**.
2. Turn on, or add with **+**, the program that runs the server. Under Claude Desktop that is
   `whatsapp-mcp` itself (Claude runs extensions through its own helper, which makes the
   server its own program to macOS); the path is on the `binary:` line of `whatsapp_status`.
   If you start the server by hand, it is the terminal or app you started it from.
3. Quit that app completely and open it again.

**Repeat this after every update.** The grant belongs to the exact program: a rebuilt
`whatsapp-mcp` signed ad-hoc is a new program to macOS, and so is a new version of whatever
app launches it (Claude Code lost its own grant this way when it updated). A stable signing
identity would keep the grant across rebuilds, but a certificate's subject carries the name
of whoever holds it, so a binary meant to be published must not be signed with a personal one.

**Uninstalling:** remove the extension in Claude, remove the `whatsapp-mcp` entry from Full
Disk Access, and delete the cache (`rm -rf ~/Library/Caches/whatsapp-mcp` — it holds
plaintext copies of your WhatsApp data and is not removed with the extension).

## The rules worth knowing before you use it

**Reading WhatsApp needs Full Disk Access** — see [Permissions](#permissions). Without it the
server says so, with the steps, instead of reporting a missing file.

**The databases are opened `mode=ro`, and deliberately not `immutable=1`.** WhatsApp keeps
them in WAL mode, so the newest messages can sit only in the `-wal` file; an immutable
reader never looks there and would miss them. `immutable=1` is also a promise to SQLite
that nothing changes the file, which is false while WhatsApp runs — SQLite documents that
it may then return incorrect results or `SQLITE_CORRUPT`. A read-only reader takes a shared
lock for the length of one short transaction; in WAL mode that never blocks WhatsApp's own
writes, and a read-only connection cannot checkpoint. `PRAGMA query_only` is on for every
connection as a second refusal to write.

**Reading updates one WhatsApp file.** SQLite records every reader in the database's `-shm`
index, so that file's bytes and modification time change when this server reads. It is a
coordination file shared between WhatsApp and its readers, and holds no messages. Nothing
else in WhatsApp's container is written.

**When WhatsApp is not running** its databases have no `-wal` or `-shm` file. A `mode=ro`
connection could not open one without them in testing, and with nothing running there is
nothing to read from the log and nothing that can change the file — exactly what
`immutable=1` promises, and one of the three documented ways to open a WAL database
read-only. That case, and only that case, uses `immutable=1`, so reading creates no file
beside WhatsApp's own. `whatsapp_status` reports the size of the log.

**The schema is undocumented, and checked rather than assumed.** WhatsApp's local storage is
private and free to change shape in any update. If it ever stops matching what these tools
expect, `whatsapp_status` reports that as a fault — never as "you have no messages". A
schema change reading as an empty inbox would be the wrong kind of quiet failure.

**What genuinely is not in this database, and will not be guessed:**

- No LID→phone-number mapping in the chat database. A `…@lid` address WhatsApp has never
  resolved for you stays a LID there. `lid_lookup` reads separate pairing tables in
  `LID.sqlite` and `ExtChatDB`; how much they cover has not been measured.
- No disappearing-message or expiration setting, under any name, anywhere in the schema.
- A message deleted for everyone shows only that a deletion happened, with its sender and
  date. The original text is not recoverable, and the row it replaced cannot even be
  identified — WhatsApp clears it in place with no second copy and no link back.
- Who starred a message, and when. A star is a yes/no flag on the message; nothing else is stored.
- Reactions come with the reactor's address when WhatsApp stored one. Some entries (seen on
  messages from other people) name nobody; they are reported as "reactor not recorded". The one
  such entry that was checked was the owner's own reaction, but one case is not a rule, so it is
  never reported as you.
- Delivery/read status is reported as a raw number, never as a word. Ten distinct codes exist
  in the wild and none has been confirmed against WhatsApp's own interface, so no tool here
  will claim a message was "read" on the strength of a guess.

## Install

### 1. Build the bundle

```bash
./scripts/pack.sh
```

That builds an arm64 (Apple silicon only) release binary and writes
`dist/whatsapp-mcp.mcpb`. There is no `Info.plist` embedded; none has been needed so far (see
[Frameworks and APIs](#frameworks-and-apis)). An ad-hoc signature (the default) runs, but it is a new
program to macOS on every build, so Full Disk Access must be granted again each time. A stable
identity (`MCPB_SIGN_IDENTITY`) keeps the grant — but never sign a binary you publish with a
personal certificate, whose subject carries its holder's name.

### 2. Install it

Open `dist/whatsapp-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and reopen
it** — reinstalling does not replace a server process that is already running, and the old
one keeps answering.

### 3. Check it

Call `whatsapp_status`. It says `readable` when macOS lets the server open WhatsApp's database;
`ACCESS DENIED` means Full Disk Access is missing (see [Permissions](#permissions)) and `NOT
FOUND` means the file is not there — open WhatsApp for Mac at least once. For a video's sound, install `ffmpeg` (see [Prerequisites for transcription](#prerequisites-for-transcription)).

## Tool switches

Every tool can be turned on or off individually in Claude Desktop's extension settings,
because the manifest declares them all. No tool changes WhatsApp, so there is no switch that
can turn on anything destructive. Two switches are worth knowing: `db_query` reaches any
allow-listed database, and `audio_transcribe` is the one that declares it writes its cache.

Reading needs no configuration. Transcription needs the speech model for your language, and
`ffmpeg` for a video's sound (see above); `--ffmpeg` and `--cache-directory` exist for manual runs.

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

- **No LID→phone-number mapping exists in the chat database.** A `…@lid` sender this server
  cannot name stays a LID there; `lid_lookup` may find a pairing elsewhere, or nothing.
- **A copy is only as new as its last refresh.** A copy is retaken when the source or its
  log has changed, which for a busy database means a new copy — the database's own size,
  not the log's — after each change. A transaction WhatsApp has not committed yet is not in
  one; every answer says when its copy was taken.
- **Transcripts can be wrong**, and are labelled automatic. Basque and Catalan are refused.
- **Status updates have no tool**, because their database's structure could not be verified.
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

The suite runs against an in-memory fake store, fixture SQLite databases, or files generated by
the test itself (a gradient, a hand-written PDF, a one-second clip) —
invented, never a copy of anything real. Three things are not that, and say so: a test runs the real `ffmpeg` when Homebrew's is installed
(and is skipped otherwise); one runs macOS's real recogniser on speech synthesised by `say`, off
unless `WHATSAPP_MCP_SPEECH_TESTS=1`; and the `ServerLifecycle` suite starts the built debug
binary and stops it with real signals, off unless `WHATSAPP_MCP_E2E=1` (run `swift build` first;
it needs the en-US speech model). See `CLAUDE.md`, whose
hard rule at the top is what makes that non-negotiable.

Manual verification against a real WhatsApp database is the owner's job, and is done on a
copy: put a copy of `ChatStorage.sqlite` (and, for attachments, the files it names under
`Message/`) in a temporary directory and start the server with `--database <that copy>` and
`--cache-directory <another temporary directory>`, so neither the live container nor the real
cache is touched. Delete both afterwards.

## Licence

MIT.
