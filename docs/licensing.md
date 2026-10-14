# Licensing

What is licensed how, and why. The short list is [`NOTICE.md`](../NOTICE.md); the full table of third-party
components is [`ATTRIBUTION.md`](../ATTRIBUTION.md). This document is not legal advice; it explains the choices the
project made and the obligations it took on.

## ossover itself: GPL-3.0-or-later

All code in this repository (`Sources/`, `Tests/`, `engine/*.sh`, `engine/manifest.py`, `scripts/probes/`) is
licensed under the GNU General Public License, version 3 or (at your option) any later version. Every Swift file
carries `// SPDX-License-Identifier: GPL-3.0-or-later`.

Why GPL and not MIT/Apache like PhotoCraft:

1. **Reuse.** The fastest honest way to a working Wine front end on macOS was to adapt code from
   [Whisky](https://github.com/Whisky-App/Whisky) (WhiskyKit) and [highball](https://github.com/gauthierpiarrette/highball)
   (HighballKit), both GPL-3.0. Adapted code keeps its copyright line in the file header; GPL-3.0-or-later is the
   licence that lets it live alongside new code without a relicensing negotiation.
2. **The point of the project is that it stays open.** ossover exists because the useful parts of CrossOver are LGPL
   and the rest is not. Copyleft on the front end keeps a fork from re-closing what the evidence pass opened.
3. **"or later"** keeps the option of moving to a future GPL version and avoids a licence-version conflict with
   dependencies that are "GPL-3.0-or-later" themselves.

Contributions are accepted under the same terms (inbound = outbound): GPL-3.0-or-later for code, CC0-1.0 for
recipes. No CLA.

GPL-3.0 is compatible with everything ossover links or executes: Apache-2.0 (swift-argument-parser, MoltenVK), MIT
(DXMT 0.80, DepotDownloader), zlib (DXVK), MPL-2.0 (wine-gecko) and the LGPL components below. ossover does not link
the engine into its own binary; it `exec`s `wine` and `wineserver` as separate processes.

## The engine: LGPL-2.1-or-later and what it asks of us

The engine is Wine, built from the CrossOver 26.3.0 source tarball CodeWeavers publishes under the LGPL, with three
patches that are themselves LGPL-2.1-or-later (from highball-engine; one originates in MacPorts). Wine's licence is
the GNU Lesser General Public License v2.1 or later. Distributing a built engine (the tarball `ossover engine
install` consumes) triggers the LGPL's obligations, and ossover meets them like this:

| Obligation | How ossover meets it |
|---|---|
| Provide the complete corresponding source of what is distributed | The engine manifest's `source` block and [`engine/inputs.json`](../engine/inputs.json) list the **exact URL and SHA-256** of every input: the CrossOver 26.3.0 source tarball (`ac99c8ca…d6872`), DXMT, MoltenVK, DXVK-macOS, wine-mono, wine-gecko, the MacPorts installer and port list. The modifications are the patches in [`engine/patches/`](../engine/patches/), verbatim. `engine/build.sh` reproduces the build. A published engine's `manifest.json` → `components` lists each bundled library with its version and licence |
| Keep the source available for as long as the binary is | Each published engine release is to carry a mirror of the exact CrossOver source tarball it was built from (CodeWeavers has re-uploaded tarballs under the same name before; the SHA-256 pin detects that), beside the engine tarball. No engine has been published yet; this is a v0.1 requirement in the [roadmap](../ROADMAP.md) |
| Preserve notices | `engine/package.sh` copies DXMT's and DXVK's licence files beside their overlays and records every component's licence in `manifest.json` → `licenses`; the Wine tree's `LICENSE`, `COPYING.LIB` and `AUTHORS` must be added to the engine tarball before the first published release (also tracked for v0.1). The patch headers keep their authors' notes |
| Let the user relink / replace the library | Nothing from the engine is statically linked into ossover. The engine is a directory of dynamically linked Mach-O files the user can replace wholesale (`ossover engine install` another manifest) or file by file (the rpath rule makes every module resolve from its own location, no `DYLD_*` needed) |
| No further restrictions | Engine tarballs are ad-hoc signed, not DRM'd; the `SHA256SUMS` file is for integrity, not enforcement |

The same applies to the bootstrap engine, which ossover does not build but downloads from frankea's Whisky release:
the manifest pins its URL and hash, and its source is the frankea/Whisky and winecx repositories named in the
manifest `notes`.

msync (LGPL-2.1), GStreamer and FFmpeg (LGPL-2.1) inside the engine are covered by the same mechanism: pinned inputs,
versions recorded in `components`, dynamically linked.

### The CrossOver source tarball and the CrossOver product

CodeWeavers publishes the LGPL parts of CrossOver (the Wine tree with their patches) because the LGPL requires it.
Building from that tarball is what the licence is for. It does **not** make the result CrossOver: the GUI, the
Python tooling, `cxcompatdb.so`, CrossTies and the compatibility database are proprietary, were never decompiled, and
nothing from them is in this repository or in any engine ossover builds. "CrossOver" is CodeWeavers' trademark and
ossover does not use it in product names, bundle identifiers or engine ids; `cx26.3` in an engine id names the source
tarball version, as `wine11.16` names the Wine version. The scope of the analysis is recorded in
[`docs/rea/README.md`](rea/README.md) (the inventory, signing and dyld pass; no decompilation) and
[`docs/rea/wine-fork.md`](rea/wine-fork.md) (the Ghidra pass, on the LGPL binaries only); [`AGENTS.md`](../AGENTS.md)
§4 has the rules every contributor follows.

## D3DMetal: never redistributed

Apple's Game Porting Toolkit ships D3DMetal (`D3DMetal.framework`, `libd3dshared.dylib` and a set of Windows DLLs)
under Apple's own licence, which, as published, is for non-commercial use, applies to the framework as a whole and
grants no right to sublicense or redistribute. CrossOver bundles it under terms Apple gave CodeWeavers; open
projects that asked Apple for the same (UTM did, publicly) have not received an answer. Until Apple says otherwise,
ossover treats D3DMetal as something only the end user may obtain:

- ossover **never downloads** the Game Porting Toolkit and **never bundles** any file from it in an engine or a
  renderer pack.
- `ossover renderer import-gptk <dmg>` reads a disk image the user downloaded from Apple with their own developer
  account after accepting Apple's licence. The files are copied verbatim, their Apple code signature is verified,
  and they are never re-signed, stripped or rewritten.
- `ossover renderer accept <id>` records, in `$OSSOVER_HOME/licenses/`, that the user accepted Apple's licence for
  that pack; a bottle cannot select `d3dmetal` before that record exists. Removing the pack keeps the record.
- The imported pack lives under the user's `$OSSOVER_HOME`, outside any ossover distribution.

DXMT is the default renderer precisely because it is open (MIT at 0.80, LGPL-2.1-or-later after) and can be shipped
in the engine.

## Recipes and compatibility data: CC0-1.0

Everything under [`recipes/`](../recipes/), including `_schema.json`, is dedicated to the public domain under
[CC0 1.0](../LICENSES/CC0-1.0.txt). Each recipe says so in its `license` field.

Why: a recipe is a fact about a game ("4.04 wants HairWorks off and `launcher-configuration.json` pointed at
DirectX 11"), and facts about games should flow freely between ossover, Whisky, highball, Heroic, Lutris-style
launchers and the people maintaining them without anyone asking about licence compatibility. CC0 also matches what
the recipes replace: CrossOver's CrossTies are proprietary and signed; ossover's are public domain and plain JSON.

A recipe must not contain copyrighted material from a game (no extracted files, no `user.settings` copied wholesale
from the game's defaults beyond the keys it sets) and must not contain anything from CrossOver's CrossTies beyond
the fact a CrossTie establishes (cited by ledger row).

## Things ossover does not license because they are not ours

- **Games.** `ossover steam fetch` downloads the depot of a game the user owns, with the user's own Steam
  credentials typed into Valve's steamcmd. ossover redistributes nothing and the bottle is the user's.
- **The screenshot** in `docs/images/` is © CD PROJEKT S.A. and reproduced only to document compatibility; see
  [`ATTRIBUTION.md`](../ATTRIBUTION.md).
- **Trademarks.** CrossOver, CodeWeavers, Apple, macOS, Metal, Game Porting Toolkit, D3DMetal, Wine, WineHQ, Steam,
  Valve, The Witcher, CD PROJEKT, Epic Games, GOG belong to their owners and appear here only to describe
  compatibility. The ossover name is not trademarked; a fork may keep or change it.

## Quick reference

| What | Licence | File |
|---|---|---|
| ossover code (`Sources/`, `Tests/`, `engine/*.sh`, `engine/manifest.py`, `scripts/probes/`) | GPL-3.0-or-later | [`LICENSE`](../LICENSE) |
| Code adapted from Whisky / highball | GPL-3.0 (compatible; headers kept) | [`NOTICE.md`](../NOTICE.md) |
| Recipes, schema, compatibility data (`recipes/`) | CC0-1.0 | [`LICENSES/CC0-1.0.txt`](../LICENSES/CC0-1.0.txt) |
| Engine patches (`engine/patches/`) | LGPL-2.1-or-later | patch headers |
| Vendored winetricks (`scripts/vendor/`) | LGPL-2.1-or-later | [`scripts/vendor/README.md`](../scripts/vendor/README.md) |
| Documentation (`docs/`, `README.md`, …), except the screenshot in `docs/images/` (© CD PROJEKT S.A., see [`ATTRIBUTION.md`](../ATTRIBUTION.md)) and the REA evidence records (a release asset, partly derived from third-party binaries; see its `README.txt` / `EXCLUDED.txt`) | GPL-3.0-or-later (same as the code) | [`LICENSE`](../LICENSE) |
| Engines ossover downloads or builds | LGPL-2.1-or-later + per-component (see table) | engine `manifest.json` → `licenses`, `components` |
| D3DMetal | Apple's licence, accepted by the user, never redistributed | `$OSSOVER_HOME/licenses/` |
