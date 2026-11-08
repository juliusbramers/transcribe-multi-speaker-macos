# tmsm

`tmsm` turns any audio file into a Markdown transcript with speaker labels (Speaker 1–4). It runs locally on Apple silicon. After a one-time model download, nothing leaves your Mac. Scripts and agents can call it as easily as people can.

## Install

Paste this line into Terminal. It works from zsh, bash and fish.

```sh
/bin/sh -c 'd="$(mktemp -d)" || exit 1; trap "rm -rf \"$d\"" EXIT; trap "exit 130" HUP INT TERM; cd "$d" && r=https://github.com/juliusbramers/transcribe-multi-speaker-macos/releases && v="$(curl -fsSLI --connect-timeout 20 -o /dev/null -w "%{url_effective}" "$r/latest")" && v="${v##*/v}" && f="tmsm-$v-macos-arm64.tar.gz" && curl -fsSLO --connect-timeout 20 "$r/download/v$v/$f" && curl -fsSL --connect-timeout 20 "$r/download/v$v/SHA256SUMS" | grep " $f\$" | shasum -a 256 -c - && tar -xzf "$f" && "./tmsm-$v-macos-arm64/tmsm" install'
```

Built for macOS 15 or later on Apple silicon. Tested on macOS 27.

### For agents and scripts

The same steps, then straight to Markdown on stdout: no file, no questions, and missing models downloaded on the way. Everything else, including the checksum line, goes to stderr. The transcription runs only if the install succeeded:

```sh
/bin/sh -c 'exec >&2; d="$(mktemp -d)" || exit 1; trap "rm -rf \"$d\"" EXIT; trap "exit 130" HUP INT TERM; cd "$d" && r=https://github.com/juliusbramers/transcribe-multi-speaker-macos/releases && v="$(curl -fsSLI --connect-timeout 20 -o /dev/null -w "%{url_effective}" "$r/latest")" && v="${v##*/v}" && f="tmsm-$v-macos-arm64.tar.gz" && curl -fsSLO --connect-timeout 20 "$r/download/v$v/$f" && curl -fsSL --connect-timeout 20 "$r/download/v$v/SHA256SUMS" | grep " $f\$" | shasum -a 256 -c - && tar -xzf "$f" && "./tmsm-$v-macos-arm64/tmsm" install --no-setup' && ~/.tmsm/tmsm ~/memo.m4a --output - --quiet
```

Add `> memo.md` to keep the transcript. After that, `cat memo.m4a | tmsm - --output - --quiet` works too. [docs/cli.md](docs/cli.md) has the pipes, exit codes and the determinism guarantee.

### What the install line does

- It runs in its own `/bin/sh`, whatever your shell is, and works in a temporary folder that is removed at the end, even after an error or Ctrl-C. Its exit status is the install's.
- It finds the latest release on this repository's Releases page and downloads its tarball.
- It checks the tarball against `SHA256SUMS` with `shasum -c` before anything is unpacked or run.
- It runs `tmsm install`. This puts the program in `~/.tmsm`, with a manifest of its files, and adds `~/.tmsm` to your `PATH`:
  - zsh: one line, marked `# tmsm`, in `~/.zprofile`;
  - bash: the same line in the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` that exists;
  - fish: the snippet `~/.config/fish/conf.d/tmsm.fish`.
- It then asks for a quality preset and downloads its models from Hugging Face. Nothing else is downloaded until you choose.

The builds are not signed. A copy fetched with `curl` carries no quarantine mark, so macOS starts it without a dialog. A copy downloaded in a browser is blocked until you clear the mark once: `xattr -dr com.apple.quarantine <folder>`.

### Update

```sh
tmsm update
```

This runs the same steps: download, `SHA256SUMS` check, install. Your models and settings stay.

### Uninstall

```sh
tmsm uninstall
```

This removes the following:

- the program (`~/.tmsm`);
- every model, the config and the caches (`~/Library/Application Support/tmsm`, or `TMSM_HOME` if you set one);
- the Keychain item `tmsm`;
- the `PATH` line or fish snippet;
- the two folders macOS creates for the `tmsm` process (`~/Library/Caches/tmsm`, `~/Library/HTTPStorages/tmsm`).

Your transcripts stay. tmsm removes only what it can prove is its own: a home it created (marked `.tmsm-home`), a program folder with its manifest, lines marked `# tmsm`. It leaves anything uncertain alone, says so, and exits with `1`.

If `tmsm` no longer starts, the recovery script installed beside it does the same, with the same checks:

```sh
/bin/sh ~/.tmsm/uninstall.sh
```

If `~/.tmsm` itself is gone, the same script is in every release tarball and at `scripts/uninstall.sh` in this repository.

## Quick start

```sh
tmsm memo.opus                      # writes ~/Desktop/memo.md, prints its path
tmsm interview.m4a --speakers 2 --language de
tmsm meeting.mp4 --output ~/Notes/ --preset fast
tmsm memo.opus --json               # result as JSON, for scripts and agents
cat memo.m4a | tmsm - --output - --quiet > memo.md   # stdin to stdout, no file
tmsm setup                          # change the preset, or pick models one by one
tmsm setup --list                   # presets and models, with download sizes
```

The transcript starts with the file name as a heading, followed by one paragraph per turn (`Speaker 1: …`). Existing files are never overwritten: a second run writes `memo 2.md`.

tmsm reads m4a, mp3, WhatsApp ogg/opus, wav, flac, and the audio in mp4/mov. Opus decoding uses `ffmpeg` when it is installed.

### Presets

`tmsm setup` asks once for the quality you want. `--preset` overrides that choice for one run. `tmsm setup --list` shows each preset's models, RAM and download size, read from the program itself. `individual` lets you pick any speech-to-text model and any speaker model from the catalogue. A gated model asks once for a Hugging Face token, which is typed in hidden and kept in your Keychain.

## Command-line reference and scripting

[docs/cli.md](docs/cli.md) covers stdout and stderr, exit codes, the `--json` result, environment variables such as `HF_TOKEN`, setup without questions, and the full `--help` of every command.

## Development

```bash
scripts/setup.sh     # once after cloning: enables the git hooks
scripts/check.sh     # secrets, swift format, build, tests (also runs on git push)
scripts/release.sh   # release build, tarball and SHA256SUMS in dist/ (dry run; --publish uploads)
```

There is no hosted CI. The checks run locally:

| When | What |
|---|---|
| `git commit` | betterleaks on staged changes, `swift format lint` on staged Swift files |
| `git push` | `scripts/check.sh`: full-history secrets scan, format lint, `swift build`, tests |

Requires macOS on Apple silicon, the Xcode Command Line Tools (`xcode-select --install`) and `brew install betterleaks`.

During development, set `TMSM_HOME` to a scratch folder so models and caches stay out of your real home.

### Tests without Xcode

`swift test` needs full Xcode (XCTest and Swift Testing are not usable with the Command Line Tools alone), so tests live in an executable target instead:

- `Sources/selftest/` depends on the library target and runs every test case (`CoreCases`, `SetupCases`, …).
- A failing case prints its name and the mismatch; any failure exits non-zero.
- Run it with `swift run selftest`; `scripts/check.sh` runs it after `swift build`.
- `SetupCases` also checks that the `tmsm` output quoted in `docs/cli.md` matches the binary (`scripts/docs-reference.sh` regenerates it), and that the README and docs name no flag the program lacks.

## Credits

Models and libraries are credited in [NOTICE](NOTICE).
