# Signing, hardened runtime and entitlements (H9)

Authority for every row: `shipped-artifact` unless marked otherwise. "REA" = Evidence ID in `evidence/crossover-26.3.0-inventory.json`; "shell" = `codesign -dvvv` / `codesign -d --entitlements -` on the unzipped bundle (cross-check; identical results).

## Signature table (observed)

| Target | Identifier | Format | Authority chain | Team | CodeDirectory | Hardened runtime | Timestamp (secure) | Evidence |
|---|---|---|---|---|---|---|---|---|
| `CrossOver.app` (bundle) | `com.codeweavers.CrossOver` | app bundle, Mach-O universal (x86_64 arm64) | Developer ID Application: CodeWeavers Inc. (9C6B7X7Z8E) → Developer ID CA → Apple Root CA | 9C6B7X7Z8E | v=20500, sha256, hashes 297+7, Sealed Resources v2 rules=13 files=6632 | **yes** (`flags=0x10000(runtime)`, Runtime Version 15.1.0) | 15 Jul 2026 16:50:45 | REA `ev_fc6c33c8…`; shell |
| `Contents/MacOS/CrossOver` | same as bundle | universal | same | same | same | yes | same | REA `ev_fc6c33c8…`, arch `ev_89ea221b…` |
| `Frameworks/Sparkle.framework` (2.4.1) | `org.sparkle-project.Sparkle` | bundle, universal | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400, files=108 | no flag | 16:49:36 | shell |
| `Frameworks/Python.framework` (3.13.3) | `org.python.python` | bundle, universal | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400, files=752 | no flag | 16:49:54 | shell |
| `CrossOver-Hosted Application/wineloader` | `com.codeweavers.CrossOver.wineloader` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20500, hashes 4+7 | **yes** | 16:50:42 | REA `ev_f4e1b20c…`, arch `ev_9bce8501…` |
| `lib/wine/x86_64-unix/wine` (second loader executable) | `com.codeweavers.CrossOver.wineloader` (same identifier) | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20500 | **yes** | — | shell |
| `CrossOver-Hosted Application/wineserver` | `com.codeweavers.CrossOver.bin.wineserver` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20500, hashes 141+7 | **yes** | 16:50:43 | REA `ev_5fe15767…`, arch `ev_9ec9cced…` |
| `lib/wine/x86_64-unix/ntdll.so` | `com.codeweavers.CrossOver.lib.ntdll_so` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400, `flags=0x0` | no (library) | 16:50:00 | REA `ev_620e7207…`, arch `ev_958f58d9…` |
| `lib/wine/x86_64-unix/winemac.so` | `…lib.winemac_so` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400 | no | 16:50:00 | REA `ev_4e553a92…` |
| `lib/wine/x86_64-unix/winevulkan.so` | `…lib.winevulkan_so` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400 | no | 16:50:02 | REA `ev_b2f8d7d2…` |
| `lib/wine/x86_64-unix/cxcompatdb.so` | `…lib.cxcompatdb_so` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400 | no | 16:49:59 | REA `ev_a0bc0106…` |
| `lib/dxmt/x86_64-unix/winemetal.so` | `…lib.winemetal_so` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400, hashes 5851+2 | no | 16:50:30 | REA `ev_ace51ea4…` |
| `lib64/libMoltenVK.dylib` | `…lib64.libMoltenVK_dylib` | thin x86_64 | CodeWeavers Developer ID | 9C6B7X7Z8E | v=20400 | no | 16:50:39 | shell |
| `lib64/apple_gptk/external/libd3dshared.dylib` | `com.apple.libd3dshared` | thin x86_64 | **Software Signing → Apple Code Signing CA → Apple Root CA** | not set | v=20400, hashes 19+2 | no | none | REA `ev_a2a71be8…`, arch `ev_d837524a…` |
| `lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal` | `com.apple.D3DMetal` | bundle, thin x86_64 | **Software Signing (Apple)** | not set | v=20400, hashes 1271+3, Sealed Resources files=8, Info.plist entries=19 | no | none | REA `ev_46204c3d…`, arch `ev_d500ca69…` |
| `D3DMetal.framework/…/Resources/{libdxcompiler,libdxilconv,libmetalirconverter}.dylib`, `libdxccontainer.dylib` | `com.apple.libdxcompiler`, `com.apple.libdxilconv`, `com.apple.libmetalirconverter`, `libdxccontainer-55554944e138…` | thin x86_64 | Software Signing (Apple) | not set | — | no | — | shell |

Designated requirements (observed, REA): CodeWeavers binaries use `identifier "<id>" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "9C6B7X7Z8E"`; the Apple parts use `identifier "com.apple.D3DMetal" and anchor apple` / `identifier "com.apple.libd3dshared" and anchor apple`.

