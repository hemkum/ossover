# How ossover was built

A free CrossOver alternative is not a new idea; Whisky, highball and a dozen scripts already wrap Wine on macOS.
What ossover tried to do differently was to start from evidence of how the real product works rather than from
folklore, to stay inside the licence while doing so, and to say plainly what is measured and what is not. This
document is the account of that, including who did what and which tools did it.

The approach is modelled on how [ArtCraft](https://getartcraft.com/) shipped
[PhotoCraft](https://github.com/storytold/photocraft): a clean-room alternative to a commercial product (their
README calls it a clean-room reimplementation of Adobe Photoshop) with an `AGENTS.md` for the next contributor,
human or agent, an `ATTRIBUTION.md` for every borrowed thing, and a status block that does not oversell. How much
of PhotoCraft was written by agents is their story to tell; the agent-driven workflow below is ossover's own.

## 1. The question

CodeWeavers' CrossOver is the best way to run Windows games on an Apple Silicon Mac, and most of it is Wine, which
is LGPL and whose CrossOver patch set CodeWeavers publishes as a source tarball. The rest (the GUI, the bottle
tooling, the signed compatibility database, CrossTies) is proprietary. The question was: **which of the things
CrossOver does are actually needed for a game to run well, and how much of that is already open?** Not "how do we
clone CrossOver" but "what does the evidence say a bottle, an engine and a renderer must do".

The acceptance test was deliberately narrow: one game, The Witcher 3: Wild Hunt 4.04 (DirectX 11), playable on the
owner's M5 Pro, with a frame-time benchmark against the CrossOver trial on the same save. One title that can be
measured beats ten that "work".

## 2. The guardrails

CrossOver's EULA forbids reverse-engineering its proprietary parts. Before any analysis started, the owner fixed the
scope and it never moved:

| In scope | Out of scope, always |
|---|---|
| The trial bundle's inventory (7,425 files), `Info.plist`, code signatures, entitlements, dyld resolution traces | Decompiling `Contents/MacOS/CrossOver` (the GUI) |
| Mach-O headers, exports, imports, rpaths and strings of every binary, including proprietary ones | Decompiling anything under `lib/python/` (the `.pyc` tooling) |
| The plain-text Perl launcher, bottle templates, `cxbottle.conf`, `crossover.inf`, `cxfixes.xml`, the `.tie` XML | Decompiling `cxcompatdb.so` (its exports and strings were read; its logic was not) |
| Full analysis (Ghidra) of the **LGPL** binaries: `ntdll.so`, `winemac.so`, `winevulkan.so`, DXMT's `winemetal.so` | Anything in Apple's `D3DMetal.framework` / `libd3dshared.dylib` beyond signature, headers and strings |
| The LGPL source tarball, read for behaviour and cited `file:line` | Copying anything: no Perl, no template, no registry snippet, no CrossTie |
| | Running the trial (no EULA acceptance, so no runtime capture; every "what happens at run time" question is marked `unknown` by construction) |

Both artifacts came from CodeWeavers' public CDN with no account: `crossover-26.3.0.zip` (387,192,026 bytes, SHA-256
`8688e084…a26`, matching their sidecar) and `crossover-sources-26.3.0.tar.gz` (149,054,023 bytes, `ac99c8ca…d6872`).
Everything was done on the extracted copies in a scratch directory; nothing was executed from them.

## 3. The evidence pass

The reverse-engineering was done with [REA](https://github.com/morluto/rea) (`rea-agents` 6.4.0, as an MCP server
inside Claude Code) using its `native-macos` provider (the Xcode toolchain: `codesign`, `otool`, `nm`, `dyld_info`,
`vtool`, `plutil`) and its artifact-graph provider for the ZIP inventory, with **Ghidra** as the decompiler for the
LGPL binaries. Hopper (demo) was available as a second opinion and was not needed. The owner's plan set nine
hypotheses to confirm or refute:

