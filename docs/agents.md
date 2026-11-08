# tmsm for agents

`tmsm` is built to be called from scripts and agents. This page is the contract. The reference at the end quotes `tmsm --help`, and `scripts/check.sh` fails when that quote and the binary differ.

## The rules

- **A run never asks.** `tmsm <file>` with missing flags uses defaults: speakers `auto` (at most 4), language `auto`, output to the Desktop, and the configured preset.
- **stdout holds only the result**: the path of the written file, or one JSON object with `--json`. Everything else goes to stderr.
- **Progress goes to stderr.** In a terminal it is one redrawn line. Without one, it is a plain line per stage (`tmsm: Transcribing`). `--quiet` turns it off.
- **Errors**: one line, `tmsm: <message>`, on stderr. The exit code is non-zero.
- **Exit codes**: `0` success, `1` failure, `64` bad usage (an unknown flag or value).
- **Nothing is overwritten.** If `memo.md` exists, the run writes `memo 2.md`, `memo 3.md`, …

## Transcribe

```sh
tmsm recording.m4a --json --quiet
tmsm recording.m4a --speakers 2 --language de --output ~/Notes/ --preset fast
```

`--json` prints:

```json
{
  "durationSeconds" : 504.2,
  "input" : "/path/recording.m4a",
  "language" : "auto",
  "output" : "/Users/me/Desktop/recording.md",
  "preset" : "default",
  "speakerModel" : "nemotron3-offline",
  "speakers" : 2,
  "transcriptionModel" : "parakeet-ultra",
  "words" : 1234
}
```

`speakerModel` is absent when `--speakers 1` skips speaker labelling. The Markdown file has a `# <file name>` heading, then one `Speaker N: …` paragraph per turn, without timestamps.

`tmsm <file>` is short for `tmsm transcribe <file>`. A file named like a subcommand (`setup`) needs `tmsm transcribe setup` or a path such as `./setup`.

## First launch and setup

- If no preset has been chosen yet, the first run in a terminal asks for one and downloads it. Without a terminal, or with `--preset`, `--json` or `--quiet`, nothing is asked: the run uses the `default` preset, downloads its models as needed, and saves no choice.
- `tmsm setup` without options asks in a terminal. With options it never asks, which is how an agent sets up:

```sh
tmsm setup --preset default --keep-unused                    # downloads, saves, prints the config path
tmsm setup --transcription parakeet-v3 --speakers nemotron3-offline --delete-unused
tmsm setup --list                                            # presets and models (quoted below)
```

- Without `--delete-unused` or `--keep-unused`, setup keeps models it no longer needs whenever it can't ask.
- A gated model needs a Hugging Face token. Pass it as `HF_TOKEN`. Agents never get the hidden prompt. A person running `tmsm setup` types it once, and it is kept in the Keychain under service `tmsm`. `HF_TOKEN` wins over the Keychain.

## Install, update, uninstall

- `tmsm install`, run from an unpacked release, copies the program to `~/.tmsm` and adds one `PATH` line, marked `# tmsm`, to the login profile. It prints the installed executable's path. `--no-setup` skips the preset question.
- `tmsm update` downloads the latest release, checks it against `SHA256SUMS`, and installs it. `tmsm update --check` prints the latest version and exits `0` only if it is newer. `--to <version>` installs a given version.
- `tmsm uninstall --yes` removes the following, without asking: the tmsm home, the program, the `PATH` line, the Keychain item, and `~/Library/Caches/tmsm` and `~/Library/HTTPStorages/tmsm`. Without a terminal, `--yes` is required. If the tmsm home holds files tmsm did not create, it is left alone, the rest is removed, and the exit code is `1`.

## Environment

| Variable | Effect |
|---|---|
| `TMSM_HOME` | Where models, config and caches live. Default: `~/Library/Application Support/tmsm`. |
| `HF_TOKEN` | Hugging Face token for gated models. It wins over the Keychain. |
| `TMSM_DEBUG=1` | Also writes the raw words and speaker segments to `TMSM_HOME/cache/debug/`. |
| `HOME` | The Desktop, `~/.tmsm` and the login profile are resolved against `$HOME`. |

Everything tmsm writes, apart from your transcripts, is under `TMSM_HOME`, `~/.tmsm` and the one `PATH` line. The exceptions are two folders that macOS itself creates for the `tmsm` process, `~/Library/Caches/tmsm` (the Core ML compile cache) and `~/Library/HTTPStorages/tmsm`. Both sit in the account's home even when `$HOME` points elsewhere. `tmsm uninstall` removes them.

## Reference

These blocks are the exact output of the command above each one, run with an empty `TMSM_HOME`.

### `tmsm --help`

