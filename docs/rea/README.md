# REA evidence pass — CrossOver 26.3.0 (static, provider-free)

Task `inventory-signing-dylib` (plan §3 Phase 1 steps 1–6). Static only; nothing from the target trees was executed. Deep decompilation (Ghidra/Hopper) was **not** used in this pass — every REA record here comes from REA's `native-macos` provider (file/plutil/codesign/lipo/llvm-otool/llvm-nm/dyld_info/dwarfdump/vtool) or the `rea-artifact-graph` provider (pure header parsing).

## Scope and labelling

* EULA scope observed: no decompilation of `Contents/MacOS/CrossOver`, `lib/python/*.pyc`, `cxcompatdb.so` (headers/strings/imports only) or `lib64/apple_gptk/*` (signature/headers/strings only). Nothing was copied into the repo.
* Every fact in `signing.md` / `inventory.md` carries **observed | inferred | unknown**, an authority (`shipped-artifact` / `historical-reference` / `analyst-inference`) and a location: a REA Evidence ID (`ev_…`, only for actual REA tool output), a plain-shell observation (`shell:` + command), or `file:line` of a plain-text script.
* Hypotheses referenced: H1 launch chain/dyld, H2 renderer selection (`cxcompatdb.so` ↔ `prepend_dll_path`), H3 sync, H5 fork identity, H6 D3DMetal, H9 signing/entitlements (plan §3 Phase 1; §4/§5 "⟂REA" items).

## Artifact identities (observed, shipped-artifact)

| Artifact | SHA-256 | Size | Notes |
|---|---|---|---|
| `crossover-26.3.0.zip` | `8688e0848c4e5f79f1cc351cb52d32447da00c6c00cfd3b4bb2d164d44589a26` | 387,192,026 B | equals the CodeWeavers `.zip.sha256` sidecar (shell: `shasum -a 256`) ; REA root `art_80cc394e0ff2da15a9804828032700ecaaf941e7418bda407bbd0318d424e66f` |
| `crossover-sources-26.3.0.tar.gz` | `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872` | 149,054,023 B | shell: `shasum -a 256`; not opened with REA in this pass |
| unzipped `CrossOver.app` | — | 1,030,006,645 B on disk; 7,425 files, 91 symlinks, 816 dirs (shell `find`) | matches REA ZIP inventory (7,426 file occurrences incl. the zip root, 91 symlink, 816 directory) |

Key member hashes (from the REA ZIP inventory, Evidence `ev_e1b9f036…`; all re-verified by REA `open_binary` on the unzipped files):

| Path (under `CrossOver.app/Contents/`) | SHA-256 | Size |
|---|---|---|
| `MacOS/CrossOver` (universal x86_64+arm64) | `1d245f2f9f52bd56a120616fede8b1eb9cca9fa228319de04a2cbeabd8de7174` | 2,422,880 |
| `Info.plist` | `48d3fedca14d94c970184003bef34997ca1c3fdb479fe2e6c0268f98502fd28b` | 6,056 |
| `SharedSupport/CrossOver/CrossOver-Hosted Application/wine` (Perl) | `04da13c940c57919334520f2fee4adb2186edb41904faf8f86647a0a03114953` | 42,412 |
| `…/CrossOver-Hosted Application/wineloader` | `ed1318f573bbcd7f153c6fc4c0de66dcf5642b5967e9665991503acb29ea9159` | 33,040 |
| `…/CrossOver-Hosted Application/wineserver` | `f9c4ed146c7d6dfc94334255907d4e0658218585085ca2107a5181b4deb474fc` | 598,160 |
| `…/lib/wine/x86_64-unix/wine` (second loader exe) | `b5edb0444b5b25ba0aa5…` (shell) | 33,568 |
| `…/lib/wine/x86_64-unix/ntdll.so` | `ab32585d767ae631154235861a2e0e8ea61bd09267a2dd341a439e3e8ed071fc` | 608,032 |
| `…/lib/wine/x86_64-unix/winemac.so` | `a46e1c63a5096210626d64ef6c62ddea7632f95dbcf437b1a3bf006d43dcf532` | 467,456 |
| `…/lib/wine/x86_64-unix/winevulkan.so` | `5bdbc651ada2613f6df7a86a1632faef464e03f4a141a9cea18dd5d6871332b1` | 582,928 |
| `…/lib/wine/x86_64-unix/cxcompatdb.so` | `a423c706e424c81537f19c2c04691689dcab3dc8d005d3926e98c3ad1f4b1df7` | 116,976 |
| `…/lib/dxmt/x86_64-unix/winemetal.so` | `df3c7b88696039768b4800b60067fe6bca1b6188cd8e294bc25058f4412c83b3` | 24,169,040 |
| `…/lib64/apple_gptk/external/libd3dshared.dylib` | `5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995` | 95,952 |
| `…/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal` | `05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8` | 5,263,744 |