| H | Question | What it fed |
|---|---|---|
| H1 | How does the launcher start Wine and with which environment? | the golden environment table |
| H2 | How is a renderer (wined3d / DXVK / DXMT / D3DMetal) selected and placed? | the overlay strategy |
| H3 | Who sets msync/esync and what is the default? | the sync default |
| H4 | What is a bottle on disk and how is a prefix initialised? | `bottle.json` and `Prefix` |
| H5 | Which Wine is it, and is the LGPL tarball complete enough to rebuild it? | the engine base and patch list |
| H6 | How is D3DMetal wired in, and what is Apple-signed? | the GPTK import flow |
| H8 | How are per-app tweaks delivered (CrossTies, `cxfixes.xml`, the compat DB)? | the recipe system |
| H9 | How is it signed, with which entitlements? | the packaging and signing plan |

(H7 was never defined; the ledger says so rather than inventing one.)

The output lives in [`docs/rea/`](rea/): a report per topic (`inventory.md`, `signing.md`, `env-table.md`,
`renderer-selection.md`, `bottle-format.md`, `wine-fork.md`, `app-tweaks.md`), the 172 raw evidence files (published
as the GitHub Release asset `docs-rea-evidence-crossover-26.3.0.tar.xz` rather than in the git tree, minus the
records derived from proprietary binaries; extract it into `docs/rea/evidence/` to resolve the `evidence/…`
citations), an
[`unknowns.md`](rea/unknowns.md) of open questions with what would resolve each and under which authority, and the
two documents the code is held to:

- [`ledger.md`](rea/ledger.md): **82 rows**, one per question, each marked **observed** (the artifact says so),
  **inferred** (an analyst's reading of observed facts) or **unknown**, with its authority (`shipped-artifact`,
  `historical-reference` for the published source, `analyst-inference`) and its evidence IDs.
- [`decisions.md`](rea/decisions.md): **39 decisions** (38 from the pass plus one added out of sequence by the
  verification), each pointing at the rows that justify it and marked "Confirmed" (the code already does this) or
  "Change" (the code must move).

Then an adversarial verification pass re-checked every citation against the artifacts. It changed 19 ledger rows,
rewrote 11 decisions, moved two unknowns to resolved and narrowed one to a blocking ABI question, and recorded all
of that at the top of each file. The ledger is append-and-correct, never silently rewritten.

## 4. What the evidence changed

The point of evidence is that it contradicts you. Some of the things ossover does differently because of the pass:

- **No `DYLD_*` variables, anywhere.** Whisky-style front ends set `DYLD_FALLBACK_LIBRARY_PATH` for D3DMetal.
  CrossOver sets none (zero hits in every plain-text file), its hardened-runtime loaders lack the entitlement that
  would let dyld honour them, and D3DMetal is found through `libd3dshared.dylib`'s own `@loader_path` rpath. Gone
  from the environment table and forbidden by rule.
- **`WINEMSYNC` only.** The Whisky pattern "set `WINEESYNC=1` and `WINEMSYNC=1` so D3DMetal doesn't break" is not
  CrossOver practice: esync is not compiled into the CrossOver tree at all. One variable, one value per prefix
  lifetime (client/server mismatch is a hard exit in `msync_init`), and a sync change stops the wineserver first.
- **Renderer selection is purely by Unix DLL path.** Since CrossOver 24, no renderer DLL is copied into a prefix
  and no `WINEDLLOVERRIDES` is set for any backend; the proprietary `cxcompatdb.so` calls an LGPL export,
  `prepend_dll_path()`, that has no in-tree caller. ossover's own engine carries a small patch that exposes the
  same thing as `WINEDLLPATH_PREPEND` (strategy C). On engines without it the "copy into `system32`" fallback
  (strategy B) turned out to be subtler than planned: `WINEDLLPATH` can never shadow a builtin the engine ships, so
  the pack's D3D DLLs end up running against the engine's own `winemetal` pair, an ABI coupling that is now stated
  in the code and gated by version.
