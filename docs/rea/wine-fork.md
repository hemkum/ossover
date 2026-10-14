# CrossOver 26.3.0 — Wine fork: shipped binaries (REA deep static pass)

Task: `ghidra-deep` (Phase 1, step 8 of the plan). Static only; nothing from the target trees was executed.
Provider: REA CLI `rea-agents@6.4.0` with Ghidra 12.1.4 (headless, JDK 21.0.12.1), run per binary with a
local `--snapshot`. Hopper was not used. All Ghidra addresses below are file offsets of the `__TEXT`
segment (vmaddr 0 == fileoff 0 for every target; confirmed by the Ghidra string addresses matching
byte offsets found with Python).

Legend used in every row: **observed** (the artifact says so) / **inferred** (analyst reading of
observed facts) / **unknown**. Authority: `shipped-artifact` (REA output or shell inspection of the
unzipped app), `historical-reference` (the CrossOver 26.3.0 source tarball at
`rea-targets/src/tree/sources`, read for behaviour only, cited as `file:line`), `analyst-inference`.
"REA" rows carry a REA Evidence ID; "shell" rows are plain `strings`/`nm`/`otool`/`objdump`/`codesign`
observations saved under `docs/rea/evidence/shell-*.txt`.

Scope kept: Ghidra decompilation only on the LGPL Wine unixlibs (`ntdll.so`, `winemac.so`) and the
open-source DXMT unixlib (`winemetal.so`). `cxcompatdb.so`, `libd3dshared.dylib` and `D3DMetal` were
inspected through headers, strings and signatures only (`inspect-macho`, `inspect-signature`,
`strings`, `otool`, `nm`); none of them was decompiled and nothing from them is copied here.

---

## Shipped binaries

### Identity

| Binary (under `Contents/SharedSupport/CrossOver/`) | SHA-256 | Size | Signing identifier / authority | REA IDs (macho, signature) |
|---|---|---|---|---|
| `lib/wine/x86_64-unix/ntdll.so` | `ab32585d767ae631154235861a2e0e8ea61bd09267a2dd341a439e3e8ed071fc` | 608,032 | `com.codeweavers.CrossOver.lib.ntdll_so`, Developer ID Application: CodeWeavers Inc. (9C6B7X7Z8E) | `ev_4a5a4ebd…929694`, `ev_620e7207…da848d` |
| `lib/wine/x86_64-unix/winemac.so` | `a46e1c63a5096210626d64ef6c62ddea7632f95dbcf437b1a3bf006d43dcf532` | 467,456 | (not re-checked; same CodeWeavers chain expected — **unknown**) | `ev_b62941e8…b4359` |
| `lib/wine/x86_64-unix/cxcompatdb.so` | `a423c706e424c81537f19c2c04691689dcab3dc8d005d3926e98c3ad1f4b1df7` | 116,976 | `com.codeweavers.CrossOver.lib.cxcompatdb_so`, CodeWeavers Developer ID | `ev_73fb4495…5963f`, `ev_a0bc0106…759d63` |
| `lib/dxmt/x86_64-unix/winemetal.so` | `df3c7b88696039768b4800b60067fe6bca1b6188cd8e294bc25058f4412c83b3` | 24,169,040 | `com.codeweavers.CrossOver.lib.winemetal_so`, CodeWeavers Developer ID | `ev_153f5788…5a2d7a78`, `ev_ace51ea4…3fb5697` |
| `lib64/apple_gptk/external/libd3dshared.dylib` | `5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995` | 95,952 | `com.apple.libd3dshared`, **Apple** "Software Signing" chain, no TeamIdentifier | `ev_b7c8967d…527d3b57`, `ev_a2a71be8…d025fbd` |
| `lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal` | `05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8` | 5,263,744 | `com.apple.D3DMetal`, **Apple** "Software Signing" chain, no TeamIdentifier | `ev_9e546d42…a3ff1e`, `ev_46204c3d…747a9bca` |

All six are thin x86_64 Mach-O (shell `file`). Build metadata (shell `otool -l`, `shell-*-otool-l.txt`):
`ntdll.so`/`winemac.so`/`cxcompatdb.so` minos 10.15 sdk 15.1; `winemetal.so` minos **14.0** sdk 15.1;
`libd3dshared.dylib` and `D3DMetal` minos 14.0 sdk **15.4** (D3DMetal `Info.plist`: `DTSDKName
macosx15.4.internal`, `LSMinimumSystemVersion 14.0`, `CFBundleShortVersionString 3.0`;
`version.plist`: `ProjectName D3DRendererMetal`, `SourceVersion 32047000000000`).

LC_RPATH / LC_ID_DYLIB (shell `otool -l`):

| Binary | LC_ID_DYLIB | LC_RPATH |
|---|---|---|
| ntdll.so, winemac.so | `@rpath/<name>.so` | `@loader_path/`, `@loader_path/../../../lib64` |
| cxcompatdb.so | `win64/cxcompatdb.so` (odd id; loaded by absolute path, see below) | none |
| winemetal.so | `@rpath/winemetal.so` | `@loader_path/:@loader_path/../../` (one entry containing a colon, as shipped) |
| libd3dshared.dylib | `@rpath/libd3dshared.dylib` | `@loader_path` |
| D3DMetal | `/System/Library/Frameworks/D3DMetal.framework/Versions/A/D3DMetal` | `@executable_path/../Frameworks`, `@loader_path/Frameworks`, `@loader_path/../Resources`, `@loader_path/Resources` |
| wineloader | – | `@loader_path/../../../lib64` |
| wineserver | – | `@loader_path/../lib64`, `@loader_path/../../../lib64` |

---

### ntdll.so (LGPL; full Ghidra pass)

The binary is stripped of local symbols: only 290 exported names survive (shell `nm -gU`, REA
`ev_4a5a4ebd…`). Static functions were located through string cross-references and are named below
by their Ghidra `FUN_` address plus the source function the behaviour matches
(`historical-reference`, `wine/dlls/ntdll/unix/*.c`).

#### Fork identity (feeds H5)

| # | Fact | Status | Location |
|---|---|---|---|
| N1 | Version/build string `wine-11.0-8726-g2e2f5fca349` is embedded (Ghidra merges it with the preceding hex-digit table into one defined string at `0x763d0`; the text proper starts at `0x763e0`). | observed (REA `ev_c611b9fd…ba30c0`; shell strings line 2117) | `ntdll.so` `0x763e0` |
| N2 | That string is referenced from `___wine_main` (`0x1fb90`, ref at `0x1fe80`: the `--version` path) and from `_NtQuerySystemInformation` (`0x52060`, refs at `0x5213a/0x52147/0x5215d`, the `%s%c%s%c%s%c%s` Wine-version information class). | observed (REA `ev_57ef14c4…582868`, `ev_e43631a5…9a0026d`) | `ntdll.so` |
| N3 | Reading: upstream Wine **11.0** tag plus 8,726 CodeWeavers commits (`git describe` form), head commit `2e2f5fca349`. | inferred (analyst) | – |
| N4 | CX-specific exports present in the unixlib that upstream ntdll.so does not have: `_prepend_dll_path` (`0x1def0`), `_add_load_order_override` (`0x24300`), `___wine_unix_spawnvp` (`0x25320`). The first two are the names `cxcompatdb.so` looks up by string. | observed (shell nm; REA `ev_9b1995ac…a572aa`) | `ntdll.so` export table |
| N5 | The `/opt/cxoffice` configure prefix is baked in: `init_paths` derives `bin_dir` and `data_dir` from `dll_dir` using the literals `/opt/cxoffice/bin`, `/opt/cxoffice/lib/wine`, `/opt/cxoffice/share/wine` (relative-path construction, so the macOS app layout `<CX>/lib/wine` → `<CX>/bin`, `<CX>/share/wine` still works). | observed (REA `ev_b34071a8…3aac7e9`, pseudocode lines 41–42; strings 2790/2817/2818) | `FUN_0001fea0` |
| N6 | Source tarball counterpart: `loader.c:475-491` (`init_paths`), `build_relative_path` at `loader.c:281`. | historical-reference | `sources/wine/dlls/ntdll/unix/loader.c` |

