# CrossOver 26.3.0 — bottle format, creation and sync defaults (H4, H3)

Plain-text pass; IDs `SH-TT-nn` are shell observations (not REA Evidence IDs). Shorthand/authority conventions as in `env-table.md`. Raw logs: `docs/rea/evidence/text-tooling-layout-hashes-diffs.txt` (template diffs, setup md5s), `text-tooling-envgrep.txt`.

## 1. Creation chain (observed, shipped-artifact)

```
cxbottle --create --bottle NAME [--template win10_64] [--description D] [--scope private|managed] [--param SECTION:KEY=VALUE]...
  └─ compute_new_wineprefix → $CX_BOTTLE_PATH/NAME            (CXBottle.pm:133-166; cxbottle:597-612)
  └─ mkpath + lock, WINEPREFIX=realpath                          (cxbottle:535-544, 609-612)
  └─ exec  <template_dir>/setup --create [--updater wineprefixcreate] [--description D]   (cxbottle:611-637)
        └─ CXBT_win10_64->create($cxconfig, {description, updater, scope})               (setup:99-117)
              1. write cxbottle.conf from bottle_data/cxbottle.conf + [Bottle] keys       (CXBT:191-208)
              2. touch system.reg ("WINE REGISTRY Version 2" + "#arch=win64")            (CXBT:210-218)
              3. run_inf("win10", scope, 0): wine --wl-app rundll32.exe … setupapi.dll,InstallHinfSection Win10Install 128 bottle_data/crossover.inf (CXBT:101-179, 220)
                 then the same with --wl32-app if lib/wine/i386-windows exists (WoW64 half)
              4. re-create dosdevices/y: → $HOME                                          (CXBT:222-229)
              5. regedit pipe: Outlook DenyShellExecute (when [BottleDefaults] OutlookSecurity=1)   (CXBT:231-252)
              6. wine --ux-app wineserver -w  (wait for bottle shutdown, "Wine bug 41713")  (CXBT:253-256)
              7. run_bottle_hooks(["create", template_dir])  ($CX_ROOT/support/scripts.d, ~/…/CrossOver/scripts.d, <bottle>/scripts.d; files named NN.name) (CXBT:260; CXBottle.pm:470-518)
  └─ --param SECTION:KEY=VALUE written into cxbottle.conf afterwards                       (cxbottle:638-652)
  └─ setup_bottle_environment + update_bottle                                              (cxbottle:1142-1157)
  └─ --default: relative symlink $CX_BOTTLE_PATH/default → NAME                            (cxbottle:1172-1197)
```

Default template when `--template` is omitted: `win98` (`cxbottle:359`; `CXBottle::get_template_directory` also defaults to `win98`, `CXBottle.pm:388-395`). `cxtemplate --template T --query introspect` loads `CXBT_T.pm` and prints `[properties] category=crossover` — the only query any template supports (`cxtemplate:187-228`; `CXBT:81-94`).

## 2. `cxbottle.conf` — every key (observed)

Source template: `$CX/share/crossover/bottle_data/cxbottle.conf` (325 lines; parsed by `CXConfig.pm` — case-insensitive section/key names, `"Name" = "Value"` or `Name=Value`, `;` comments, `<undef>` deletes a key). Written by `CXRWConfig` which preserves the template's comment lines (`CXRWConfig.pm:588-608`).

