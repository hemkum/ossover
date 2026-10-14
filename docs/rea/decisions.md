# ossover — decisions fed by the CrossOver 26.3.0 REA pass

Concrete changes (and confirmations) for the ossover code and engine design, each pointing at the
`ledger.md` row that justifies it. "Confirmed" means the current code already does what the evidence
supports; "Change" means the code or design must move. Status vocabulary and authority as in `ledger.md`;
anything marked *inferred* there stays a working assumption here. Verification pass (2026-10-13): items 6, 12,
14, 15, 16, 20, 21, 23, 24, 36, 37 rewritten and item 39 added after checking the decisions against the
current `Sources/`, `recipes/`, `engine/` and `renderers/` files; no code or recipe was changed by that pass —
every "Change" below is still to do.

## WineEnvironment (`Sources/OssoverKit/Wine/WineEnvironment.swift`)

1. **Change — drop `DYLD_FALLBACK_LIBRARY_PATH` / `DYLD_FALLBACK_FRAMEWORK_PATH`** from
   `rendererVariables(.d3dmetal)` and `frameworkVariables`. CrossOver never sets `DYLD_*` (0 hits in every
   plain-text file), its hardened-runtime loaders lack `cs.allow-dyld-environment-variables` so dyld would ignore
   them anyway, and D3DMetal is found through `libd3dshared.dylib`'s own `LC_RPATH @loader_path`. Keeping the rows
   would make the env table depend on whether the engine is ad-hoc or Developer-ID signed. → L-54, L-73, L-74.
2. **Confirmed — `CX_APPLEGPTK_LIBD3DSHARED_PATH=<pack>/external/libd3dshared.dylib`** (absolute path; the
   LGPL `init_non_native_support` reads it verbatim, needs macOS ≥ 14, has no fallback). Remove the `TODO(REA)`.
   **Change**: export it whenever an accepted GPTK pack exists on a CX-derived engine, for every process of the
   bottle, not only when `renderer == .d3dmetal` — CrossOver sets it "regardless of whether D3DMetal is enabled"
   (`wine:679-684`), it only drives Rosetta non-native-region registration. → L-53, L-55, L-57.
3. **Confirmed — `CX_ACTIVE_GRAPHICS_BACKEND=<renderer kind>` on CX-derived engines** with the values
   `wined3d|dxvk|dxmt|d3dmetal` (readers in `win32u/vulkan.c:3005-3011` and `win32u/d3dkmt.c:716-729`; the same
   literals sit in `cxcompatdb.so`). Remove the `TODO(REA)`. Do **not** emulate `CX_GRAPHICS_BACKEND`; nothing
   in Wine reads it. → L-17, L-18, L-19.
4. **Change — `syncVariables`**: on engines with `capabilities.esync == false` (every CX-derived engine; esync is
   not compiled into the 26.3.0 tree) emit `WINEMSYNC=1|0` only and no `WINEESYNC` row at all. Keep the explicit
   `WINEMSYNC=0` for `sync=none` (equivalent to unset, documents intent). The Whisky "set both =1" pattern is
   not CX practice. → L-30, L-32.
5. **Change — delete `PYTHONPATH`** from the environment handed to Wine if the process env is built on top of the
   parent's (CX deletes it unconditionally); make sure the golden table has no `PYTHONPATH` row. Do **not** copy
   CX's wipe of `WINEDLLOVERRIDES`/`CX_WINDOWS_VERSION`: the bottle's `dllOverrides` must survive. → L-05.
6. **Confirmed** — `ROSETTA_ADVERTISE_AVX` is `1` or absent, never `0` (L-06); `DOTNET_EnableWriteXorExecute=0`
   always (L-07); `WINEDEBUG` default `fixme-all`, bench `-all`, renderer verification `+loaddll` (L-09); no
   `WINEWRAPPER` (L-10). **Change — `WINESERVER` / `WINELOADER` rows**: `WineEnvironment.make` sets neither today
   (the only setter is `Winetricks.environment`, `Winetricks.swift:54-58`); launches rely on Wine deriving
   `bin_dir` from `dll_dir` (L-50) and on the loader exporting `WINELOADER` itself, so the log header and the
   golden env table do not contain the rows the earlier wording claimed. Add two fixed rows
   (`WINESERVER=<engine>/bin/wineserver`, `WINELOADER=<engine>/bin/wine`, before the bottle env) so relocated or
   symlinked engines and the allowlisted log header are deterministic, and add them to the golden table.
   → L-10, L-50.