## Tool versions (observed on this host, 2026-10-13)

| Tool | Version |
|---|---|
| REA MCP server | `rea-agents` 6.4.0 via `npx` (`~/.npm/_npx/<hash>/node_modules/rea-agents`), MCP protocol 2025-11-25, tools catalog digest `25802f6d…`; skill `reverse-engineer-anything` v37 |
| REA providers used | `native-macos` (Xcode toolchain wrappers), `rea-artifact-graph` v1. Deep providers: Ghidra `not_configured`, Hopper launcher `available` (not used), IDA `not_configured` |
| macOS | 26.7.1 (25G241), Apple silicon (arm64) host |
| Xcode / cctools | Xcode 27.0 (27A266a); llvm-otool/otool cctools-1040; llvm-nm; `dyld_info`; `codesign` (no version flag) |
| jq / node | jq-1.7.1-apple; node v26.11.1, npx 11.20.0 |

## Evidence files (this pass)

| File | Content | Records | SHA-256 |
|---|---|---|---|
| `evidence/crossover-26.3.0-zip-inventory.json` | `inspect_artifact` (`ev_bc5227c990b5326a34df7372981af043ebfa6572b440d15ad804f20c3c988a1a`) + `inventory_artifact` (`ev_e1b9f0361c4a8777bdd3f242ddaa6cb565999cb4f303d4788e0f97c1a3ec9a2f`) of the ZIP; 6,550 nodes / 8,241 edges / 8,333 occurrences; graph sha `a40717e600726fee893eb256aaa72cb79ad89fb70827fe616d14b84095210db5`, manifest `agm_9188c83bfdc421e0af27118b4525212f263692a19954f09a7d01be9b84b4de23`; integrity contradictions: none | 2 | `c8383bcca910a2da0b737ab22ab3fad3fcad0cef84acc198babf24f87bd6d1da` |
| `evidence/crossover-26.3.0-inventory.json` | plist, signatures, architectures, Mach-O headers and dyld traces for the 10 Mach-O targets below (exported before `close_binary`) | 34 | `59d6e232255fba1b88d51a58c4814e85bd1adc6e014eb338a1179c0d0463c0dd` |

Why two files: the ZIP records left the live ledger when that target was closed (checkpoint after the close held 24 records, none from the ZIP), so the ZIP inventory was exported on its own first. Other `evidence/*` files in this directory (`shell-*`, `ntdll-*`, `winemac-*`, `sources-pass-*`, `cli-*`) were produced by the parallel deep-analysis / sources agents, not by this pass.

## Evidence ID index (final bundle)

