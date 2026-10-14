# AGENTS.md: guide for AI agents and contributors

ossover is a free, open-source CrossOver alternative for Apple Silicon Macs: a Swift 6 package (`OssoverKit` library +
`ossover` CLI), shell scripts that build a Wine engine from CodeWeavers' LGPL sources, CC0 JSON recipes, and an
evidence ledger from a reverse-engineering pass on CrossOver 26.3.0. Licence GPL-3.0-or-later; recipes CC0-1.0. The
product name is written **ossover**, lowercase, everywhere. Read this file first, then the directory you are about to
touch.

## 1. Orientation (5 minutes)

| Read | Why |
|---|---|
| [`README.md`](README.md) | What works, how the layers fit, the honest status |
| [`docs/rea/decisions.md`](docs/rea/decisions.md) | The 39 design decisions the evidence produced; each cites a ledger row. Code must agree with them or change them |
| [`docs/rea/ledger.md`](docs/rea/ledger.md) | 82 rows, one per question: observed / inferred / unknown, authority, evidence IDs. The source of truth for "why does ossover do X" |
| [`docs/rea/unknowns.md`](docs/rea/unknowns.md) | Open questions (`U-n`). Do not resolve one by guessing |
| [`docs/rea/README.md`](docs/rea/README.md) | Scope and labelling of the REA pass, tool versions, evidence files |
| [`engine/README.md`](engine/README.md) | Building, packaging and gating the own engine |
| [`recipes/_schema.json`](recipes/_schema.json) | The recipe format (`ossover.recipe/1`), mirrored by `Sources/OssoverKit/Model/Recipe.swift` |
| [`docs/benchmark.md`](docs/benchmark.md) | The benchmark definition and the harness method |
| [`docs/licensing.md`](docs/licensing.md) | Why GPL, what the LGPL asks of the engine, why D3DMetal is never shipped |
| [`ROADMAP.md`](ROADMAP.md) | v0.1 / v0.2 / v0.3 |
| The owner's plan file (local, not in the repo; ask for it) | The original plan the owner approved; its §4–§5 are the design the code follows and the ledger cites them by section |

## 2. Workspace map

```text
Package.swift                Swift tools 6.1, macOS 15+, swift-argument-parser; language mode 6
Sources/OssoverKit/          the library (no CLI, no UI)
  Paths.swift                $OSSOVER_HOME layout (default ~/Library/Application Support/ossover)
  Model/                     Engine, EngineManifest, RendererPack, Bottle, BottleSettings, Program, Recipe, Source, Version
  Store/                     Download (resumable, sha256), EngineStore, EngineProbe, EngineIntegrity, RendererStore, BottleStore, LicenceRecord
  Wine/                      WineEnvironment (pure, golden-tested), WineRunner, WineServer, Registry, WinVersion, Prefix, Winetricks
  Renderer/                  RendererSelection (resolver, strategies B/C), RendererMaterializer, PEBuiltinMark, CrossOverBottleConfig
  Recipe/                    RecipeEngine (plan → apply), IniFile
  Steam/                     SteamCMD, DepotDownloader, AppManifestACF, VDF, SteamFetchGuard
  Bench/                     MetalHUDLog, LogStream, Harness, InputInjector, WindowProbe, Screenshot, ProgramLauncher
  Util/                      Shell, Tar, SHA256, SysInfo, ProcessTable, WindowsPath
Sources/ossover/             the CLI: one file per command group (DoctorCommand, EngineCommands, BottleCommands, RunCommand, …)
Tests/OssoverKitTests/       Swift Testing; Tests/Fixtures/{manifests,bottles,recipes,hudlogs,acf}
engines/*.json               engine manifests (URL + sha256 + capabilities); x64-frankea-… is the bootstrap, x64-gcenx-… the control
renderers/*.json             renderer pack manifests (DXMT 0.80, DXVK-macOS 1.10.3)
recipes/*.json               CC0 recipes + _schema.json
engine/                      inputs.json (pins), patches/, build.sh, package.sh, manifest.py, gates.sh, selftest.sh
scripts/vendor/winetricks    pinned winetricks (LGPL-2.1+), sha256 beside it
scripts/probes/              tiny Windows probes (d3d11probe, d3d11present) built with mingw-w64
docs/rea/                    the REA evidence pass: reports, ledger, decisions, unknowns, evidence/ (172 files)
docs/benchmark-results/      committed result.json files (hud.ndjson is gitignored)
docs/images/                 README images
```

## 3. Build, test, run

