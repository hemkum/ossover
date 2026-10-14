# Attribution

Every third-party component ossover vendors, adapts, downloads or builds, with its author, source and licence.
ossover's own code is GPL-3.0-or-later ([`LICENSE`](LICENSE)); recipes are CC0-1.0
([`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt)); the short form of this list is [`NOTICE.md`](NOTICE.md). When you
add a component, add a row here and a line in `NOTICE.md` in the same change.

## In this repository

Code and files that are checked in.

| Path | What | Author | Source | Licence |
|---|---|---|---|---|
| `Sources/OssoverKit/**` (files whose header says "Adapted from Whisky …") | Wine process control, registry access, `winecfg -v`, RetinaMode/LogPixels, bottle settings mapping, tar, Rosetta checks | Isaac Marovitz and Whisky contributors, © 2023–2025 | <https://github.com/Whisky-App/Whisky> | GPL-3.0 |
| `Sources/OssoverKit/**`, `Sources/ossover/**` (files whose header says "Adapted from highball …") | Engine store, resumable download, bottle model, wine runner, process table, paths, recipe runner, Steam manifest parsing, shell helpers | Gauthier Piarrette, © 2026 | <https://github.com/gauthierpiarrette/highball> | GPL-3.0 |
| `engine/patches/0001-use-the-real-user-name.patch`, `0003-ntdll-winedllpath-prepend.patch`, `0014-msync-unregister-early-return.patch` | Patches on the CrossOver LGPL Wine tree (verbatim copies; `0003` originates from MacPorts' game-porting-toolkit `1005-ntdll-d3dmetal-env.diff`) | Gauthier Piarrette (highball-engine); MacPorts contributors | <https://github.com/gauthierpiarrette/highball-engine> | LGPL-2.1-or-later |
| `scripts/vendor/winetricks` | winetricks at commit `f3890f67`, sha256 beside it | Winetricks contributors | <https://github.com/Winetricks/winetricks> | LGPL-2.1-or-later |
| `Package.swift` dependency `swift-argument-parser` ≥ 1.5.0 | CLI argument parsing (fetched by SwiftPM, not vendored) | Apple Inc. and contributors | <https://github.com/apple/swift-argument-parser> | Apache-2.0 |
| `docs/images/witcher3-menu-m5pro.jpg` | Screenshot, see [Screenshot credit](#screenshot-credit) | — | — | not covered by the GPL |

## Downloaded or built at run time

Nothing below is in the repository. ossover downloads each from the URL pinned in a manifest (`engines/*.json`,
`renderers/*.json`, `engine/inputs.json`) and verifies its SHA-256 before use.

| Component | Version pinned | Used as | Author | Source | Licence |
|---|---|---|---|---|---|
| Wine | 11.0 (CrossOver 26.3.0 source tree) | Base of the own engine (`engine/build.sh`) | Wine contributors; CodeWeavers, Inc. for the CrossOver patch set | <https://www.codeweavers.com/crossover/source> | LGPL-2.1-or-later |
| msync | in the CrossOver tree (`server/msync.c`, `dlls/ntdll/unix/msync.c`) | Mach-semaphore synchronisation | Marc-Aurel Zent (marzent); CodeWeavers | <https://github.com/marzent/wine-msync> | LGPL-2.1 |
| frankea Whisky Libraries | v4.6.4-beta.1 (Wine 11.16 + CrossOver 26.3 patches + DXMT 0.80 + DXVK 1.10.3) | **Bootstrap engine** `x64-frankea-wine11.16-cx26.3-v4.6.4b1` | frankea and Whisky contributors | <https://github.com/frankea/Whisky/releases/tag/v4.6.4-beta.1> | LGPL-2.1-or-later (Wine), MIT (DXMT), zlib (DXVK), LGPL (GStreamer/FFmpeg) |
| Gcenx macOS_Wine_builds, wine-devel | 11.18 | **Control engine** `x64-gcenx-wine-devel-11.18` (proves the capability gates; DXMT must fail on it) | Gcenx | <https://github.com/Gcenx/macOS_Wine_builds> | LGPL-2.1-or-later |
| DXMT | 0.80 | Direct3D 10/11 on Metal (default renderer) | 3Shain and contributors | <https://github.com/3Shain/dxmt> | MIT for 0.80 (LGPL-2.1-or-later from later releases) |
| DXVK-macOS | 1.10.3 (20230507 repack) | Direct3D 9/10/11 on Vulkan via MoltenVK (optional renderer) | Gcenx; DXVK contributors (Philip Rebohle et al.) | <https://github.com/Gcenx/DXVK-macOS> | zlib |
| MoltenVK | 1.4.2 | Vulkan on Metal, for DXVK and winevulkan | The Khronos Group / The Brenwill Workshop | <https://github.com/KhronosGroup/MoltenVK> | Apache-2.0 |
| wine-mono | 10.4.1 (own engine); 11.3.0 (bootstrap engine) | .NET runtime for Windows programs | Wine contributors / Mono contributors | <https://dl.winehq.org/wine/wine-mono/> | mixed (see its LICENSE) |
| wine-gecko | 2.47.4 (x86, x86_64) | HTML engine for Windows programs | Wine contributors / Mozilla | <https://dl.winehq.org/wine/wine-gecko/> | MPL-2.0 |
| GStreamer (core, base, good, bad, libav) | MacPorts x86_64 ports at build time | Media playback in the own engine | GStreamer contributors | <https://gstreamer.freedesktop.org/> | LGPL-2.1 |
| FFmpeg | MacPorts `ffmpeg7` | `winedmo` media foundation backend | FFmpeg contributors | <https://ffmpeg.org/> | LGPL-2.1 |
| freetype, gnutls, SDL2, glib and the rest of the MacPorts closure | as pinned by `engine/inputs.json` → `toolchain.macports.ports` | Libraries the Unix side of Wine dlopens; copied into `wine/lib` by `engine/package.sh` and listed per library in the engine's `manifest.json` → `components` | respective authors | <https://www.macports.org/> | per library (FreeType, LGPL-2.1, zlib, LGPL-2.1, …) |
| mingw-w64 (GCC) | Homebrew `mingw-w64` | Builds the PE half of the own engine (build tool, not shipped) | mingw-w64 contributors | <https://www.mingw-w64.org/> | various (public domain, ZPL, LGPL for parts); build tool only, nothing from it is shipped |
| steamcmd | Homebrew cask `steamcmd` | Steam depot fetch (`ossover steam`); installed by the user, never bundled | Valve Corporation | <https://developer.valvesoftware.com/wiki/SteamCMD> | proprietary (Steam Subscriber Agreement) |
| DepotDownloader | user-installed, optional | Steam depot fetch fallback (`--tool depotdownloader`) | SteamRE contributors | <https://github.com/SteamRE/DepotDownloader> | MIT |
| Apple Game Porting Toolkit / D3DMetal | user-supplied dmg | Direct3D 11/12 on Metal, **import only** (`ossover renderer import-gptk`), never downloaded, bundled or redistributed | Apple Inc. | <https://developer.apple.com/games/game-porting-toolkit/> | Apple proprietary; the user accepts Apple's licence and `ossover renderer accept` records it |

CodeWeavers CrossOver 26.3.0 itself (the trial bundle) was analysed, not used: no file from it is in this repository
or in any engine ossover builds. The scope of that analysis is recorded in [`docs/rea/README.md`](docs/rea/README.md)
(the inventory, signing and dyld pass; no decompilation), [`docs/rea/wine-fork.md`](docs/rea/wine-fork.md) (the
Ghidra pass, on the LGPL binaries only) and [`AGENTS.md`](AGENTS.md) §4 (the rules).

## Screenshot credit

`docs/images/witcher3-menu-m5pro.jpg` shows The Witcher 3: Wild Hunt 4.04 running in an ossover bottle on an Apple
M5 Pro (macOS 26.7.1, bootstrap engine, DXMT renderer), captured on 2026-10-14 by the project owner from his own
licensed Steam copy. The Witcher 3: Wild Hunt and its artwork are © CD PROJEKT S.A.; The Witcher is a trademark of
CD PROJEKT S.A. The image is reproduced here only to document compatibility and is not covered by this repository's
GPL-3.0-or-later licence. Forks that do not need it should remove it.

## Trademarks

CrossOver and CodeWeavers are trademarks of CodeWeavers, Inc. Apple, macOS, Metal, Game Porting Toolkit and D3DMetal
are trademarks of Apple Inc. Wine is a registered trademark of the Software Freedom Conservancy, Inc. Steam is a
trademark of Valve Corporation. Epic Games is a trademark of Epic Games, Inc. GOG is a trademark of GOG sp. z o.o.
ossover is an independent, open-source project and is not affiliated with, sponsored by or endorsed by any of them;
the names are used only to describe compatibility.
