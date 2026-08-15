# Manual verification

Most claims this server makes can be settled with an aggregate query against the real
database, and `CLAUDE.md` says to prefer exactly that. What is left here is the part SQL
cannot answer on its own: whether what the tools report **matches what WhatsApp itself
shows on screen**.

```bash
npx @modelcontextprotocol/inspector ./.build/release/whatsapp-mcp
```

Nothing in this script sends anything, because this server has no way to. It reads.

## 0 — Before you start

WhatsApp for Mac must be installed and signed in, and should have been opened at least once
recently so the database is current.

## 1 — The store, and the fact that nothing guards it

| Step | Call | Expected |
|---|---|---|
| 1.1 | `whatsapp_status` | Database found, readable, with chat and message counts. |
| 1.2 | Read the output | It says the file is opened **read-only and immutable**, that **no macOS permission is involved**, and that the server has no tool that sends or deletes. |
| 1.3 | Quit WhatsApp, send yourself a message from your phone, wait, call `whatsapp_status` | May report pending unwritten changes; the newest message may not appear yet. |
| 1.4 | Open WhatsApp for Mac, wait a moment, call again | The message appears. |

Steps 1.3–1.4 demonstrate the honest cost of `immutable=1`. It is not a bug, and the status
tool is what keeps it from looking like one.

## 2 — Schema drift, the failure that matters most

This is the check to repeat after **every WhatsApp update**.

| Step | Call | Expected |
|---|---|---|
| 2.1 | `swift test` | Passes. The suite pins every schema assumption against a fixture database. |
| 2.2 | `whatsapp_status` | Reports the shape as expected, with no missing tables. |
| 2.3 | Point the server at a deliberately wrong path (a copied empty SQLite file) | Reports an **unexpected shape**, naming the missing tables. |
| 2.4 | In that state, `chats_list` | **Refused as a fault** — not an empty list. |

Step 2.4 is the one to care about. If a schema change ever reads as "you have no chats",
this server has become a liar rather than a tool.

## 3 — Chats

| Step | Call | Expected |
|---|---|---|
| 3.1 | `chats_list` | Individual and group chats, with ids, unread counts and last-message dates matching the app. |
| 3.2 | Default call | Archived chats are **absent**. |
| 3.3 | `include_archived: true` | They appear. |
| 3.4 | `include_hidden: true` | 12 more chats appear on the measured library, each marked `(hidden)`. Worth checking what WhatsApp itself calls these — the flag is reported without a name because nobody has confirmed one. |
| 3.5 | `name` filter | Matches ignoring case and accents. |
| 3.6 | `kinds` filter set to groups | Only groups. |
| 3.7 | A chat you have pinned in WhatsApp | Marked `(pinned)`, and its date is the **real** last-message date, not the year 7026. |

## 4 — Messages

| Step | Call | Expected |
|---|---|---|
| 4.1 | `chat_get` on a busy chat | Newest first; timestamps match the app to the minute. |
| 4.2 | `order: "oldest"` | Reversed. |
| 4.3 | Page with `offset` | Says what it withheld and how to get the next page. |
| 4.4 | A photo, a sticker, a voice note, a location | Each says **what kind it was**, never an empty line. |
| 4.5 | A voice note somebody recorded, beside an audio file somebody attached | `[voice note 0:14]` and `[audio 0:28]`. **This is the check worth doing carefully** — WhatsApp stores both as type 3 and only `ZMEDIAORIGIN` separates them, so a wrong reading here is invisible in the output. |
| 4.6 | A message where somebody was `@`-mentioned | The name appears inline as `@Name (digits)`, and `message_get` lists the same person under `mentions:`. |
| 4.7 | `chat_get` on a nonexistent id | Says so. |
| 4.8 | `whatsapp_search` for a word you know | Matches across chats, laid out exactly as `chat_get` lays it out with the chat named on each line. |
| 4.9 | `after` later than `before` | Refused. |
| 4.10 | `starred_only: true` | Only starred messages. |
| 4.11 | A group message from someone whose name WhatsApp knows | Named — not shown as `CNXy9s8GIAA=`, and not attributed to the group itself. |
| 4.12 | `message_get` on a link somebody sent | The URL, and the preview title and summary WhatsApp built. A message with several links shows **one** preview and appears **once**. |
| 4.13 | `message_get` on any message | A `delivery code:` line with a bare number and the sentence saying this server will not guess what it means. If a version ever prints "read" or "delivered" there, that mapping was invented. |