| Section | Key | Default in template | Written at create by | Read by |
|---|---|---|---|---|
| `[Bottle]` | `MenuRoot` | commented (doc default `""`) | `[BottleDefaults] MenuRoot` = `/Windows Applications` (`etc/CrossOver.conf:345`; `CXBT:201-202`) | cxmenu |
| | `MenuStrip` | commented (doc `0`) | `[BottleDefaults] MenuStrip` = `1` (`etc:346`; `CXBT:203-204`) | cxmenu |
| | `BottleID` | commented | `uuidgen` output, else `<dev>-<ino>-<time>` (`CXUtils.pm:598-615`; `CXBT:195`) | `CXBottle::get_bottle_tag` (`CrossOver-<id>`), menus/assocs |
| | `Version` | **`26.3.0.39832`** (`cxbottle.conf:111`, the only uncommented value) | inherited from template; on upgrade removed then re-merged from the new template (`CXBT:306-307`, `356-357`) | `upgrade_cxbottle` (old-version logic; `.eval` deleted when it changes, `CXBT:283`) |
| | `Timestamp` | commented | `[CrossOver] BuildTimestamp` (`CXBT:196`) | launcher upgrade trigger (SH-TT-07) |
| | `Encoding` | commented | `CXUtils::get_system_encoding(1)` (`CXBT:197`) | upgrade |
| | `Description` | commented | `--description` (`CXBT:199`) | GUI/cxbottle |
| | `Template` | commented | `win10_64` etc. (`CXBT:198`) | `CXBottle::get_template_directory` → which `setup` runs on upgrade |
| | `WindowsVersion` | commented | **never written** by templates (bounded grep) | doc only |
| | `Updater` | commented | `wineprefixcreate` for managed scope (`cxbottle:617`; `CXBT:200`) | launcher stub logic (`wine:472-486`, `554-628`) |
| | `ManagedLinkType` | commented (doc `Symbolic`) | — | `wineprefixcreate:229` |
| | `MenuMode`, `AssocMode` | commented (doc `ignore`) | `ignore` (`CXBT:205-206`); upgrade sets `install` if missing (`CXBT:318-319`) | cxmenu/cxassoc, `CX_BOTTLE_MODE` override |
| | `AllowUntrusted` | commented (doc `0`) | set to `1` by the "Always Continue" dialog (`wine:441-465`) | `wine:419` |
| | `WineArch` | **not in template** | `win64` / `win32` (`CXBT:207`) | launcher `WINEDLLPATH`/`lib64` choice (`wine:659`, `674`) |
| `[ManagedUpdatePolicy]` | regex → `Delete|Ignore|Link|LinkDir|Copy|Registry[,ReplaceFiles|ReplaceDirs|ReplaceConflicting]` | 20 rules (`cxbottle.conf:261-314`): `^\.wineserver$`=Delete; `desktopdata`, `windata`=LinkDir; `cxbottle.conf`=Link,ReplaceFiles; `system.reg`=Registry,ReplaceFiles,ReplaceConflicting; `userdef.reg`,`user.reg`=Registry,ReplaceConflicting; Office/Notes/Outlook/Quicken/QuickTime/Trillian/spool rules=Copy; `drive_c/users/crossover/`=Copy; temp/history dirs=Ignore | template | `wineprefixcreate` (managed→stub replication, `CXReplicateDir`) |
| `[EnvironmentVariables]` | `"VAR" = "value"` | only the commented example `"PROMPT" = "$p$g"` | GUI toggles (unknown), CrossTies (`preinstallenvironment`), template migration (`CXBT:448-467`), `cxbottle --param EnvironmentVariables:KEY=VALUE` | launcher `set_environment` (SH-TT-08) |

Other bottle-level files observed by name: `system.reg`, `user.reg`, `userdef.reg`, `drive_c/`, `dosdevices/{c:→../drive_c, z:→/, y:→$HOME}` (`wineprefixcreate:282-301`; `CXBT:222-229`), `desktopdata/`, `windata/`, `.wineserver`, `cxmenu.conf` (`CXBT:425`), `dxvkfiles.conf` (legacy, deleted on upgrade), `files` (stub file list, `wineprefixcreate`), `scripts.d/`, `.eval` (`CXBT:283`), `.update-timestamp` (not seen). A directory counts as a bottle iff `system.reg` exists (`CXBottle.pm:192`, `658`).

## 3. Template inheritance (observed)

