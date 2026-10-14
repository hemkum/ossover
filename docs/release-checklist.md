# Release checklist — first public release of ossover

| | |
|---|---|
| Target | `github.com/hemkum/ossover`, public, tag `v0.1.0-alpha.1` (pre-release) |
| Identity | `hemkum <25156367+hemkum@users.noreply.github.com>` — author, committer and tagger of everything public |
| Scripts | `scripts/release/package-evidence.sh` (evidence → release asset), `scripts/release/export-public.sh` (tree → single-commit export). Both are print-only towards GitHub |
| Audit date | 2026-10-14, on the working tree at `6b9cc4c` plus the other agents' uncommitted files |

## 0. Rules that do not bend

1. The public repository starts from **one** commit of the current tree. The private history (9 commits authored as
   `ossover <work e-mail>`) is never pushed, never force-pushed, never "cleaned up" — it stays local.
2. `docs/rea/evidence/` never enters the public tree. It ships as a GitHub Release asset built by
   `package-evidence.sh`, minus every record derived from a proprietary binary.
3. No benchmark numbers anywhere: none have been measured. Gate (empty on the audit date):
   `git grep -niE '\b[0-9]{2,3} ?fps\b' -- . ':!docs/rea/evidence'`
4. The release scripts never push and never call `gh`. Every GitHub-side step is run by hand from the commands they print.
5. Fix findings in the **source tree**, re-run the export; never patch the export directory by hand.

## 1. Personal-data audit

### Commands

The identity literals (the work e-mail domain, `<first-name>@`, old handles, `/Users/<user>`) live in the
gitignored `local/privacy-patterns.txt`, one extended-regex alternative per line (escape dots: `example\.com`),
so that no file in the public tree carries them. Both release scripts source `scripts/release/privacy-re.sh` and
refuse to run without that file (`OSSOVER_PRIVACY_RE` overrides it for a one-off). Create it once:

```sh
mkdir -p local
printf '%s\n' '<work-e-mail-domain>' '<first-name>@' '<old-handle>' '/Users/<user>' > local/privacy-patterns.txt
```

The agreed pattern, as run (the generic token shapes carry a bracketed character so that this file never matches
itself; the regex semantics are identical):

```sh
git grep -n -I -iE "$(paste -sd '|' local/privacy-patterns.txt)|ghp[_]|github[_]pat_|sk-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|PRIVATE[ ]KEY"
grep -rlE "$(paste -sd '|' local/privacy-patterns.txt)" docs/rea/evidence
grep -rlw "$(id -un)" docs/rea/evidence      # the bare user name as a word (ls -l owner columns)
git grep -n -I -w "$(id -un)"                 # the same over the tree: catches JSON-escaped "\/Users\/<user>" too
```

Extended scan over the same tree (tracked **and** untracked-not-ignored files, evidence included): the
`-Users-<user>-` form of the home path, Claude Code scratchpad paths under `/private/tmp`, any `/Users/<name>`
path, this Mac's ComputerName and LocalHostName (`scutil --get …`) and `hostname -s`, the owner's first name,
`password` / `secret`
/ `api key` / `token` / `bearer`, IPv4 literals, `/Volumes/`, and the EXIF of the one image. `.build-*`,
`engine/work`, `engine/staging` and `.claude/` were not scanned: they are gitignored or excluded and the export
skips them unconditionally.

### Findings and dispositions