Step 4.4 is the difference between a record and a gap: a message with no text is a photo or
a sticker, not an empty message.

## 5 — Groups

| Step | Call | Expected |
|---|---|---|
| 5.1 | `group_get` on a group you know well | Everyone in the app's own "Group info" screen appears, with the right admin flags. |
| 5.2 | Compare against someone who **left** that group | This is the one worth doing. The member table keeps rows flagged inactive (86 of 190 measured), so a departed member most likely still appears, marked `(inactive)`. Confirm that reading is right — it is the only part of `group_get` inferred from a flag rather than read from a label. |
| 5.3 | `group_get` on a chat that is not a group | Refused, naming the chat's real kind. |
| 5.4 | Created-by / created-date / name-last-changed | Match what WhatsApp shows in "Group info". |
| 5.5 | A group whose icon you have seen in the app | An `Icon:` line whose path opens to that picture. A `Picture id:` line instead means the file is not on this Mac, which is normal. |
| 5.6 | `chat_get` on a group where someone was recently added or removed | Some events show `→ subject`; many show only an actor and a code. **That is correct and final** — 145 of the measured library's group events carry no subject anywhere in the database, and `ZWAGROUPMEMBERSCHANGE` was measured and proven unable to supply one. Do not reintroduce a correlation for it. |

## 6 — Media

| Step | Call | Expected |
|---|---|---|
| 6.1 | `media_list` | What was shared, with kind, size and date. On the measured library the nine kinds total 4897 rows, not the media table's 26733 — the rest are link-preview thumbnails on text messages and are correctly left out. |
| 6.2 | Old media never downloaded to this Mac | No path, and a note at the foot explaining that — normal, not an error. |
| 6.3 | A path it does report | The file genuinely opens. |
| 6.4 | A location somebody shared | Coordinates appear, and they land where the place actually is. **No photo, video or sticker anywhere in the list shows coordinates** — those columns hold pixel dimensions on every other kind, and a photo reported as a place is the failure this check exists for. |
| 6.5 | A shared contact card | The name on the card, and the full vCard under `message_get`. No other kind shows either; a 44-character base64 string appearing as a name, or a sticker appearing as somebody's contact, means a type gate was lost. |
| 6.6 | `kinds: ["voice_note"]`, then `kinds: ["audio"]` | Disjoint lists. On the measured library, 51 and 1. |
| 6.7 | A PDF somebody sent | `[document]` with its filename — and **no length**. `ZMOVIEDURATION` counts something else on a document (0 to 472, mostly 1–4, on `.pdf` files), so `[document 0:02]` means the gate was dropped and a contract is being reported as a two-second clip. |

## 7 — What is simply not there

These confirm absences, so "nothing appears" is the pass condition, not a bug to file.

| Step | Call | Expected |
|---|---|---|
| 7.1 | A chat with disappearing messages turned on | No TTL and no ephemeral marker anywhere in the output. WhatsApp does not store one locally. |
| 7.2 | A message someone deleted for everyone | `[deleted for everyone]` with its sender and date, and nothing else. The text is gone, and the row it referred to cannot be identified — `ZTEXT` never holds a stanza id and `ZPARENTMESSAGE` is NULL on every row in the database. |
| 7.3 | A group sender showing as `NNNNN@lid` | Stays a LID. There is no LID→phone table in this schema; cross-referencing a name is Claude's job via the Contacts server, not this server's. |
| 7.4 | `message_get` on a message you know was read | A number after `delivery code:`, never the word "read". Ten codes exist and none has been confirmed against the app; 6 is the commonest both incoming and outgoing, which is why no mapping is offered. |

## 8 — Packaging

| Step | Command | Expected |
|---|---|---|
| 8.1 | `bash scripts/pack.sh` | Every check passes. No TCC or Info.plist check appears — there is nothing left needing one. |
| 8.2 | Install, restart Claude Desktop | Seven switches appear, one per tool, and none of them can write anything. |

**Re-run section 2 after every WhatsApp update.** It is the only part of this script that
goes stale on somebody else's schedule.