- **D3DMetal needs strategy C.** The plan assumed environment-only activation on the bootstrap engine; the source
  says otherwise (`wine.inf` registers only `atidxx64`/`nvapi64`/`nvngx` as fake DLLs; `dll_dir` is always searched
  first). Without the prepend patch, selecting `d3dmetal` would have produced a silently broken configuration whose
  log header said "d3dmetal". The resolver now refuses it with a reason.
- **msync by default is a deliberate divergence.** CrossOver's fresh-bottle default is off (a GUI toggle); it turns
  msync on for every Steam install through a tie. ossover defaults to msync on every bottle whose engine has it and
  surfaces CrossOver's own warning text about applications that misbehave.
- **Registry defaults were trimmed to what has a reader.** Several `crossover.inf` entries the plan had copied
  (`Systray\Hidden`, `X11 Driver\ShowSystray`) have no reader in the 26.3.0 tree. Dropped; the one that does
  (`Explorer\ShowSystray`) is cited to the line that reads it.
- **The rpath rule became a gate.** CrossOver's `wineloader` carries an rpath that is dead; everything resolves
  through the `.so` files' own rpaths, and the DXMT overlay it ships has a malformed, colon-joined rpath that only
  works because `ntdll.so` is already loaded. ossover's packager gives every Mach-O a self-contained rpath set and
  `gates.sh rpath_self_contained` fails any engine where that is not true, the kind of accident a dlopen sweep
  would have let through.
- **`minMacOS` is 14.0 whenever a DXMT or D3DMetal overlay is active**, because `winemetal.so`, `libd3dshared.dylib`
  and `D3DMetal` are all built with a macOS 14 floor, even though the plain engine's floor is the toolchain's.
- **CrossTies became recipes, with their facts cited.** The Steam tie's dependencies (Core Fonts, the VC++ runtime
  pair, `d3dcompiler_47`, msync, `WINE_WAIT_CHILD_PIPE_IGNORE=steam.exe`) became steps in `recipes/steam.json`; the
  Witcher 3 tie's choice of **DXVK** (not DXMT) became a second recipe so the benchmark compares like with like,
  while DXMT stays the default for playing.
- **The LGPL tarball is enough.** 290 of 290 `ntdll.so` exports and 3 of 3 `winemac.so` exports of the shipped
  binaries have definitions in the published source, including the CrossOver-only `prepend_dll_path`,
  `add_load_order_override` and `__wine_unix_spawnvp`; the shipped fork string is `wine-11.0-8726-g2e2f5fca349`,
  upstream 11.0 plus 8,726 CodeWeavers commits. That is what makes "build your own engine" a real offer and not a
  hope.

## 5. The build

With the ledger in hand the code was written as a Swift 6 package, `OssoverKit` plus the `ossover` CLI, reusing
(with per-file attribution, both GPL-3.0) the parts of WhiskyKit and HighballKit that were already right: Wine
process control, registry access, `winecfg -v`, resumable SHA-256 downloads, the engine store, the process table.
The new parts are the pure, golden-tested `WineEnvironment`, the renderer resolver and materialiser, the recipe
engine with `when` predicates, the steamcmd orchestration that never touches a password, and the Metal HUD
benchmark harness. About 200 Swift Testing tests run without Wine, Rosetta or the network.

Order of events, as the commit history records it:

1. Scaffold: GPL-3.0-or-later, CC0 for recipes, `NOTICE.md`, the package layout from the plan.
2. Engine build scripts with pinned inputs, written before the build was possible, so the packaging policy
   (closure, rpaths, signing, manifest shape, twenty gates) could be unit-tested on a synthetic Mach-O tree.
