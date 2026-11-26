# dltidy

A macOS background agent for `~/Downloads`. For each new file:

- **Generic name** (`IMG_1234`, UUID, timestamp, `ChatGPT Image …`, `Screenshot …`): renamed from its
  content by Claude Haiku. `IMG_9999.HEIC` → `hardware-store-receipt-itemized-purchases.heic`.
- **Image**: `.png` and `.jpg` copies (whichever it isn't). Metadata kept.
- **Video** (incl. animated GIF/WebP): `.mp4` copy, plus `.gif` if ≤ 10 s. HDR → SDR. Live Photo `.MOV`s
  get no copies.

Originals are never deleted. Files present at install are ignored.

## Install

Needs macOS 15+, Swift 6, `brew install imagemagick ffmpeg`, and an Anthropic API key (use a dedicated
Console workspace with a spend limit).

```sh
make install                            # build, sign, load the LaunchAgent
pbpaste | ~/.local/bin/dltidy set-key   # with the key on the clipboard
```

Allow Downloads access if prompted. Signing uses a dedicated keychain; `make install` asks for its password
and locks it after signing, so no other process can sign as dltidy.
`make uninstall [PURGE=1]` removes it (`PURGE=1` also removes state, logs and key).

## Commands

| `dltidy …` | |
|---|---|
| `status` | Health, API usage, pending items |
| `log [-n N]` | Recent actions |
| `doctor` | Health checks |
| `pause` / `resume` | Stop / restart processing |
| `undo [--last \| <name>]` | Restore a file's old name |
| `set-key` | Store the API key |

Log: `~/Library/Logs/dltidy/`. State: `~/Library/Application Support/dltidy/`.

## How it works

**Event model.** FSEvents only triggers a scan; a SQLite ledger decides. A file is processed once it is
a non-empty top-level file, not a partial download, unchanged across 3 scans (≥ 5 s), at least 20 s old,
and decodes.

**No reprocessing, no regeneration.** Files are identified by inode, hash, and an xattr on every output.
Outputs are built in staging and moved in atomically. Deleted files are never recreated; duplicates are
skipped by hash. Ambiguity resolves to "do nothing".

**Spend controls.** All API calls pass through `Budget.reserve()`, which records each call before sending it.

| Control | Default |
|---|---|
| Requests per file | 3 max |
| Calls per day / month | 300 / 3,000 |
| Input tokens per month | 6M |
| Retries | one, after 5 min |
| Circuit breaker | 3 failures → 15 min, doubling to 6 h |
| Crash loop | 5 starts in 10 min → safe mode |

Cost is about $0.0001 per image; the worst case under the caps is about $1/month. If naming is
unavailable, files are converted now and renamed if the API returns within 24 h.

**Failures** produce one notification per incident. The daemon never exits on errors, so launchd cannot
restart-loop it.

## What leaves your machine

Only naming requests to the Anthropic API. Files with meaningful names send nothing.

- **Unclear name**: the filename stem, in a classification call.
- **Generic name**: the original filename plus a 768 px JPEG thumbnail (image, video mid-frame, PDF page
  without text) or up to 2 KB of extracted text (PDF, docx/rtf/odt, xlsx/pptx strings, csv, txt).
  Generic PDF names from bank or payroll portals, such as `document (1).pdf` or `download.pdf`, qualify.

No EXIF or GPS data is sent; the thumbnail is re-encoded from pixels.

## Development

```
Sources/DLTidyKit/     interfaces, tool runner, Keychain
Sources/DLTidyMedia/   conversion (ImageMagick, ffmpeg, AVFoundation)
Sources/DLTidyNaming/  name rules, content extraction, Anthropic client
Sources/DLTidyCore/    ledger, scanner, pipeline, budget, health
Sources/dltidy/        daemon and CLI
Support/magick/        ImageMagick policy, copied into the app bundle before signing
```

`swift test` runs against fakes; live API calls need `DLTIDY_LIVE=1`.

### Other model providers

The core talks to the model only through `NamingService` (`Sources/DLTidyKit/Interfaces.swift`), so caps
and retries apply to any provider. To add Gemini or OpenAI:

1. Implement `NamingService` in `Sources/DLTidyNaming/`, modeled on `AnthropicNamingClient.swift`:
   one request per call, JSON-schema output, mapped to `APIResult`.
2. Select it in `Sources/dltidy/Daemon.swift` and store its key under its own Keychain account
   (`Keychain.swift`).
3. Copy `Tests/DLTidyNamingTests/ClientTests.swift`.

Caps count tokens, not dollars; set a lower token cap for pricier models.

## License

GPL-3.0
