<!-- One change per pull request. Link the issue it closes. -->

## What this changes

<!-- One paragraph: what, and why now. -->

Closes #

## Kind of change

- [ ] Bug fix
- [ ] Feature
- [ ] Recipe (new or changed `recipes/*.json`)
- [ ] Engine build (`engine/`)
- [ ] Docs or REA evidence (`docs/`)
- [ ] CI or tooling

## How I tested it

<!-- Commands run, engine id, macOS version, chip. For a game: the exact `ossover` commands and the verdict. -->

## Checklist

- [ ] `swift build` and `swift test` pass locally
- [ ] New or changed behaviour has tests (swift-testing under `Tests/OssoverKitTests`), or the PR says why it cannot
- [ ] Engine scripts changed: `bash -n engine/*.sh` and `./engine/selftest.sh` pass
- [ ] JSON under `engines/`, `renderers/` and `recipes/` passes `python3 -I .github/scripts/catalog_check.py .`
- [ ] **No proprietary CrossOver code or data.** Nothing is copied from CrossOver's GUI, `.pyc` tooling, `cxcompatdb.so`, CrossTies, `cxfixes.xml` or its compatibility database. Behaviour learned from the LGPL sources or the shipped bundle is cited to a `docs/rea/ledger.md` row (`REA L-nn`) or a `decisions.md` number, not pasted
- [ ] **Recipes are CC0.** Every new or changed recipe has `"license": "CC0-1.0"` and contains only my own words and settings
- [ ] No Apple D3DMetal / Game Porting Toolkit files, hashes of its files, or download links are added
- [ ] Every new download is pinned: `source.sha256` is a real hash (a `TBD` carries a `TODO` note saying why)
- [ ] New source files start with `// SPDX-License-Identifier: GPL-3.0-or-later`; adapted code keeps its original copyright line and `NOTICE.md` is updated
- [ ] No secrets, Steam credentials or personal paths in code, fixtures or logs
- [ ] Benchmark numbers, if any, come from an `ossover bench` run whose `results/<timestamp>/` directory is attached or linked; nothing is estimated
- [ ] Docs updated where behaviour changed (`README.md`, `CONTRIBUTING.md`, `engine/README.md`, `--help` text)
