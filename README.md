# tmsm

`tmsm` turns an audio or video file into a Markdown transcript, with speaker labels (Speaker 1–4) or as plain paragraphs. It runs locally on Apple silicon; after the model download nothing leaves your Mac. People and agents call it the same way.

## Install

Paste this line into Terminal (zsh, bash or fish). macOS 15 or later, Apple silicon.

```sh
/bin/sh -c 'd="$(mktemp -d)" || exit 1; trap "rm -rf \"$d\"" EXIT; trap "exit 130" HUP INT TERM; cd "$d" && r=https://github.com/juliusbramers/transcribe-multi-speaker-macos/releases && v="$(curl -fsSLI --connect-timeout 20 -o /dev/null -w "%{url_effective}" "$r/latest")" && v="${v##*/v}" && f="tmsm-$v-macos-arm64.tar.gz" && curl -fsSLO --connect-timeout 20 "$r/download/v$v/$f" && curl -fsSL --connect-timeout 20 "$r/download/v$v/SHA256SUMS" | grep " $f\$" | shasum -a 256 -c - && tar -xzf "$f" && "./tmsm-$v-macos-arm64/tmsm" install'
```

It downloads the latest release, checks it against `SHA256SUMS`, puts `tmsm` in `~/.tmsm`, adds that to your `PATH`, and asks once which preset you want (models come from Hugging Face). Open a new terminal window afterwards.

- `tmsm update` installs the latest release the same way; models and settings stay.
- `tmsm uninstall` removes the program, every model, the config and caches, the `PATH` line and the Keychain item. Transcripts stay.
- The builds are not signed. A copy downloaded in a browser needs `xattr -dr com.apple.quarantine <folder>` once; the install line needs nothing.

### For agents

The same install without questions, then the transcript on stdout. Progress and the checksum line go to stderr; nothing is asked, and missing models are downloaded on the way:

```sh
/bin/sh -c 'exec >&2; d="$(mktemp -d)" || exit 1; trap "rm -rf \"$d\"" EXIT; trap "exit 130" HUP INT TERM; cd "$d" && r=https://github.com/juliusbramers/transcribe-multi-speaker-macos/releases && v="$(curl -fsSLI --connect-timeout 20 -o /dev/null -w "%{url_effective}" "$r/latest")" && v="${v##*/v}" && f="tmsm-$v-macos-arm64.tar.gz" && curl -fsSLO --connect-timeout 20 "$r/download/v$v/$f" && curl -fsSL --connect-timeout 20 "$r/download/v$v/SHA256SUMS" | grep " $f\$" | shasum -a 256 -c - && tar -xzf "$f" && "./tmsm-$v-macos-arm64/tmsm" install --no-setup' && ~/.tmsm/tmsm ~/memo.m4a --output - --quiet
```

`--json` prints the result as JSON instead of the path. Exit codes, stdin/stdout, environment variables and every `--help` are in [docs/cli.md](docs/cli.md).

## Use

```sh
tmsm memo.opus                               # ~/Desktop/memo.md, prints its path
tmsm interview.m4a --speakers 2 --language de
tmsm lecture.mp4 --speakers none --preset fast   # plain paragraphs, no speaker model
tmsm meeting.m4a --preset extreme --output ~/Notes/
tmsm memo.opus --json
cat memo.m4a | tmsm - --output - --quiet > memo.md
tmsm setup                                   # change the preset
tmsm setup --list                            # presets and models, with sizes
```

Input: m4a, mp3, ogg/opus, wav, flac, and the audio of mp4/mov (opus needs `ffmpeg` on the PATH). Output: `# <file name>`, then one paragraph per speaker turn (`Speaker 1: …`), or plain paragraphs with `--speakers none`. Existing files are never overwritten. Without `--language` the language is detected; with the same input, preset and options the output is byte-identical.

### Presets

| Preset | What runs | Peak RAM | Setup download |
|---|---|---:|---:|
| `fast` | Parakeet Ultra alone, plain paragraphs (`--speakers auto` adds Nemotron-3) | 0.4 GB | 0.8 GB |
| `default` | Parakeet Ultra, Nemotron-3 speaker segments, words assigned by overlap | 0.4 GB | 0.8 GB |
| `accurate` | Nemotron-3 first, then every speaker turn decoded on its own by Parakeet Ultra | 0.4 GB | 0.8 GB |
| `extreme` | MOSS-Transcribe-Diarize hears the whole file and cuts the speaker turns, Parakeet Ultra decodes them | up to 12 GB | 2.1 GB |

English and German are what the presets are tuned on. Parakeet Ultra covers 25 European languages; other languages go to Qwen3-ASR 1.7B (3.7 GB, fetched on first use, about 6 GB of RAM). `extreme` needs a recording of at most 90 minutes for MOSS; longer ones, and files MOSS does not finish, fall back to `accurate`'s pipeline with a note on stderr. [docs/models.md](docs/models.md) has every model, the measurements behind the presets, languages, licences and the pinned Hugging Face commits.

## Development

```sh
scripts/setup.sh     # once: enables the git hooks
scripts/check.sh     # secrets, swift format, build, tests (also runs on git push)
scripts/release.sh   # release build, tarball and SHA256SUMS in dist/ (--publish uploads)
```

Needs the Xcode Command Line Tools and `brew install betterleaks`. Set `TMSM_HOME` to a scratch folder so models stay out of your real home. Tests are the `selftest` executable (`swift run selftest`); `scripts/docs-reference.sh` regenerates the `--help` blocks in `docs/cli.md`.

## Licence

tmsm is released under the [Apache License 2.0](LICENSE). Models are downloaded by the user from Hugging Face under their own licences; they and the libraries are credited in [NOTICE](NOTICE).
