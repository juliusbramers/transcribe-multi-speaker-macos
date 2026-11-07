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
| `git push` | `scripts/check.sh`: full-history secrets scan, format lint, `swift build`, `swift test` |

Requires macOS on Apple Silicon, full Xcode (Command Line Tools alone cannot run `swift test`) and `brew install betterleaks`.
