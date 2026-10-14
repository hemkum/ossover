# Third-party notices

ossover is licensed under GPL-3.0-or-later (see LICENSE). Recipes and the compatibility
database under `recipes/` are CC0-1.0 (see LICENSES/CC0-1.0.txt). The full table, with
versions, sources and the screenshot credit, is ATTRIBUTION.md.

Code adapted from other GPL-3.0 projects keeps its original copyright notice in the
file header:

- WhiskyKit — Copyright © 2023–2025 Isaac Marovitz and Whisky contributors, GPL-3.0
  (https://github.com/Whisky-App/Whisky)
- Highball / HighballKit — Copyright © 2026 Gauthier Piarrette, GPL-3.0
  (https://github.com/gauthierpiarrette/highball)

Other third-party material in this repository:

- winetricks (`scripts/vendor/winetricks`, upstream commit f3890f67) — Copyright ©
  Winetricks contributors, LGPL-2.1-or-later (https://github.com/Winetricks/winetricks)
- Engine patches `engine/patches/0001-use-the-real-user-name.patch`,
  `0003-ntdll-winedllpath-prepend.patch` and `0014-msync-unregister-early-return.patch` —
  verbatim from highball-engine, Gauthier Piarrette; `0003` originates in MacPorts'
  game-porting-toolkit port (MacPorts contributors); LGPL-2.1-or-later
  (https://github.com/gauthierpiarrette/highball-engine)
- swift-argument-parser — SwiftPM dependency declared in `Package.swift`, fetched at build
  time, not vendored; Copyright © Apple Inc. and the Swift project authors, Apache-2.0
  (https://github.com/apple/swift-argument-parser)
- Contributor Covenant 2.1 (`CODE_OF_CONDUCT.md`) — Copyright © Coraline Ada Ehmke and
  contributors, CC BY 4.0 (https://www.contributor-covenant.org)
- `docs/images/witcher3-menu-m5pro.jpg` — a screenshot of The Witcher 3: Wild Hunt,
  © CD PROJEKT S.A., reproduced only to document compatibility and not covered by the GPL
  (ATTRIBUTION.md, "Screenshot credit")

Runtime components ossover downloads or builds at run time (not in this repository):

- Wine (LGPL-2.1-or-later), including the CodeWeavers CrossOver patch set published at
  https://www.codeweavers.com/crossover/source
- msync (LGPL-2.1) — https://github.com/marzent/wine-msync
- DXMT (MIT ≤0.80, LGPL-2.1-or-later after) — https://github.com/3Shain/dxmt
- DXVK-macOS (zlib) — https://github.com/Gcenx/DXVK-macOS
- MoltenVK (Apache-2.0) — https://github.com/KhronosGroup/MoltenVK
- GStreamer (LGPL-2.1), FFmpeg (LGPL-2.1), wine-mono, wine-gecko

Apple's D3DMetal / Game Porting Toolkit is proprietary and is never downloaded,
bundled or redistributed by ossover. Users import their own copy after accepting
Apple's licence.

Nothing in this repository is copied from CodeWeavers CrossOver's proprietary
components (GUI, bottle tooling, CrossTies, compatibility database). Behaviour was
observed; code was not reused.