7. **Change — GStreamer rows**: `GST_PLUGIN_SYSTEM_PATH=<engine>/lib/gstreamer-1.0` and a **per-engine**
   `GST_REGISTRY=<OSSOVER_HOME>/cache/gstreamer-registry-<engineId>.x86_64.bin` (CX uses one per-user file
   because it has one engine; two engines sharing a registry would poison each other). → L-08.
8. **Label — `LC_ALL=en_US.UTF-8`** is an ossover choice, not CX parity (CX sets `LC_ALL` only per app, through
   the registry under a locale condition). Keep it, mark the golden-test row "ossover-specific", and let recipes
   use the registry pattern (`HKCU\Software\Wine\LC_ALL`) for per-app locales. → L-14, L-69.
9. **Confirmed — DXMT rows** `DXMT_LOG_PATH`, `DXMT_LOG_LEVEL`, optional `DXMT_CONFIG`, and
   `DXMT_ENABLE_NVEXT` for `dlssMetalFX`: all four names are strings in the DXMT PE DLLs (`d3d11.dll`,
   `dxgi.dll`); `winemetal.so` reads none, so they belong in the Wine process env exactly as now. `D3DM_ENABLE_METALFX`
   is likewise a confirmed D3DMetal string; its effect is unverified. → L-58, L-59.
10. **Optional** — `CX_ROOT=<engine>` on CX-derived engines (`winemac.so` reads it for icon lookup; effect of
    leaving it unset is unknown, U-11). Leave unset until a visible defect appears. → L-15.
11. **Confirmed** — merge order engine `baseEnv` → fixed rows → bottle env → program env → extra is compatible
    with CX's global < user < bottle < launcher < `--env` precedence. → L-03.

## Renderer overlay (`RendererSelection.swift`, `RendererMaterializer.swift`, `PEBuiltinMark.swift`)

12. **Change — strategy B semantics (corrected)**: `WINEDLLPATH` can never shadow a builtin the engine's own
    `lib/wine` already ships — `dll_paths[0]` is always `dll_dir` and `WINEDLLPATH` components follow (L-20,
    `src:loader.c:387-408`). A builtin-**marked** file in `system32` does not help either: `load_builtin`
    (`loader.c:1655-1658`) turns a `wine_builtin` image into `LO_BUILTIN_NATIVE` and `find_builtin_dll`
    (`loader.c:1595-1632`) then walks `dll_paths` from `dll_dir`, pairing the PE and its `.so` from the **same**
    entry. The earlier plan of copying the pack's `winemetal.dll` "mark kept" was therefore a no-op redirect to
    the engine's `lib/wine/x86_64-windows/winemetal.dll` + `x86_64-unix/winemetal.so`. On the bootstrap engine
    both exist (`engines/x64-frankea-….json` notes: `winemetal.dll` in both PE dirs, `winemetal.so` "differs from
    the 0.80 release's"). Real strategy-B outcome: the pack's `d3d11`/`dxgi`/`d3d10core` (mark stripped, native,
    `n,b`) run against the **engine's** winemetal pair — an ABI coupling that must be stated and gated.
    Rules: (a) strategy B copies only `d3d11.dll`, `dxgi.dll`, `d3d10core.dll` (and the `i386-windows` half) with
    the mark stripped; never `winemetal.dll`, never `nvapi64`/`nvngx`; (b) `WINEDLLPATH+=<overlay>` is kept only
    for names absent from the engine's `lib/wine` (nothing on CX-derived engines, which ship
    `winemetal.{dll,so}`); (c) new gate in `RendererMaterializer.unmet` (mirrored in `RendererResolver.unmet`):
    refuse strategy B unless `engine.manifest.bundledRenderer(.dxmt)?.version == pack.version` (or, stricter, the
    engine's `lib/wine/x86_64-unix/winemetal.so` sha256 equals the pack's `x86_64-unix/winemetal.so`), reason
    "strategy B runs the pack's D3D DLLs against the engine's winemetal; versions differ"; (d) the preferred
    strategy-B pack is the engine-bundled one (`RendererResolver.pack(of:engine:packs:)` already ranks it first)
    once decision 16 makes it resolvable; (e) the `winemetal.dll` presence check prescribed by the old wording
    is dropped. On the frankea engine the version gate passes (`0.80` = `0.80`) while the `winemetal.so` bytes
    differ: whether frankea's `winemetal.so` build is ABI-compatible with the 0.80 release's PE DLLs is **U-20**,
    the blocking unknown for strategy B there. Rewrite the doc comments at `RendererMaterializer.swift:84-95`
    and `PEBuiltinMark.swift:11-16`, which encode the old model. → L-20, L-24, L-25, U-20.
