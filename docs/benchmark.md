# The ossover benchmark

One game, one place, one set of settings, one method, so that a number from this Mac and a number from yours mean
the same thing. **No results have been measured yet**; every row in the table below says "pending" and will be
replaced only by a `result.json` produced by `ossover bench`.

## Definition

| Item | Value |
|---|---|
| Game | The Witcher 3: Wild Hunt **4.04**, Steam app 292030, branch `next-gen`, the **DirectX 11** executable (`bin/x64/witcher3.exe --launcher-skip -skipStartScreen`) |
| Scene | **Hierarch Square, Novigrad**, daytime, standing at the fountain, a save game loaded from the main menu (the newest save in `gamesaves/`; the owner creates it once in-game) |
| Bottle | 64-bit Windows 10 prefix, **msync**, RetinaMode on at 96 dpi, isolated user folders, `ROSETTA_ADVERTISE_AVX=1` |
| Renderer | **DXMT** (default); DXVK for the matrix |
| Game settings | **HairWorks off** (`[Rendering] HairWorksLevel=0`), **borderless 2560x1600** (`[Viewport] Resolution="2560x1600"`, `FullScreenMode=1`), VSync off, the **High** preset. Set by `recipes/witcher3.json`; `bench run` checks them before it starts |
| Window | 45 s load, 20 s warm-up, **60 s measured**, 15 s cooldown; **3 runs**, **median** reported |
| Pass line | **≥ 60 fps average** and **≥ 30 fps 1% low** over the 60 s, and **≥ 0.9×** the identical run under the CrossOver 26.3 trial on the same Mac, save and settings |
| Reference machine | Apple M5 Pro, 16 cores, 24 GB, built-in 3024x1964 panel, macOS 26.7.1 |

2560x1600 is not a display mode of the 3024x1964 panel, which is why the window is borderless with RetinaMode on:
Wine gets a 2560x1600 surface and the Mac driver scales it. Any other machine should keep the same resolution so the
GPU work is comparable; the panel size is recorded in `result.json` either way.