Decision fed (H5): the engine base is CX's `wine-11.0` branch, not vanilla 11.0; the three CX exports
in N4 are the ABI that the proprietary `cxcompatdb.so` depends on. ossover's own engine (Phase 4)
built from the tarball will reproduce them automatically; the bootstrap engine (Phase 2, if it reuses
CX unixlibs) must not expect vanilla-Wine symbol sets.

#### DLL search path: `set_dll_path` / `prepend_dll_path` / `WINEDLLPATH` (feeds H2)

| # | Fact | Status | Location |
|---|---|---|---|
| D1 | `WINEDLLPATH` (`0x79a43`) has exactly two code references: `0x2001b` inside `FUN_0001fea0` and `0x224ea` inside `FUN_000224d0`. The warning `%s found in WINEDLLPATH but not a builtin, ignoring` (`0x7f934`) is referenced from `FUN_000602f0` (virtual.c builtin mapping). | observed (REA `ev_e75e4ede…99abd6a`, `ev_e82a1d9d…6c546f`) | `ntdll.so` |
| D2 | `FUN_0001fea0` (`0x1fea0`–`0x2046b`, caller `___wine_main`) is `init_paths` with `set_dll_path` inlined: `dladdr` on itself → `realpath` → `ntdll_dir`; if the dir does **not** end in `/dlls/ntdll` (build-tree case) and ends in `/x86_64-unix`, `dll_dir` = parent; then `getenv("WINEDLLPATH")`; `dll_paths` is allocated as `count+2` entries; **entry 0 is `dll_dir`** (only when not in a build tree), followed by the `WINEDLLPATH` components split on `:` and `strdup`'d; `dll_path_maxlen` updated; then `HOME`, `USER`, `WINEPREFIX` are read (config dir). No other environment variable participates in the DLL path. | observed (REA `ev_b34071a8…3aac7e9`, pseudocode lines 21–140) | `FUN_0001fea0` |
| D3 | Answer to "does set_dll_path read anything besides WINEDLLPATH?": **no**. `WINEDLLPATH_PREPEND` does not exist in the binary (absent from both the `strings` dump and the Ghidra string inventory, regex `WINEDLLPATH` matched only the two strings in D1). | observed (REA `ev_c611b9fd…ba30c0`; shell grep) | – |
| D4 | `_prepend_dll_path` (`0x1def0`–`0x1df88`): counts the current `dll_paths` (global `DAT_000b0f98`), `calloc`s a new array with the argument at index 0 followed by the old entries, frees the old array, bumps `dll_path_maxlen` (`DAT_00087e50`). Ghidra callers: **none**; the only incoming reference is a DATA reference from `0xb52ed` (symbol/export table), i.e. nobody inside `ntdll.so` calls it. | observed (REA `ev_dfa5b837…0ab17800`, `ev_e1d68d36…f95ad8ee3`) | `0x1def0` |
| D5 | Source: `loader.c:365-385` (`/* CW Hack 24067 */`, `visibility("default")`), `set_dll_path` at `loader.c:387-408`. | historical-reference | `sources/wine/dlls/ntdll/unix/loader.c` |
| D6 | `FUN_000224d0` (`0x224d0`–`0x22789`, callers `FUN_0001e040`/`FUN_0001e160` = loader exec helpers) is `preloader_exec`: if `WINEDLLPATH` is set it creates a `/winetemp-…/` link or symlink named after the app, points `%s/ntdll.so` at it, sets `WINEPRELOADERAPPNAME`, then `execv`s. This is the Dock-name hack (`loader.c:662-684`, CW HACK 22144), not a DLL-path consumer. | observed (REA `ev_98210b09…376e206f`) + historical-reference | `FUN_000224d0` |
| D7 | `cxcompatdb.so` load site: `FUN_00020530` (`0x20530`, 23 body ranges, callers `___wine_main` and thunk `FUN_00023fe0`) is `start_main_thread`. Near its end it `asprintf`s `"%s/cxcompatdb.so"` with `ntdll_dir` (`DAT_00087e78`), `dlopen`s it with mode `5` (= `RTLD_LAZY\|RTLD_LOCAL`), and on failure logs `error loading cxcompatdb.so: %s` via the `WARN` channel (`FUN_0001e5b0(2, …, "start_main_thread", …)`). It runs **after** `load_ntdll`/`load_wow64_ntdll`/`load_apiset_dll` and the `localtime` hook, and **before** `server_init_process_done`. The path is fixed: the same directory as `ntdll.so`; no environment variable can redirect it. | observed (REA `ev_24ff438e…673f92f21`, pseudocode lines 1078–1087; `ev_8fb0bf40…9aea85`) | `FUN_00020530` @ `0x21f8e` |
| D8 | Source: `loader.c:2219-2262` (`start_main_thread`, `/* CW Hack 24067 */` block at 2246–2259). | historical-reference | `sources/wine/dlls/ntdll/unix/loader.c` |
| D9 | `cxcompatdb.so` does **not** import `_prepend_dll_path` or `_add_load_order_override` (its 54 undefined symbols are listed in `shell-cxcompatdb.so-nm-u.txt`; REA `ev_73fb4495…5963f` lists the same set); it imports `_dlsym`, `_getenv`, `_setenv` and carries the strings `prepend_dll_path`, `prepend_cx_root_dll_path`, `add_load_order_override`, `add_dll_overrides`, `couldn't get ntdll export`. | observed (shell; REA macho) | `cxcompatdb.so` strings 456–477 |
| D10 | Therefore `cxcompatdb.so` resolves `prepend_dll_path` at run time with `dlsym` and is the only caller; the call happens from inside `start_main_thread`'s `dlopen` (constructor / `compatdb_init`) or later from its process hooks. Which exact moment is **unknown** (no decompilation of `cxcompatdb.so`). | inferred | – |
| D11 | Renderer directories named in `cxcompatdb.so` strings, adjacent to `CX_GRAPHICS_BACKEND` / `set_graphics_backend` / `using %s as the graphics backend`: `lib/dxmt`, `lib/dxvk`, `lib/vkd3d-proton`, `lib64/apple_gptk/wine`, formatted with `%s/%s` after `CX_ROOT`. `CX_ACTIVE_GRAPHICS_BACKEND` with values `d3dmetal` / `dxmt` sits next to `redirect_nvngx_to_d3dmetal` and the path `\??\unix%s/lib64/apple_gptk/wine/x86_64-windows/nvngx.dll`. | observed (shell strings 255–263, 465–477) | `cxcompatdb.so` |
| D12 | Every renderer-overlay PE in the app carries the "Wine builtin DLL" marker (`lib/dxmt/x86_64-windows/{d3d11,dxgi,winemetal,nvngx}.dll`, `lib64/apple_gptk/wine/x86_64-windows/{d3d11,d3d12,nvngx}.dll`), so they pass the `virtual.c:3800` builtin check when found through `dll_paths`. | observed (shell strings) | – |
| D13 | `lib64/apple_gptk/wine/x86_64-unix/{atidxx64,d3d11,d3d12}.so` are symlinks to `../../external/libd3dshared.dylib`; the matching PE side is `lib64/apple_gptk/wine/x86_64-windows/{atidxx64,d3d11,d3d12,dxgi,nvapi64,nvngx}.dll`. `lib/wine/x86_64-windows/` still contains vanilla `d3d10core.dll, d3d11.dll, d3d12.dll, dxgi.dll`. | observed (shell ls) | – |