<!-- tmsm --help -->
```text
OVERVIEW: Turn an audio file into a Speaker 1–4 Markdown transcript, locally.

stdout gets the path of the written file (or JSON with --json); progress goes
to stderr.
Models, config and caches live in TMSM_HOME (default: ~/Library/Application
Support/tmsm).

USAGE: tmsm <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  transcribe (default)    Transcribe a file (the default command: `tmsm
                          <file>`).
  setup                   Choose the preset or individual models, download
                          them, delete unused ones.
  install                 Put tmsm in ~/.tmsm and add it to PATH in your login
                          profile.
  update                  Install the latest release (checked against
                          SHA256SUMS). Models stay.
  uninstall               Remove tmsm, its models, config, caches, Keychain
                          token and PATH line.

  See 'tmsm help <subcommand>' for detailed help.
```

### `tmsm transcribe --help`

<!-- tmsm transcribe --help -->
```text
OVERVIEW: Transcribe a file (the default command: `tmsm <file>`).

USAGE: tmsm transcribe <file> [--speakers <speakers>] [--language <language>] [--output <output>] [--preset <preset>] [--json] [--quiet]

ARGUMENTS:
  <file>                  Audio or video file: m4a, mp3, ogg/opus, wav, flac,
                          mp4, mov, …

OPTIONS:
  --speakers <speakers>   Number of speakers: 1-4 or auto (at most 4). (values:
                          auto, 1, 2, 3, 4; default: auto)
  --language <language>   Spoken language as an ISO 639-1 code (de, en, …) or
                          auto. (default: auto)
  -o, --output <output>   Output file or folder (default: the Desktop).
                          Existing files are never overwritten.
  --preset <preset>       Preset for this run: fast, default, individual
                          (default: the configured preset).
  --json                  Print the result as JSON on stdout instead of the
                          output path.
  -q, --quiet             No progress on stderr.
  --version               Show the version.
  -h, --help              Show help information.

```

### `tmsm setup --help`

<!-- tmsm setup --help -->
```text
OVERVIEW: Choose the preset or individual models, download them, delete unused
ones.

Without options it asks in the terminal; with options it asks nothing (for
agents). A gated model needs a Hugging Face token: typed in hidden and kept in
the Keychain, or passed as HF_TOKEN.

USAGE: tmsm setup [--preset <name>] [--transcription <id>] [--speakers <id>] [--delete-unused] [--keep-unused] [--list]

OPTIONS:
  --preset <name>         Preset to use from now on (see --list).
  --transcription <id>    Speech-to-text model id; implies --preset individual.
  --speakers <id>         Speaker model id; implies --preset individual.
  --delete-unused         Delete downloaded models the new setting no longer
                          uses, without asking.
  --keep-unused           Keep downloaded models the new setting no longer
                          uses, without asking.
  --list                  List presets and models, mark the configured one, and
                          exit.
  --version               Show the version.
  -h, --help              Show help information.

```

### `tmsm setup --list`

<!-- tmsm setup --list -->
```text
Presets (tmsm setup --preset <name>):
  fast        parakeet-v3 + nemotron3-c128-split-w8a8, 575 MB download
              Parakeet v3 + Nemotron-3 c128-split-w8a8, ~1 GB RAM, 25 languages
* default     parakeet-ultra + nemotron3-offline, 820 MB download
              Parakeet Ultra + Nemotron-3 offline, ~1.5 GB RAM, 25 languages
  individual  any two models below (tmsm setup --transcription <id> --speakers <id>)

Speech-to-text models:
  parakeet-v3     Parakeet TDT 0.6B v3, 480 MB, 25 languages, CC-BY-4.0
  parakeet-ultra  Parakeet Ultra, 630 MB, 25 languages, CC-BY-4.0

Speaker models:
  nemotron3-c128-split-w8a8  Nemotron-3 Diarization (c128-split-w8a8), 95 MB, OpenMDW-1.1
  nemotron3-offline          Nemotron-3 Diarization (offline), 190 MB, OpenMDW-1.1

* = in use
```

### `tmsm install --help`

<!-- tmsm install --help -->
```text
OVERVIEW: Put tmsm in ~/.tmsm and add it to PATH in your login profile.

Run from the unpacked release folder; the install line does this for you.

USAGE: tmsm install [--no-setup]

OPTIONS:
  --no-setup              Don't ask for a preset afterwards (the first
                          transcription uses the default).
  --version               Show the version.
  -h, --help              Show help information.

```

### `tmsm update --help`

<!-- tmsm update --help -->
```text
OVERVIEW: Install the latest release (checked against SHA256SUMS). Models stay.

USAGE: tmsm update [--check] [--to <version>]

OPTIONS:
  --check                 Only print the latest version; exit 0 if it is newer
                          than this one, else 1.
  --to <version>          Install this version instead of the latest, e.g.
                          0.1.0.
  --version               Show the version.
  -h, --help              Show help information.

```

### `tmsm uninstall --help`

<!-- tmsm uninstall --help -->
```text
OVERVIEW: Remove tmsm, its models, config, caches, Keychain token and PATH
line.

Transcripts you wrote stay where they are.

USAGE: tmsm uninstall [--yes]

OPTIONS:
  -y, --yes               Don't ask for confirmation (needed without a
                          terminal).
  --version               Show the version.
  -h, --help              Show help information.

```
