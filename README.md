# dltidy

A background macOS agent that watches `~/Downloads`. When a new file arrives:

- **Generic name** (`IMG_1234.HEIC`, a UUID, a timestamp, `ChatGPT Image …`, `Screenshot …`): the file gets a
  kebab-case name based on its content, from Claude Haiku. `IMG_9999.HEIC` → `hardware-store-receipt-itemized-purchases.heic`.
- **Image**: a `.png` copy if it is not a PNG, a `.jpg` copy if it is not a JPEG. EXIF, GPS and color
  profile are kept; transparency becomes white in the JPEG.
- **Video** (animated GIF/WebP included): an `.mp4` copy if it is not an MP4, and a `.gif` for clips of 10 s
  or less. HDR video becomes H.264 SDR. The `.MOV` half of a Live Photo gets no copies.

Originals are never deleted. Files present at install are left alone.

## Requirements

- macOS 15 or later, Xcode command-line tools (Swift 6)
- `brew install imagemagick ffmpeg`
- An Anthropic API key. Create a separate Console workspace for dltidy with a monthly spend limit
  ($5 is enough) and create the key in that workspace.

## Install

```sh
make install                              # build, sign, install the app and LaunchAgent, run doctor
pbpaste | ~/.local/bin/dltidy set-key     # copy the API key first; it never appears on screen
```

Approve the one-time "DLTidy would like to access files in your Downloads folder" prompt if it appears.
The agent starts at login and launchd restarts it if it exits. Rerun `make install` to upgrade.

`make install` needs no prompts. The signing identity lives in its own keychain
(`~/Library/Application Support/dltidy-signing/`, generated password, codesign pre-authorized), so
signing works from a headless shell. A stable identity keeps the Downloads grant and the Keychain access
across rebuilds.

Uninstall: `make uninstall`. `make uninstall PURGE=1` also removes the ledger, logs and the API key. The
signing keychain stays; delete `~/Library/Application Support/dltidy-signing/` to remove it.

## Commands

`~/.local/bin/dltidy` (add `~/.local/bin` to `PATH`):

| Command | Effect |
|---|---|
| `status` | Health, API calls used against the caps, breaker state, pending items |
| `log [-n N]` | Recent actions |
| `doctor` | Run the health checks |
| `pause` / `resume [--skip-backlog]` | Stop / restart processing |
| `undo [--last \| <name>]` | Restore the old name of a renamed file and its copies |
| `set-key` | Store the API key (hidden prompt, or piped on stdin) |

Files: log `~/Library/Logs/dltidy/dltidy.log`, state `~/Library/Application Support/dltidy/`, key in the
login Keychain under service `local.dltidy`.

## How it works

### Event model

FSEvents only triggers a scan. Each scan lists the top level of `~/Downloads` and compares it with a SQLite
ledger, and the ledger decides what happens. A scan also runs every 5 minutes, after wake, and at start.
A scan that cannot read the folder aborts; it is never treated as "empty".

A file is processed when all of these hold:

1. A regular top-level file, not hidden.
2. Not a partial download (`.crdownload`, `.part`, `.download`, …) and no such sibling.
3. Size above 0.
4. Not known to the ledger.
5. Inode, size and mtime unchanged across 3 scans spanning at least 5 s.
6. No other new file for 5 s (60 s max), so Live Photo pairs and AirDrop batches group.
7. At least 20 s since it appeared under its current name, so you can open a fresh download from the
   browser before it is renamed.
8. A clone of it decodes. Retries at 30 s, 2 min and 10 min, then the file is marked unreadable.

### No reprocessing, no regeneration

- Identity is inode + size + mtime, a SHA-256 hash, and an xattr (`local.dltidy.role`) on every file
  dltidy writes. The path is display data only.
- Outputs are built in a staging folder from a `clonefile` copy, tagged, recorded in the ledger, then
  moved into Downloads with an atomic no-overwrite rename. No partial file appears in Downloads.
- A deleted original or copy is recorded as missing and never recreated. A re-download of identical
  bytes is skipped by hash. An existing file at a target name blocks that copy.
- Every ambiguous case resolves to "do nothing".

### Spend controls

`Budget.reserve()` is the only path to the API. It records each call in the ledger before the request is
sent, so a crash mid-request still counts.