Decision fed (H2, overlay strategy): because `dll_paths[0]` is always `dll_dir` (`<engine>/lib/wine`)
and `WINEDLLPATH` entries come **after** it (D2), vanilla `d3d11.dll`/`dxgi.dll`/`d3d12.dll` in
`lib/wine/x86_64-windows` always win over anything placed in `WINEDLLPATH`. CrossOver gets the DXMT /
D3DMetal overlay in front only through `prepend_dll_path`, called from the proprietary
`cxcompatdb.so`. ossover options, in order of preference: (a) on its own engine (Phase 4) keep the
tiny LGPL hook and call it from an ossover-owned, open shim loaded the same way (or simply build the
chosen renderer's DLLs into `lib/wine` at engine-build time); (b) on any engine, override per bottle
with `WINEDLLOVERRIDES` plus copies of the renderer DLLs in the prefix `system32` (Whisky-style),
which bypasses `dll_paths` entirely; (c) do not rely on `WINEDLLPATH` for renderer selection.
`CX_ACTIVE_GRAPHICS_BACKEND` must still be exported (`d3dmetal` or `dxmt`) because `win32u` reads it
(`sources/wine/dlls/win32u/d3dkmt.c:719`, `vulkan.c:3007`, historical-reference).

#### Sync: msync (feeds H3)

| # | Fact | Status | Location |
|---|---|---|---|
| S1 | The only sync-selection environment variable in `ntdll.so` is `WINEMSYNC` (`0x7832f`). `WINEESYNC`, `WINEMSYNC_QLIMIT`, `WINEMSYNC_SPINS` are **absent** from the binary (strings dump and Ghidra inventory; esync is not compiled into this build). | observed (REA `ev_c611b9fd…ba30c0`; shell grep of 3,907 strings) | – |
| S2 | `FUN_0001c0b0` (`0x1c0b0`–`0x1c0ee`) is `do_msync`: cached in `DAT_00084ad4` (initial `-1`); `getenv("WINEMSYNC")` → value `atoi`'d → non-zero means on; unset or `0` means **off**. Callees: `_getenv`, `_atoi`. Fourteen callers, all sync primitives (`_NtQuerySemaphore`, `_NtQueryEvent`, `_NtReleaseMutant`, `_NtQueryMutant`, `_NtSignalAndWaitForSingleObject`, and nine unnamed `FUN_0004a080…FUN_000516c0`). | observed (REA `ev_25e10a54…3bb577aa61`, `ev_9f77a1be…14db3b8`) | `FUN_0001c0b0` |
| S3 | `FUN_0001c360` (`0x1c360`, called only from `start_main_thread` `FUN_00020530`) is `msync_init` with `do_msync` inlined: if msync is **off** it issues server request `0x129` (`get_inproc_alert_fd`) and, unless the server answers `STATUS_INVALID_PARAMETER` (`0xC000000D`), prints `Server is running with WINEMSYNC but this process is not…` and `exit(1)`. If msync is **on**: `stat` the config dir, build the Mach port name `wine-%lx-msync` from the prefix inode, `dlsym(RTLD_DEFAULT,"mach_msg2_trap")` (falls back to `mach_msg` with a warning), `task_get_special_port` + `bootstrap_look_up`, then `request_shm_from_server` (`FUN_0001c5f0`); any failure → `exit(1)`. | observed (REA `ev_4f0b7719…dca3ffab4`) | `FUN_0001c360` |
| S4 | Source: `msync.c:417-425` (`do_msync`), `msync.c:580-640` (`msync_init`), both `#ifdef __APPLE__`; the `WINEMSYNC_QLIMIT` knob lives only in the server (`server/msync.c:628`). | historical-reference | `sources/wine/dlls/ntdll/unix/msync.c`, `sources/wine/server/msync.c` |

Decision fed (H3, sync default): the engine's compiled-in default is msync **off**; nothing in
`ntdll.so` turns it on without `WINEMSYNC=1`. Because a client/server mismatch is fatal (S3), ossover
must set `WINEMSYNC` once per prefix launch (same value for `wineserver`, `wineboot` and every app) and
never change it while a `wineserver` for that prefix is alive. `WINEESYNC` is a no-op on this engine
and should not appear in the env table. `WINEMSYNC_QLIMIT` is a server-only knob (S4).

#### Non-native code regions: `init_non_native_support` (feeds H6)

| # | Fact | Status | Location |
|---|---|---|---|
| G1 | `CX_APPLEGPTK_LIBD3DSHARED_PATH` (`0x7a0a9`) is referenced once, at `0x2415c`, inside `FUN_00024150` (`0x24150`–`0x242e9`). The function name string `init_non_native_support` is referenced at `0x242a0`/`0x242c6` in the same function (TRACE header). | observed (REA `ev_77e6952d…c18994ad`, `ev_bd40c3d2…8085748`) | `FUN_00024150` |
| G2 | Pseudocode: `getenv("CX_APPLEGPTK_LIBD3DSHARED_PATH")`; both function-pointer globals reset to 0; proceed only if the variable is set **and** `uname` succeeds **and** the release parses as `%u.%u` with major `> 0x16` (i.e. Darwin ≥ 23, macOS 14); then `dlopen(path, 4)` (`RTLD_LOCAL`); on success `dlsym` `register_non_native_code_region` and `supports_non_native_code_regions`, `dladdr` on the latter to record the library base and `getsegmentdata(__TEXT)` to record its code end; TRACE `Loaded libd3dshared.dylib, does%s support non-native code regions`; on `dlopen` failure TRACE `Loading libd3dshared.dylib failed: %s`. | observed (REA `ev_b012b7fd…c368f865a`, pseudocode lines 15–54) | `FUN_00024150` |
| G3 | Answer to "fallback if the env var is unset?": **none**. The value is used verbatim as the `dlopen` argument; there is no path relative to `ntdll_dir`, no `@rpath`, no second candidate. Unset variable ⇒ the function returns before `dlopen`, leaving both pointers NULL, so `pe_module_loaded` never registers regions (`loader.c:1355-1366`). | observed + historical-reference | `FUN_00024150`; `loader.c:1321-1353` |
| G4 | Ghidra reports **no direct callers**: the function is reached through `pthread_once` from `pe_module_loaded` (`loader.c:1359`), a `__wine_unix_call` entry invoked after each PE module load; the TRACE `Marking non_native_code_region: %p-%p` (`0x7a082`) is in that caller. | observed (empty caller list) + historical-reference | – |
| G5 | What the env var points at in the shipped app: `libd3dshared.dylib` exports exactly those two symbols (`_register_non_native_code_region` `0x2440`, `_supports_non_native_code_regions` `0x2470`) plus `__Z18GetMacDRVFunctionsv`, `___wine_unix_call_funcs`, `SyncHelper::Instance`, `WineMonitor::MonitorEnumProc`, `Shared_nvapi_*`. | observed (shell nm; REA `ev_b7c8967d…527d3b57`) | `libd3dshared.dylib` |

Decision fed (H6, activation env): ossover must export `CX_APPLEGPTK_LIBD3DSHARED_PATH=<abs path to
libd3dshared.dylib>` for every process of a D3DMetal bottle; the variable is consumed by the LGPL
unixlib, so it survives an engine rebuild from the tarball. Without it D3DMetal still loads (through
the `d3d11.so`/`d3d12.so` symlinks, D13) but Rosetta non-native-region registration is skipped;
whether that is merely slower or breaks is **unknown** (runtime-only question).

#### Alternative loader hook (context for H1)

| # | Fact | Status | Location |
|---|---|---|---|
| L1 | `FUN_00026f00` (`0x26f00`, 5 ranges, single caller `_NtCreateUserProcess` `0x25610`) is `send_to_cx_loader`: `getenv("CX_ALT_LOADER_SOCKET")`; if unset, TRACE `…is not set; nothing to do` and return FALSE; else exe-name whitelist check (`\Rockstar Games\Launcher\Launcher.exe` is explicitly suppressed), registry keys `\Registry\User\S-1-5-21-0-0-0-1000\Software\CrossOver\{UseAltLoader,SuppressAltLoader}`, `unsetenv("CX_ALT_LOADER_SOCKET")`, AF_UNIX `socket`/`connect`, `sendmsg` with up to five fds (stdin/out/err, wineserver socket, `WINE_WAIT_CHILD_PIPE`). | observed (REA `ev_acfd2f1b…a9d9cd`, `ev_f98ea89c…f4942b36`) | `FUN_00026f00` |
| L2 | Source: `process.c:296-399` (`send_to_cx_loader`), call at `process.c:861-864` ("CrossOver Hack 10523"). | historical-reference | `sources/wine/dlls/ntdll/unix/process.c` |
| L3 | Other environment names present in `ntdll.so` (strings; not traced): `WINE_SIMULATE_WRITECOPY` (read in `start_main_thread`, `atoi`), `WINE_WAIT_CHILD_PIPE`, `WINE_WAIT_CHILD_PIPE_IGNORE`, `WINE_LARGE_ADDRESS_AWARE`, `WINE_HOST_` (prefix), `WINEPRELOADERAPPNAME`, `WINELOADERNOEXEC`, `WINEBOOTSTRAPMODE`, `__CX_UNIX_` (UTF-16 prefix), `DYLD_LIBRARY_PATH` (with the `%s/dlls/ntdll:%s/dlls/win32u` build-tree form), and the standard `WINEDEBUG`, `WINEDLLOVERRIDES`, `WINEPREFIX`, `WINESERVER`, `WINELOADER`, `WINEARCH`, `WINESERVERSOCKET`, `WINEPRELOADRESERVE`-family. | observed (shell strings) | `shell-ntdll-strings.txt` |

Decision fed (H1): `CX_ALT_LOADER_SOCKET` is a GUI-side feature (CrossOver's Launcher proxy); ossover
leaves it unset, which is the no-op path (L1).

---

### winemac.so (LGPL; Ghidra pass)

Exports (shell `nm -gU`; REA `ev_b62941e8…b4359`): `_macdrv_functions` (data, `0x610d0`),
`___wine_unix_call_funcs` (`0x55990`), `___wine_unix_call_wow64_funcs` (`0x559a0`). Imports include
`_dlopen`, `_dlsym`, `_getenv`, `_CGDirectDisplayCopyCurrentMetalDevice`, `OBJC_CLASS_$_CAMetalLayer`;
linked frameworks include `Metal`, `QuartzCore`, `AppKit` (shell `otool -L`).

#### `macdrv_functions` (D3DMetal ↔ driver table; feeds H6)

| # | Fact | Status | Location |
|---|---|---|---|
| M1 | `_macdrv_functions` occupies 192 bytes at `0x610d0`: 24 relocated pointers, decoded with REA `read-bytes` (Ghidra applies the rebase): `[0] 0x23750, [1] 0x23780, [2] 0x23880, [3] 0x238d0, [4] 0x23910, [5] 0x23940, [6] 0x23980, [7] 0x239c0, [8] 0x23a00, [9] 0x23a40, [10] 0x23a80, [11] 0x23b20, [12] 0x23bc0, [13] 0x23c60, [14] 0x23d00, [15] 0x23d60, [16] 0x23dc0, [17] 0x23ec0, [18] 0x23f40, [19] 0x23f90, [20] 0x24000, [21] 0x24080, [22] 0x24110, [23] 0x24150`. | observed (REA `ev_aff1cae8…404ad6bf6`) | `winemac.so` `0x610d0` |
| M2 | Slot 4 (`0x23910`) is a 39-byte function whose only strings are `my_macdrv_create_metal_device` / `macdrv_create_metal_device\n` (TRACE) before tail-calling `FUN_00022d70`; slot 6's TRACE strings `my_macdrv_view_create_metal_view` are referenced at `0x23996` (inside `0x23980`). This fixes the slot order as: `macdrv_init_display_devices, get_win_data, release_win_data, macdrv_get_cocoa_window, macdrv_create_metal_device, macdrv_release_metal_device, macdrv_view_create_metal_view, macdrv_view_get_metal_layer, macdrv_view_release_metal_view, on_main_thread, RegQueryValueExA, RegSetValueExA, RegOpenKeyExA, RegCreateKeyExA, RegCloseKey, EnumDisplayMonitors, GetMonitorInfoA, AdjustWindowRectEx, GetWindowLongPtrW, GetWindowRect, MoveWindow, SetWindowPos, GetSystemMetrics, SetWindowLongPtrW`. | observed (REA `ev_83bffb46…02f12c4`, `ev_307ca2e1…6771d9c7`, `ev_4ca3e596…b05e83ae`) + historical-reference (`d3dmetal.c:39-66`, `C_ASSERT == 192`, table at `d3dmetal.c:397-423`) | `winemac.so` |
| M3 | Nothing inside `winemac.so` references the table (xrefs to `0x610d0`: empty). It exists for `dlsym` consumers: `libd3dshared.dylib` (string `macdrv_functions` + `_dlsym` import + exported `GetMacDRVFunctions()`), and DXMT's `winemetal.so` (below). | observed (REA `ev_d9410021…92f913`; shell) | – |
| M4 | The file is `d3dmetal.c` ("Mac graphics driver hooks used by D3DMetal (part of the Apple Game Porting Toolkit)", CodeWeavers 2023, LGPL) compiled only for `__x86_64__`; the `d3dmetal_client_surface` view ivar (`0x4e30c`, ref `0x5ce90`) comes from `cocoa_window.m:379` (`CW HACK 22435`). | historical-reference + observed | `sources/wine/dlls/winemac.drv/d3dmetal.c`, `cocoa_window.m` |
| M5 | There is no "d3dmetal init" routine in `winemac.so`: slot 4 calls the ordinary Metal-device creation (`MTLCreateSystemDefaultDevice`/`CGDirectDisplayCopyCurrentMetalDevice` imports) and D3DMetal drives the rest through the table. | inferred from M1–M4 | – |

#### `RetinaMode` registry read (feeds H2/H8 settings)

| # | Fact | Status | Location |
|---|---|---|---|
| R1 | Option names are not stored as whole UTF-16 strings; the compiler emitted 16-byte SSE constants for the first eight WCHARs and inline immediates for the rest. `R·e·t·i·n·a·M·o` sits at `0x44a70` (preceded by `EnableAp` at `0x44a60`), so no Ghidra-defined string "RetinaMode" exists. | observed (Python scan; REA search found only the ObjC selectors `setRetinaMode:` `0x50968`, `setLayerRetinaProperties:` `0x50766`) | `winemac.so` `0x44a70` |
| R2 | `0x44a70` is referenced exactly once, at `0x2fb19`, inside `FUN_0002e460` (`0x2e460`–`0x2fdce`, caller `FUN_0002fde0`). That function's strings are `macdrv_init`, `setup_options`, `Software\Wine\Mac Driver`, `Software\Wine\AppDefaults`, `load_strings`: it is `macdrv_init` with `setup_options` inlined. | observed (REA `ev_4cb8677a…c2499d1bc`, `ev_c7f342cc…533af07e11`, `ev_c0a7195f…f73718318`) | `FUN_0002e460` |
| R3 | Shape of the reads: `FUN_0002d930("Software\\Wine\\Mac Driver")` opens the HKCU key; the per-app key is opened under `Software\Wine\AppDefaults\<exe>` only when an app name is known; each option does `RtlInitUnicodeString` + `NtQueryValueKey(…, KeyValuePartialInformation=2, buf, 0x800)` first on the app key then on the global key; a value is "true" when its first WCHAR is `Y`/`y`/`T`/`t`/`1` (the `0x2100000021 >> (c-0x54)` bit test seen for every boolean option). The last option read (pseudocode lines ~763–787) is the only one queried on the **global key alone** and its result is copied into a second global (`DAT_000626d8 = DAT_000626f0`), matching `retina_on = retina_enabled`. | observed (pseudocode) + historical-reference (`macdrv_main.c:392-397`: `RetinaMode` is read with `appkey == NULL` on purpose) | `FUN_0002e460` |
| R4 | `FUN_000251e0` (`0x251e0`, callers `FUN_000245b0`, `FUN_000249d0`) writes `\Registry\Machine\Software\Wine\Mac Driver\Initial Display Mode\Display 0x%08x` with `PixelEncoding`/`PixelWidth`/`PixelHeight` etc. via `NtSetValueKey` from `CGDisplayCopyDisplayMode` data (display.c initial-mode cache). | observed (REA `ev_49a29c54…fcc285b6`, `ev_04c9bbcf…cec0af92`, `ev_955cbad9…0999b9e`) | `FUN_000251e0` |
| R5 | CX-specific env in `winemac.so`: `CX_ROOT` (`0x46f1c`, refs `0x14127` and `0x3c55a`: icon lookup `cocoa_icon_utils.m:85` and window.c:838) and `CX_FWD_COMPAT_GL_CTX` (`0x4ab6d`, ref `0x35cee`: `opengl.c:2167`). Registry key strings also include `Software\Wine\Mac Driver\Cursors`. | observed (REA `ev_7fdcc278…eed99c0ec`, `ev_f18fce95…4bea433`) + historical-reference | – |

Decision fed: `RetinaMode` is a plain `HKCU\Software\Wine\Mac Driver\RetinaMode` string value
(`Y`/`N`), read once at driver init per process, never per app. ossover's bottle settings write it
through `reg add` at prefix creation; a change needs a `wineserver` restart to take effect.

---

### winemetal.so (DXMT unixlib, open source; Ghidra + shell)

| # | Fact | Status | Location |
|---|---|---|---|
| W1 | Exports: 15,090 symbols, among them `___wine_unix_call_funcs` (`0x1414d60`) and `___wine_unix_call_wow64_funcs` (`0x1415160`); the rest are LLVM/`dxmt::` C++ symbols (the AIR converter is linked in). Imports: 421, including `_dlsym`, `_getenv`, `_NtSetEvent`, `_bootstrap_look_up`, `_posix_spawn`, ColorSync, sqlite3; **`_macdrv_functions` is not an import**, even though `@rpath/winemac.so` and `@rpath/ntdll.so` are `LC_LOAD_DYLIB` dependencies. | observed (shell nm/otool; REA `ev_153f5788…5a2d7a78`) | `winemetal.so` |
| W2 | How it obtains `macdrv_functions`: `FUN_0000a650` (`0xa650`–`0xa73c`, no static callers: it is a `__wine_unix_call` entry) calls `dlsym(RTLD_DEFAULT (-2), "macdrv_functions")`; on success it reads slots `+0x08` (`get_win_data`), `+0x10` (`release_win_data`), `+0x30` (`macdrv_view_create_metal_view`), `+0x38` (`macdrv_view_get_metal_layer`); if the table is missing it falls back to `dlsym(RTLD_DEFAULT, …)` of each of those four names individually. With all four pointers it does `get_win_data(hwnd)` → takes the view at `+0x18` of the returned record (`client_cocoa_view`, `d3dmetal.c:74`) → `macdrv_view_create_metal_view(view, device)` → stores the view and `macdrv_view_get_metal_layer(view)` into the caller's struct → `release_win_data`. A second function at `0xa740` does the same for slot `+0x40` (`macdrv_view_release_metal_view`, fallback at `0xa778`). The stub at `0x127f938` is `_dlsym` (`otool -Iv`). Its only callee is `_dlsym`; its only strings are the five symbol names. | observed (REA `ev_9c21a93f…d8400e2` for `0xa650`; shell `objdump` `shell-winemetal-objdump-0xa560-0xa7c0.txt` for `0xa740`/`0xa778`) | `winemetal.so` `0xa650`, `0xa740` |
| W3 | The slot offsets match the `winemac.so` table layout in M2 exactly (indices 1, 2, 6, 7, 8), so DXMT binds to the same `macdrv_functions_t` ABI as D3DMetal. The fallback names are the pre-table winemac exports, kept for older CrossOver/Wine builds. | inferred | – |
| W4 | `DXMT_*` environment: **none** in `winemetal.so` (ASCII and UTF-16 scans). The DXMT env lives in the PE side: `d3d11.dll`: `DXMT_CAPTURE_EXECUTABLE, DXMT_CAPTURE_FRAME, DXMT_CONFIG, DXMT_CONFIG_FILE, DXMT_LOG_LEVEL, DXMT_LOG_PATH, DXMT_METALFX_SPATIAL_SWAPCHAIN`; `dxgi.dll`: `DXMT_CONFIG, DXMT_CONFIG_FILE, DXMT_ENABLE_NVEXT, DXMT_LOG_LEVEL, DXMT_LOG_PATH, DXMT_USE_DEFAULT_METAL_CACHE`; `nvngx.dll`/`nvapi64.dll`: `DXMT_LOG_LEVEL, DXMT_LOG_PATH`. Config-file keys seen: `dxmt.conf`, `dxmt.shaderMetalVersion`, `d3d11.preferredMaxFrameRate`, `d3d11.metalSpatialUpscaleFactor`, `d3d11.ignoreMapFlagNoWait`, `d3d11.log`, `dxgi.customVendorId/DeviceId/DeviceDesc`, `dxgi.forceSDR`, `dxgi.log`, with built-in per-exe regex profiles (`GenshinImpact|YuanShen|ZenlessZoneZero`, `SONIC_X_SHADOW_GENERATIONS`, `OMORI`). | observed (shell strings of `lib/dxmt/x86_64-windows/*.dll`) | `shell-dxmt-*-strings.txt` |
| W5 | DXMT version string: **not present**. The PE version resources of `d3d11.dll`/`dxgi.dll` carry a spoofed `FileVersion 10.0.17763.1 (WinBuild.160101.0800)`, `ProductVersion 10.0.17763.1`, `LegalCopyright MIT License`. The only provenance is the embedded Metal-shader debug path `/Volumes/gitlab_data/gitlab/builds/j911ygmXM/0/crossover/crossover/dxmt/src/airconv/shaders/*.metal` (an internal CodeWeavers GitLab build of DXMT, compiled with `Apple metal version 32023.368`, AIR target `air64-apple-macosx14.0.0`), and `dxmt::dxbc::setup_metal_version(…SM50_SHADER_METAL_VERSION)`. The CrossOver sources tarball does **not** contain a `dxmt/` tree (its top level is android, busybox, cabextract, dxvk, freetype, ghostscript, glib, gnutls, gstreamer, htmltextview, makedep, moltenvk, po4a, pyxdg, vkd3d, wine). | observed (shell strings; shell `ls` of sources) | – |
| W6 | REA/Ghidra status: the first `search` on this 24 MB binary hit the provider timeout (`provider_timeout`, 330,000 ms default, `winemetal-search-strings.json`). Re-running with `REA_GHIDRA_STARTUP_TIMEOUT_MS=3000000` completed the `function 0xa661` analysis in 491 s (`ev_9c21a93f…d8400e2`, W2). The follow-up Ghidra string search (`macdrv_functions\|DXMT_\|dxmt\|gitlab\|WINEMETAL\|getenv`) is recorded in the addendum if it finished before the report was closed. | observed | `docs/rea/evidence/winemetal-*.json` |

Decision fed (H6/H2): DXMT needs only (1) `winemac.so` loaded in the process (it is, as the display
driver) exporting `macdrv_functions`, and (2) its own PE DLLs found first. No DXMT-specific env is
required for operation; `DXMT_CONFIG`/`DXMT_CONFIG_FILE` are optional tuning. ossover's env table for a
DXMT bottle therefore reduces to the renderer DLL overlay plus `CX_ACTIVE_GRAPHICS_BACKEND=dxmt`.

---

### cxcompatdb.so (proprietary; headers + strings only, no decompilation)

| # | Fact | Status | Location |
|---|---|---|---|
| C1 | No exported symbols; 54 imports; dependencies `@rpath/ntdll.so`, `@rpath/libgnutls.30.dylib`, `libSystem`. Imports of interest: `_dlsym`, `_getenv`, `_setenv`, `_NtCreateUserProcess`, `_NtCreateFile`, `_NtQueryInformationProcess`, `_mprotect`, `_sysctlbyname`, `_gnutls_pubkey_import`, `_gnutls_pubkey_verify_data2`, `_gnutls_load_file`, `_ntdll_wcsicmp`. | observed (REA `ev_73fb4495…5963f`; shell nm) | – |
| C2 | Strings describe: a signed JSON database (`%s/compatdb-%d.dat`, `%s.sha256`, `%s/share/crossover/data/tie.pub`, `verify_file`, `invalid signature`, `CX_HOME`), syscall-table patching (`KeServiceDescriptorTable`, `patch_syscalls`, `couldn't find NtCreateUserProcess in syscall table`), per-app "hacks" (`apply_in_process_hacks`, `HACK: appending command line`, `HACK: replacing exe path`, `HACK: adding env vars`, `HACK: adding dll overrides`, `add_load_order_override`, `add_dll_overrides`, `couldn't get ntdll export`), the graphics-backend selector (D11) and the nvngx redirect (D11). | observed (shell strings 240–300, 455–480) | `shell-cxcompatdb-strings.txt` |
| C3 | Environment names it carries: `CX_GRAPHICS_BACKEND`, `CX_ACTIVE_GRAPHICS_BACKEND`, `CX_ROOT`, `CX_HOME`; it also reads `sysctl.proc_translated` (Rosetta detection). | observed (shell strings) | – |

Decision fed (H2/H8): everything the `.tie`/compatdb machinery does at run time (command-line
rewriting, env injection, DLL overrides, backend selection) is proprietary, but all of it is expressed
through public LGPL hooks (`prepend_dll_path`, `add_load_order_override`, `WINEDLLOVERRIDES`,
`NtCreateUserProcess`). ossover re-implements the subset it needs as bottle-recipe actions applied
before launch rather than as an in-process hook library.

---

### libd3dshared.dylib and D3DMetal (Apple proprietary; signature + strings + headers only)

| # | Fact | Status | Location |
|---|---|---|---|
| A1 | Both are signed by Apple (`Software Signing` → `Apple Code Signing Certification Authority` → `Apple Root CA`, TeamIdentifier not set, CodeDirectory flags `0x0`); the D3DMetal framework bundle is intact (`_CodeSignature/CodeResources`, `Resources/{Info.plist,version.plist,LICENSE,default.metallib,libdxcompiler.dylib,libdxilconv.dylib,libmetalirconverter.dylib,libdxccontainer.dylib}`). `LICENSE` is the xxHash BSD-2 notice only. | observed (shell `codesign -dvvv`; REA `ev_a2a71be8…`, `ev_46204c3d…`) | – |
| A2 | `libd3dshared.dylib` (224 strings): dependencies `libc++`, `Foundation`, `CoreGraphics`, `libSystem`, `libobjc`; imports `_dlopen`, `_dlsym`; strings `/System/Library/Frameworks/D3DMetal.framework/D3DMetal` and `@rpath/D3DMetal.framework/D3DMetal`, `GFXTHandle && "Failed to dlopen D3DMetal"`, `GFXT_Initialize`, `D3DRMDispatch_Init_block_invoke`, `shared.mm`, `macdrv_functions`, `KERNEL32`, `wine_get_unix_file_name`, `wine_get_dos_file_name`, `/usr/lib/libRosetta.dylib`, `rosetta_get_runtime_version`, `sysctl.proc_translated`, `os_sync_wait_on_address`/`wake_by_address_*`, `D3DMetalWineThread`, and the D3D entry names it forwards (`D3D12CreateDevice`, `D3D11CreateDevice`, `CreateDXGIFactory2`, `NVSDK_NGX_D3D1{1,2}_*`, `nvapi_QueryInterface`). Exports: see G5. | observed (shell strings/nm/otool; REA `ev_b7c8967d…`) | `shell-libd3dshared-strings.txt` |
| A3 | Reading of A2: libd3dshared is the Wine-side shim: it `dlopen`s `D3DMetal` (system path or `@rpath`, which with its `@loader_path` rpath resolves to `external/D3DMetal.framework/D3DMetal`; the order of the two candidates is **unknown** without decompiling), looks up `macdrv_functions` with `dlsym`, and exposes `GetMacDRVFunctions()`/`__wine_unix_call_funcs` to the GPTK PE DLLs. | inferred | – |
| A4 | `D3DMetal` (5.26 MB, 38,050 strings, 3,963 exports): `_D3DMetalVersionString` = `@(#)PROGRAM:D3DMetal  PROJECT:D3DMetal-3.0` (bytes at `0x24c4e0`), `_D3DMetalVersionNumber` `0x24c510`, `_GFXT_Initialize` `0xc5f15`; 76 `NVSDK_NGX_*` exports; MetalFX classes imported: `MTLFXSpatialScalerDescriptor`, `MTLFXTemporalScalerDescriptor`, `MTLFXTemporalDenoisedScalerDescriptor`, `MTLFXFrameInterpolatorDescriptor`; dependencies include `@rpath/libmetalirconverter.dylib`, `@rpath/libdxccontainer.dylib`, `MetalFX`, `MetalKit`, `CoreAnalytics` (private). | observed (shell; REA `ev_9e546d42…`) | – |
| A5 | D3DMetal environment names (ASCII strings): `D3DM_ALLOW_HOOKING, D3DM_BOUNDS_CHECK, D3DM_DEVICE_DESCRIPTION, D3DM_DEVICE_ID, D3DM_DEVICE_REVISION, D3DM_DEVICE_SUBSYS, D3DM_DXIL_PROCESS_DEBUG_INFORMATION, D3DM_ENABLE_ASYNC_COMMIT, D3DM_ENABLE_METALFX, D3DM_EXE_OVERRIDE, D3DM_FLUSH_POS_INF_TO_NAN, D3DM_FORCE_RTZ_TEXWRITE, D3DM_IGNORE_D3D11_RENDER_BARRIERS, D3DM_LOD_BIAS, D3DM_MIN_LOD_CLAMP, D3DM_MULTITHREADED_INTERFACE_ENABLE, D3DM_NOT_IMPLEMENTED, D3DM_NO_WINDOW, D3DM_NVNGX_PATH, D3DM_POSITION_INVARIANCE, D3DM_RETAIN_REFERENCES, D3DM_SAMPLE_NAN_TO_ZERO, D3DM_SHOW_HUD_STATS, D3DM_SUPPORT_DXR, D3DM_VENDOR_ID, D3DM_WAIT_ON_RESET`, plus `MTL_HUD_ENABLED`, `MTL_SHADER_VALIDATION`, and `WINEPREFIX` (used for `%s/gpuinfo`, fallback `%s/.wine/gpuinfo`). `nvngx.dll` and `nvapi64` are named next to `D3DM_NVNGX_PATH`; the fatal message `Failed to get drawable for HWND. Run with D3DM_NO_WINDOW=1 env.` is present. | observed (shell strings 35996–36889, 37014) | `shell-d3dmetal-strings.txt` |

Decision fed (H6, lookup order): the D3DMetal activation chain on the shipped app is
`CX_GRAPHICS_BACKEND=d3dmetal` (bottle config, read by `cxcompatdb.so`) → `prepend_dll_path("<CX_ROOT>/lib64/apple_gptk/wine")`
→ Wine loads `x86_64-windows/d3d11.dll|d3d12.dll` whose unixlib symlinks resolve to
`external/libd3dshared.dylib` → libd3dshared `dlopen`s `D3DMetal.framework` via `@rpath=@loader_path`
→ D3DMetal calls back through `macdrv_functions`; in parallel ntdll registers non-native regions when
`CX_APPLEGPTK_LIBD3DSHARED_PATH` is set. The GPTK pack ossover imports must therefore keep the relative
layout `external/{libd3dshared.dylib, D3DMetal.framework}` and `wine/x86_64-{unix,windows}` with the
symlinks, and ossover sets both `CX_APPLEGPTK_LIBD3DSHARED_PATH` and `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal`.
Whether `D3DMetal` is looked up at the system path first (A3) only matters if a user has a system
D3DMetal installed; left **unknown**.

---

## Answers to the task questions (short form)

| Question | Answer | Rows |
|---|---|---|
| `set_dll_path` reads anything besides `WINEDLLPATH`? | No. Only `WINEDLLPATH`; `dll_dir` (from `dladdr`) is always first. | D2, D3 |
| Who calls `prepend_dll_path` internally? | Nobody; sole caller is `cxcompatdb.so` via `dlsym`. | D4, D9, D10 |
| `init_non_native_support` fallback when env unset? | None; returns without `dlopen`. Needs macOS ≥ 14. | G2, G3 |
| msync init / `WINEMSYNC` semantics | `do_msync` = `atoi(WINEMSYNC) != 0`, cached; mismatch with server is fatal; esync absent. | S1–S3 |
| cxcompatdb dlopen site | `start_main_thread`, `"%s/cxcompatdb.so"` with `ntdll_dir`, `RTLD_LAZY\|RTLD_LOCAL`, failure is a WARN. | D7 |
| `macdrv_functions` export | 24-slot table at `0x610d0`, decoded; consumed only by `dlsym` users. | M1–M3 |
| `RetinaMode` read | In `macdrv_init`/`setup_options` (`FUN_0002e460`), HKCU `Software\Wine\Mac Driver`, global key only. | R1–R3 |
| winemetal: dlsym vs import | `dlsym(RTLD_DEFAULT, "macdrv_functions")` with per-symbol fallback; not an import. | W1–W3 |
| DXMT version string | Not present; only the CX GitLab build path; PE resources spoof 10.0.17763.1. | W5 |
| DXMT env | None in `winemetal.so`; `DXMT_*` set lives in the PE DLLs (list in W4). | W4 |
| libd3dshared / D3DMetal | Apple-signed; `D3DMetal-3.0`; `D3DM_*` list; nvngx/MetalFX present. | A1–A5 |

## Unknowns (record_unknown candidates)

1. Exact moment `cxcompatdb.so` calls `prepend_dll_path` (constructor vs. later hook) — needs
   decompilation of a proprietary file; out of scope. Evidence for/against: D7, D9, D10.
2. Order in which `libd3dshared.dylib` tries `/System/Library/Frameworks/D3DMetal.framework/D3DMetal`
   versus `@rpath/D3DMetal.framework/D3DMetal` — Apple binary, strings only (A2, A3).
3. Runtime effect of leaving `CX_APPLEGPTK_LIBD3DSHARED_PATH` unset (performance vs. failure) —
   runtime-only (G3).
4. DXMT upstream version/commit behind `winemetal.so` — not recorded in any shipped artifact (W5).
5. `winemac.so` code-signature identifier (not queried; expected CodeWeavers chain).
6. (resolved) The Ghidra `function 0xa661` run on `winemetal.so` completed — see W2/X2.

## Evidence index (REA JSON under `docs/rea/evidence/`)

| File | Operation | Subject | Evidence ID |
|---|---|---|---|
| `ntdll-search-strings-env.json` | search_strings | ntdll.so | `ev_c611b9fdab3d55f69a8aa448623e88472fe22430d7f5e29e7e6783dc48ba30c0` |
| `ntdll-search-procedures.json` | search_procedures | ntdll.so | `ev_9b1995ac819914916564e1e89fb80ff9ddadd48f2b114e06df0d3e8749a572aa` |
| `ntdll-trace-WINEDLLPATH.json` | trace_feature | ntdll.so | `ev_e82a1d9db1a50daebef7c3b9076cfee78ea2ce0697de31ded8edfd12896c546f` |
| `ntdll-xrefs-WINEDLLPATH.json` | xrefs | ntdll.so | `ev_e75e4edefd133ddf3d352a1d52f80655f138a4531d434ee4ef241a90f99abd6a` |
| `ntdll-xrefs-cxcompatdb-so-fmt.json` | xrefs | ntdll.so | `ev_8fb0bf409a3dc38fc70f3c63556700658a8380f619b5b185a6416510a59aea85` |
| `ntdll-xrefs-CX_APPLEGPTK.json` | xrefs | ntdll.so | `ev_77e6952dbe0e315ccc83a8d1f665b532a3fcd3d3e55cfc471dedd284c18994ad` |
| `ntdll-xrefs-init_non_native_support-name.json` | xrefs | ntdll.so | `ev_bd40c3d280a9bec0b57e54cb0656b93033748464f7e230e568c0613898085748` |
| `ntdll-xrefs-WINEMSYNC.json` | xrefs | ntdll.so | `ev_9f77a1beb25ef0c2ce31a1dd62acc5bc049839df41382cd097055159014db3b8` |
| `ntdll-xrefs-prepend_dll_path.json` | xrefs | ntdll.so | `ev_e1d68d365bbd8110eff13cf408ef6b5861c32841fde93af60d3c5f1f95ad8ee3` |
| `ntdll-xrefs-CX_ALT_LOADER_SOCKET.json` | xrefs | ntdll.so | `ev_f98ea89cccbe9034a349dc8b2c65ead995c695bef0239325703e43c3f4942b36` |
| `ntdll-xrefs-version-string.json` | xrefs (0x763d0) | ntdll.so | `ev_8eb8e97af5bc04a4634aeec839aa7d78065ac35b2fdf7e22b24896af8ed5f315` |
| `ntdll-xrefs-version-string-0x763e0.json` | xrefs (0x763e0) | ntdll.so | `ev_57ef14c4bff07e73790be8ac8dd61f9f2c920302b1f590a91a2d81ae19582868` |
| `ntdll-function-FUN_0001fea0-winedllpath-reader-1.json` | analyze_function (init_paths/set_dll_path) | ntdll.so | `ev_b34071a89d445eb2dbdd65e9246bd219e89c991270db313dcd3f509ad3aac7e9` |
| `ntdll-function-at-0x2001b-probe.json` | analyze_function (same function, interior-address probe) | ntdll.so | `ev_2c53ce9dfdb5bd87999406cde2b51ca0a9ee6fe5506c888ed43200602732e160` |
| `ntdll-function-FUN_000224d0-winedllpath-reader-2.json` | analyze_function (preloader_exec) | ntdll.so | `ev_98210b0910fc4591a35ed2509fbe3cbe45fc2417fe240960aa2693d1376e206f` |
| `ntdll-function-cxcompatdb-dlopen-site.json` | analyze_function (start_main_thread) | ntdll.so | `ev_24ff438ebb7ee7c66a140f28cf97b98f32b696e82769c5d801f5151673f92f21` |
| `ntdll-function-init_non_native_support.json` | analyze_function | ntdll.so | `ev_b012b7fd09d9ac8d223ba6a770368ba4363281fa496f5536af4a0f2c368f865a` |
| `ntdll-function-winemsync-reader.json` | analyze_function (do_msync) | ntdll.so | `ev_25e10a5479d52bfb8c8141cc2cf16eafaa690b9c5ef3fc531aa4163bb577aa61` |
| `ntdll-function-msync_init-candidate.json` | analyze_function (msync_init) | ntdll.so | `ev_4f0b7719ad61207dcb831f3a378d3fb4600e518ae963529b8ddffd9dca3ffab4` |
| `ntdll-function-prepend_dll_path.json` | analyze_function | ntdll.so | `ev_dfa5b8378b32e5ce7d0ecdb6106213368c3daa31f2fbb4f2a6335f6f0ab17800` |
| `ntdll-function-send_to_cx_loader.json` | analyze_function | ntdll.so | `ev_acfd2f1bab0fb28f87e7ce66c8125c6f0f42c5a562b396ddf873a40d6ba9d9cd` |
| `ntdll-function-version-string-user-0x5213a.json` | analyze_function (NtQuerySystemInformation) | ntdll.so | `ev_e43631a5e42c7fa15b8916c505947b79ee7b17bc7fac6d6d0223da89d9a0026d` |
| `ntdll-function-add_load_order_override.json` | analyze_function | ntdll.so | see addendum below |
| `ntdll-inspect-macho.json` | inspect_macho | ntdll.so | `ev_4a5a4ebdce76503ec342946774abfcd36ac4e0c0e69ab994e99ee6530b929694` |
| `ntdll-inspect-signature.json` | inspect_signature | ntdll.so | `ev_620e7207cb0aaadb58ca2d3aac446e031f510f3bc8b62673fc202fc42ada848d` |
| `winemac-search-procedures.json` | search_procedures | winemac.so | `ev_e5dd9670c209a493c52f0c1c8da0c289080960dfd7e918c8cb46cf656c1eb92e` |
| `winemac-search-strings.json` | search_strings | winemac.so | `ev_555af57dee64683d79296d1d4cf48440afbaf7faa5568265a8285a59c5dbccca` |
| `winemac-xrefs-macdrv_functions.json` | xrefs (0x610d0) | winemac.so | `ev_d9410021f7e57b5bf3678543a3d658d80a728ae85dc665beabee22f03292f913` |
| `winemac-xrefs-Software-Wine-Mac-Driver.json` | xrefs | winemac.so | `ev_c0a7195fc44002c59dc7e375dbd6839373f9933ad31634e40ecf1f3f73718318` |
| `winemac-xrefs-Registry-Mac-Driver.json` | xrefs | winemac.so | `ev_04c9bbcf9cbf7313d03fafbd6839d3eb6da09df4bc4259c01d740e89cec0af92` |
| `winemac-xrefs-my_macdrv_create_metal_device.json` | xrefs | winemac.so | `ev_307ca2e18eb02c2bcddfbd34d49d2d08b7dc1675a9f387a6cdbb45776771d9c7` |
| `winemac-xrefs-my_macdrv_view_create_metal_view.json` | xrefs | winemac.so | `ev_4ca3e59675c7a09b58b734e2b6de543f4744d98dcfe3ee1e8a2389e7b05e83ae` |
| `winemac-xrefs-d3dmetal_client_surface.json` | xrefs | winemac.so | `ev_d6ea3dc775e2deb7d90599cd4b7e12bcdbd8a5bc7d33797dfab9f3d075582c43` |
| `winemac-xrefs-CX_ROOT.json` | xrefs | winemac.so | `ev_7fdcc27849c89b260b0e41e5071a89856ac7945e56f1a6864452045eed99c0ec` |
| `winemac-xrefs-CX_FWD_COMPAT_GL_CTX.json` | xrefs | winemac.so | `ev_f18fce958741ed8375702bd0237135daaf4a66295225ccc7da6ba2ced4bea433` |
| `winemac-xrefs-Initial-Display-Mode.json` | xrefs | winemac.so | `ev_955cbad96d7bde68176ae6d4d283e3c416aa83b99dfe8b4215b39424f0999b9e` |
| `winemac-xrefs-RetinaMode-const-0x44a70.json` | xrefs | winemac.so | `ev_4cb8677a17d48a97508fa7940dc3c542d00ef1dd6495e70a25bfaf3c2499d1bc` |
| `winemac-function-setup_options-candidate.json` | analyze_function (macdrv_init + setup_options) | winemac.so | `ev_c7f342cc35ecc98f4629b2b2781fdb49214f118eb1807ddff9465c533af07e11` |
| `winemac-function-registry-mac-driver-reader.json` | analyze_function (initial display mode writer) | winemac.so | `ev_49a29c54d912a6b66c4e4a041d822ba0b2d3917b46e2ba44ac1fbdecfcc285b6` |
| `winemac-function-my_macdrv_create_metal_device.json` | analyze_function | winemac.so | `ev_83bffb463f6a9af058ac29b76f5bea38117d3371db7de991597ce45aa02f12c4` |
| `winemac-read-bytes-macdrv_functions-0x610d0.json` | read_bytes (192 B) | winemac.so | `ev_aff1cae8e7ec487ab5114192c336df26f84059e90b3a761d446d678404ad6bf6` |
| `winemac-inspect-macho.json` | inspect_macho | winemac.so | `ev_b62941e8ac06ddfa9453e1ac87b77772bcbe5f4bcbeb1866c59a50ef2e1b4359` |
| `winemetal-search-strings.json` | search_strings (first attempt) | winemetal.so | **provider_timeout** (330,000 ms) |
| `winemetal-function-macdrv_functions-lookup-0xa661.json` | analyze_function (long-timeout rerun) | winemetal.so | see addendum below |
| `winemetal-inspect-macho.json` | inspect_macho | winemetal.so | `ev_153f5788a79bbeaf27b5819785b9fc0ca760f1ed7b7e5819bb24b6165a2d7a78` |
| `winemetal-inspect-signature.json` | inspect_signature | winemetal.so | `ev_ace51ea4be43ca641340abdb5945e7aefca99ef82b78159b082d7a3373fb5697` |
| `cxcompatdb-inspect-macho.json` | inspect_macho | cxcompatdb.so | `ev_73fb4495cb8254f0822bd88a02677ac7a77dd2bc8ec382792ae45d2c6995963f` |
| `cxcompatdb-inspect-signature.json` | inspect_signature | cxcompatdb.so | `ev_a0bc0106e77f25b990a702d54a481cc0489ff7cd9ce061d2bdc673a2eb759d63` |
| `libd3dshared-inspect-macho.json` | inspect_macho | libd3dshared.dylib | `ev_b7c8967dda45080913ff50b235ff79a204c80bc18cf2d41918b18570527d3b57` |
| `libd3dshared-inspect-signature.json` | inspect_signature | libd3dshared.dylib | `ev_a2a71be85f2f7b40c73b12cd2a191ba9e749413473fafeb48bc4b2e1dd025fbd` |
| `D3DMetal-inspect-macho.json` | inspect_macho | D3DMetal | `ev_9e546d42475eb43edfc55fcf26cff902c9abe3456f7b97d3a7c5191e82a3ff1e` |
| `D3DMetal-inspect-signature.json` | inspect_signature | D3DMetal | `ev_46204c3dd654adab5f870331653ae0f494a82a6fa7a160c7d0ed94d6747a9bca` |
| `cli-doctor.json`, `cli-capabilities.json` | doctor / capabilities | – | (no Evidence ID; environment record) |

Plain-shell observation files (no Evidence ID): `shell-<binary>-strings.txt`, `shell-<binary>-strings-utf16.txt`,
`shell-<binary>-nm-gU.txt`, `shell-<binary>-nm-u.txt`, `shell-<binary>-otool-L.txt`, `shell-<binary>-otool-l.txt`,
`shell-dxmt-<dll>-strings*.txt`, `shell-winemetal-objdump-0xa560-0xa7c0.txt`. Decompiler text extracted from
the REA JSON for the LGPL/DXMT functions is kept beside it as `*.pseudocode.txt`.

Snapshots used for repeatable CLI runs live in the session scratchpad (`rea-snapshots/*.snapshot.json`),
not in the repo.

## Addendum (filled after the long-running jobs finished)

| # | Fact | Status | Location |
|---|---|---|---|
| X1 | `_add_load_order_override` (`0x24300`–…): takes one WCHAR string; if the load-order tables are not initialised (`DAT_00087e98 == 0`) it calls the initialiser `FUN_000243a0`; copies the string with `calloc`; hands it to `FUN_000244c0` (the "add one `dll=mode` set to the env list" helper); then `qsort`s the env override list (`DAT_00087eb0`, count `DAT_00087ea0`, 16-byte entries, comparator `FUN_000247a0`). Ghidra callers: **none**; the only incoming reference is a DATA reference from the symbol table (`0xb5346`), i.e. exactly like `prepend_dll_path` it exists for `dlsym` by `cxcompatdb.so` (strings `add_load_order_override`, `HACK: adding dll overrides`). Source: `loadorder.c:253-258` (`/* CX Hack 24067 */`, `visibility("default")`). | observed (REA `ev_1d04b424…adf50eef0`) + historical-reference | `ntdll.so` `0x24300` |
| X2 | `winemetal.so` Ghidra function analysis at `0xa661` completed with the raised timeout: `FUN_0000a650`, see W2. | observed (REA `ev_9c21a93f…d8400e2`) | `winemetal.so` |

Decision fed by X1 (H2/H8): per-app DLL overrides from CrossOver's compat database are injected through
this LGPL export at process start; ossover gets the same effect with `WINEDLLOVERRIDES` in the launch
env (same parser, `loadorder.c`), so no in-process hook is needed.

Evidence index additions:

| File | Operation | Subject | Evidence ID |
|---|---|---|---|
| `ntdll-function-add_load_order_override.json` | analyze_function | ntdll.so | `ev_1d04b4249eac99936e2a47a01cd71e1dda6b77c514f74ab43e5d264adf50eef0` |
| `winemetal-function-macdrv_functions-lookup-0xa661.json` | analyze_function (`FUN_0000a650`) | winemetal.so | `ev_9c21a93f5a22c84beb4ad6f62e504ddf3bda206db6a1cc1b68caf53dbd8400e2` |
| `winemetal-search-strings.json` | search_strings (long-timeout rerun, regex `macdrv_functions\|DXMT_\|dxmt\|gitlab\|WINEMETAL\|getenv`) | winemetal.so | `ev_356546ada1a12844aeb02650268b73e02ef940428538579fcd480c0bf65940c3` |

### Late results

| # | Fact | Status | Location |
|---|---|---|---|
| X3 | The second `winemetal.so` Ghidra string search completed in 447 s (after a 491 s import; `REA_GHIDRA_STARTUP_TIMEOUT_MS=3000000`). 993 defined strings matched the regex; all but a handful are mangled `dxmt::` / `dxmt::dxbc` / `dxmt::air` C++ symbol names. Exactly one `macdrv_functions` string exists (`0x12e5a80`, the one `FUN_0000a650` passes to `dlsym`, W2). **Zero** strings contain `DXMT_` and **zero** contain `WINEMETAL`; the only `getenv` hits are symbol-name strings (`getenv` `0x1321663`, `_getenv` `0x146e78d`/`0x1713e11`), not environment-variable names. The `gitlab` hits are the three embedded Metal-shader debug blobs already listed in W5. This confirms W4 from the Ghidra string inventory, within its stated limitation that only Ghidra-defined string data is inventoried. | observed (REA `ev_356546ad…65940c3`) | `winemetal.so` |
