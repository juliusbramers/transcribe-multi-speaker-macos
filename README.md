# transcribe-multi-speaker-macos

Mac-only command-line tool for local transcription with speaker diarization, built to be called by agents.
Runs on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio). No UI, no network after the one-time model download.

Status: setup only, no code yet.

## Development

```bash
scripts/setup.sh   # once after cloning: enables the git hooks
scripts/check.sh   # secrets, swift format, build, tests (also runs on git push)
```

There is no hosted CI. The checks run locally:

| When | What |
|---|---|
| `git commit` | betterleaks on staged changes, `swift format lint` on staged Swift files |
| `git push` | `scripts/check.sh`: full-history secrets scan, format lint, `swift build`, tests |

Requires macOS on Apple Silicon, the Xcode Command Line Tools (`xcode-select --install`) and `brew install betterleaks`. Full Xcode is not needed.

### Tests without Xcode

`swift test` needs full Xcode (XCTest and Swift Testing are not usable with the Command Line Tools alone), so tests live in an executable target instead:

- `Sources/selftest/` is an executable target that depends on the library target and runs every test case.
- A failing case prints its name and the mismatch; any failure exits non-zero.
- Run it with `swift run selftest`; `scripts/check.sh` runs it automatically when the folder exists.