* 13 templates: `win98, win2000, winxp, winxp_64, winvista, winvista_64, win7, win7_64, win8, win8_64, win10, win10_64, win11_64`, each a dir with `CXBT_<name>.pm` + `setup`. There is **no inheritance mechanism** (no `use parent`/`require` of another CXBT; every file is a full 689-line copy).
* `diff -u win10_64 vs win11_64 (.pm)`: only lines 2, 9, 12 differ (`package`, `$template`, `$windows_version` `win10`→`win11`). `setup` differs only in the template name/package lines. `diff -u win10 vs win10_64`: only `$template` and `$winearch` (`win32`→`win64`). 13 distinct `setup` md5s because each embeds its name. (`text-tooling-layout-hashes-diffs.txt`)
* `$windows_version` selects the `crossover.inf` section `<winver>Install` (regex `win98|win2000|winxp|vista|win7|win8|win10|win11`, `CXBT:111-115`); upgrades use `DefaultInstall` (`CXBT:106-110`; the inf has `[DefaultInstall]` = Win98 upgrade and `[DefaultInstall.NT]` — setupapi's `.NT` suffixing picks the NT one on NT bottles, inferred).

## 4. `crossover.inf` — what a win10_64 bottle gets (observed; `$CX/share/crossover/bottle_data/crossover.inf`, 640 lines, UTF-8 BOM)

`[Win10Install]` (`inf:295-314`) = AddReg `VersionInfo10, ColorsReg, DrivesReg, FallbackAssociationReg, MiscReg, WineDllOverridesReg, WineDllOverridesRegNT, WineSettingsReg, ODBCReg`; DelReg `ObsoleteRegHacks`; CopyFiles `MediaFiles` (`Notify.wav` → `c:\Windows\Media`), `CatFiles` (`oem0.cat` → `system32\catroot\{f750e6c3-…}`); DelFiles `wcmd.exe` (system32), `rundll32.exe` (windows); RegisterDlls `actxprxy.dll`. (`DrivesReg` is referenced but not defined in this file — bounded grep; setupapi ignores a missing section, inferred.)

| Section | Content (registry) |
|---|---|
| `[VersionInfo10]` (`inf:316-327`) | `HKLM\Software\Microsoft\Windows NT\CurrentVersion`: `CSDVersion=""`, `CurrentMajorVersionNumber=10`, `CurrentMinorVersionNumber=0`, `CurrentBuildNumber="19045"`, `CurrentBuild="19045"`, `CurrentType="Multiprocessor Free"`, `CurrentVersion="6.3"`, `ProductName="Windows 10 Pro"`, `UBR=5796`; `HKLM\System\CurrentControlSet\Control\Windows\CSDVersion=0`; `…\Session Manager\Environment\OS="Windows_NT"`. **No `ProductType` for win10** (only Win2000/XP set `WinNT`). |
| `[VersionInfo11]` (`inf:352-363`) | same keys with `22000`, `"Windows 11 Pro"`, `UBR=588`, `CurrentVersion="6.3"`. |
| `[WineSettingsReg]` (`inf:558-611`) | `HKCU\Software\Wine\Fonts\Replacements`: Arial→Bitstream Vera Sans, JP/SC/TC/KR replacements to Hiragino/STSong/LiSong Pro/NanumGothic, MS UI Gothic→Ume UI Gothic; `HKCU\Software\Wine\AppDefaults\{cxcplinfo,cxmklnk,winemenubuilder,winewrapper}.exe\Explorer\Desktop="root"`; `HKCU\Software\Wine\Systray\Hidden=1`; `HKCU\Software\Wine\X11 Driver\ShowSystray="false"`; `HKCU\Software\Wine\Direct3D\cb_access_map_w=1` ("Rocket League performance"). |
| `[WineDllOverridesReg]` (`inf:442-510`) + `[WineDllOverridesRegNT]` (`inf:540-549`) | `HKCU\Software\Wine\DllOverrides`: `native, builtin` for atl, hhctrl.ocx, iernonce, itss, mshtml, mlang, msvcirt, msvcrt40, msvcrtd, odbccp32, riched20, riched32, softpub, dxdiagn, dplay*, dpn*, d3dxof, crypt32, devenum, hlink, jscript, quartz, rsabase, secur32, shdocvw, shdoclc, urlmon, wintrust, wscript.exe, odbc32, amstream; `dciman32=native`; `*docbox.api=""`; `*autorun.exe`, `*user.exe` = `native,builtin`; `*ctfmon.exe`, `*ddhelp.exe`, `*findfast.exe`, `*maildoff.exe`, `*mdm.exe`, `*mosearch.exe`, `*pstores.exe`, `*ieinfo5.ocx` = `builtin`; NT: msi, `*msiexec.exe`, ole32, oleaut32, olepro32, rpcrt4, wininet = `builtin`. AppDefaults: `cxwget.exe\DllOverrides\wininet=builtin`; `winewrapper.exe\DllOverrides\{crypt32,rsabase,rsaenh}=builtin`. |
| `[MiscReg]` (`inf:419-432`) | IE start page `http://www.codeweavers.com`; `HKCU\…\Explorer\Advanced\HideFileExt=0`; MailBeep → `C:\Windows\Media\Notify.wav`; Crystal Reports CommonFiles; **`HKCU\Software\CrossOver\SuppressAltLoader\{steam, steamsysinfo, conhost, UbisoftConnect, LauncherPatcher, RockstarService, RockstarErrorHandler}=0`**. |
| `[ColorsReg]` (`inf:412-417`) | `HKCU\Control Panel\Colors`: ActiveBorder/ButtonFace/ButtonLight/InactiveBorder/Menu = `228 228 228`. |
| `[FallbackAssociationReg]` (`inf:552-555`) | `HKLM\Software\Classes\CrossOverFallback\shell\Open\command` = `cxnative.exe -- cxnativeopen --background "%1"`. |
| `[ODBCReg]` (`inf:613-614`) | `DefaultDSNDir`. |
| `[ObsoleteRegHacks]` (`inf:374-409`) | deletes legacy per-app hacks (Valve DXLevel, iTunes, MouseHack, vc_redist msxml overrides, `MCC-Win64-Shipping.exe` concrt140, …). |
| `[CXBuiltins]…[WineCfg]` (`inf:619-640`) | menu entries `..\Builtin Tools\{Notepad, File Explorer, Command Shell, Wine Configuration}`. |

`share/wine/wine.inf` is the stock Wine inf plus CX hacks; the only display default is `HKLM\…\Hardware Profiles\Current\Software\Fonts\LogPixels=0x60` (96 dpi) (`wine.inf:518`); CW HACK 22435 registers `atidxx64.dll`, `nvapi64.dll`, `nvngx.dll` as fake DLLs (`wine.inf:739-742`).

**AppDefaults written at creation**: only the four `Explorer\Desktop=root` entries, the `winewrapper.exe`/`cxwget.exe` DllOverrides above, and (when `OutlookSecurity=1`, default on) `HKCU\Software\Wine\AppDefaults\Outlook.exe\DenyShellExecute="bat;com;cpl;exe;hta;lnk;pif;scr;vbe;vbs;wsf;wsh"` (`CXBT:238-244`; `etc/CrossOver.conf:347-348`). Per-app AppDefaults otherwise come from CrossTies (see app-tweaks.md).

## 5. High Resolution Mode (H4) — observed absence

| ID | Fact | Status |
|---|---|---|
| SH-TT-65 | `RetinaMode`, `LogPixels` (other than wine.inf's 96 dpi default), `HighRes*`, `Mac Driver` have **0 hits** in the launcher, all `cx*` scripts, `lib/perl`, templates, `crossover.inf`, `etc/CrossOver.conf`. The GUI strings show the feature as a bottle-level toggle that requires a reboot ("Reboot Bottle and Enable High Resolution Mode", "WARNING: Many Windows applications render incorrectly in high resolution mode", Retina/non-Retina mix notes). | observed (bounded negative) |
| SH-TT-66 | Historical-reference: `src/dlls/winemac.drv/macdrv_main.c:391-396` reads `HKCU\Software\Wine\Mac Driver\RetinaMode` (prefix-wide, deliberately not per-app: "The DPI and monitor sizes should be consistent for all processes in the prefix"); `src/programs/winecfg/x11drvdlg.c:232-237`, `304` read/write `HKCU\Control Panel\Desktop\LogPixels` falling back to `HKCC\Software\Fonts\LogPixels`. | historical-reference |
| SH-TT-67 | CrossTies touch `Mac Driver` only via `OpenGLSurfaceMode` (18), `EditMenu` (8), `UniqueMonitorNames` (3), `UsePreciseScrolling`, `RightOptionIsAlt`, `LeftOptionIsAlt`, `Decorated` (1 each); two ties set `HKLM\…\Hardware Profiles\Current\Software\Fonts\LogPixels` (dword 72 / 64, i.e. 114/100 dpi) per app. | observed |

Inference for ossover: "High Resolution Mode" = `HKCU\Software\Wine\Mac Driver\RetinaMode=y` (+ a DPI bump, plan says 192 — **not confirmed** by this pass; the GUI's exact LogPixels value and key are unknown since the writer is the GUI). Keep the plan's `retina` + `dpi` settings and require a bottle reboot (`wineserver -k` → restart), as CX does.

## 6. Sync defaults (H3)

| ID | Fact | Status |
|---|---|---|
| SH-TT-68 | A freshly created bottle gets **no** `WINEMSYNC`/`WINEESYNC` key: `create()` writes only the `[Bottle]` keys listed in §2 (`CXBT:191-208`), and the launcher never sets either (bounded grep: the only hits are the migration lines `CXBT:462-464`). | observed |
| SH-TT-69 | Wine reads `WINEMSYNC` as `getenv && atoi` (`src/dlls/ntdll/unix/msync.c:418-425`; `src/server/msync.c:533`) ⇒ unset = **off**. `WINEMSYNC_QLIMIT` tunes the Mach port-set queue limit (`server/msync.c:628-629`). Client/server mismatch is a hard error (`ntdll/unix/msync.c:589-600`) ⇒ changing it needs a bottle restart — matches the GUI's "Reboot Bottle and Enable MSync". | historical-reference + observed strings |
| SH-TT-70 | ESync does not exist in the 26.3.0 tree except in `kernel32/tests` (bounded grep); templates convert `WINEESYNC=1`→`WINEMSYNC=1` and drop `WINEESYNC` on upgrade (`CXBT:462-464`). | historical-reference + observed |
| SH-TT-71 | CrossTie path to MSync: `Steam` (c4.206, cxversion 26) → predependency `Game Launcher Dependencies` (c4.21822) → predependency `Enable MSync` (c4.21821), whose install profile is intentionally empty "There is custom logic in cxaiecore that makes this tie work" with `useif platform=Mac` (`crossover.tie:262229-262248`; the Steam block's `<predependency>` is at `16493`). ⇒ Installing Steam through CrossOver turns MSync on for that bottle (mechanism inside the GUI's `cxaiecore`, unknown). | observed (tie) / inferred (effect) |

ossover decision (H3), as first drafted here: default `sync=none` for parity with a raw CX bottle, `sync=msync` for the Witcher recipe and any Steam bottle (CX does the same via the tie chain). **Superseded by `decisions.md` 20/21**: msync by default on every msync-capable engine with CX's warning surfaced at `bottle create`, recipes override per workload, and `recipes/steam.json` must move to `sync=msync` (it still says `none`). Never set `WINEESYNC` on CX-derived engines (no implementation). Expose `WINEMSYNC_QLIMIT` only as an advanced engine knob.

## 7. Managed/stub bottles (for completeness, observed)

`cxbottle --create --scope managed` writes `Updater=wineprefixcreate`; the launcher then creates a per-user **stub** under `CX_BOTTLE_PATH` by running `wineprefixcreate --ref-dir <managed> <stub>` (`wine:575-604`), which replicates the managed tree according to `[ManagedUpdatePolicy]`, fixes `dosdevices`, runs `rundll32 shell32.dll,wine_update_symbolic_links`, writes the `files` list, and calls `--cx-hooks pre-create-stub/create-stub` (`wineprefixcreate:132-363`). ossover does not need multi-user bottles; ignore.