Sweep (shell, every Mach-O under `Contents/SharedSupport/CrossOver`, 113 thin x86_64 files): **0 unsigned**; exactly 6 files carry a non-CodeWeavers authority, all `Software Signing` (Apple): `libd3dshared.dylib`, `D3DMetal`, and the four `D3DMetal.framework/Versions/A/Resources/*.dylib`. Everything else is CodeWeavers Developer ID.

## Entitlements (observed; REA `inspect_signature` + `codesign -d --entitlements -`)

| Executable | Entitlements |
|---|---|
| `Contents/MacOS/CrossOver` (GUI) | `com.apple.security.automation.apple-events`, `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.device.audio-input`, `com.apple.security.device.camera` |
| `wineloader`, `lib/wine/x86_64-unix/wine`, `wineserver` | `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.disable-executable-page-protection`, `com.apple.security.cs.disable-library-validation`, `com.apple.security.device.audio-input`, `com.apple.security.device.camera` |
| all `.so`/`.dylib` (incl. Apple parts) | none (`entitlements: null`) — entitlements are an executable property |

Absent on every CodeWeavers executable (observed): `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-dyld-environment-variables`, `com.apple.security.get-task-allow`, `com.apple.security.cs.debugger`, any sandbox or network entitlement.

## Info.plist facts relevant to packaging (observed, REA `ev_9ce4d67e…`)

