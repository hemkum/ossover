# Contributing to ossover

ossover is a free, open-source alternative to CrossOver for Apple-silicon Macs: Wine engines,
DXMT/DXVK renderer packs, msync, bottles and CC0 recipes, driven by a Swift CLI
(`ossover`) and library (`OssoverKit`). It is pre-release and maintained by one person
(@hemkum), so the rules below exist to keep every contribution reviewable in one sitting.

Jump to: [Ground rules](#ground-rules) · [Ways to contribute](#ways-to-contribute) ·
[Development setup](#development-setup) · [Repository map](#repository-map) ·
[Code conventions](#code-conventions) · [Commits and pull requests](#commits-and-pull-requests) ·
[Evidence and the REA ledger](#evidence-and-the-rea-ledger) · [Benchmarks](#benchmarks)

## Ground rules

1. **Clean room.** CrossOver's Wine is LGPL and CodeWeavers publishes its sources: reading,
   building and patching that tree is fine and is exactly what `engine/` does. CrossOver's GUI,
   its `.pyc` tooling, `cxcompatdb.so`, CrossTies, `cxfixes.xml` and its compatibility database
   are proprietary and covered by CodeWeavers' EULA. Do not decompile them, do not copy them,
   and do not re-type their data as a recipe. Behaviour learned by observing the shipped bundle
   or the LGPL sources is cited to a row of `docs/rea/ledger.md` (`REA L-nn`) or an item of
   `docs/rea/decisions.md`; the code already does this, keep the chain intact.
2. **Never Apple's D3DMetal.** It is not downloaded, bundled, hashed into fixtures or linked
   from a manifest. Users import their own Game Porting Toolkit dmg with
   `ossover renderer import-gptk` and accept Apple's licence themselves.
3. **Licences.** Code is `GPL-3.0-or-later` (every Swift file starts with an SPDX header; new
   shell and Python scripts carry the same line);
   recipes under `recipes/` are `CC0-1.0`; code adapted from Whisky or Highball keeps its
   original copyright line and is listed in `NOTICE.md`. By opening a pull request you agree
   that your contribution is offered under the same terms (inbound = outbound). There is no CLA.
4. **Facts, not folklore.** Frame rates come from `ossover bench` with the results directory
   attached; compatibility verdicts come from the issue form, run on real hardware; every
   CrossOver-parity claim points at evidence. If something is unknown, say so (there is a
   file for it: `docs/rea/unknowns.md`).
5. **No credential handling.** ossover never reads a Steam password, token or Steam Guard code,
   and never will. `steamcmd` prompts in your own terminal.

## Ways to contribute

| What | How |
|---|---|
| **Compatibility report** | The *Compatibility report* issue form: game, store, engine id, renderer, sync, macOS, chip, measured fps, verdict, logs. Reports are folded into the recipe's `status` and `reports` fields. |
| **Recipe** (CC0) | Copy the closest `recipes/*.json`, follow `recipes/_schema.json`, keep `"license": "CC0-1.0"` and `"status": "untested"` until someone reports. Check the plan with `ossover recipe apply recipes/<file>.json --bottle <bottle> --dry-run`. One recipe per game + version + variant, id `<game>-<version>-<variant>` (`witcher3-4.04-dx11`). Put the why in `description`, `note` steps and `knownIssues`; cite ledger rows when a setting mirrors CrossOver. |
| **Bug report** | The *Bug report* form, with the full command output and `ossover doctor`. |
| **Code** | See [Development setup](#development-setup) and [Code conventions](#code-conventions). Open an issue first for anything bigger than a bug fix. |
| **Engine build** | `engine/README.md`. The build needs Rosetta 2, an x86_64 MacPorts tree and an expected 30–45 minutes (the plan's estimate; no cold build has been timed yet); CI never builds an engine. `engine/selftest.sh` exercises the packaging rules and gates in ~10 s without a build and runs in CI. |
| **Docs** | Typos and clarifications are welcome anywhere. `docs/rea/` is evidence: changing a ledger row means re-checking the cited evidence file, not rewording it. |
| **Store support** (GOG, Epic, …) | Open a feature request first. Depot fetching must keep the no-credentials rule (the tool prompts, ossover does not). |

## Development setup

- An Apple-silicon Mac on macOS 15 or newer.
- Xcode with Swift 6.1 or newer (`swift-tools-version: 6.1`; developed on Xcode 27 / Swift 6.4).
- Rosetta 2 only to run games and the `dlopen`/`wine_version` engine gates, not to build or
  test: `softwareupdate --install-rosetta --agree-to-license`.
- Optional, for the full pipeline: `brew install --cask steamcmd` (depot fetches),
  `brew install cabextract` (winetricks verbs such as `corefonts`), `brew install mingw-w64`
  (`scripts/probes/build.sh` and the engine build).

```sh
git clone https://github.com/hemkum/ossover.git
cd ossover
swift build
swift test
swift run ossover doctor
```

`.build-*/` directories are ignored by git so several `swift build --scratch-path .build-<name>`
trees can coexist. To try a change for real:

```sh
swift run ossover engine install x64-frankea-wine11.16-cx26.3-v4.6.4b1   # ~480 MB, SHA-256 verified
swift run ossover bottle create test --winver win10 --sync msync --renderer dxmt
swift run ossover run test 'C:\windows\system32\notepad.exe'
```

Everything ossover writes lives under `$OSSOVER_HOME` (default
`~/Library/Application Support/ossover`); point it at a scratch directory while developing.
Manifests and recipes are read from the checkout (`engines/`, `renderers/`, `recipes/`),
found from the working directory or `$OSSOVER_REPO`.

## Repository map

| Path | What lives there | Licence |
|---|---|---|
| `Sources/OssoverKit/` | The library: engines, renderer overlays, bottles, Wine environment, recipes, Steam depot fetch, bench harness | GPL-3.0-or-later |
| `Sources/ossover/` | The CLI (swift-argument-parser); thin wrappers over OssoverKit | GPL-3.0-or-later |
| `Tests/OssoverKitTests/`, `Tests/Fixtures/` | swift-testing suites and verbatim fixtures | GPL-3.0-or-later |
| `engines/*.json` | Engine manifests: pinned URL + SHA-256, paths, capabilities, bundled renderers | GPL-3.0-or-later |
| `renderers/*.json` | Renderer pack manifests (DXMT, DXVK) | GPL-3.0-or-later |
| `recipes/*.json`, `recipes/_schema.json` | Per-game recipes and their JSON Schema | **CC0-1.0** |
| `engine/` | Builds the ossover Wine engine from CodeWeavers' LGPL sources: `inputs.json` pins, `patches/`, `build.sh`, `package.sh`, `gates.sh`, `selftest.sh` | GPL-3.0-or-later (patches LGPL-2.1-or-later) |
| `docs/rea/` | The CrossOver 26.3.0 evidence pass: ledger, decisions, unknowns, raw evidence | GPL-3.0-or-later |
| `docs/benchmark-results/` | `ossover bench` result directories, once there are any | GPL-3.0-or-later |
| `scripts/vendor/` | Vendored `winetricks` (LGPL-2.1-or-later) with its pinned SHA-256 | upstream |
| `scripts/probes/` | Small Windows probes (D3D11) cross-compiled with mingw-w64 | GPL-3.0-or-later |

## Code conventions

- **Swift 6 language mode**, strict concurrency. Logic goes into `OssoverKit`; a CLI command
  parses arguments, calls the kit and prints. Anything decidable without I/O (environment
  tables, recipe plans, path mapping, manifest decoding) is a pure function with a test.
- **Tests** use swift-testing (`import Testing`, `#expect`). Fixtures under `Tests/Fixtures`
  are captured verbatim (some are CRLF, as the game or Wine wrote them), so `.gitattributes`
  marks the directory `-text`. Do not "fix" their line endings.
- **Headers.** `// SPDX-License-Identifier: GPL-3.0-or-later` on line 1; adapted code adds the
  origin and copyright on line 2 (see `Sources/OssoverKit/Paths.swift`).
- **Formatting** follows `.editorconfig`: 4 spaces for Swift, Python and C; 2 for JSON, YAML
  and `engine/*.sh`; LF everywhere.
- **Shell** is bash with `set -euo pipefail`, must pass `bash -n`, and names the ledger row next
  to each rule it implements (`# REA L-64`).
- **Python** is standard library only and is run with `python3 -I`.
- **Error messages** say what to do next (`source.sha256 is TBD; pin the hash before installing`).
- **Manifests and recipes** must pass the catalog check
  (`python3 -I .github/scripts/catalog_check.py .`, the same script CI runs), and new download
  sources are pinned: `"sha256": "TBD"` is refused at install time and only acceptable with a `TODO` note.

## Commits and pull requests

- Branch from `main`; one change per pull request.
- Subject line: `Area: what changed`, imperative, under ~72 characters. Examples from the log:
  `Engine: pinned inputs, build/package/gates scripts`,
  `witcher3 recipe: record DXMT 0.80 stream-output limitation observed at first launch`.
  The body says why, and cites ledger rows or decision numbers when the change mirrors
  CrossOver. No sign-off line is required.
- Fill in the pull request template; its checklist is the review checklist.
- CI (`.github/workflows/ci.yml`) must be green: `swift build`, `swift test`, `bash -n` on the
  shell scripts, the catalog check, the Swift decoders over `engines/`, `renderers/` and
  `recipes/`, and `engine/selftest.sh`. CI runs on a `macos-15` arm64 runner and never
  downloads an engine.
- Reviews come from @hemkum (`.github/CODEOWNERS`). Expect days, not hours.

## Evidence and the REA ledger

`docs/rea/ledger.md` has one row per question asked of CrossOver 26.3.0, each marked
`observed`, `inferred` or `unknown` with its authority (`shipped-artifact`,
`historical-reference` for the LGPL tarball, `analyst-inference`) and the evidence file or
`file:line`. `docs/rea/decisions.md` turns rows into code and engine decisions, numbered.
The scope of that pass was inventory plus the LGPL sources: nothing proprietary was decompiled
and nothing was copied, and contributions stay inside that scope.

When you change behaviour that mirrors CrossOver, point at the row. When no row covers it, add
the question to `docs/rea/unknowns.md` and make the ossover choice explicit in the code
comment ("ossover-specific, not CX parity") rather than guessing at parity.

## Benchmarks

`ossover bench run` launches the game, loads the benchmark save, measures the Metal HUD
per-frame log and writes `results/<timestamp>/` under the bottle with per-run average fps and
1 % low and the median over runs. A number in an issue, a recipe, the README or a commit
message must come from such a directory, with resolution, settings, scene and duration stated.
As of this writing no benchmark has been measured for the project; do not add one without the
results directory to back it.

## Security

Vulnerabilities go through GitHub's private vulnerability reporting, not the issue tracker:
see `SECURITY.md`, which also says what ossover does with downloaded binaries.

## Trademarks

CrossOver and CodeWeavers are trademarks of CodeWeavers, Inc.; Wine is a registered trademark of
the Software Freedom Conservancy; Apple, macOS, Metal, Game Porting Toolkit and D3DMetal are
trademarks of Apple Inc.; Steam is a trademark of Valve Corporation; The Witcher and CD PROJEKT
are trademarks of CD PROJEKT S.A.; Epic Games and the Epic Games Store are trademarks of Epic
Games, Inc.; GOG is a trademark of GOG sp. z o.o. ossover is an independent, open-source project
and is not affiliated with, sponsored by or endorsed by CodeWeavers, Apple, the Wine project,
Valve, CD PROJEKT S.A., Epic Games or GOG; these names are used only to describe compatibility.