| Target | inspect_signature | list_architectures | inspect_macho | trace_dylib_resolution |
|---|---|---|---|---|
| `CrossOver.app` → `Contents/MacOS/CrossOver` | `ev_fc6c33c8993683232a1a547d394e54aa3eb9dbe5eb3ca1e7f091d14347ca575d` | `ev_89ea221bebe0ae6933da41270115a461618febeab15d1e9559e11e9fbc2099d0` | — (inspect_plist `ev_9ce4d67ea24e85b4827095b3e00c98025336d023d060dbaa2e8437e5ffd5e82d`) | x86_64 whole bundle `ev_83f237c6fceffda55d79e2a4735c574d58ae77a3c599982f5c4b3a45743cf81c`; arm64 GUI root `ev_b53dd3338780632df80febd8d32db5c48393647bff2a76f1756d64b1461d6584` |
| `wineloader` | `ev_f4e1b20c823d746a2d8c06e4f03d6c727236ba256384e12ee5f431d51fec7886` | `ev_9bce850112c5afcd422edc5b5aa9c386626eb1e96f7593b6aa5eed87e2454dbb` | `ev_ad4142d7d56a64a854d1c721cd5aeb4f54b4480c14fab50c2ba47add0db9cc31` | `ev_c42494711798dba1cb4de820f0d7146864f2c97b20d5eb9cf099a177be3a8d44` |
| `wineserver` | `ev_5fe15767a2a422534f1393a89c7ce1e98dda7e0ad49fc6232694d8206b22abca` | `ev_9ec9cced22a0eeb284c01205d44d399a7c453bb38ffae92b93bdd0c8f1b94765` | — (otool only) | `ev_e339b135c922de413a0dd9b375123c532864c921884f21f0c9ab3d5be32c4289` |
| `ntdll.so` | `ev_620e7207cb0aaadb58ca2d3aac446e031f510f3bc8b62673fc202fc42ada848d` | `ev_958f58d9a301736a4053c832e515a1a774e0de272bfbde05d2ffac41eebaeeb7` | `ev_4a5a4ebdce76503ec342946774abfcd36ac4e0c0e69ab994e99ee6530b929694` | `ev_16a5f6393267481af28ca4cb42597244f2963aa482122233f7662b62e32ef589` |
| `winemac.so` | `ev_4e553a92bdab6a029cd60bd8c52f9b1946c04861635092645ba0b964c46e36cf` | — | `ev_b62941e8ac06ddfa9453e1ac87b77772bcbe5f4bcbeb1866c59a50ef2e1b4359` | `ev_8f7295e321747f91b3a164fb5ddadc63bb4510934ca22c1072e531793e7b5eea` |
| `winevulkan.so` | `ev_b2f8d7d2fbe7c260e7401ea51a2d8006f2e593ce56d3af422d1eead46fb17426` | — | `ev_f2ef02efce70b02e194b2215b80c3f366b1d09b08fff153da7e32ea9b57bd4ac` | — |
| `cxcompatdb.so` | `ev_a0bc0106e77f25b990a702d54a481cc0489ff7cd9ce061d2bdc673a2eb759d63` | — | `ev_73fb4495cb8254f0822bd88a02677ac7a77dd2bc8ec382792ae45d2c6995963f` | `ev_b5d8cc72263f15be30e9c1a14ae569ca20c2313842362fc1003538f7bbbea87d` |
| `lib/dxmt/x86_64-unix/winemetal.so` | `ev_ace51ea4be43ca641340abdb5945e7aefca99ef82b78159b082d7a3373fb5697` | — | `ev_153f5788a79bbeaf27b5819785b9fc0ca760f1ed7b7e5819bb24b6165a2d7a78` | `ev_a8b649befd97cee5c2de5347759d1a8ac77309f560fe7b264c6d93f8757bbd11` |
| `libd3dshared.dylib` (= `apple_gptk/wine/x86_64-unix/d3d11.so` symlink target) | `ev_a2a71be85f2f7b40c73b12cd2a191ba9e749413473fafeb48bc4b2e1dd025fbd` | `ev_d837524aa3a54c0680f256293267335e6894d1f0d1aa0f28e51085a1ec74f6e6` | `ev_b7c8967dda45080913ff50b235ff79a204c80bc18cf2d41918b18570527d3b57` | `ev_b5f965702b1f6b2bc93106062733de5f179ca8f6c16add4c88930a38f7b165c0` |
| `D3DMetal.framework/Versions/A/D3DMetal` | `ev_46204c3dd654adab5f870331653ae0f494a82a6fa7a160c7d0ed94d6747a9bca` | `ev_d500ca699ddb360f94b5864d735b9448313459f0212ddeaa54e4fe563d1da6cb` | `ev_9e546d42475eb43edfc55fcf26cff902c9abe3456f7b97d3a7c5191e82a3ff1e` | — |