13. **Confirmed — strategy C** (`WINEDLLPATH_PREPEND`, patch `0003`) is the open equivalent of what CrossOver
    gets from `prepend_dll_path()` called by `cxcompatdb.so`; it is the preferred mechanism on the ossover engine
    and the only prefix-neutral one (CX itself stopped copying renderer DLLs into prefixes at CX 24). → L-20,
    L-21, L-26.
14. **Change — d3dmetal overlay layout and activation**: the GPTK pack keeps `external/{libd3dshared.dylib,
    D3DMetal.framework}` and `wine/x86_64-{unix,windows}` **with the six `x86_64-unix/*.so →
    ../../external/libd3dshared.dylib` symlinks** recreated; `renderer import-gptk` copies verbatim and verifies
    `anchor apple`, never re-signs, strips or rewrites install names. Activation = overlay prepended (strategy C)
    + `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` + `CX_APPLEGPTK_LIBD3DSHARED_PATH`; nothing else is required by
    evidence. **D3DMetal additionally requires `capabilities.dllPathPrepend`** (strategy C) on top of
    `d3dmetalHost`: there is no environment-only activation. `RendererResolver.strategy(for: .d3dmetal)` returns
    `.none` on engines without `dllPathPrepend` (`RendererSelection.swift:118-123`) on the claim that "the CX
    tree's own fake D3DMetal DLLs (CW HACK 22435) take over once libd3dshared is loaded"; the evidence
    contradicts it — `wine.inf:739-742` registers only `atidxx64`/`nvapi64`/`nvngx` as fake DLLs, the only LGPL
    modules referencing `libd3dshared` are `dlls/ntdll/unix/loader.c` and `unix_private.h` (the
    non-native-region hook, not D3D forwarding, L-53), and `dll_dir` is always searched first (L-20). On the
    bootstrap engine (`d3dmetalHost=true`, `dllPathPrepend=false`) `renderer d3dmetal` therefore materialises
    nothing, Wine loads wined3d's `d3d11`/`dxgi`/`d3d12`, yet the process gets
    `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` (flipping the `d3dkmt` WDDM 2.7 HwSch caps, L-19) and `libd3dshared`
    — a silently broken configuration whose log header says "d3dmetal". Code: `strategy(.d3dmetal)` returns
    `.prepend` only; `RendererMaterializer.unmet` and `RendererResolver.unmet` add "D3DMetal needs
    WINEDLLPATH_PREPEND (engine patch 0003; capability dllPathPrepend)" when it is missing; delete the
    `OverlayStrategy.none` doc-comment clause "activated by environment alone" (`RendererSelection.swift:9-10`)
    and the CW HACK 22435 comment (`:119-121`); remove the `TODO(REA)` at `RendererSelection.swift:122`. → L-20,
    L-53, L-55, L-63, L-75.
15. **Confirmed — `PEBuiltinMark`** models the mark correctly (17 bytes at DOS-stub offset `0x40`; CrossOver's
    overlay PEs carry it and start with `MZ` at offset 0). **Change**: `keepMarked = ["winemetal.dll"]`
    (`RendererMaterializer.swift:95`) loses its justification with decision 12 — `winemetal.dll` is never copied
    under strategy B, so the set becomes empty (or the constant goes away) and every strategy-B copy is stripped.
    → L-25.