| # | Where | What | Disposition |
|---|---|---|---|
| 1 | `docs/rea/README.md:41` | absolute npx cache path `/Users/<user>/.npm/_npx/<hash>/node_modules/rea-agents` | **Fixed** (this task): now `~/.npm/_npx/<hash>/node_modules/rea-agents` |
| 2 | `docs/rea/README.md:73` | the session scratchpad path `S=<scratchpad root>/-Users-<user>-other-claude-ossover/<session uuid>/scratchpad/rea-targets` — user name and session id. Not matched by the agreed pattern; caught by the extended scan | **Fixed** (this task, path line only): now `S=<scratchpad>/rea-targets` |
| 3 | `docs/rea/evidence/cli-capabilities.json` | 2 × home path (REA `command_path` / `root_path` under the npx cache) | Never in the public tree. `package-evidence.sh` rewrites it to `~` (0 residues after the rewrite) |
| 4 | `docs/rea/evidence/cli-doctor.json` | 8 × home path: `~/.claude.json`, `~/Library/Application Support/Claude/…`, `~/Applications/Hopper Disassembler.app/…` — REA's environment self-report (which MCP clients and disassemblers exist on this Mac) | Rewritten to `~`. Optional: leave the file out with `--exclude '<pattern>|cli-doctor'` if the tool inventory of this Mac should stay private. No secrets in it |
| 5 | `docs/rea/evidence/shell-cxcompatdb-strings.txt:289` | `couldn't get path to private[ ]key` — a string inside CodeWeavers' proprietary `cxcompatdb.so`; false positive of the secret pattern | Excluded from the archive by name (proprietary-binary record); never in the public tree |
| 6 | `docs/rea/evidence/*` — 64 files, 129 occurrences | the scratchpad path with the user name in REA record `path` fields, `otool -L` / `objdump` headers and `text-tooling-layout-hashes-diffs.txt` | Rewritten to `<scratchpad>` by `package-evidence.sh`, which re-greps the staged tree for the user name, the home path and the secret pattern and refuses to package on any hit (0 on the audit date) |
| 7 | git history (9 commits) | author = committer = `ossover <work e-mail>` | History is not exported. `export-public.sh` creates one commit as the noreply identity and asserts that no other author, committer or tagger exists in the new repository |
| 8 | `.claude/worktrees/…` | an agent worktree copy of the tree (with a stale copy of finding 1) | Local only (`.git/info/exclude`); the export skips `.claude/` |
| 9 | `engine/work`, `engine/staging` → `~/.cache/ossover-engine/…` | untracked symlinks into the home directory (`engine/build.sh` creates them because the checkout path contains a space) | gitignored; the export skips symlinks and refuses any symlink in its index |
| 10 | `Tests/OssoverKitTests/ReviewFixTests.swift:388` | a code comment with the owner's first name | Keep: the first name of a public GitHub user, no contact data |
| 11 | `Tests/Fixtures/hudlogs/sample.ndjson` | `"userID":501` in Metal HUD log lines | Keep: a macOS uid, not identifying |
| 12 | `Sources/**`, `Tests/**` | synthetic `/Users/h` and `/Users/x` paths in tests and doc comments | Keep: not real paths; the strict gate only flags names of 3+ characters |
| 13 | `docs/images/witcher3-menu-m5pro.jpg` | EXIF holds resolution only; comment `Screenshot`; a Photoshop IRB block; no device, serial, GPS or author fields | Keep |
| 14 | everything else | ComputerName / LocalHostName, old handles, the work-e-mail domain, token shapes (`ghp[_]`, `github[_]pat_`, `sk-…`, `AKIA…`), IPv4 literals, `/Volumes/`: **0 hits** in tracked and untracked files, evidence included | — |
| 15 | `scripts/release/export-public.sh`, `scripts/release/package-evidence.sh`, this file | the identity literals themselves (work e-mail domain, `<first-name>@`, old handle, `/Users/<user>`) were written into the gate patterns in plain text; the bracketed character only stopped self-matching, a reader saw them | **Fixed** (this task): moved to the gitignored `local/privacy-patterns.txt`, read by `scripts/release/privacy-re.sh`; both scripts die without it; the export skips `local/` |
| 16 | `docs/rea/evidence/text-tooling-layout-hashes-diffs.txt:151-154` | `ls -l` output whose owner column is the bare macOS user name (`lrwxr-xr-x@ 1 <user> wheel … autorun -> wine`, ×4); the rewrite rules only knew `/Users/<user>`, `-Users-<user>-` and `<user>@` | **Fixed** (this task): `package-evidence.sh` rewrites the owner column to `<user>` and its verification now greps the bare name as a word (`grep -rInwF`) |
| 17 | `engine/__pycache__/manifest.cpython-39.pyc` | untracked, not-ignored Python bytecode; copied into the export (binary, so `git grep -I` would never see an embedded absolute path) | **Fixed** (this task): file deleted; `__pycache__/` and `*.pyc` gitignored; `export-public.sh` skips them as build artifacts |
| 19 | `Tests/Fixtures/hudlogs/sample.ndjson` (10 lines), `Tests/Fixtures/hudlogs/logstream-redacted.ndjson` (4 lines) | `"processImagePath":"\/Users\/<user>\/Library\/Application Support\/ossover\/…"` — the home path in JSON-escaped form (`\/`), which the agreed pattern and the extended scan both missed; found by the word-bounded user-name grep on the export. The "redacted" fixture is not fully redacted | **Open — Tests owner (blocks the export).** Replace the user segment with the synthetic `h` the tests already use (`\/Users\/h\/Library\/…`, keeping the escaping and the rest of the path so the prefix-ownership filter still matches) and re-run `swift test`. `export-public.sh` now matches `\/`-escaped paths (hard) and the bare user name as a word (strict), so the export fails until this is done |
| 18 | `engine/out/x64-ossover-cx26.3-r1.tar.xz` → `manifest.json` → `source.url` (and `engine/out/…/manifest.json:14`) | `file:///Users/<user>/…/engine/out/….tar.xz`, written by `engine/manifest.py` (`Path(tarball).resolve().as_uri()`). Not in the public tree (`engine/out` is gitignored and skipped) and `release.yml` uploads the CLI tarball only, but it ships the moment the engine tarball is attached to a release or referenced from `engines/*.json` | **Open — engine owner.** Write the public download URL (`https://github.com/hemkum/ossover/releases/download/<tag>/<name>.tar.xz`) or a placeholder into the in-tarball manifest, keep `file://` only in the out-dir sidecar; add a `gates.sh` check that `tar -xJOf <tarball> '*/manifest.json' \| grep -c '/Users/'` is 0; rebuild r1 before any upload |

