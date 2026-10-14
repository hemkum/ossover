# engine/ — building the ossover Wine engine

Builds `x64-ossover-cx26.3-r1` from CodeWeavers' CrossOver 26.3.0 LGPL sources (Wine 11.0 base
plus their macOS hacks: msync, `macdrv_functions`, D3DMetal host hooks) with the patch series in
`patches/`, then packages a relocatable, ad-hoc-signed engine directory and tarball that
`ossover engine install` consumes. Design: plan §5 "Engine build design"; reference recipes:
[highball-engine](https://github.com/gauthierpiarrette/highball-engine) and
[winecx-gptk](https://github.com/frankea/winecx-gptk) (cited inline in the scripts).

| File | Purpose |
|---|---|
| `inputs.json` | pinned URLs + sha256 for every input, MacPorts/Homebrew toolchain, patch list |
| `patches/*.patch` | applied in lexical order on top of `sources/wine` |
| `build.sh` | fetch → prep → tools → configure → build → install (each a flag, each logged + timed) |
| `package.sh` | staging → `out/<id>/` (layout, overlays, closure, relocation + rpath rule, signing, manifest) → `.tar.xz` |
| `manifest.py` | writes `manifest.json` in the `EngineManifest.swift` shape from the values `package.sh` measured |
| `gates.sh` | release gates on `out/<id>/`; PASS/FAIL per gate, non-zero exit on any FAIL |
| `selftest.sh` | the rpath policy, `manifest.py` and the offline gates on a synthetic Mach-O tree (no build needed) |

Evidence: the packaging rules below follow `docs/rea/decisions.md` 27–32 (ledger rows `L-12`, `L-21`,
`L-29`, `L-45`–`L-52`, `L-62`, `L-64`, `L-78`); each script cites the row next to the rule it implements.

## Prerequisites (one-time, needs your password)

1. **Rosetta 2** — the Unix half is x86_64: `sudo softwareupdate --install-rosetta --agree-to-license`
2. **Xcode** (27.0 works; the SDK still has x86_64) with the command line tools.
3. **Homebrew** (arm64): `brew install mingw-w64 bison ccache cabextract freetype xz`
   (`mingw-w64` = GCC for the PE half, not llvm-mingw; `bison` ≥ 3 at `/opt/homebrew/opt/bison/bin`;
   `freetype` is only for the native tools stage's `sfnt2fon`).
4. **MacPorts** with an **x86_64** tree (installer pinned in `inputs.json` → `toolchain.macports`).
   Before installing any port, edit `/opt/local/etc/macports/macports.conf`:
   ```
   build_arch                 x86_64
   macosx_deployment_target   15.0
   buildfromsource            always
   ```
   The second line sets the target for ports *built here*; the third is what makes it stick: ports
   fetched as prebuilt binary archives were built on the buildbots for the running macOS (measured
   2026-10-14 without it: 566 of 567 MacPorts dylibs `minos 26.0`, only a locally built `libjbig`
   at 15.0). `build.sh --check` measures this and warns; `package.sh` then raises the manifest's
   `minMacOS` to the bundled closure's floor so ossover refuses older macOS rather than dyld
   failing on it (`OSSOVER_STRICT_FLOOR=1` makes it fatal instead). Building everything from
   source takes hours (ffmpeg, x265, GStreamer). Then:
   ```
   sudo port -N install pkgconfig gettext freetype gnutls libsdl2 vulkan-headers \
        gstreamer1 gstreamer1-gst-plugins-base gstreamer1-gst-plugins-good \
        gstreamer1-gst-plugins-bad gstreamer1-gst-libav ffmpeg7
   ```
   (the list is `toolchain.macports.ports` in `inputs.json`; `build.sh --check` verifies all of it).

`./engine/build.sh --check` prints what is missing and exits non-zero until everything is there.

## Build

```sh
cd engine
./build.sh --fetch --pin      # first time only: downloads, pins the "TBD" sha256 values into inputs.json
./build.sh --all              # fetch (verify) → prep → tools → configure → build → install
./package.sh                  # out/<id>/ + out/<id>.tar.xz (+ .sha256)
./gates.sh out/x64-ossover-cx26.3-r1
```

Steps are flags and re-runs are idempotent: `--fetch` skips verified downloads, `--prep` skips when
the tarball and patch set are unchanged (stamp in `work/wine/.ossover-prep-stamp`), `--tools` and
`--build` are incremental `make`, `--install` and `package.sh` rebuild their outputs from scratch.
`--jobs N` sets `make -j` (default `hw.ncpu`; plan §5 used `-j22` on the 16-core M5 Pro).
`--clean` removes `work/{wine,build,build-tools}` and `staging/` but keeps downloads and the ccache.
`--verbose` streams step output; otherwise only `work/logs/<step>.log` gets it (tail printed on failure).

Expected times (plan §5, M5 Pro): **cold build 30–45 min, warm (ccache) 6–10 min**; `package.sh`
≈ 2–5 min (xz compression dominates; multi-threaded through Homebrew `xz` when present);
`gates.sh` ≈ 1 min (the dlopen sweep loads ~500 libraries under Rosetta).

### What build.sh does (plan §5)

1. `--fetch`: `curl` each `inputs.inputs.*` into `work/dl/`, verify sha256; `--pin` writes computed
   hashes back for `"TBD"` entries (`python3 -I` json rewrite; the file is reformatted with 2-space
   indent). `OSSOVER_MIRROR_URL=<base>` is tried before upstream (CodeWeavers has re-uploaded tarballs).
2. `--prep`: extract `sources/wine` → `work/wine`, apply `patches/*.patch` with `patch -p1` (a patch
   named in `inputs.json` but absent on disk is a warning), cross-check the wine-mono/gecko pins
   against `dlls/appwiz.cpl/addons.c`.
3. `--tools`: native arm64 `configure --enable-archs=i386,x86_64 --without-x --without-wayland
   --without-gstreamer --without-ffmpeg --disable-tests` + `make __tooldeps__` in `work/build-tools`
   (plus the `nls/locale.nls` link wrc needs).
4. `--configure`: the x86_64 configure in `work/build` with `CC="ccache /usr/bin/clang -arch x86_64"`,
   `--host=x86_64-apple-darwin24 --with-wine-tools=… --enable-archs=i386,x86_64 --with-mingw`, the full
   `--with/--without` list, `MACOSX_DEPLOYMENT_TARGET=15.0`, `PKG_CONFIG_{PATH,LIBDIR}` =
   `/opt/local/libexec/ffmpeg7/lib/pkgconfig` (ffmpeg7 is a versioned libexec port; its `.pc` files
   are not in `/opt/local/lib/pkgconfig`) + `/opt/local/{lib,share}/pkgconfig`,
   `LDFLAGS=-L/opt/local/lib -Wl,-headerpad_max_install_names`, `ac_cv_lib_soname_{MoltenVK,freetype,
   gnutls,SDL2}` as bare names, `ac_cv_func_pipe2=no` and `-Werror=unguarded-availability-new` (the
   SDK on this Mac is 27.0, the floor is 15.0). It fails if ffmpeg/gstreamer were not found or any
   `SONAME_*` in `config.h` is an absolute path.
5. `--build`: `make -j`, then scans the log for "introduced in macOS" availability warnings.
6. `--install`: `make install-lib DESTDIR=staging` (never `install`, which builds 2000 import libs).

If the repo path contains whitespace (this checkout does), autoconf/make/DESTDIR cannot be used in
place: `build.sh` creates `engine/work` and `engine/staging` as symlinks into
`$OSSOVER_BUILD_ROOT` (default `~/.cache/ossover-engine`) and builds there. `.gitignore` covers both.

### What package.sh does

Layout `out/<id>/wine/{bin,lib/wine/{x86_64-unix,x86_64-windows,i386-windows},lib/*.dylib,
lib/gstreamer-1.0,libexec/gstreamer-1.0,share/wine/{mono,gecko}}` and `out/<id>/overlays/{dxmt,dxvk}`:

- loader symlinks if Wine installed it beside `ntdll.so`; `i386-unix` removed (WoW64-only engine);
- wine-mono 10.4.1 and wine-gecko 2.47.4 (x86 + x86_64) extracted into `share/wine`;
- MoltenVK 1.4.2 from the Khronos tar, `lipo -thin x86_64`, into `wine/lib`;
- all MacPorts GStreamer plugins except X11/GL/GTK/Qt sinks (`--gst-exclude RE` to change) plus
  `gst-plugin-scanner`; the sonames Wine dlopens (`SONAME_*` from `work/build/include/config.h`:
  freetype, gnutls, SDL2) seeded from `/opt/local/lib`;
- strip: `x86_64-w64-mingw32-strip --strip-debug` on the PE dirs, `strip -x -S` on Unix binaries
  (`--no-strip` to skip);
- DXMT 0.80 → `overlays/dxmt/{x86_64-unix,x86_64-windows,i386-windows}` (tarball root `v0.80/`,
  verified with `tar tf` at run time); DXVK-macOS `-builtin` repack `{x86_64,i386}-windows/` (or the
  plain repack's `x64/x32`) → `overlays/dxvk/{x86_64-windows,i386-windows}` (optional; skipped with
  a warning if not downloaded). DXMT's `winemetal.{so,dll}`
  are also copied into the engine's builtin dirs so a fresh prefix gets a placeholder
  (`--no-winemetal-builtin` to disable). The builtin `d3d11/dxgi/d3d10core` stay Wine's. DXMT 0.80
  and MoltenVK 1.4.2 are newer than CrossOver's 0.72-25 / 1.2.10 and are shipped as gated
  capabilities (`macdrvExports`, the `.so` rpaths reaching `libMoltenVK.dylib`), not as CX parity
  (REA L-29, L-49);
- dependency closure: `otool -L` over every Mach-O, every `/opt/local` dylib copied (recursively)
  into `wine/lib`, then `install_name_tool -id @loader_path/<name>` and `-change` to
  `@loader_path/<name>` (siblings), `@loader_path/../../<name>` (from `lib/wine/x86_64-unix`),
  `@loader_path/../<name>` (gstreamer plugins); `/usr/lib` and `/System` untouched; a binary that
  imports Apple's `_iconv` is pointed at `/usr/lib/libiconv.2.dylib`, one that imports GNU's
  `_libiconv` gets the MacPorts copy;
- **rpath rule** (REA L-12, L-64; decision 28): every Mach-O gets its own `LC_RPATH` set, so
  nothing depends on the loader executable's rpath (CrossOver's is dead and everything still
  resolves through the `.so` rpaths). Wine's unix modules name each other `@rpath/ntdll.so`,
  `@rpath/win32u.so`, `@rpath/winemac.so` and dlopen freetype/gnutls/SDL2/MoltenVK by bare soname,
  which dyld tries as `@rpath/<soname>` against the calling image's rpaths. Sets: `lib/wine/
  x86_64-unix/*` → `@loader_path/` + `@loader_path/../../../lib`; `lib/*.dylib` → `@loader_path/`;
  `lib/gstreamer-1.0/*` → `@loader_path/` + `@loader_path/../`; `bin/*` → `@loader_path/../lib`;
  `libexec/gstreamer-1.0/*` → `@loader_path/../../lib`; `overlays/*/x86_64-unix/*` →
  `@loader_path/` + `@loader_path/../../../wine/lib/wine/x86_64-unix` + `@loader_path/../../../wine/lib`
  (CrossOver's overlay `winemetal.so` ships one malformed colon-joined entry and loads only because
  `ntdll.so`/`winemac.so` are already in the process; ours resolves them from its own root).
  Malformed (colon-joined) and builder-path (`/opt/local`, `/nix`, …) entries are deleted;
- **then** `codesign --force --sign - --timestamp=none` on every Mach-O, verified;
- `manifest.json` written by `manifest.py` in exactly the shape `Sources/OssoverKit/Model/
  EngineManifest.swift` decodes (`id`, `wineVersion`, `wineVersionString`, `minMacOS`,
  `source{url,sha256,extract{strip,into}}`, `paths{wine,wineserver,libWine}`, `baseEnv`, the six
  `capabilities`, `bundledRenderers[]` with `layout{unix,pe,pe32}`, `addons{wineMono,wineGecko}`),
  capabilities measured on the tree (`strings`/`nm`), `esync` false
  because the CX tree does not compile it in (REA L-32), `wineVersionString` read from `ntdll.so`
  (REA L-45), `minMacOS = max(toolchain floor, overlay floor, closure floor)` — CrossOver's DXMT
  `winemetal.so` is `minos 14.0` (DXMT 0.80's is 15.0), so a DXMT/D3DMetal overlay raises a lower
  toolchain floor (REA L-62; decision 29); the closure floor is the highest `minos` of every other
  bundled Mach-O (MacPorts binary archives, see Prerequisites; recorded as `build.closureMinMacOS`).
  The extra keys (`components`, `build`, `licenses`, per-renderer `requires`/`minMacOS`) are the
  packaging record; `ossover engine install` drops them when it re-saves the manifest.
  `SHA256SUMS`, `out/<id>.tar.xz` + `out/<id>.tar.xz.sha256`. The `source`
  block is always present with `extract: {strip: 1, into: "."}` (the tarball is `<id>/…`); inside
  the tarball `sha256` is `TBD` (it cannot know its own hash), the out-dir copy gets the real hash
  and size after the tar. `ossover engine validate-manifest <file> [--layout]` (hidden subcommand)
  decodes a manifest with the Swift model; `gates.sh manifest` calls it when `OSSOVER_BIN` or
  `PATH` has an `ossover`.

Log: `work/logs/package.log`. `--no-tar`, `--no-sign`, `--keep-tmp` for debugging.

### Gates (`gates.sh`)

`layout manifest sha256sums absolute_refs minos overlay_minos rpath_self_contained dlopen
macdrv_exports dllpath_prepend soname_strings i386_count ntdll_size winedmo_ffmpeg gst_plugins addons
overlays wine_version codesign weak_imports` — `gates.sh --list` prints them, `--only`/`--skip`
select, `--strict` makes WARN fatal. `dlopen` and `wine_version` need Rosetta and WARN-skip without
it. The `dlopen` sweep compiles a tiny x86_64 C helper on the fly, preloads `ntdll.so` and
`win32u.so` (Wine's unix modules resolve their symbols through the flat namespace) and loads
everything else with `RTLD_NOW` and no `DYLD_*` help; flat-namespace lookup failures are reported
separately from real relocation failures.

- `rpath_self_contained` (REA L-12, L-64; decision 28): for every Mach-O, each `@rpath/` and
  `@loader_path/` dependency must resolve from that image's own `LC_RPATH`s and location; an
  `@executable_path/` dependency or a colon-joined rpath fails. Structural, needs no Rosetta — the
  `dlopen` sweep would let an overlay `winemetal.so` with broken rpaths through because
  `winemac.so` is already loaded by the time it is retried, exactly the accident CrossOver relies on.
- `overlay_minos` (REA L-62, L-78; decision 29): every Mach-O under `overlays/` is `minos <= 14`
  and, while a DXMT/D3DMetal overlay with Mach-Os is present, the manifest's `minMacOS` is `>= 14.0`
  and at or above each overlay's measured floor; a per-renderer `minMacOS` in the manifest must
  equal the measured value.
- `manifest`: the `EngineManifest` shape (see above) — `source.extract` is `{strip: 1, into: "."}`,
  `paths` has only the model's keys, `capabilities.esync` is false, no `DYLD_*` row in `baseEnv`,
  every bundled renderer has `kind`/relative `path`/`layout`/`builtinMarked`; then the Swift decoder
  itself when `OSSOVER_BIN=<path to ossover>` is set or `ossover` is on `PATH`.

### Self-test (`selftest.sh`)

`./engine/selftest.sh` (≈10 s, needs only clang/otool/python3) builds a synthetic engine tree of
tiny Mach-Os, proves the untreated overlay `winemetal.so` fails `rpath_self_contained` (REA L-64),
applies the rpath policy extracted from `package.sh` by function name, checks every location's
rpath set, writes the manifest with `manifest.py`, runs the offline gates (`manifest sha256sums
absolute_refs minos overlay_minos rpath_self_contained`) and the negative cases (`minMacOS 13.0`,
an overlay module built for macOS 15, the pre-REA manifest shape). With `OSSOVER_BIN` set it also
runs `ossover engine validate-manifest --layout`. `--write-fixture <path>` saves the generated
manifest; `Tests/Fixtures/manifests/package-sh-engine.json` is produced this way so the Swift
tests decode exactly what the packager writes.

## Installing the result

```sh
ossover engine install "engine/out/x64-ossover-cx26.3-r1/manifest.json"
```

The manifest's `source.url` is a `file://` URL to `engine/out/x64-ossover-cx26.3-r1.tar.xz`; the
installer verifies `source.sha256`, extracts `extract` (`<id>/`) into
`~/Library/Application Support/ossover/engines/<id>/`, strips `com.apple.quarantine`, and the
ad-hoc signatures are enough because ossover `exec`s the engine binaries directly (plan §5,
Gatekeeper note). To publish, copy `out/<id>/manifest.json` to `engines/<id>.json` and replace
`source.url` with the hosted tarball URL.

Runtime environment the manifest asks for (`baseEnv`, `${engine}` expanded by ossover):
`GST_PLUGIN_SYSTEM_PATH`, `GST_REGISTRY` (per-engine registry file), `GST_PLUGIN_SCANNER`. No
`DYLD_*` row: CrossOver never sets one, a hardened-runtime loader ignores them (REA L-54, L-73), and
the rpath rule plus the `rpath_self_contained`/`dlopen` gates make the tree load without them.

## Troubleshooting

- `configure: error: ... unsafe srcdir` / make errors with the repo path → whitespace in the path;
  `build.sh` handles it via `OSSOVER_BUILD_ROOT` (see above). Delete a stale `engine/work` symlink
  if you move the build root.
- `configure: error: FFmpeg 64-bit development files not found` → `PKG_CONFIG_LIBDIR` lacks
  `/opt/local/libexec/ffmpeg7/lib/pkgconfig` (fixed in `build.sh` 2026-10-14). A failed configure
  now prints its `configure: error:` line and the last checks; the full text is `work/build/config.log`.
- `package.sh` warns "N bundled Mach-O(s) are built for macOS 26.0" / manifest `minMacOS` is above
  15.0 → MacPorts binary archives; add `buildfromsource always` to `macports.conf`,
  `sudo port -N -s upgrade --force installed`, re-run `package.sh` (no Wine rebuild needed).
- `soname_strings` gate fails → a dlopen'd library got an absolute path at configure time; add an
  `ac_cv_lib_soname_<lib>=<bare name>` to `step_configure` in `build.sh` and re-run `--configure --build --install`.
- `dlopen` gate: "Library not loaded" → closure/relocation bug (check `work/logs/package.log` for the
  `+ lib` lines); "symbol not found in flat namespace" → a module needs another Wine module loaded
  first (WARN, expected for a few drivers).
- `ntdll_size` fails → `x86_64-w64-mingw32-strip` missing or `--no-strip` was used.
- `rpath_self_contained` fails → the named image lacks the rpath set for its location (a file in a
  directory `wanted_rpaths` in `package.sh` does not know?) or a `@loader_path/` dependency was not
  bundled; `install_name_tool` dying with "not enough space" on a third-party overlay module means
  it was linked without `-headerpad_max_install_names` — delete its malformed rpath first.
- `overlay_minos` fails → the manifest `minMacOS` is below an overlay's measured floor or a
  renderer's declared `minMacOS` disagrees with its Mach-Os. An overlay newer than 14.0 is a WARN
  (DXMT 0.80's `winemetal.so` is 15.0; `--strict` makes it a FAIL); re-decide the rule (decision
  29) rather than editing the manifest by hand.
- `manifest` fails on "Swift EngineManifest refused it" → the shape in `manifest.py` drifted from
  `Sources/OssoverKit/Model/EngineManifest.swift`; `ossover engine validate-manifest <file>` prints
  the offending key path.
- Wine's `--version` prints something other than `wine-11.*` → the tree is not the pinned 26.3.0
  tarball (its `VERSION` file says `Wine version 11.0`).
- ccache lives in `work/ccache` (`CCACHE_DIR` to move it); `CCACHE_MAXSIZE` defaults to 8G.

## Licensing

Wine and the patches: LGPL-2.1-or-later. Bundled: MoltenVK (Apache-2.0), DXMT 0.80 (MIT), DXVK
(zlib), wine-mono (mixed), wine-gecko (MPL-2.0), the MacPorts closure per library (freetype, gnutls,
GStreamer, FFmpeg, SDL2, glib, …; recorded in `manifest.json` → `components`). D3DMetal is never
bundled. "CrossOver" is a CodeWeavers trademark; this is a build from their published LGPL sources,
not CrossOver.
