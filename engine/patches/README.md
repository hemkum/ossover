# engine/patches — patches carried on top of the CrossOver 26.3.0 LGPL Wine tree

Applied in lexical order by `engine/build.sh` with `patch -p1` from inside `sources/wine` of
`crossover-sources-26.3.0.tar.gz` (sha256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`,
pinned in `engine/inputs.json`). The three files are verbatim copies of
`gauthierpiarrette/highball-engine/patches/` (clone of 2026-10-13); their headers (author notes,
verification, upstream status) are kept untouched. highball-engine states "Wine and the patches to it
are LGPL-2.1-or-later" (`README.md:40` of that repo), so they can be redistributed with this GPL-3.0
project; per-file attribution stays in the headers.

Evidence for every claim below: `docs/rea/wine-fork.md` → "LGPL sources" and
`docs/rea/evidence/sources-pass-patch-dryrun.txt`. The REA pass confirmed the base and this patch
set (decision 27): the tarball is complete for the unix side — 290/290 `ntdll.so` and 3/3
`winemac.so` exports of the shipped CrossOver have definitions in it, including the CX-only
`prepend_dll_path`, `add_load_order_override`, `__wine_unix_spawnvp` and `KeServiceDescriptorTable` (REA L-46); the shipped
fork string is `wine-11.0-8726-g2e2f5fca349`, i.e. upstream 11.0 + 8,726 CodeWeavers commits (REA
L-45); and the three patches dry-run as tabled below (REA L-47). The three files are byte-for-byte
the highball-engine originals (re-verified with `cmp` on 2026-10-14).

Alternative kept on record (decision 31, REA L-21): an **unpatched** tarball build dlopens
`<ntdll_dir>/cxcompatdb.so` from `start_main_thread` (`RTLD_LAZY|RTLD_LOCAL`, failure is only a
WARN), so an *open* ossover `cxcompatdb.so` placed in `<engine>/lib/wine/x86_64-unix/` could call the
exported `prepend_dll_path` itself and give strategy C without patch `0003`. Not needed while `0003`
is carried; it becomes the fallback if a future tarball bump makes `0003` stop applying.

## Dry-run against the pinned tree (2026-10-13)

`patch -d <APFS clone of sources/wine> --dry-run --verbose -p1 -i <patch>` with `/usr/bin/patch 2.0-12u11-Apple`.
Never run inside the original extracted tree.

| Patch | sha256 | Files | Hunks | Result |
|---|---|---|---|---|
| `0001-use-the-real-user-name.patch` | `32f32bc1c3b270def7a0622f1fe67afdcf20d3877cd51e99be17b50817ecf1d6` | `dlls/advapi32/advapi.c`, `dlls/shell32/shellpath.c` | advapi.c #1 @47, #2 @62; shellpath.c #1 @2632 | clean, no offset, no fuzz, exit 0 |
| `0003-ntdll-winedllpath-prepend.patch` | `8a56c17512731bd853ddc9e638761a5f9623b65e7c44bbefd89e757c3b868dc9` | `dlls/ntdll/unix/loader.c` | #1 succeeded at 387 **(offset -209 lines)** | applies, no fuzz, exit 0 — the hunk header says `@@ -596` but `set_dll_path` is at line 387 in the CX 26.3.0 tree; harmless |
| `0014-msync-unregister-early-return.patch` | `09c46f062f7e936bb331274192ce3436dbd18242a1b1618ca4944b6193158715` | `dlls/ntdll/unix/msync.c`, `server/msync.c` | msync.c #1 @377; server/msync.c #1 @177, #2 @514 | clean, no offset, no fuzz, exit 0 |

## What each patch does and why ossover carries it

- **0001** — removes CrossOver Hack 12735: `GetUserNameA/W` returning `"crossover"` unless
  `CX_REPORT_REAL_USERNAME` is set (`dlls/advapi32/advapi.c:52,77`) and the hard-wired
  `C:\users\crossover` in `%USERPROFILE%` expansion (`dlls/shell32/shellpath.c:2635`). Restores
  upstream behaviour (`WINEUSERNAME` → `users\<macOS user>`), so bottles are portable between engines
  and recipe paths (`Documents\The Witcher 3\…`) are predictable. Design: plan §4 "Prefix".
- **0003** — adds `WINEDLLPATH_PREPEND` to `set_dll_path()` (`dlls/ntdll/unix/loader.c:387-407`):
  directories listed there are searched *before* the engine's own `lib/wine` builtins. The CX tree only
  honours `WINEDLLPATH` (searched after `dll_dir`) and the exported `prepend_dll_path()`
  (`loader.c:365-385`, CW Hack 24067) has no in-tree caller — it exists for the proprietary
  `cxcompatdb.so`. This patch is what makes renderer overlays (DXMT/DXVK/D3DMetal) work without
  mutating the prefix: plan §4 "Renderer overlay, strategy C"; engine manifest
  `capabilities.dllPathPrepend=true`. Origin: MacPorts game-porting-toolkit `1005-ntdll-d3dmetal-env.diff`.
- **0014** — fixes a wineserver memory leak in msync's multi-object wait: the client early-return path
  now unregisters via `server_remove_wait()` (`dlls/ntdll/unix/msync.c:377-389`), the server unregisters
  objects `0..i-1` for any `i > 0` (`server/msync.c:514-517`), and the "node memory pool exhausted"
  warning prints once (`server/msync.c:177-187`). Carried because ossover enables `WINEMSYNC=1` by
  default on CX-derived engines (plan §4 env table, §3 Phase 3 sync comparison).

## Not carried (evaluated later, per plan §3 Phase 4)

`0002` (wined3d OpenGL-first: conflicts with CW Hack 18311 Vulkan-first on macOS; keep CX default until the
Witcher benchmark says otherwise), `0005`–`0013`, `0015`–`0021` from the same series. `0013`
(NX-compat under Rosetta) and `0015` (CoreAudio buffer) are the first candidates to re-test.

## Rules

- A patch that upstream Wine or CodeWeavers ships is deleted here in the same change that bumps the
  pinned tarball.
- Re-run the dry-run table whenever `engine/inputs.json` changes; record offsets/fuzz here.
- Never copy code from the CrossOver bundle; patches modify only the LGPL tree.