```sh
swift build                                   # debug build of OssoverKit + ossover
swift build -c release
swift test                                    # ~200 Swift Testing tests; no Wine, no network, no Rosetta needed
swift test --filter WineEnvironmentTests      # one suite
swift run ossover --help                      # the CLI; `ossover help <group> <command>` for flags
./engine/selftest.sh                          # packaging policy + manifest shape on a synthetic Mach-O tree, ~10 s
./engine/build.sh --check                     # is the x86_64 toolchain (Rosetta, MacPorts, mingw-w64) in place?
```

Integration (needs Rosetta 2 and a 481 MB engine download; use a scratch home so your real bottles are untouched):

```sh
export OSSOVER_HOME=$(mktemp -d)/ossover
swift run ossover engine install engines/x64-frankea-wine11.16-cx26.3-v4.6.4b1.json
swift run ossover bottle create t --engine x64-frankea-wine11.16-cx26.3-v4.6.4b1
swift run ossover run t 'C:\windows\notepad.exe'
```

Several agents may build in the same checkout at once: use `--scratch-path .build-<yourname>` (`.build-*/` is
gitignored) so builds do not clobber each other. Do not run two `swift test` invocations against the same scratch
path.

## 4. Golden rules

### Never copy CrossOver's proprietary code (outranks everything)

CrossOver is CodeWeavers' product. Its Wine tree is LGPL and published; its GUI, Python tooling (`.pyc`),
`cxcompatdb.so`, CrossTies database and compatibility database are proprietary and its EULA forbids reverse
engineering them. ossover's rule set:

- **In scope** for evidence: the bundle inventory, `Info.plist`, code signatures and entitlements, dyld traces,
  Mach-O headers/exports/imports/strings, the plain-text Perl launcher and bottle templates, configs, `.inf`, `.tie`
  XML, and full analysis of the **LGPL** binaries (`ntdll.so`, `winemac.so`, `winevulkan.so`, …) and the LGPL source
  tarball.
- **Out of scope, always**: decompiling `Contents/MacOS/CrossOver`, anything under `lib/python/`, `cxcompatdb.so`
  (headers, exports and strings are fine; its logic is not), and Apple's `D3DMetal`/`libd3dshared.dylib` beyond
  signatures, headers and strings.
- **Nothing is copied.** Not a line of Perl, not a template, not a registry snippet, not a CrossTie. Facts are
  recorded as `file:line` citations and re-implemented. The Wine patches ossover carries modify only the LGPL tree
  and come from highball-engine (LGPL-2.1-or-later), attributed in their headers.
- **No runtime capture of the trial** unless the owner has installed it and accepted the EULA; such evidence is
  labelled `controlled-replay` and kept separate from shipped-artifact rows.
- If you are unsure whether something is in scope, it is out of scope until a human says otherwise.

### Evidence first

- Every behaviour copied from CrossOver cites a ledger row (`REA L-nn`) or a plain-shell/source observation
  (`SH-TT-nn`, `src:file:line`). "Whisky does it" or "a forum says so" is a hypothesis, not evidence; label it.
- An ossover choice that is **not** CrossOver parity (e.g. `LC_ALL=en_US.UTF-8`, `CEF_DISABLE_SANDBOX=1`,
  msync-by-default) is labelled "ossover-specific" in the code comment and in the golden test.
- Changing a decision means editing `docs/rea/decisions.md` in the same change, with the new evidence. Adding an
  unknown means a `U-n` row in `unknowns.md`. The ledger is append-and-correct, never silently rewritten: a
  verification pass records what it changed and why.
- **Never invent numbers.** No fps, no build times, no sizes that were not measured. "Pending" is a valid value.
  Benchmark results enter the repo only as `result.json` files produced by `ossover bench`.
- `TODO(REA)` marks a claim awaiting evidence. Resolve it with a citation or leave it; do not delete it to make the
  code look finished.

### Safety and licences

- **No passwords, ever.** steamcmd and DepotDownloader prompt in the user's terminal. The CLI has no `--password`
  flag and never will.
- **No D3DMetal download.** `renderer import-gptk` reads a dmg the user obtained from Apple; files are copied
  verbatim, verified against Apple's signature, never re-signed, stripped or rewritten. `renderer accept` records
  the licence acceptance.
- **Every download is pinned** by URL + SHA-256 in a manifest; `EngineStore`/`RendererStore` refuse `"sha256": "TBD"`.
  Pin on first download, record the `tar tf` layout in the manifest `notes`.
