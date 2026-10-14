# ossover roadmap

**Stage: alpha** · one title verified (The Witcher 3: Wild Hunt 4.04, DirectX 11) on one Mac (Apple M5 Pro,
macOS 26.7.1) on a third-party bootstrap engine · no benchmark numbers published yet.

> **Last reviewed:** 2026-10-14 · **Target:** what CodeWeavers CrossOver 26.3 does for Windows games on Apple
> Silicon, as free software, with the same or better frame times on the same game.

This page is the one-page view. The evidence behind the design is in [`docs/rea/`](docs/rea/), the benchmark
definition in [`docs/benchmark.md`](docs/benchmark.md), the engine build in [`engine/README.md`](engine/README.md).
Nothing below has a date; items move when they are done, not when a calendar says so.

## Where it stands

| Area | Today |
|---|---|
| Engine | Bootstrap engine (frankea Whisky Libraries v4.6.4-beta.1: Wine 11.16 + CrossOver 26.3 LGPL patches + DXMT 0.80) installs, verifies and runs. Own engine from CodeWeavers' LGPL sources: scripts and gates written, build in progress, not packaged. |
| Renderers | DXMT 0.80 (default, verified as the D3D11 provider in a bottle), DXVK-macOS 1.10.3 (optional), D3DMetal (user import only; needs the own engine). No DirectX 12. |
| Bottles | Create, list, settings, delete; 64-bit Windows 10, msync, RetinaMode, isolated user folders, engine stamp. |
| Games | The Witcher 3 4.04: Steam depot via steamcmd, recipe, runs, playable. |
| Harness | `smoke` and `bench run`/`bench attach` on Metal HUD per-frame logs: implemented and unit-tested; the benchmark runs are pending. |
| App | None. CLI only. |
| Distribution | Build from source. No signed or notarized binaries. |
| Tests | About 200 Swift Testing tests, no Wine needed; `engine/selftest.sh` for the packaging policy. |

## v0.1 — Proof

The release that makes the README's claims measurable.

- **Benchmark results published.** The matrix in [`docs/benchmark.md`](docs/benchmark.md): The Witcher 3 4.04 in
  Hierarch Square, DXMT and DXVK, msync and none, on the bootstrap engine and on the own engine, three-run medians
  with `result.json` committed under `docs/benchmark-results/`. The pass line is ≥60 fps average and ≥30 fps 1% low
  over 60 s, and ≥0.9× the identical run under the CrossOver 26.3 trial (measured with `ossover bench attach`).
- **Own engine shipped.** `x64-ossover-cx26.3-r1` built from the CrossOver 26.3.0 LGPL tarball, all twenty
  `engine/gates.sh` gates passing, tarball + SHA-256 hosted, manifest in `engines/`, `WINEDLLPATH_PREPEND` (strategy
  C) as the overlay mechanism, so a bottle is never mutated for a renderer. The LGPL paperwork ships with it: the
  Wine tree's `LICENSE`, `COPYING.LIB` and `AUTHORS` inside the tarball and a mirror of the exact CrossOver source
  tarball beside it (see [`docs/licensing.md`](docs/licensing.md)).
- **Notarized CLI.** The `ossover` binary signed with a Developer ID and notarized, attached to a GitHub release.
  The engine stays ad-hoc signed in v0.1 (ossover `exec`s it directly; Gatekeeper is not involved).
- **D3DMetal import verified** on the own engine with a user-supplied Game Porting Toolkit disk image, as the stretch
  renderer, including the `renderer accept` licence record.
- **Recipe `status`** for `witcher3-4.04-dx11` moves from `untested` to `works` with a dated `reports` entry.

## v0.2 — App

The release a non-terminal user can use.

- **SwiftUI `Ossover.app`** over `OssoverKit`: engines (install, verify, remove), bottles, bottle detail (settings,
  programs, Run with a live log pane, Kill, Recipes), Developer ID signed and notarized with the entitlements the
  evidence supports (`cs.allow-unsigned-executable-memory`, `cs.disable-executable-page-protection`,
  `cs.disable-library-validation`; never `cs.allow-dyld-environment-variables`).
- **GPTK import UX**: drop Apple's dmg on the app, read the licence, accept, done; the pack stays byte-identical and
  Apple-signed.
- **More recipes**, with `status`/`reports` filled in by the people who ran them. Candidates are DirectX 11 titles
  that already have a CrossTie or a Whisky/highball recipe to compare against.
- **Epic Games Store support via [Legendary](https://github.com/derrod/legendary)**: `ossover epic fetch` that
  downloads a game's Windows build with Legendary into a bottle, the same way `steam fetch` uses steamcmd (the
  login happens in Legendary's own flow, never through ossover), plus a recipe convention for Epic titles. Tracked as
  a GitHub issue on the repository.
- **GOG via [gogdl](https://github.com/Heroic-Games-Launcher/heroic-gogdl)**: the same pattern for GOG's DRM-free
  Windows builds.
- **CrossOver bottle importer** (read-only): map `cxbottle.conf` (`CX_GRAPHICS_BACKEND`, legacy `WINEDXVK`,
  `WINED3DMETAL`, `WINEESYNC` → msync) to `bottle.json`, as the evidence ledger prescribes.
- **Homebrew tap** for the CLI.

## v0.3 — After Rosetta

macOS 27 is the last release with general-purpose Rosetta 2; whether Wine qualifies for the games-only subset after
that is unknown. v0.3 is the answer that does not depend on the answer.

- **arm64 + FEX engine**: Wine running natively on Apple Silicon with FEX translating the x86_64 game code through
  ARM64EC, the direction CodeWeavers announced for CrossOver 27. Needs macOS 26.5+ and Apple's
  `com.apple.developer.cross-architecture-support` entitlement, so it is also a signing and distribution problem, not
  only a build.
- **KosmicKrisp and DXVK ≥ 2**: a second Direct3D path through Mesa's Vulkan-on-Metal driver, which brings the
  Vulkan features MoltenVK lacks (transform feedback among them), so DXVK is no longer capped at 1.10.3 on macOS.
- **DirectX 12**: only through D3DMetal today, and only with the user's own GPTK copy; whether an open path exists is a
  v0.3 question.
- **Benchmark on more machines**: the same save, the same settings, M1 through M5, as community `result.json`
  contributions.

## Not planned

- Bundling or downloading D3DMetal or any part of Apple's Game Porting Toolkit (licence; see
  [`docs/licensing.md`](docs/licensing.md)).
- Reproducing CrossOver's proprietary parts: the GUI, CrossTies, the signed compatibility database. Recipes are the
  open equivalent.
- Accounts, stores, telemetry, auto-update daemons.
- Windows apps that are not games are not a goal; they may work, nobody is testing them.