| Control | Default |
|---|---|
| Requests per file group | 3 (1 name check + 2 naming attempts) |
| Daily / monthly call caps | 300 / 3,000 |
| Monthly input-token cap | 6,000,000 |
| Transient failure (5xx, network) | one second attempt after 5 min, no third |
| Rate limit (429) | pause for `max(retry-after, 60 s)`, 1 h max |
| Bad key (401/402/403) | stop until `set-key` |
| Circuit breaker | opens after 3 failures for 15 min, doubling to 6 h |
| Crash loop | 5 starts in 10 min → safe mode (no API calls, no conversions) |
| Fuse | > 2,000 actions/hour or a repeated action → pause + one notification |
| Outer limit | Console workspace spend limit |

Requests use `claude-haiku-5-5`, thinking disabled, effort `low`, `max_tokens` 300, a JSON-schema response,
and images scaled to ≤ 768 px and ≤ 300 KB. Measured cost: about $0.0001 per image. The worst case under
the caps is about $1.05 a month.

When naming is unavailable (offline, cap reached, breaker open) files are converted under their old
names, and the group is renamed if the API returns within 24 h of arrival.

### Failure handling

Health checks (Downloads readable, tools present, key present, staging, ledger, free space) run at start
and every 5 minutes. A failing check sends one notification per incident and the daemon waits and
rechecks; it does not exit, so launchd cannot restart it in a loop. The ledger is backed up daily (7
kept) and restored from the newest good backup if it is corrupt.

## Code layout

```
Sources/DLTidyKit/     shared interfaces (Interfaces.swift), tool runner, Keychain
Sources/DLTidyMedia/   probing and conversion: ImageMagick, ffmpeg, AVFoundation (HDR)
Sources/DLTidyNaming/  name rules, slug, content extraction, Anthropic client
Sources/DLTidyCore/    ledger, scanner, readiness, pipeline, budget, health, CLI queue
Sources/dltidy/        daemon (FSEvents, launchd) and CLI entry point; wires the modules
Support/               Info.plist, LaunchAgent template, signing script
Tests/                 one test target per module
```

DLTidyCore depends only on the protocols in `DLTidyKit/Interfaces.swift`; the executable picks the
implementations. Tests run with fakes and never call the live API (`DLTIDY_LIVE=1` is required for that in
debug builds).

```sh
swift test
```

## Using another model provider (Gemini, OpenAI)

The naming provider is replaceable in code; there is no runtime setting yet.

The core talks to the model through the `NamingService` protocol in `Sources/DLTidyKit/Interfaces.swift`:

```swift
public protocol NamingService: Sendable {
    func classifyStem(_ stem: String, apiKey: String) async -> APIResult<Bool>
    func suggestName(for payload: NamingPayload, originalName: String, apiKey: String) async -> APIResult<NameSuggestion>
}
```

Each call makes one HTTP request and returns one `APIResult`: `ok`, `final` (no retry), `transient`,
`rateLimited`, or `authFailure`. Caps, breaker, retry rules and deferred rename sit above this protocol and
apply to any provider.

Anthropic-specific code:

| Location | What |
|---|---|
| `Sources/DLTidyNaming/AnthropicNamingClient.swift` | Request, response parsing, status mapping |
| `Sources/dltidy/Daemon.swift` (`naming: AnthropicNamingClient()`) | Provider choice |
| `Sources/DLTidyKit/Keychain.swift` (`apiKeyAccount`) | Keychain entry `anthropic-api-key` |
| `Sources/dltidy/main.swift` (`sk-ant-` check) | Key-format warning in `set-key` |

To add a provider:

1. Write a client in `Sources/DLTidyNaming/` that implements `NamingService`: one request per call, no
   retries, a JSON-schema response (`{name, confidence}` for naming, `{generic}` for the name check),
   image input as base64 JPEG, and the status mapping above. Gemini and OpenAI both support structured
   output and image input.
2. Add a provider setting (for example `dltidy set-key --provider gemini`) that stores the key under a
   per-provider Keychain account, and build the matching client in `Daemon.swift`.
3. Copy `Tests/DLTidyNamingTests/ClientTests.swift`: a URLProtocol stub, one request per call, every
   `APIResult` case, and request-body checks.

The caps count calls and tokens, not dollars. The 6M-token monthly cap is about $0.60 of input on Haiku;
on a more expensive model the same cap allows more spend. Give each provider its own token cap, or add a
per-token price and cap dollars.
