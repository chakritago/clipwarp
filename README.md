<div align="center">

<img src="assets/mascot.png" width="150" alt="Warpy, the clipwarp mascot">

# clipwarp

**Paste screenshots into Claude Code on Windows.**

Copy an image anywhere → press `Ctrl+V` in Claude Code → it attaches.
A tiny, local PowerShell utility. No admin, no dependencies.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-46C2A3.svg)](LICENSE)
[![Install](https://img.shields.io/badge/install-one%20command-FF654A)](#install)

<img src="assets/demo.gif" width="820" alt="clipwarp: install and watch in PowerShell, then a screenshot pasted straight into Claude Code with Ctrl+V">

</div>

---

## The problem

On **native Windows**, Claude Code can't read an image from the clipboard.
`Ctrl+V` and `Alt+V` silently do nothing after you snip with Snipping Tool
(`Win+Shift+S`), Lightshot, ShareX, or "Copy image" in a browser — a long-standing
issue reported across
[anthropics/claude-code#22068](https://github.com/anthropics/claude-code/issues/22068),
[#26679](https://github.com/anthropics/claude-code/issues/26679), and
[#32791](https://github.com/anthropics/claude-code/issues/32791) (the latter two
still open; `Alt+V` only works under WSL).

What **always** works is a file **path** pasted as text — Claude Code auto-attaches
any `.png` / `.jpg` / `.gif` / `.webp` path it sees. **clipwarp** turns whatever
image is on your clipboard into exactly that, automatically:

```text
┌─────────────┐     ┌──────────────────────────────┐     ┌────────────────────┐
│  Win+Shift+S │ ──▶ │  clipwarp: save clipboard    │ ──▶ │  Ctrl+V in Claude  │
│  / Ctrl+C    │     │  image → PNG, put its path   │     │  Code = image      │
│  anywhere    │     │  on the clipboard as text    │     │  attached ✓        │
└─────────────┘     └──────────────────────────────┘     └────────────────────┘
```

## Install

From a reviewed local clone in **PowerShell**:

```powershell
git clone https://github.com/chakritago/clipwarp
.\clipwarp\install.ps1 -SourceRoot .\clipwarp
```

Remote installation requires a release manifest published at a single full commit
SHA. Review the bootstrap installer before executing it; do not pipe a mutable
`main` script directly to `iex`. With a trusted local installer, use
`-SourceRoot '' -Commit <40-character-SHA>`. All payload downloads use that commit
and must match the fixed inventory and SHA-256 manifest before activation.
Checksums detect corruption, **not publisher authenticity or a digital signature**.
No remote release/manifest is published as part of this change.

The installer copies the scripts to `%USERPROFILE%\.claude\scripts` and registers a
`clipwarp` command (plus a short **`cw`** alias) in the all-hosts profile of **both**
PowerShell editions — Windows PowerShell 5.1 and PowerShell 7 — so it works whichever
one you open. Start the watcher explicitly with `clipwarp watch`; upgrades restart
only a previously verified running watcher. Login autostart is opt-in via
`clipwarp autostart`; updates preserve any existing login shortcut. Open a **new** terminal afterwards (or run `. $PROFILE`) so
the command is found.

> No admin rights, no services, no dependencies — plain PowerShell and .NET classes
> that ship with Windows. Image conversion runs **locally**; optional browser actions require explicit clicks.

## Quick start

### Automatic (recommended) — plain `Ctrl+C` → `Ctrl+V`

```powershell
clipwarp watch       # start it again if you previously ran `clipwarp stop`
clipwarp autostart   # optional: also start it at every login
```

While the watcher runs, **every image that lands on the clipboard is converted
automatically** — snip, Lightshot, browser "Copy image", `Ctrl+C` on an image file.
Just `Ctrl+V` in Claude Code and the image attaches. Meaningful text copies also
remain unchanged and offer a small clickable Google Calendar prompt near the mouse.
Calendar prompts can be disabled independently with `clipwarp calendar disable`;
image conversion continues normally.

The clipboard is rewritten as **dual format**, so nothing else breaks:

| Paste target | What pastes |
|---|---|
| Claude Code / any terminal | the saved image's **path** (auto-attaches) |
| Photoshop, Word, Discord, a browser… | the original **image** |

### ChatGPT Web & Target Awareness

When using ChatGPT on the web (e.g. in Chrome, Edge, Firefox, Brave, Vivaldi, Opera), pasting a copied image pastes the **actual image**, never a local file path.
In auto mode, browsers receive a pure image payload (PNG / Bitmap) without
`UnicodeText` or file-drop lists. File pickers and recognized terminals receive an
image plus path payload. Target classification is a local compatibility heuristic,
not proof of a browser page's origin or permission to send a message.

You can also check or explicitly configure the target mode at any time:
```powershell
clipwarp target status       # view active mode (default: auto)
clipwarp target auto         # file picker / terminal -> dual; other apps -> image-only
clipwarp target chatgpt      # force pure image output (no path text)
clipwarp target claude       # force dual format (path text + image)
```

Copies that carry meaningful text alongside an image (e.g. a paragraph from Word)
are left untouched by image conversion and use that text in the calendar prompt.

### Google Calendar prompt

After a meaningful text copy or a successful image conversion, a topmost prompt
appears directly below the pointer position captured when you copied, stays within
the correct monitor's working area, and dismisses after the configured duration
(with countdown). The initial display must not steal typing focus; hover or active
interaction pauses expiry. Click Calendar to open it, or dismiss with `Esc` after
focusing the popup. Run is never the default Enter action.
Copied text containing an explicit ISO local date and 24-hour time, such as
`Review 2026-09-15 14:30`, creates a timed event; a range such as
`Meeting 2026-09-15 14:00-15:30` sets an explicit end. An ISO date without a
time creates an all-day event on that date. Supported forms also include DMY dates,
Thai dates and AM/PM times. Unrecognized text uses the existing tomorrow all-day
fallback. Invalid explicit dates require review instead of crashing or silently
claiming a valid event. Showing the prompt and using Calendar do not change the clipboard.

The text popup offers separate Calendar, ChatGPT and Run actions. **ChatGPT is a
manual handoff**: an explicit click may copy the original text (only if the
clipboard has not changed) and opens `https://chatgpt.com/?temporary-chat=true`.
Check that you are in a temporary chat, then paste and send yourself. Clipwarp does
not verify browser origin, composer or focus, does not use window titles as proof,
and never sends global paste/Enter keystrokes. Opening the URL is not a claim that
a message was sent. Message text and local paths never appear in the URL or logs.
A newer clipboard copy cancels the stale copy instead of overwriting it.

For an image, Google Calendar's template URL cannot upload or attach a local file.
clipwarp therefore opens the event editor with a sensible image title and tomorrow's
date, then opens Explorer with the preserved image selected. **You must drag that
selected file into the event or use Calendar's attachment control, then save the
event.** No upload or attachment is claimed, and no OAuth, Drive API, credentials,
or browser automation are used.

Image paths produced by clipwarp, empty clipboard content, and duplicate clipboard
notifications do not create prompts. To disable all automatic clipboard handling
and prompts, run `clipwarp stop`; also run `clipwarp unautostart` if login startup
was enabled.

Settings live in `%USERPROFILE%\.claude\clipwarp.json`. A missing file uses defaults;
invalid or unreadable configuration is not silently overwritten or treated as
permission to resume automation. A validated backup may be used; otherwise
processing pauses with a diagnostic. Use `clipwarp calendar enable|disable|status` instead of
editing the file by hand. Very long Unicode text uses a temporary UTF-8 file so
it does not exceed Windows command-line limits; the popup consumes and removes it.
Long or multiline clipboard text gets a concise, single-line event title and the
complete original text is placed in event details when it fits the bounded Google
Calendar URL transport. Timed-event parsing retains the original clipboard text for
those details. Calendar URLs include a mapped IANA timezone for timed events and
remain bounded. Image paths are never
included by default. `clipwarp calendar image-details enable` opts into sending only
the filename to Google when a prompt is accepted; `full-path` is a separate, less
private opt-in. Use `clipwarp calendar duration 45` to change the single-time default
(1–1440 minutes), or `duration status` to inspect it.

`clipwarp calendar export -Title 'Planning 2026-09-15 14:00-15:00' [-Details '...'] [-Path event.ics] [-TimeZone 'SE Asia Standard Time']`
creates a local RFC 5545 `.ics` file. It does not open Google or change the clipboard;
only the explicit `-Clipboard` switch copies the exported file path as text. Export
uses the same date/time parser and configured default duration as the popup, and
accepts either a Windows or IANA timezone ID. `SE Asia Standard Time` maps to
`Asia/Bangkok`; unknown Windows IDs safely omit timezone metadata. Popup previews
show only the event title and parsed date/time. The watcher replaces a prior text
popup it owns, and a process-wide popup guard prevents independently launched text
and image prompts from accumulating concurrently. Bounded cleanup removes only old
`clipwarp-title-<GUID>.txt` transport files. In-process image conversion remains
future work.

```powershell
clipwarp status       # is the watcher running? is autostart on?
clipwarp stop         # stop it
clipwarp unautostart  # remove the login autostart
```

> [!IMPORTANT]
> **Pause before copying sensitive content.** Auto targeting rewrites clipboard
> formats according to the foreground app; forced dual/text modes can expose a
> local file path to text boxes. Use `clipwarp privacy pause` or `clipwarp stop`
> when not needed, and `clipwarp unautostart` to disable login startup.

### Manual — one command per paste

1. Snip or copy any image (`Win+Shift+S`, Lightshot, ShareX, a browser…).
2. Run **`cw`** (short for `clipwarp`).
3. Switch to Claude Code and press `Ctrl+V`. Done.

## Commands

| Command | What it does |
|---|---|
| `clipwarp watch` | Start image auto-conversion and text/image Calendar prompts again after stopping it. |
| `clipwarp autostart` | Start the watcher automatically at every login. |
| `clipwarp status` | Is the watcher running? Is autostart on? |
| `clipwarp stop` | Stop the watcher. |
| `clipwarp unautostart` | Remove the login autostart. |
| `clipwarp calendar enable\|disable\|status` | Configure Calendar prompts without changing image conversion or watcher state. |
| `clipwarp actions calendar\|chatgpt\|runCommand enable\|disable\|status` | Configure each action independently, preserving disabled migrated settings. |
| `clipwarp popup duration <seconds 3-300>\|status` | Configure popup timeout; interaction pauses countdown. |
| `clipwarp target explain [-Json]` | Explain the shared target rule without logging window captions. |
| `clipwarp calendar image-details enable\|full-path\|disable\|status` | Control whether image event details expose nothing (default), a filename, or a full local path. |
| `clipwarp calendar duration <minutes>\|status` | Set or inspect the default duration for a single explicit time. |
| `clipwarp calendar export -Title <text> [-Details <text>] [-Path <file>] [-TimeZone <id>] [-Clipboard]` | Parse strict ISO date/time text and export a local `.ics`; only `-Clipboard` copies its path as text. |
| `clipwarp history -Limit 20` | List saved clipwarp images newest-first (maximum 100). Never changes the clipboard. |
| `clipwarp recopy [index\|path]` | Explicitly copy the newest saved image path, a 1-based history index, or a named managed image path to the clipboard. |
| `clipwarp clean -Before <date>` | Delete only direct-child `clip-*` image files older than the cutoff (default 7 days). |
| `clipwarp doctor [-Json]` | Read-only diagnostics for installed metadata, profiles, watcher/autostart, PowerShell policy, config and output path. |
| `clipwarp version [-Json]` | Show installed origin/version metadata, or identify a development checkout. |
| `clipwarp clean -Preview` / `-WhatIf` | Preview managed deletions without touching files. |
| `cw` | Convert one clipboard image, show the Calendar prompt, then `Ctrl+V`. |

## Supported clipboard formats

clipwarp reads the clipboard in whatever format the source app actually used — this
is what makes it work where a naive `Get-Clipboard -Format Image` fails:

| Clipboard format | Typical source |
|---|---|
| `CF_BITMAP` / `CF_DIB` | Snipping Tool, `Win+Shift+S`, `PrtScn` |
| `PNG` / `image/png` stream | Lightshot, Chrome, Firefox, Discord, ShareX |
| `CF_DIBV5` (alpha, BITFIELDS) | alpha-aware apps — decoded manually, since GDI+ can't parse `BITMAPV5HEADER`+`BI_BITFIELDS` |
| `CF_HDROP` (file copy) | `Ctrl+C` on an image file in Explorer |
| HTML with `data:` URI / `file:///` src | browser "Copy image" fallback |
| Plain text that is already an image path | anything |

Image clipboard payloads must be genuine PNG plus a decoded bitmap, never JPEG/GIF/
WebP bytes merely labelled PNG. GIF uses its first frame. WebP is supported only when
the installed decoder can actually decode it; otherwise the encoding is reported
unsupported. Source bytes, dimensions, pixel count and decoded memory are bounded;
malformed or substantially truncated DIB images are rejected before allocation.
Clipboard publication compares the source sequence while holding the native lock,
so a slow conversion does not overwrite a newer copy.

## Privacy & housekeeping

- **Local by default.** Image conversion and storage stay local. Accepting a Calendar prompt
  opens Google's Calendar website; clipwarp itself uploads no images. Deliberately
  launched PowerShell commands can access the network or modify your machine.
- **Opt-in retention.** `clipwarp privacy retention 7` deletes managed images older
  than seven days after successful conversions, excluding the active image.
  `clipwarp privacy retention 0` disables automatic deletion (the default).
  Valid values are 0-3650 days. The validated `retention` configuration also supports
  opt-in `maxCount` and `maxBytes` caps (zero means unlimited). There is no background
  cleanup timer; files remain until another successful conversion or explicit cleanup.
  Cleanup skips reparse points and refuses directories reached through them.
- **Safe history tools.** `history` is bounded and read-only. `clean` refuses a drive
  root and only deletes matching managed files directly inside `-OutDir`; `recopy` is
  the only history command that writes to the clipboard.
- **Performance roadmap.** Image conversion still uses an isolated PowerShell child
  process for compatibility with the multi-format decoder and both PowerShell editions;
  an in-process conversion path remains future work and requires separate benchmarking.

Pause before working with passwords, financial records, or other sensitive material:

```powershell
clipwarp privacy pause
clipwarp privacy status
# After leaving the sensitive app:
clipwarp privacy resume  # copy again to process new content
```

Pause is persistent in `%USERPROFILE%\.claude\clipwarp.json` (`paused: true`).
It suppresses watcher image conversion, target rewriting, text prompts, and manual
conversion. Checks occur before processing and publication; it does not cancel an
already open popup or undo a file already saved by an in-flight conversion. Close
prompts and use `clipwarp stop` when you need the listener fully stopped. Explicit
`recopy` and Calendar export remain deliberate actions. There is no automatic
sensitive-process detection: foreground process names cannot reliably identify the
source of every clipboard copy. Pause before copying, rather than after.

Clipboard sequence comparison occurs under the native clipboard lock before
publication, including the initial conversion and target switches. A newer copy
cancels a stale write. Custom ownership markers are bookkeeping, not a security
boundary against other local applications. A native publication failure after
emptying the clipboard may leave a partial payload; clipwarp cannot roll back
another application's clipboard safely.

Saved files and temporary Calendar title files can contain sensitive content.
Cleanup is ordinary deletion, not secure erasure; it does not clear Windows
Clipboard History, cloud sync, backups, or copies retained by other applications.
Configure those Windows features yourself if needed. No unsupported History/cloud
API is used. Clicking Run with PowerShell deliberately executes clipboard text in
a visible PowerShell window only after a full-script review shows the interpreter
and working directory and you explicitly confirm. The reviewed snapshot, not a
fresh clipboard read, is executed. Long scripts use a unique current-user-protected
transport file and a fixed loader rather than exceeding the Windows process launch
limit; transport failure cancels execution. Enter never activates Run. Calendar parsing, details privacy, and ICS export are
independent of command detection.

Auto targeting uses process/window-title heuristics: Windows file pickers and
terminals (including recognized integrated-terminal titles) receive dual payloads;
other apps receive image-only. A browser page titled "Open" or "PowerShell" is not
itself a file picker or terminal. A screenshot overlay retains the preceding target
for at most 12 seconds from overlay entry; a new non-overlay target replaces it.
`web`, `chatgpt`, and `image-only` force PNG/bitmap without path text/file-drop;
`claude` and `dual` force image plus path text/file-drop; `text` forces path text.
Use `clipwarp target <mode>` for persistent settings or `-TargetMode <mode>` for
one conversion. An explicit non-auto flag overrides the saved mode.

The real ChatGPT paste and Windows file-picker GUI boundary remains **unverified**
by the automated suite. Tests construct payloads and exercise helper logic without
opening a UI or accessing the real clipboard; they cannot prove how a particular
browser/app version consumes those formats.

## Regression tests

With existing PowerShell 7 and Windows PowerShell 5.1 executables available:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1 -Engine All -ResultsPath .\test-results.json
# Run one edition or focused suites:
.\tests\run-all.ps1 -Engine Pwsh -Suite '*calendar*','*chatgpt*' -SuiteTimeoutSeconds 120
# If pwsh is not on PATH:
.\tests\run-all.ps1 -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe'
```

The runner launches every `tests/*.Tests.ps1` in a separate process under the
selected editions, captures stdout/stderr and JSON suite results, and applies a
per-suite timeout. A Windows job owns each suite and its descendants, including
children left after successful exit. Missing engines, failures and timeouts are
nonzero results. Generated environment/profile/temp roots prevent ordinary tests
from using user settings. Compatibility tests parse PowerShell and compile C#;
installer tests must supply isolated roots and mocked watcher/profile operations.
The runner itself performs no real clipboard, browser or autostart action.

### Verification boundaries

The normal suites must use generated profile/config/temp roots and must not access
the real clipboard or open a browser. Interactive native fixtures belong under
`tests/integration` and require explicit opt-in on a disposable desktop. They are
not part of the default test run. Passing helper/AST tests is not evidence of a
real ChatGPT send, file-picker paste, focus/hover/DPI behavior, or clipboard round-trip.
Environment-variable redirection is isolation for cooperative tests, not a security
sandbox for arbitrary native APIs.

## สรุปความปลอดภัย (ภาษาไทย)

- ChatGPT เป็นการส่งต่อแบบ **วางและส่งเอง** ไม่ใช้ global Ctrl+V/Enter ไม่ยืนยัน
  origin จากชื่อหน้าต่าง และไม่รายงานว่าส่งสำเร็จ ข้อความไม่อยู่ใน URL หรือ log
- Calendar, ChatGPT และ Run แยกการเปิดใช้งานได้ Run ต้องอ่านสคริปต์เต็ม พร้อม
  interpreter/working directory แล้วกดยืนยัน จึงรัน snapshot ที่ตรวจแล้ว
- รองรับ ISO, DMY, วันที่ไทย และ AM/PM ข้อความที่ไม่รู้จักใช้กิจกรรมทั้งวันของ
  วันพรุ่งนี้ วันที่ผิดต้องตรวจทาน URL จำกัดรวม 1,900 ตัวอักษรหลังเข้ารหัส
- GIF ใช้เฟรมแรก WebP ต้องมี decoder จริง ภาพเกินขีดจำกัดหรือ DIB ขาดข้อมูล
  ถูกปฏิเสธ ไม่เปลี่ยน bytes ที่ไม่ใช่ PNG ให้เป็น PNG เพียงด้วยชื่อ format
- Autostart และ retention เป็น opt-in เก็บค่าที่ผู้ใช้ปิดไว้ ใช้
  `clipwarp clean -WhatIf` เพื่อดูรายการก่อนลบ ไม่ลบไฟล์อื่นหรือไล่ผ่าน reparse point
- การลบไม่ใช่ secure erase และไม่ล้าง Windows Clipboard History, cloud หรือ backup
- ทดสอบ helper ในรากชั่วคราวไม่เท่ากับทดสอบ clipboard/browser จริง ต้องแยก native
  integration แบบยินยอมชัดเจน และรายงานกรณีที่ยังไม่ได้ทดสอบ

## Scripting

`clipwarp` prints the saved path, so it composes:

```powershell
$img = clipwarp -Quiet   # -> C:\Users\you\.claude\pasted-images\clip-....png
```

| Flag | Meaning |
|---|---|
| `-OutDir <path>` | Where to save PNGs (default `%USERPROFILE%\.claude\pasted-images`). |
| `-Quiet` | Print only the path. |
| `-KeepImage` | Dual-format write: path as text **and** the original image (what the watcher uses). |

## FAQ

<details>
<summary><b>Why doesn't Ctrl+V image paste work in Claude Code on Windows?</b></summary>

Claude Code's terminal UI on native Windows can't read raw bitmaps from the Windows
clipboard, and `Alt+V` is WSL-only. Pasting a file **path** as text is the reliable
route — clipwarp automates it.
</details>

<details>
<summary><b>How do I paste a screenshot into Claude Code?</b></summary>

With the watcher running (`clipwarp watch`), take the screenshot (`Win+Shift+S`,
`PrtScn`, Lightshot…), then press `Ctrl+V` in Claude Code. Without the watcher, run
`cw` after the screenshot, then `Ctrl+V`.
</details>

<details>
<summary><b>Does it work with WSL?</b></summary>

Under WSL, Claude Code's own `Alt+V` usually works. clipwarp targets **native Windows**
(Windows Terminal, PowerShell, cmd, VS Code terminal), where nothing else does.
</details>

<details>
<summary><b>Will it clutter my disk?</b></summary>

Saved images remain until you delete them. Automatic cleanup is **off by default**.
Opt in with `clipwarp privacy retention 7`, or preview an explicit cleanup with
`clipwarp clean -WhatIf` (see [Privacy & housekeeping](#privacy--housekeeping)).
</details>

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (preinstalled) **or** PowerShell 7 — both supported and both
  registered by the installer (clipboard access is marshalled onto an STA thread
  internally)
- [Claude Code](https://claude.com/claude-code) running in any native Windows terminal

## Uninstall

```powershell
# Works after any install (the installer copies the uninstaller here):
& "$HOME\.claude\scripts\uninstall.ps1"
& "$HOME\.claude\scripts\uninstall.ps1" -PurgeImages   # also delete saved images

# Or, from the git clone you installed from:
.\clipwarp\uninstall.ps1
```

The uninstaller stops only a verified watcher, removes its login-autostart shortcut,
removes the fixed installed inventory, and strips the `clipwarp` profile block from
both editions. Use `-WhatIf` first. Images, settings, logs and transports are separate
opt-in purge categories (`-PurgeImages`, `-PurgeSettings`, `-PurgeLogs`,
`-PurgeTransport`). Unrelated files and nested directories are retained; purge does
not recurse through arbitrary user folders or reparse points. Recent/in-use title
transports and command transports without provable ownership/expiry are retained.
Windows Clipboard History, cloud copies and backups are not removed.

## Contributing

Issues and PRs welcome — especially reports of clipboard formats from apps that still
fail (attach the output of `clipwarp` without `-Quiet`).

## License

[MIT](LICENSE)