The `password` / `secret` / `token` hits are all documentation of the *absence* of credential handling
(`Steam account name (never a password)`, `STEAM_TOKEN: "secret"` in a test that asserts the log header redacts it).

## 2. Before the export (per owner)

- [x] ~~**docs/rea owner** — finding 2: `docs/rea/README.md:73`.~~ Done (path line replaced).
- [ ] **Tests owner** — finding 19: the two HUD-log fixtures carry `\/Users\/<user>\/…`; replace the user segment with
      the synthetic `h` and keep `swift test` green. The export's hard gate fails on these lines until then.
- [ ] **engine owner** — finding 18: `engine/manifest.py` writes the operator's home path as `source.url` into the
      in-tarball `manifest.json`; fix, add the gate, rebuild `x64-ossover-cx26.3-r1` before any engine upload.
- [ ] **engine owner** — `engine/build.sh`, `package.sh`, `gates.sh`, `selftest.sh` have no
      `# SPDX-License-Identifier: GPL-3.0-or-later` line (the Swift files, `manifest.py`, `scripts/probes/*`,
      `scripts/release/*` and `.github/scripts/catalog_check.py` do); add it as line 2.
- [ ] **docs/rea owner** — point `docs/rea/README.md` at the release asset (`README.md`, `docs/how-it-was-built.md`
      and `package-evidence.sh`'s `README.txt` already do). Suggested paragraph (after "Evidence files (this pass)"):

  > The raw records under `evidence/` are not in this repository. They are attached to the GitHub Release
  > `v0.1.0-alpha.1` as `docs-rea-evidence-crossover-26.3.0.tar.xz` (sha256 in the `.sha256` sidecar; `MANIFEST.txt`,
  > `EXCLUDED.txt` and `SHA256SUMS` inside). Records derived from proprietary binaries — Apple's D3DMetal and
  > libd3dshared, CodeWeavers' `cxcompatdb.so` — are not published; the ledger keeps the facts they supported. Unpack
  > the archive's `evidence/` directory here to make the `evidence/…` citations resolve.

- [ ] **docs/rea owner** — `wine-fork.md:279,290,307` cite `ntdll-xrefs-cxcompatdb-so-fmt.json`,
      `ntdll-function-cxcompatdb-dlopen-site.json` and `winemac-xrefs-d3dmetal_client_surface.json`. These are LGPL
      (ntdll / winemac) records whose *file names* match the agreed exclusion pattern. Decide: package with the anchored
      pattern below (keeps them; recommended) or add a note to the README paragraph that they are absent.
- [ ] **.gitignore owner** — add `/dist/`: `package-evidence.sh` writes there and only `*.tar.xz` is ignored today
      (the `.sha256` and `.manifest.txt` sidecars are not). The export skips `dist/` regardless. (`__pycache__/` and
      `*.pyc` were added by this task, finding 17.)
- [ ] **recipes owner** — `recipes/witcher3.json` still says `"status": "untested"` while the game is playable on the
      bootstrap engine; set `works` or `partial` with a `reports` entry (`recipes/_schema.json`), or leave it and say
      why in the README's Status block.
- [ ] **recipes owner** — `recipes/witcher3.json` `knownIssues[1]` ("Sirens, rotfiends, hounds … invisible" under
      DXVK) says `fix: Use renderer dxmt`, which `knownIssues[5]` contradicts (DXMT 0.80 has no stream output either).
      Reword the fix: no open renderer has it; D3DMetal is the only macOS path. `README.md` and `docs/benchmark.md`
      already say so.
- [ ] **owner (Hemant)** — `NOTICE.md` gained an "Other third-party material in this repository" block (winetricks,
      the three engine patches, swift-argument-parser, the Contributor Covenant, the screenshot) so that it matches
      `ATTRIBUTION.md`; `AGENTS.md` §5 reserves that file for the owner, so read the diff before committing.
- [ ] **README owner** — Status block says: bootstrap engine, own engine build in progress, no benchmark numbers;
      trademark paragraph present; the hero image is `docs/images/witcher3-menu-m5pro.jpg`.
- [ ] **AGENTS.md** — keep (contributor guide) or drop; it goes public as-is.
- [ ] `.github/workflows/release.yml` is `workflow_dispatch` only, so it cannot collide with the manual release below.
      Run it later with the same tag to attach the CLI tarball to the existing release; check its notarization TODO first.
- [ ] Tests green on the tree that will be exported: `swift test --scratch-path .build-main` (operator's shell, not an
      agent session).
- [ ] `LICENSE`, `NOTICE.md`, `ATTRIBUTION.md`, `LICENSES/CC0-1.0.txt`, `scripts/vendor/README.md` agree on every
      third-party licence (WhiskyKit / Highball GPL-3.0, winetricks LGPL-2.1+, DXMT MIT at 0.80).

## 3. Build the evidence asset

```sh
# default pattern (the agreed one): drops 30 files, 24 proprietary-derived + 6 LGPL records named after them
scripts/release/package-evidence.sh --out dist

# recommended: anchored pattern, drops exactly the 24 proprietary-derived files and keeps the 6 LGPL records
scripts/release/package-evidence.sh --out dist \
  --exclude '^(D3DMetal|cxcompatdb|libd3dshared)-|^shell-(D3DMetal|cxcompatdb|d3dmetal|libd3dshared)[.-]'
```

Expected with the default pattern (audit date): `staged: 142 files (54957165 bytes), 54 rewritten, 30 excluded by
name`; archive ≈ 3.8 MB; `dist/docs-rea-evidence-crossover-26.3.0.tar.xz`, `.sha256` and `.manifest.txt`. Verify:

```sh
xz -dc dist/docs-rea-evidence-crossover-26.3.0.tar.xz | tar -tf - | grep -iE 'D3DMetal|libd3dshared|cxcompatdb' # empty (default) or only the 6 LGPL names (anchored)
mkdir -p /tmp/ev && xz -dc dist/docs-rea-evidence-crossover-26.3.0.tar.xz | tar -xf - -C /tmp/ev
(cd /tmp/ev/docs-rea-evidence-crossover-26.3.0 && shasum -a 256 -c SHA256SUMS | grep -vc ': OK$')   # 0
grep -rlE "$(paste -sd '|' local/privacy-patterns.txt)" /tmp/ev                                     # nothing
grep -rlw "$(id -un)" /tmp/ev                                                                       # nothing
cat /tmp/ev/docs-rea-evidence-crossover-26.3.0/EXCLUDED.txt
```

## 4. Export the public tree

```sh
scripts/release/export-public.sh --dry-run            # lists what will be copied and skipped
scripts/release/export-public.sh --tag                # export to ../ossover-public, gates, one commit, tag v0.1.0-alpha.1
```

What the gates check: the agreed pattern (hard; the identity half comes from `local/privacy-patterns.txt` and the
export dies without it; `/Users/<user>` is matched plain and JSON-escaped), the extended scan plus the bare user
name as a word (strict; `--no-strict` only downgrades them to warnings and only after the hits have been read and
judged), no symlinks, no file over 50 MB, LICENSE / NOTICE.md / Package.swift present, no `docs/rea/evidence`, no
`local/`, no `__pycache__` / `*.pyc`. Defaults: `docs/announce/` is **not** exported (`--include-announce`
to keep it); untracked-but-not-ignored files **are** (`--tracked-only` to restrict to the index).

Then look at the result before anything leaves the machine:

```sh
cd ../ossover-public
git log --format='%an <%ae> | %cn <%ce> | %s'          # exactly one line, the noreply identity
git for-each-ref --format='%(taggername) %(taggeremail)' refs/tags
git ls-files | wc -l; du -sh -I .git .
git grep -n -I -iE "$(paste -sd '|' ../ossover/local/privacy-patterns.txt)|ghp[_]|github[_]pat_|sk-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|PRIVATE[ ]KEY"   # exit 1
git grep -n -I -w "$(id -un)"                          # exit 1: the bare user name
swift build                                            # optional: proves the export builds on its own
```

## 5. Publish (operator, by hand, in this order)

The export prints these and writes them to `../ossover-public-helpers/gh-commands.sh`; read them before running.

1. `gh auth status` — logged in as `hemkum`.
2. GitHub → Settings → Emails: "Keep my email addresses private" is on and shows `25156367+hemkum@users.noreply.github.com`.
   If the address differs, re-run the export with `--email <the shown address>`; otherwise the commit will not link to
   the account.
3. `gh repo create hemkum/ossover --public --source . --push --remote origin --description "…"` — creates the repo
   and pushes `main` (one commit).
4. `gh repo edit hemkum/ossover --add-topic …` — topics, issues, discussions.
5. `git push origin v0.1.0-alpha.1` — the tag (`gh repo create --push` pushes the branch only).
6. `gh release create v0.1.0-alpha.1 --prerelease --title "ossover v0.1.0-alpha.1" --notes-file …
   dist/docs-rea-evidence-crossover-26.3.0.tar.xz dist/docs-rea-evidence-crossover-26.3.0.tar.xz.sha256`
   — release notes are generated at `../ossover-public-helpers/release-notes-v0.1.0-alpha.1.md`; read them first.
7. `gh issue create --repo hemkum/ossover --title "Epic Games Store support: …" --label enhancement --body-file …`
   — the issue body is at `../ossover-public-helpers/issue-epic-games-support.md`; this is the owner's own first issue.
8. On github.com: Settings → Code security → enable **secret scanning** and **push protection**; Settings → General
   → confirm the licence is detected as GPL-3.0; check the commit shows the `hemkum` avatar.
9. Pin the repo on the profile; star it from nowhere else.

## 6. Announce

Order: GitHub release live → LinkedIn (`docs/announce/linkedin.md`, ≤ 1,300 characters, one image) → Instagram
(`docs/announce/instagram.md`, caption ≤ 2,200 characters, three-slide carousel) → portfolio site, when it exists
(`docs/announce/portfolio-blurb.md`, 120 words + facts). Replace every link placeholder with the live URL; attach
`docs/images/witcher3-menu-m5pro.jpg`; post no fps or "vs CrossOver" numbers.

## 7. Afterwards

- `dist/` stays out of git; the archive lives on the release.
- When `ossover bench` results are committed under `docs/benchmark-results/`, update README Status, the recipe
  `status`, and only then the announcement copy.
- If something personal is found in the public tree later: fix forward in a commit; do not rewrite history on a
  repository other people may already have cloned, unless it is a secret (then rotate the secret first).
- The private checkout keeps its history; `scripts/release/export-public.sh --force` regenerates the export at
  any time, but a second publish is an ordinary `git push` from the public clone, not a new export.
