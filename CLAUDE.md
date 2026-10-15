# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Nothing is ever written to, modified in or deleted from WhatsApp's container
(`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared`), and no send capability exists. Do not print, log or commit real message text, contact names or phone numbers; prefer aggregate or structural queries over selecting rows.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real chat store, never the real cache, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that. A test that needs a cache directory passes its own temporary one.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

The read path takes a database path, so the gentle route is a copy of the store under a temporary directory you made yourself — never the live file — deleted in the same session. `--database` points the server at such a copy and `--cache-directory` at a temporary cache; use both, so a manual run touches neither the live container nor the real cache.

## The one place this server writes

`~/Library/Caches/whatsapp-mcp/` (`--cache-directory` moves it, for manual runs and tests) and nowhere else — not WhatsApp's container, not the media files it reads, and no file of this server's own code goes to the system temporary directory. (SQLite and the Apple frameworks it calls may use the system's temporary files for their own transient work; that is theirs, not a write location of this server.) It holds:

- **Copies of allow-listed WhatsApp databases** (`<Name>.sqlite`, with a `<Name>.stamp.json`), made with the SQLite online-backup API from a source opened `mode=ro&immutable=1` and refreshed when the source's modification time or size changes. While one is being written it exists as `<Name>.sqlite.tmp-<uuid>`. Before a copy is kept, everything `blockedReads` refuses (feature keys, media keys, key-value blobs, the protocol queues) is emptied in it with `secure_delete` on; if that fails, the copy fails.
- **Transcripts** (`transcripts/<sha256>-<language>.json`), so the same audio is recognised once. `media_view` on a video writes one too when it is given a `language`.
- **A scratch directory** (`tmp/<uuid>/`) for the WAV `ffmpeg` produces, deleted when the call ends. A process killed mid-call can leave one behind; it is safe to delete.

This is **real message data, in plaintext, kept until the owner deletes it** — not a scratch space. Directories this server creates are `0700` and its files `0600`; a directory that already existed keeps its mode, because it is not this server's to change. Never print, commit or attach its contents, and never use it for debugging. A new write location, or a new kind of thing kept there, means amending this section first.

The only `sqlite3_open_v2` in the project that is not `SQLITE_OPEN_READONLY` opens the temporary file a copy is being written to inside that directory.

## What this is

A local MCP server (Swift 6, stdio transport) for WhatsApp. It reads WhatsApp's databases — the chat store `ChatStorage.sqlite` directly, the rest through the private copies above — and the media files under `Message/`. No network of any kind: no cloud API, no credential, and no model download. Nothing outward-facing, and nothing that changes WhatsApp.

Not affiliated with, endorsed by, or connected to WhatsApp or Meta.

## APIs

- [SQLite C API](https://www.sqlite.org/c3ref/intro.html) against WhatsApp's own databases, opened read-only and immutable through a [URI filename](https://www.sqlite.org/uri.html); `sqlite3_create_function_v2` for accent- and case-insensitive matching; `sqlite3_backup_*` for the cache copies; `sqlite3_set_authorizer` to refuse reads of key material in `db_query`; a progress handler and `SQLITE_LIMIT_LENGTH` to bound it.
- Apple frameworks, none of which needs a TCC permission as far as has been observed: `Speech` (`SpeechAnalyzer`/`SpeechTranscriber`, macOS 26 and later, on-device only), `AVFoundation`, `ImageIO`, `PDFKit`, `CryptoKit`, `UniformTypeIdentifiers`.
- One local subprocess, `ffmpeg` (Homebrew's prefixes or `--ffmpeg`), run on a single file with `-protocol_whitelist file`, to convert Ogg Opus, which macOS cannot open.

## Surface not used

- FTS and `MATCH`, the blob API, busy handlers.
- Any write to WhatsApp's container, and any open of its *databases* other than `mode=ro&immutable=1`. Media files are opened for reading only, by the Apple frameworks and `ffmpeg`.
- Any network access, including a speech-model download: a locale that is supported but not installed is reported, never fetched.
- A language fallback. A language the speech engine lacks (Basque, Catalan) is an error, never a transcript in another language.
- **What can never be read**, by any tool, whatever it is called: `enc-key.dat`, `Axolotl*.sqlite`, Signal key material, `BotPKICRL*`, `*.lock`, `Logs`. Databases are an allow-list (`AllowedDatabase`), not a deny-list, and the caller names one, never a path. Inside the allowed databases, `blockedReads` refuses key columns and raw protocol queues at prepare time.
- The schema is WhatsApp's private storage, undocumented and free to change in any update. Readers name the tables and columns they need, taken from the real `.schema`, and a missing one is reported as a changed schema. If a check fails, say the reads are wrong — not that there are no messages.

## Commands

```bash
swift build
swift build -c release
swift test
WHATSAPP_MCP_SPEECH_TESTS=1 swift test --filter NativeSpeech   # real recogniser, synthesised speech; off by default
```