## Reproduction order

Paths: `S=<scratchpad>/rea-targets` (the session scratch directory), `APP=$S/app/CrossOver.app`, `CX=$APP/Contents/SharedSupport/CrossOver`.

1. `shasum -a 256 $S/zip/crossover-26.3.0.zip $S/src/crossover-sources-26.3.0.tar.gz`; compare with `$S/zip/crossover-26.3.0.zip.sha256`.
2. `open_binary {path:$S/zip/crossover-26.3.0.zip}` → `inspect_artifact {}`. The complete result (~10.5 MB) exceeds the MCP frame (`resource_constraint`, `transport`); it is retained, so `export_evidence_bundle {path:…/crossover-26.3.0-zip-inventory.json}` then `jq` on `.records[1].normalized_result.{manifest,nodes,occurrences}`.
3. `project_apple_application_graph` was **skipped**: it takes the inventory Evidence inline and that record alone is 10.5 MB, above the 10,484,736-byte MCP budget. Roles were taken from `find`/`file`/`ls -l` on `$APP` instead (shell observations). `close_binary {}`.
4. `open_binary {path:$APP}` (REA binds the main executable) → `inspect_plist {}`, `inspect_signature {}`, `list_architectures {}`, `trace_dylib_resolution {architecture:"x86_64"}` (saved by the client to a file, 86 KB; mined with `jq`), `trace_dylib_resolution {architecture:"arm64", roots:["Contents/MacOS/CrossOver"]}`.
5. For each Mach-O in the index above: `open_binary {path}` → `inspect_signature {}`, `list_architectures {}` (where asked), `inspect_macho {}` (ntdll/winemac/winemetal/D3DMetal overflow the client frame and are saved to files; mined with `jq`), `trace_dylib_resolution {architecture:"x86_64"}`. Cross-checks: `codesign -dvvv`, `codesign -d --entitlements -`, `otool -L`, `otool -l | grep -A2 LC_RPATH`, `nm -gU`, `nm -u`, `dyld_info -exports/-imports`, `strings -a`.
6. `export_evidence_bundle {path:…/crossover-26.3.0-inventory.json}` **before** `close_binary {}`.

## Limitations of this pass

* No execution, no runtime capture; dyld traces are header parsing (system paths "undetermined", code-signing/library-validation rejections not modelled).
* `trace_dylib_resolution` on a single dylib uses that dylib's directory as the analysed root, so cross-directory `@rpath` candidates are reported `escapes-target`/`unresolved`; the inferences about runtime resolution in `inventory.md` are analyst inferences from dyld's documented rpath rules.
* `inspect_macho` exports/imports are `exhaustive: false` (merged nm + dyld_info; stripped symbols may be absent).
* Notarization ticket validity was not checked (would need `spctl`/`stapler`; see `signing.md` unknowns).

## Reports

* `signing.md` — H9: signatures, hardened runtime, entitlements, Apple-signed GPTK parts, packaging decisions.
* `inventory.md` — bundle map with sizes/arches, dylib graph summary (H1/H6), Mach-O export/import facts (H2/H5/H6), component versions.

Sibling reports in this directory written by the parallel agents (not by this pass): `env-table.md`, `renderer-selection.md`, `bottle-format.md`, `wine-fork.md`, and any `ledger.md`/`unknowns.md`; their Evidence files are the `shell-*`, `ntdll-*`, `winemac-*`, `sources-pass-*`, `cli-*` entries under `evidence/`.