- **Licence headers.** Every Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`. Code adapted
  from Whisky or highball keeps the `Adapted from … Copyright …` lines. New third-party components get a row in
  `ATTRIBUTION.md` and `NOTICE.md` in the same change. Recipes carry `"license": "CC0-1.0"`.
- **No `DYLD_*` variables** in any environment handed to Wine (the evidence: CrossOver never sets them and a hardened
  runtime ignores them). No `cs.allow-dyld-environment-variables` or `cs.allow-jit` entitlement.

### Engineering

- Swift language mode 6, strict concurrency; `OssoverKit` types are `Sendable`. No UI framework in `OssoverKit`.
- `WineEnvironment.make` is pure and golden-tested: a new environment row needs a golden-table update and a ledger
  citation or an "ossover-specific" label.
- One `WINEMSYNC` value per prefix lifetime: a sync change must stop the wineserver first.
- The engine packager's rules are gates, not comments: a new packaging rule goes into `package.sh` **and**
  `gates.sh` **and** `selftest.sh`.
- Recipes are data. If a game needs logic a step type cannot express, add a step type to the schema **and** the
  Swift model **and** a test, then write the recipe.
- Keep the `README.md` "What works today" table truthful after every change that affects it.

## 5. Ownership

Several agents work in this repository at once. Edit only what you were assigned; if you must touch another area,
say so in your final message and keep the edit minimal.

| Directory | Owner / rule |
|---|---|
| `Sources/`, `Tests/` | Swift implementers. Each command group and each `OssoverKit` subdirectory is one unit of ownership |
| `engine/*.sh`, `engine/inputs.json`, `engine/patches/` | Engine build agent. `inputs.json` hashes change only with a real download |
| `recipes/` | Recipe agent. CC0. `status` is `untested` until someone ran it; `reports` are dated |
| `engines/`, `renderers/` | Store agent. Manifests mirror what `tar tf` and `strings`/`nm` say, in `notes` |
| `docs/rea/` | Evidence agents and the verifier only. Nobody else edits ledger rows |
| `README.md`, `ROADMAP.md`, `AGENTS.md`, `ATTRIBUTION.md`, `docs/*.md`, `docs/images/` | Documentation agent |
| `LICENSE`, `LICENSES/`, `NOTICE.md`, `Package.swift` | The owner (Hemant); propose, do not change |

Never `git commit` unless asked; the owner commits. Never rebuild a `.build-*` directory that another agent's
instructions say is in use. Downloaded archives go to your scratch directory, never into the repo.

## 6. Recurring tasks

**Add a recipe.** Copy the closest `recipes/*.json`, keep `"schema": "ossover.recipe/1"`, give it an id
`<game>-<version>-<variant>`, fill `requires`, `gameDir`, steps, `knownIssues`, `status: "untested"`. Validate with
`ossover recipe apply <file> --bottle <b> --dry-run`. Add a `RecipePlanTests` case if a new step type or `when`
predicate is involved.

**Add an engine manifest.** `engines/<id>.json` in the `EngineManifest.swift` shape; pin `sha256` and `size` from the
real download; record the `tar tf` layout, the `strings ntdll.so` probe results (`WINEMSYNC`, `WINEESYNC`,
`WINEDLLPATH_PREPEND`, `CX_APPLEGPTK_LIBD3DSHARED_PATH`), `nm -gU winemac.so | grep macdrv_functions`, and the
`LC_BUILD_VERSION` minos in `notes`. `ossover engine validate-manifest <file> --layout` decodes it.

**Change the engine packaging.** Edit `package.sh`, add the gate to `gates.sh`, add the positive and negative case to
`selftest.sh`, run `./engine/selftest.sh`, regenerate `Tests/Fixtures/manifests/package-sh-engine.json` with
`selftest.sh --write-fixture`.

**Record a benchmark.** `ossover bench run … --json`, copy `results/<ts>/result.json` to
`docs/benchmark-results/<date>-<engine>-<renderer>-<sync>/result.json`, add the row to `docs/benchmark.md`. Never
edit a number by hand.

**Verify a claim against CrossOver.** Find the ledger row. If none, it is an open question: add it to `unknowns.md`
with what would resolve it and which authority (`shipped-artifact`, `historical-reference`, `runtime`,
`out-of-scope`) that needs. Do not open the trial bundle's proprietary files to find out.

## 7. Final messages

When a task is done, say what you changed (absolute paths), what you verified and how (`swift test` output, a dry-run
plan, a gate run), and what remains unknown. If a result was not measured, say "pending". If you touched a file
outside your ownership, name it.