Why these choices: 4.04 is the last DirectX 11 build of the game (5.x Remastered is DirectX 12 only, which no open
renderer provides today); HairWorks has no working path on any Mac renderer; neither open renderer implements D3D11
stream output (DXVK-on-MoltenVK lacks transform feedback; DXMT 0.80 logged `CreateGeometryShaderWithStreamOutput: not
supported` seven times at the game's first launch on 2026-10-14), so sirens, rotfiends and hounds may be invisible under
both, and Apple's D3DMetal is the only macOS path with that feature; DXMT is the default on the field-report and
performance grounds of the plan (§2), not because it closes that gap; msync is the synchronisation CrossOver uses for
every Steam install and the only one that avoids wineserver round trips for Mach semaphores.

## Method: Apple's Metal Performance HUD as the frame-time source

The harness never patches the game or the renderer. It uses the frame log Apple's Metal Performance HUD writes when
asked to, which works for DXMT, DXVK, wined3d and D3DMetal alike (`MTL_HUD_ENABLED` is read by all of them, D3DMetal
included):

| Variable | Set by `bench run` | Effect |
|---|---|---|
| `MTL_HUD_ENABLED=1` | always | Enables the HUD machinery; required, `MTL_HUD_LOG_ENABLED=1` alone logs nothing |
| `MTL_HUD_LOG_ENABLED=1` | always | Logs one `metal-HUD:` line per second with the frames of that second |
| `MTL_HUD_HIDDEN=1` | always, unless `--hud-visible` | Keeps the overlay off screen. With the overlay drawn the log carries every frame twice and the harness halves the pairs; hidden is the measurement configuration |
| `WINEDEBUG=-all` | always | No Wine debug output competing for the log |

Each line has the shape

```
metal-HUD: <firstFrame>,<gfxMemoryMB>,<processMemoryMB>,<interval0>,<gpuTime0>,<interval1>,<gpuTime1>,…
```

where `interval` is the present-to-present time of a frame and `gpuTime` its GPU time, both in milliseconds. The
line reaches the process's stderr, which ossover captures into the bottle's wine log, and the unified log (`log
stream --style ndjson --predicate 'eventMessage BEGINSWITH "metal-HUD:"'`), where the frame list is `<private>`
and only the header fields survive. The wine log tail is therefore the primary source and the unified log the
cross-check; only lines from the prefix's own processes count.

From the measured 60 s window:

| Statistic | Formula |
|---|---|
| **avg fps** | `frames / Σ interval` |
| **1% low** | `1000 / p99(interval)`, the frame rate of the 99th-percentile frame time |
| p50 fps | `1000 / p50(interval)` |
| GPU time | mean `gpuTime` |
| frames, seconds | count and `Σ interval` |

Three runs; the reported value is the per-statistic median. `result.json` also records the engine id and
`wine --version`, the renderer (kind, pack, overlay strategy), the effective sync, `sw_vers`, the hardware, `pmset -g
therm` before and after, whether the target was met, and the per-run menu-reached time. `caffeinate -dims` keeps the
Mac awake for the duration.

The run itself: launch → wait for the main menu (a window for the pid, not black) → press the load key in the game's
window (Accessibility access; or `--manual-load` for a countdown in which you load the save yourself) → 45 s load →
20 s warm-up → 60 s measured → screenshot → cooldown → next run. Outputs under the bottle,
`results/<timestamp>/{hud.ndjson, wine.log, screenshot.png, result.json, …}`. The DXMT per-process logs and the
`user.settings` in effect are copied beside them.

### The reference row: CrossOver 26.3

`ossover bench attach --pid <pid> --label crossover-26.3` measures a game launched by something else for the same
60 s with the same statistics. For the CrossOver trial: set `MTL_HUD_ENABLED=1` and `MTL_HUD_LOG_ENABLED=1` with
`launchctl setenv` before launching CrossOver (GUI apps inherit the launchd environment), load the same save with
the same `user.settings`, then attach. The trial's EULA must be accepted by the person running it; the reference
number is a runtime observation and is labelled as such, separate from the static evidence in `docs/rea/`.

CodeWeavers' own CrossTie for the title selects DXVK, so the like-for-like comparison is **CrossOver + DXVK** against
**ossover + DXVK**; what CrossOver's "Auto" picks on an M5 Pro is unknown (`U-1` in `docs/rea/unknowns.md`), so a
**CrossOver + DXMT** row is measured too.

## Results

All pending. Numbers appear here only when copied from a committed `docs/benchmark-results/<run>/result.json`.

### Bootstrap engine — `x64-frankea-wine11.16-cx26.3-v4.6.4b1` (Wine 11.16 + CrossOver 26.3 patches)

| Renderer | Sync | avg fps | 1% low | p50 fps | GPU ms | Runs | Date | result.json |
|---|---|---:|---:|---:|---:|---:|---|---|
| dxmt | msync | pending | pending | pending | pending | — | — | — |
| dxmt | none | pending | pending | pending | pending | — | — | — |
| dxvk | msync | pending | pending | pending | pending | — | — | — |
| dxvk | none | pending | pending | pending | pending | — | — | — |

(esync is not compiled into CrossOver-derived trees, so there is no esync row for this engine.)

### Own engine — `x64-ossover-cx26.3-r1` (CrossOver 26.3.0 LGPL sources + patches 0001/0003/0014)

| Renderer | Sync | avg fps | 1% low | p50 fps | GPU ms | Runs | Date | result.json |
|---|---|---:|---:|---:|---:|---:|---|---|
| dxmt | msync | pending | pending | pending | pending | — | — | — |
| dxmt | none | pending | pending | pending | pending | — | — | — |
| dxvk | msync | pending | pending | pending | pending | — | — | — |
| dxvk | none | pending | pending | pending | pending | — | — | — |
| d3dmetal (user-imported GPTK) | msync | pending | pending | pending | pending | — | — | — |

### Reference — CodeWeavers CrossOver 26.3.0 trial (`bench attach`)

| Renderer | Sync | avg fps | 1% low | p50 fps | GPU ms | Runs | Date | result.json |
|---|---|---:|---:|---:|---:|---:|---|---|
| dxvk (the CrossTie's choice) | msync | pending | pending | pending | pending | — | — | — |
| dxmt | msync | pending | pending | pending | pending | — | — | — |

### Verdict

Pending. The pass line is evaluated per row by `ossover bench` (`meetsTarget` in `result.json`) and the 0.9× ratio
is computed from the two DXVK rows (and, for information, the two DXMT rows) once both exist.

## Recording a result

```sh
ossover bench run --bottle witcher3 --program witcher3 --runs 3 --json > /tmp/bench.json
# copy the run directory's result.json into the repo, named by what it measured:
mkdir -p docs/benchmark-results/2026-10-xx-x64-frankea-wine11.16-cx26.3-v4.6.4b1-dxmt-msync
cp "$OSSOVER_HOME/bottles/witcher3/results/<ts>/result.json" docs/benchmark-results/<that dir>/
```

Then add the row above from the file. `hud.ndjson` stays out of git (it is in `.gitignore`); `result.json` carries
the statistics. A row from another machine goes in a separate table headed by that machine; it does not replace the
reference-machine rows.

What invalidates a run and makes the harness refuse or mark it: a save that is not the newest, `user.settings` that
differ from the profile, a thermal state other than nominal before the run, fewer HUD frames than the window should
hold, a window that never appeared, or a wineserver started with a different sync mode than requested.