* `CFBundleIdentifier` `com.codeweavers.CrossOver`; `CFBundleShortVersionString` `26.3`; `CFBundleVersion` `26.3.0.39832`; `NSPrincipalClass` `CXApplication`; `NSMainNibFile` `MainMenu`.
* `LSMinimumSystemVersion` **10.15** (the app), but `D3DMetal`, `libd3dshared.dylib` and DXMT's `winemetal.so` carry `LC_BUILD_VERSION minos 14.0` (REA `ev_9e546d42…`, `ev_b7c8967d…`, `ev_153f5788…`); Wine's own `.so`/loader are minos 10.15, SDK 15.1 (REA `ev_4a5a4ebd…`, `ev_ad4142d7…`). D3DMetal's own `Info.plist` says `LSMinimumSystemVersion 14.0` (shell `plutil`). ⇒ *inferred*: the D3DMetal and DXMT renderers need macOS 14+, the rest of the engine does not.
* Build toolchain: `DTXcode 1610` (`16B40`), `DTSDKName macosx15.1`, `BuildMachineOSBuild 23J220`; D3DMetal: `DTXcode 1630` (`16E140`), `DTSDKName macosx15.4.internal`, `BuildMachineOSBuild 23A344013`, `version.plist` `ProjectName D3DRendererMetal`, `SourceVersion 32047000000000`, `CFBundleShortVersionString 3.0` (shell `plutil`).
* Sparkle: `SUFeedURL https://www.codeweavers.com/xml/versions/cxmac.xml`, `SUPublicEDKey HtsRMTX0R0Oqe+aWIftCC6Q4Zck7L7n9DpXkbrp7tww=`, `SUPublicDSAKeyFile dsa_pub_mac_upgrade.pem`; `NSAppTransportSecurity.NSAllowsArbitraryLoads true`.
* Document types: `.cxarchive` (Bottle Archive), `.lnk` (Editor), `com.microsoft.windows-executable` (`LSHandlerRank Default`), `.c4p` (Installation Profile), `.tie`/`.tie-CrossOver`/`.tie-CrossOverGames` (CrossTie), `public.volume`; exported UTI `com.codeweavers.crossover.log` (`.cxlog`); URL schemes `com-codeweavers-crossover-crosstie`, `com.codeweavers.private-CrossOver-app-scheme`, `com.codeweavers.private-CrossOver-crosstie-app-scheme`.
* **No `LSEnvironment` key** (observed: absent from the parsed plist) — all Wine environment is set by the Perl launcher, not by LaunchServices.
* `NSAppleEventsUsageDescription`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` present (match the TCC entitlements above).
* `Contents/CodeResources` (7,743 B, "data") exists beside `_CodeSignature/` — *inferred (analyst-inference)*: this is the location `stapler` writes a notarization ticket, so the app is notarized and stapled; not validated (see unknowns).

## Interpretation (inferred, analyst-inference unless noted)

1. **Signing order**: library timestamps 16:49:59–16:50:39, loaders 16:50:42–43, app 16:50:45 (observed) ⇒ inside-out signing with one Developer ID identity and secure timestamps; the final `--deep`-equivalent seal covers 6,632 resource files.
2. **Hardened runtime is on every executable** (GUI, both loaders, wineserver) and the loaders opt out of the three protections Wine needs: unsigned executable memory, executable-page protection (ntdll.so carries `HACK: exec fault on executable page` / `HACK: write fault on a w|x page` strings — observed, shell `strings`), and library validation.
3. **`disable-library-validation` is load-bearing**: with hardened runtime, dyld refuses libraries not signed by the same Team ID or by Apple. The process mixes CodeWeavers-signed Wine/DXMT/MoltenVK libraries with Apple "Software Signing" libraries (`libd3dshared.dylib`, `D3DMetal`), and bottles load third-party native code; without this entitlement the GPTK path and any non-CodeWeavers dylib would be rejected.
4. **`allow-dyld-environment-variables` is absent** ⇒ hardened `wineloader`/`wine`/`wineserver` ignore `DYLD_*` variables. CrossOver therefore cannot (and does not) rely on `DYLD_FALLBACK_LIBRARY_PATH`/`DYLD_FALLBACK_FRAMEWORK_PATH` to find D3DMetal; it passes an absolute path in `CX_APPLEGPTK_LIBD3DSHARED_PATH` (Perl launcher `CrossOver-Hosted Application/wine:680-683`; ntdll.so string `CX_APPLEGPTK_LIBD3DSHARED_PATH` and `Loading libd3dshared.dylib failed: %s`, shell), and `libd3dshared.dylib` finds `@rpath/D3DMetal.framework/D3DMetal` through its own `LC_RPATH @loader_path` (REA `ev_b7c8967d…`; strings `@rpath/D3DMetal.framework/D3DMetal`, `/System/Library/Frameworks/D3DMetal.framework/D3DMetal`, `GFXTHandle && "Failed to dlopen D3DMetal"`, shell).
5. **Apple GPTK parts are redistributed byte-identical**: their Apple signatures are intact (`codesign` verifies the embedded CodeDirectory; any modification would break it), with no CodeWeavers re-signing and no timestamp. The D3DMetal bundle's `LC_ID_DYLIB` is `/System/Library/Frameworks/D3DMetal.framework/Versions/A/D3DMetal` (REA `ev_9e546d42…`) although it is shipped outside `/System`; its `LC_RPATH`s (`@executable_path/../Frameworks`, `@loader_path/Frameworks`, `@loader_path/../Resources`, `@loader_path/Resources`) make `@rpath/libmetalirconverter.dylib` and `@rpath/libdxccontainer.dylib` resolve to `Versions/A/Resources/` (REA `ev_9e546d42…`; files present, shell `ls`).
6. **TCC**: camera/microphone entitlements on the loaders (not only the GUI) because Windows apps access devices from the `wineloader` process (observed entitlements + usage strings; the causal reading is inference).

## ossover decisions fed by H9

| Decision | Basis |
|---|---|
| Sign every executable with hardened runtime and exactly these loader entitlements: `cs.allow-unsigned-executable-memory`, `cs.disable-executable-page-protection`, `cs.disable-library-validation`, `device.audio-input`, `device.camera`; GUI adds `automation.apple-events`. | observed table above |
| Do **not** add `cs.allow-dyld-environment-variables` unless the engine design keeps `DYLD_FALLBACK_*` for D3DMetal (plan §4 "⟂REA activation env"); the CrossOver approach is an absolute-path env var + `@loader_path` rpath, which works under hardened runtime. | inferred #4 |
| Keep the GPTK files byte-identical (never re-sign, never strip, never rewrite install names); reference them by absolute path from the engine pack. Re-signing breaks `anchor apple` and (plan §5) is outside the GPTK licence. | inferred #5 |
| Libraries need no entitlements and no runtime flag; sign them with the same identity so library validation could be re-enabled later only if all third-party code is dropped (it cannot be, bottles load foreign DLL-side native code). | observed/inferred #3 |
| Declare `LSMinimumSystemVersion` per engine: 10.15 for plain Wine, 14.0 when the D3DMetal or DXMT overlay is active. | inferred (minos facts) |
| Dev builds that need REA runtime capture (`observe_native_calls`) must add `get-task-allow`; CrossOver release builds do not have it. | observed absence |
| Notarize + staple the app (`Contents/CodeResources`) for distribution outside the App Store. | inferred (stapled ticket) |

## Unknowns

| # | Question | Needed to resolve |
|---|---|---|
| U-S1 | Is the stapled notarization ticket valid / is the bundle notarized? | `xcrun stapler validate CrossOver.app` or `spctl -a -vv -t execute CrossOver.app` (Gatekeeper assessment; may contact Apple). Not run in this static pass. |
| U-S2 | Does CrossOver's GUI pass `get-task-allow`-less debugging restrictions to child Wine processes in any other way (e.g. `com.apple.security.cs.debugger` on a helper)? | None found in the 13 executables REA listed as roots (`ev_83f237c6…`); Sparkle helper entitlements were not dumped individually. |
| U-S3 | Why do `wineloader` and `lib/wine/x86_64-unix/wine` share the identifier `com.codeweavers.CrossOver.wineloader` although they are different binaries (33,040 vs 33,568 B, different SHA-256)? | Likely two builds of Wine's `loader/` main (bin copy vs libdir copy); would need the build scripts (not in the sources tarball pass). Harmless for H9. |