3. The foundation modules and the REA pass, in parallel, in separate scratch build directories.
4. The adversarial verification of the ledger; then the 39 decisions applied across the environment table, the
   overlay gating, prefix registry, engine stamp, store layout, recipe schema and the engine gates, with review
   fixes.
5. The bootstrap engine (frankea's Whisky Libraries v4.6.4-beta.1: Wine 11.16 with the CrossOver 26.3 patch set and
   DXMT 0.80) installed from a pinned manifest; its capabilities probed from `ntdll.so` and `winemac.so` rather than
   trusted.
6. A small Windows probe (`scripts/probes/d3d11probe.c`, built with mingw-w64) run in a bottle to prove that
   DXMT, not wined3d, serves Direct3D 11: adapter reported as Apple M5 Pro, `wined3d` never loaded.
7. The Witcher 3 depot fetched with steamcmd (the owner typing the password and Steam Guard code at steamcmd's own
   prompt), pinned to branch `next-gen`; the recipe applied; first launch on 2026-10-14. The game reached its main
   menu and was playable. DXMT logged, seven times at startup, that it does not support geometry-shader stream
   output; that observation went into the recipe's `knownIssues` the same day, because an honest recipe records
   what it saw.
8. Metal HUD per-frame logging verified from a live run and the `smoke`/`bench` harness wired to it.
9. The own-engine build from the CrossOver 26.3.0 tarball started (in progress at the time of writing). The
   benchmark runs have not been done.

## 6. Who did what

**The agents.** The code, the engine scripts, the recipes, the harness, the evidence reports and these documents
were written with **Claude Fable 5.1 in Claude Code**, orchestrated as a multi-agent workflow: a planning session
produced the plan the owner approved; then agents with explicit file ownership ran the REA inventory, the deep
analysis of the LGPL binaries, the sources pass, the plain-text tooling pass, the adversarial verification, and the
implementation of each module (foundation, CLI, engine scripts, recipes and bench, store, renderer, prefix), with
separate reviewer agents and, last, the documentation agent that wrote this. Each agent built in its own
`.build-<name>` scratch directory so that more than twenty builds could run in one checkout; the directory names
are still there, gitignored. The orchestrator relayed the owner's instructions verbatim and kept the agents to their
directories. Facts an agent was allowed to state were the ones it had verified in its own session; where it had not
measured something, the word is "pending".

**The tools.** REA (`rea-agents`), Ghidra, the Xcode toolchain, Swift and SwiftPM, swift-argument-parser, Homebrew,
MacPorts, mingw-w64, ccache, steamcmd, Apple's Metal Performance HUD. The things ossover runs: Wine and CodeWeavers'
published patch set, msync, DXMT, MoltenVK, DXVK-macOS, GStreamer, FFmpeg, wine-mono, wine-gecko, winetricks; the
bootstrap engine from frankea's Whisky fork and the control engine from Gcenx's builds. Every one of them is listed
with its licence in [`ATTRIBUTION.md`](../ATTRIBUTION.md).

**The human.** Hemant ([hemkum](https://github.com/hemkum)) set the goal and the acceptance test, fixed the
reverse-engineering scope and chose not to install the trial or accept its EULA, chose GPL-3.0-or-later and CC0,
typed the passwords for Rosetta 2 and MacPorts, logged into Steam, approved each phase at its gate, and will create
the benchmark save and run the matrix. He also decided what this project would not do: no D3DMetal redistribution,
no stores, no numbers that were not measured.

## 7. What this is not

It is not a CrossOver clone and does not try to be: there is no GUI, no CrossTies, no signed compatibility database,
and the proprietary parts were never read. It is not finished: the own engine is not packaged, one title has been
verified on one Mac, and the benchmark that gives the project its pass line is still to be run. What it is, today,
is a reproducible, evidence-cited path from CodeWeavers' LGPL source drop to a playable Witcher 3 on an Apple
Silicon Mac, with every borrowed idea pointing at the row that justifies it.