16. **Change — overlay layout: one shape, the Swift side moves**. On disk the engine keeps the CX-mirroring
    **bare** overlay root `overlays/<kind>/{x86_64-unix,x86_64-windows,i386-windows}` (what
    `engine/package.sh:23,367-371` already produces; CX's `lib/<backend>/…`, L-23). The Swift model expects
    `<pack>/wine/{arch}` instead: `RendererPack.wineDir` is `<root>/wine` (`RendererPack.swift:188`),
    `RendererResolver.packRoot(containing:)` accepts only `root/wine/x86_64-windows` or a directory literally
    named `wine` (`RendererSelection.swift:233-240`), and `BundledRenderer` decodes `layout`, not the
    `dirs`/`requires` keys `package.sh:613-625` emits. Net effect today: `bundledPacks` returns nil for the
    ossover engine's own DXMT, and even if resolved, strategy C's `dllPath` would be `overlays/dxmt/wine`, which
    does not exist. Fixes: (a) `RendererPack` accepts a bare root — `wineDir = root` when `root/x86_64-windows`
    exists, else `root/wine` (installed packs extracted with `"into": "wine"` keep the nested shape); (b)
    `packRoot(containing:)` learns the bare shape; (c) `package.sh` emits `layout: {unix, pe, pe32}` (file names,
    as `renderers/dxmt-0.80.json` does) instead of `dirs`, keeping `requires`; (d) for bundles in Whisky's
    `DXMT/{x64,x32}` shape (frankea) the engine store materialises `overlays/dxmt/{x86_64-windows ← x64,
    i386-windows ← x32}` at install so the engine-bundled pack resolves (needed by decision 12(d)). DXMT file
    set: `x86_64-unix/winemetal.so`, `x86_64-windows/{d3d10core,d3d11,dxgi,winemetal,nvapi64,nvngx}.dll`,
    `i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll` — the 0.80 asset's `tar tzf` is already recorded in
    `renderers/dxmt-0.80.json` notes[0] and the frankea manifest, so **U-13 is closed**; delete the `TODO(REA)`s
    at `RendererSelection.swift:91` and `RendererPack.swift:36` (`pe32` stays optional for packs without a
    32-bit half). → L-23, L-65.
17. **Confirmed — `EngineCapabilities.macdrvExports` and `gates.sh macdrv_exports`** are the right ABI gate:
    DXMT's `winemetal.so` does `dlsym(RTLD_DEFAULT, "macdrv_functions")` and reads slots 1, 2, 6, 7, 8 of the
    24-entry table (`d3dmetal.c:39-66`), with per-name `dlsym` fallback; it binds nothing else from `winemac.so`.
    → L-60, L-61.
18. **Change — bottle importer** (when CX-bottle import lands): map `CX_GRAPHICS_BACKEND` (`auto|wined3d|dxvk|
    dxmt|d3dmetal`), legacy `WINEDXVK=1` → `dxvk`, `WINED3DMETAL=1`/`D3DMetal=1` → `d3dmetal` (dxvk wins a tie),
    `WINEESYNC=1` → `WINEMSYNC=1`; never treat `CX_ACTIVE_GRAPHICS_BACKEND` as a setting. → L-17, L-18, L-36,
    L-70.
39. **Change — no renderer-specific `WINEDLLOVERRIDES` under strategy C** (numbered out of sequence to keep the
    earlier references stable; settles the ⟂REA at `RendererSelection.swift:107` and
    `RendererStore.swift:408-410`). Evidence: the Perl launcher deletes `WINEDLLOVERRIDES` and never sets a
    renderer override (L-05, `wine:716-717`); the DXVK CrossTie sets only `CX_GRAPHICS_BACKEND` (SH-TT-82); since
    CX 24 selection is purely by Unix DLL path (L-26) — CX uses no DLL override for any backend. Under strategy C
    the builtin-marked overlay DLLs win by path (L-20), so an override is neither needed nor CX practice; `n,b`
    is needed only under strategy B for the mark-stripped prefix copies (native file in `system32`:
    `load_builtin` → `LO_NATIVE_BUILTIN` → `STATUS_IMAGE_ALREADY_LOADED`, `src:loader.c:1672-1674`). Code: the
    two sites disagree today — `RendererResolver.defaultOverrides(.d3dmetal)` returns `[]` while
    `RendererStore.importGPTK` writes `d3d11,d3d12,dxgi=n,b` into every imported pack manifest through
    `d3dOverrides(pe:)`. Set d3dmetal overrides to `[]` in both; apply `defaultOverrides` / manifest `overrides`
    (and `d3dOverrides(pe:)`) only when the selection's strategy is `.prefixCopy`; remove both `TODO(REA)`
    comments. → L-05, L-20, L-26.

## Sync (`BottleSettings`, `WineServer`/`WineRunner`)

19. **Change — one `WINEMSYNC` per prefix lifetime**: `wineserver`, `wineboot`, `winecfg`, `reg`, winetricks and
    every program must receive the same `WINEMSYNC` (client/server mismatch is `exit(1)` in `msync_init`;
    `wineserver` reads the variable too). Editing `settings.sync` must trigger `wineserver -k` → `wineserver -w`
    before the next launch. → L-30, L-31.
20. **Decide — default `sync` (implementable rule)**: `msync` for **every** bottle on engines with
    `capabilities.msync`; `none` only where the engine lacks it (`WineEnvironment.effectiveSync` already
    downgrades). The model has no game/non-game distinction (`BottleSettings()` defaults every bottle to `.msync`,
    `BottleSettings.swift:92`; no bottle `kind` field), so the earlier "game bottles / `none` elsewhere" qualifier
    is dropped. Record that CrossOver's fresh-bottle default is **off** (GUI toggle) and that CX turns it on for
    every Steam install through the "Enable MSync" tie, so this is a deliberate divergence: `bottle create`
    surfaces CX's warning "Some Windows applications will not work correctly with MSync enabled." (SH-TT-61) and
    recipes override per workload (`steam.json`, `witcher3.json`). This reconciles `engine/patches/README.md`
    (msync by default) with `bottle-format.md` §6 (none). → L-30, L-33, L-34.
21. **Change** — `recipes/witcher3.json` uses `sync=msync` (confirmed); `recipes/steam.json` does **not**: it sets
    `sync: none` with a note arguing msync causes Steam login stalls — the opposite of what CX does (MSync on for
    every Steam install, L-34) — and the ledger holds no evidence for the stall claim; the recipe's own
    `knownIssues` attributes the login hang to llvm-mingw-built `kernelbase.dll`, not to msync. Set `steam.json`
    to `sync: msync` (CX parity, L-34). If the stall claim is kept instead, record its evidence (engine,
    reproduction) in the recipe note and in `unknowns.md` — one or the other, not a recipe that contradicts the
    ledger. `WINEMSYNC_QLIMIT` is an engine-level advanced knob only; `capabilities.esync=false` on CX-derived
    manifests. → L-32, L-34, L-35.

## Prefix init and registry (`RecipeEngine`, `.reg` batch)

22. **Change — High Resolution Mode**: write `HKCU\Software\Wine\Mac Driver\RetinaMode="y"` on the **global**
    key (the driver reads it with `appkey == NULL` and only once per process at `macdrv_init`), never under
    `AppDefaults`; write `HKCU\Control Panel\Desktop\LogPixels=<dpi>` (winecfg's key; `wine.inf` seeds the
    `HKCC` fallback with 96). Require a `wineserver` restart after the change, as CX's "Reboot Bottle and Enable
    High Resolution Mode" does. The 192-dpi value for "High Resolution Mode" is an analyst assumption (U-6).
    → L-40.
23. **Closed — `CaptureDisplaysForFullscreen`**: the value name is confirmed from source — `winemac.drv` reads it
    with `get_config_key(hkey, appkey, "CaptureDisplaysForFullscreen", …)` and `IS_OPTION_TRUE`
    (`src:dlls/winemac.drv/macdrv_main.c:326-327`; `hkey` = `HKCU\Software\Wine\Mac Driver`, `appkey` the
    per-app `AppDefaults\<exe>\Mac Driver`, `:250-276`, `:291-307`). `Prefix.registryEntries`' string `y`/`n`
    under `Mac Driver` (`Prefix.swift:80`) is right; U-7 is resolved. → L-41.
24. **Change — registry defaults from `crossover.inf`**: `winecfg -v win10` on the CX tree writes
    `CurrentBuild(Number)=19045`, `CurrentVersion=6.3`, major/minor 10/0, "Windows 10 Pro", **and** `UBR=5796` and
    `ProductOptions\ProductType="WinNT"` (`src:programs/winecfg/appdefaults.c:54`, `454-466`); the inf's
    `[VersionInfo10]` (`inf:317-327`) adds nothing beyond `CurrentType="Multiprocessor Free"` (and
    `OS=Windows_NT`, which stock `wine.inf` seeds anyway — not re-verified), so nothing version-related is copied.
    The `[WineSettingsReg]` subset listed before was CX configuration copied without a reader: drop
    `HKCU\Software\Wine\Systray\Hidden=1` (no reader in the 26.3.0 tree — grep of `programs/` and `dlls/` finds
    only winex11 `SystrayDock*` vtable names) and `X11 Driver\ShowSystray=false` (the only `ShowSystray` reader is
    `HKCU\Software\Wine\Explorer[\Desktops\<name>]\ShowSystray`, `src:programs/explorer/desktop.c:959-973`). If
    a hidden tray is wanted as an ossover choice, write `HKCU\Software\Wine\Explorer\ShowSystray=dword:0` and cite
    `desktop.c:968-970`. Keep `Direct3D\cb_access_map_w=1` only as a **labelled wined3d-fallback knob**
    (`src:dlls/wined3d/wined3d_main.c:483-486`; inert under DXMT/D3DMetal). → L-38.
25. **Change — `bottle.json.engineStamp`**: stamp engine id + version at creation and re-run the idempotent init
    steps when it changes (CX's `BuildTimestamp` ≠ `[Bottle] Timestamp` trigger). → L-42.
26. **Confirmed** — 64-bit bottles only, no template files, single init path parameterised by
    `windowsVersion × arch`. → L-39, L-43.

## Engine build and packaging (`engine/`)

27. **Confirmed — base and patches**: `crossover-sources-26.3.0.tar.gz` (sha `ac99c8ca…`) is complete for the
    unix side (290/290 `ntdll.so` and 3/3 `winemac.so` exports have definitions; shipped fork string
    `wine-11.0-8726-g2e2f5fca349`); patches `0001`/`0003`/`0014` dry-run cleanly (`0003` at `loader.c:387`,
    offset −209). → L-45, L-46, L-47.
28. **Change — rpath rule in `package.sh` + a gate**: every unix `.so` and `lib/*.dylib` carries its own
    `@loader_path/` and `@loader_path/../../../lib`-style rpaths; nothing may depend on the loader executable's
    rpath (CrossOver's `wineloader` rpath is dead and everything still resolves through the `.so` rpaths). The
    overlay `winemetal.so` ossover ships must have sane rpaths (CX's is malformed and only works by accident).
    → L-12, L-64.
29. **Change — `minMacOS`**: 14.0 whenever a DXMT or D3DMetal overlay is active (`winemetal.so`,
    `libd3dshared.dylib`, `D3DMetal` are all `minos 14.0`); the plain engine floor stays at the toolchain's. Add
    this to `gates.sh minos` per overlay. → L-62, L-78.
30. **Confirmed** — single `wine` loader, no preloader; `--prefix` is baked only as relative-path seeds, so the
    tarball is relocatable; mono 10.4.1 / gecko 2.47.4 pins match CX; `MACOSX_DEPLOYMENT_TARGET=15.0` is above
    CX's 10.15 floor and fine. → L-49, L-50, L-51, L-52.
31. **Keep on record — alternative hook**: an *open* ossover `cxcompatdb.so` placed in
    `<engine>/lib/wine/x86_64-unix/` would be dlopened by an **unpatched** tarball build (`start_main_thread`,
    fixed filename, `RTLD_LAZY|RTLD_LOCAL`, failure is only a WARN) and could call the exported `prepend_dll_path`
    itself. Not needed while patch `0003` is carried. → L-21.
32. **Change — DXMT/MoltenVK pins**: keep DXMT 0.80 and MoltenVK 1.4.2 (newer than CX's 0.72-25 / 1.2.10) but
    treat them as gated capabilities, not CX parity; the MoltenVK dylib must be reachable through the `.so`
    rpaths (`win32u.so` dlopens the ICD, `winevulkan.so` does not). → L-29, L-49.

## Signing and distribution

33. **Confirmed — v1 ad-hoc, v2 Developer ID** with hardened runtime on `wine`/`wineserver` and exactly
    `cs.allow-unsigned-executable-memory`, `cs.disable-executable-page-protection`,
    `cs.disable-library-validation`, `device.audio-input`, `device.camera`; GUI adds `automation.apple-events`;
    libraries get no entitlements. Never add `cs.allow-jit` or `cs.allow-dyld-environment-variables`; add
    `get-task-allow` only to dev builds used for REA runtime capture. → L-73, L-74, L-76.
34. **Confirmed** — GPTK files stay byte-identical and Apple-signed; notarize + staple the app (v2). → L-75,
    L-77.

## Recipes and benchmark

35. **Change — benchmark matrix**: add a `renderer=dxvk` variant for Witcher 3 (CodeWeavers' own CrossTie for
    the title selects DXVK via `CX_GRAPHICS_BACKEND=dxvk`; "Auto" for 292030 is unknown, U-1). DXMT stays the
    recipe default. → L-28, L-68.
36. **Change — `recipes/steam.json`**: the CX Steam tie (L-69) yields deps corefonts + VC++ latest x64/x86 +
    d3dcompiler_47 (both bitnesses) + MSync, and `installerenvironment WINE_WAIT_CHILD_PIPE_IGNORE=steam.exe`
    (`crossover.tie:16493`, `16500-16503`). The shipped recipe has none of these: no `winetricks` step, no
    `WINE_WAIT_CHILD_PIPE_IGNORE`, `sync: none` (decision 21). Add `{"type":"winetricks","verbs":["corefonts",
    "vcrun2022","d3dcompiler_47"]}` (vcrun2022 installs both bitnesses — the closest open equivalent of the tie's
    x64+x86 "latest" pair), `sync: msync`, and `{"type":"env","name":"WINE_WAIT_CHILD_PIPE_IGNORE",
    "value":"steam.exe","scope":"bottle","when":{"engine":{"capabilities":["msync"]}}}` — which needs the `when`
    clause to grow an engine-capability predicate (today it is platform/locale only; decision 37). The variable's
    readers are in the CX tree's `ntdll` (`src:dlls/ntdll/unix/server.c:1758-1776`, `process.c:477`, `2343`; no
    upstream reader is known — inferred); an engine with the CX sync stack (`msync`) is the available proxy for
    "CX-derived". `CEF_DISABLE_SANDBOX=1` and the global `LC_ALL` stay, labelled ossover-specific. → L-34, L-69.
37. **Confirmed** — recipes are CC0 JSON keyed by Steam app id and applied before launch; no in-process hook,
    no signature machinery (CX's compat DB is a signed `.dat` with Steam-game-id predicates, applied through
    `prepend_dll_path`/`add_load_order_override`/`WINEDLLOVERRIDES`). Add a `when` clause (platform/locale, plus
    an `engine.capabilities` all-of predicate so a step can be scoped to engines with e.g. `msync` — decision 36)
    and a `status/reports` field to `_schema.json`. → L-22, L-27, L-67.
38. **Confirmed** — bench HUD rows (`MTL_HUD_ENABLED`, `MTL_HUD_LOG_ENABLED`) are valid for D3DMetal too
    (`MTL_HUD_ENABLED` is a D3DMetal string). → L-58.

## Explicitly not carried over

* `winewrapper.exe` semantics beyond `--run` (no LGPL source) → reimplemented in `WineRunner`. → L-01, L-48.
* `cxcompatdb.so` behaviour (per-app command-line/env/DLL-override hacks, nvngx redirect) → recipes. → L-27,
  L-63.
* `CX_ALT_LOADER_SOCKET`, `SuppressAltLoader`, `CX_WINDOWS_VERSION`, `cxfixes.xml`, managed/stub bottles. → L-13,
  L-44, L-66, L-72.
