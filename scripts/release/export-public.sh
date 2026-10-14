#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/release/export-public.sh — build the public, history-free export of this checkout.
#
# The private checkout's history carries the operator's work e-mail as author/committer and the
# working tree carries docs/rea/evidence/ (65 MB, partly derived from proprietary binaries). The
# public repository therefore starts from a *single squashed commit* of the current tree, not from
# the history. This script:
#
#   1. collects the current tree (tracked + untracked-but-not-ignored files, or --tracked-only)
#      and copies it into a fresh export directory, always skipping:
#        docs/rea/evidence/**, .build*/**, .claude/**, dist/**, local/**, engine/{work,staging,out},
#        __pycache__/** and *.pyc, *.exe, archives (*.tar.*, *.zip, *.dmg), .DS_Store, .swiftpm,
#        every symlink, and docs/announce/** (operator-side social-media drafts;
#        --include-announce keeps them);
#   2. runs `git init` there, stages everything, and refuses to continue unless the personal-data
#      grep is empty:
#        - hard gate: generic shapes kept in this script (/Users/<user> and <user>@ derived from
#          `id -un`, GitHub / OpenAI / AWS token shapes, PEM private-key headers) plus the
#          operator's identity literals (work e-mail domain, old handles, …) read from the
#          gitignored file local/privacy-patterns.txt (one extended-regex alternative per line;
#          the environment variable OSSOVER_PRIVACY_RE overrides it). The export dies when
#          neither exists, so the gate cannot silently weaken (see privacy-re.sh);
#        - strict gate (default; --no-strict downgrades it to a warning): the "-Users-<user>-"
#          form of the home path as it appears in Claude Code scratchpad paths, any such
#          scratchpad path under /private/tmp, any /Users/<name> path (plain or JSON-escaped
#          "\/Users\/…"), the macOS user name as a bare word, this Mac's ComputerName,
#          LocalHostName and `hostname -s`;
#        - no symlinks in the index; no file over 50 MB (GitHub refuses >100 MB); LICENSE,
#          NOTICE.md, Package.swift present; README.md present (warning only);
#   3. commits once as  hemkum <25156367+hemkum@users.noreply.github.com>  (author AND committer,
#      overridable with --author/--email) with the message "Initial public release", tags
#      v0.1.0-alpha.1 when --tag is given (--tag-name to change it), and asserts that no other
#      identity exists in the new repository;
#   4. writes helper files next to the export (<out>-helpers/: release notes, the Epic Games
#      Store issue body, gh-commands.sh) and PRINTS the exact `gh repo create`, `gh release
#      create` and `gh issue create` commands for the operator to run.
#
# It never pushes, never calls `gh`, never touches the network. Print only.
#
# Usage
#   scripts/release/export-public.sh [--out DIR] [--tag] [--tag-name vX.Y.Z] [--tracked-only]
#       [--include-announce] [--force] [--no-strict] [--dry-run] [--author NAME] [--email ADDR]
#       [--evidence-archive FILE]
#
#   --out DIR            export directory (default: <parent of repo>/ossover-public); must not
#                        exist or must be empty, unless --force wipes it
#   --tag                create the annotated tag (default name v0.1.0-alpha.1)
#   --tracked-only       export `git ls-files` only, ignoring untracked files
#   --include-announce   keep docs/announce/ in the public tree
#   --no-strict          strict-gate hits become warnings (the hard gate still fails the export)
#   --dry-run            print what would be copied / skipped and exit
#   --evidence-archive F path of the evidence tarball to name in the printed release command
#                        (default: <repo>/dist/docs-rea-evidence-crossover-26.3.0.tar.xz)
#
# Environment
#   OSSOVER_PRIVACY_RE   identity regex to use instead of <repo>/local/privacy-patterns.txt

set -euo pipefail

die()  { printf 'export-public: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'export-public: warning: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO is not a git checkout"
# shellcheck source=scripts/release/privacy-re.sh
. "$SCRIPT_DIR/privacy-re.sh"

OUT="$(dirname "$REPO")/ossover-public"
DO_TAG=0
TAG_NAME="v0.1.0-alpha.1"
TRACKED_ONLY=0
INCLUDE_ANNOUNCE=0
FORCE=0
STRICT=1
DRY_RUN=0
AUTHOR_NAME="hemkum"
AUTHOR_EMAIL="25156367+hemkum@users.noreply.github.com"
GH_REPO="hemkum/ossover"
EVIDENCE_ARCHIVE="$REPO/dist/docs-rea-evidence-crossover-26.3.0.tar.xz"
LOCAL_USER=$(id -un 2>/dev/null || basename "${HOME:-/nonexistent}")

usage() { sed -n '3,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
need_value() { [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out)              need_value "$@"; OUT=$2; shift 2 ;;
    --tag)              DO_TAG=1; shift ;;
    --tag-name)         need_value "$@"; TAG_NAME=$2; DO_TAG=1; shift 2 ;;
    --tracked-only)     TRACKED_ONLY=1; shift ;;
    --include-announce) INCLUDE_ANNOUNCE=1; shift ;;
    --force)            FORCE=1; shift ;;
    --no-strict)        STRICT=0; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --author)           need_value "$@"; AUTHOR_NAME=$2; shift 2 ;;
    --email)            need_value "$@"; AUTHOR_EMAIL=$2; shift 2 ;;
    --evidence-archive) need_value "$@"; EVIDENCE_ARCHIVE=$2; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

for tool in git find; do command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"; done
IDENTITY_RE=$(load_privacy_re "$REPO")   # dies when the gitignored pattern file is missing
PRIVACY_SOURCE=$(privacy_re_source "$REPO")
case "$OUT" in
  "$REPO"|"$REPO"/*) die "--out must be outside the checkout ($REPO)" ;;
esac

# ---- 1. collect the current tree -------------------------------------------------------------
skip_reason() {
  # prints a reason when the path must not be exported, nothing otherwise
  case "$1" in
    docs/rea/evidence/*)                       printf 'evidence (release asset instead)' ;;
    .build*|.build*/*)                         printf 'build artifact' ;;
    .claude|.claude/*)                         printf 'agent workspace' ;;
    dist|dist/*)                               printf 'release output' ;;
    local|local/*)                             printf 'operator-local files (gitignored)' ;;
    *.pyc|__pycache__|__pycache__/*|*/__pycache__|*/__pycache__/*)
                                               printf 'build artifact' ;;
    engine/work|engine/work/*|engine/staging|engine/staging/*|engine/out|engine/out/*)
                                               printf 'engine build tree' ;;
    *.exe|*.tar.xz|*.tar.gz|*.tgz|*.zip|*.dmg) printf 'binary / archive' ;;
    .DS_Store|*/.DS_Store)                     printf 'finder metadata' ;;
    .swiftpm|.swiftpm/*|*/.swiftpm/*)          printf 'swiftpm state' ;;
    docs/announce|docs/announce/*)
      if [ "$INCLUDE_ANNOUNCE" != 1 ]; then printf 'social-media drafts (--include-announce to keep)'; fi ;;
  esac
  return 0
}

LIST_FLAGS="-c"
[ "$TRACKED_ONLY" = 1 ] || LIST_FLAGS="-co"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ossover-export.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
COPY_LIST="$TMP/copy.txt"; SKIP_LIST="$TMP/skip.txt"
: > "$COPY_LIST"; : > "$SKIP_LIST"

# shellcheck disable=SC2086
while IFS= read -r -d '' f; do
  reason=$(skip_reason "$f")
  if [ -n "$reason" ]; then printf '%s\t%s\n' "$f" "$reason" >> "$SKIP_LIST"; continue; fi
  if [ -L "$REPO/$f" ]; then printf '%s\t%s\n' "$f" "symlink" >> "$SKIP_LIST"; continue; fi
  if [ ! -f "$REPO/$f" ]; then printf '%s\t%s\n' "$f" "not a regular file / deleted in worktree" >> "$SKIP_LIST"; continue; fi
  printf '%s\n' "$f" >> "$COPY_LIST"
done < <(git -C "$REPO" ls-files -z $LIST_FLAGS --exclude-standard)

n_copy=$(wc -l < "$COPY_LIST" | tr -d ' ')
n_skip=$(wc -l < "$SKIP_LIST" | tr -d ' ')
[ "$n_copy" -gt 0 ] || die "nothing to export"

MODE_DESC='tracked + untracked'; [ "$TRACKED_ONLY" = 1 ] && MODE_DESC='tracked-only'
info "source:   $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo no-commit), $MODE_DESC)"
info "export:   $OUT"
info "files:    $n_copy to copy, $n_skip skipped"
if [ "$n_skip" -gt 0 ]; then
  info "skipped (grouped):"
  cut -f2 "$SKIP_LIST" | sort | uniq -c | sed 's/^/  /'
fi
if [ "$DRY_RUN" = 1 ]; then
  info ""; info "would copy:"; sed 's/^/  /' "$COPY_LIST"
  info ""; info "would skip:"; sed 's/^/  /' "$SKIP_LIST"
  exit 0
fi

if [ -e "$OUT" ]; then
  if [ "$FORCE" = 1 ]; then rm -rf "$OUT"
  elif [ -d "$OUT" ] && [ -z "$(ls -A "$OUT")" ]; then :
  else die "$OUT exists and is not empty (use --force to replace it)"
  fi
fi
mkdir -p "$OUT"
while IFS= read -r f; do
  mkdir -p "$OUT/$(dirname "$f")"
  cp -p "$REPO/$f" "$OUT/$f"
done < "$COPY_LIST"
if command -v xattr >/dev/null 2>&1; then xattr -cr "$OUT" 2>/dev/null || true; fi

# ---- 2. fresh repository + gates ---------------------------------------------------------------
if ! git -C "$OUT" init -q -b main 2>/dev/null; then
  git -C "$OUT" init -q
  git -C "$OUT" symbolic-ref HEAD refs/heads/main
fi
git -C "$OUT" config user.name "$AUTHOR_NAME"
git -C "$OUT" config user.email "$AUTHOR_EMAIL"
git -C "$OUT" config commit.gpgsign false
git -C "$OUT" add -A

fail=0
report() { # report LEVEL NAME LINES   (LEVEL = hard | strict; empty LINES = pass)
  local level=$1 name=$2 lines=$3
  if [ -z "$lines" ]; then printf 'gate ok    %s\n' "$name"; return 0; fi
  if [ "$level" = strict ] && [ "$STRICT" = 0 ]; then
    printf 'WARN       %s\n' "$name"
  elif [ "$level" = strict ]; then
    printf 'GATE FAIL  %s (strict; --no-strict downgrades it)\n' "$name"; fail=1
  else
    printf 'GATE FAIL  %s\n' "$name"; fail=1
  fi
  printf '%s\n' "$lines" | cut -c1-200 | head -40 | sed 's/^/    /'
}
gg() { # git grep over the staged export; "no match" (exit 1) is not an error
  local rc=0
  git -C "$OUT" grep "$@" -- . || rc=$?
  [ "$rc" -le 1 ] || die "git grep failed (exit $rc): $*"
  return 0
}

# The hard pattern: generic token shapes kept here (each carries a bracketed character so that
# this script does not match itself; the regex semantics are unchanged), the operator's forms
# derived from `id -un`, and the identity literals loaded from the gitignored
# local/privacy-patterns.txt (or $OSSOVER_PRIVACY_RE). No e-mail domain, handle or home path
# is written into a file that goes public.
GENERIC_RE='ghp[_]|github[_]pat_|sk-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|PRIVATE[ ]KEY'
# "\\?/" also matches the JSON-escaped "\/" (unified-log ndjson fixtures carry "\/Users\/<user>\/…").
HARD_RE="$GENERIC_RE|\\\\?/Users\\\\?/$LOCAL_USER(\\\\?/|\$|[^A-Za-z0-9._-])|$LOCAL_USER@|$IDENTITY_RE"
# Strict pattern (case-sensitive: Wine prefixes contain drive_c/users/<name>): scratchpad forms of
# the home path, any /Users/<name> of 3+ characters (the Swift tests use /Users/h and /Users/x as
# synthetic paths), the Claude Code scratchpad root; plain and JSON-escaped.
STRICT_RE="-Users-$LOCAL_USER-|\\\\?/private\\\\?/tmp\\\\?/claude[-]|\\\\?/Users\\\\?/[A-Za-z0-9._-]{3,}"
CN=$(scutil --get ComputerName 2>/dev/null || true)
LHN=$(scutil --get LocalHostName 2>/dev/null || true)
HN=$(hostname -s 2>/dev/null || true)   # a third value on some Macs (e.g. after a rename)
case "$HN" in localhost|localhost.*) HN="" ;; esac

info ""
info "== gates on the staged export =="
lines=$(gg -n -I -iE -e "$HARD_RE");                       report hard   "personal data / secrets (agreed pattern)" "$lines"
lines=$(git -C "$OUT" ls-files | { grep -iE -e "$HARD_RE" || true; }); report hard "personal data in file names" "$lines"
lines=$(gg -n -I -E -e "$STRICT_RE");                      report strict "scratchpad / home-path forms" "$lines"
# The bare user name as a word, case-sensitive (ls -l owner columns, escaped paths, prompts).
lines=$(gg -n -I -w -F -e "$LOCAL_USER");                  report strict "the macOS user name as a bare word" "$lines"
lines=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  hit=$(gg -n -I -iF -e "$name")
  [ -z "$hit" ] || lines="${lines:+$lines
}$hit"
done < <(printf '%s\n' "$CN" "$LHN" "$HN" | grep . | sort -u)
report strict "this Mac's ComputerName / LocalHostName / hostname -s" "$lines"
lines=$(git -C "$OUT" ls-files -s | awk '$1=="120000"{print $4}'); report hard "no symlinks in the index" "$lines"
lines=$(find "$OUT" -type f -not -path "$OUT/.git/*" -size +50M);   report hard "no file over 50 MB" "$lines"
find "$OUT" -type f -not -path "$OUT/.git/*" -size +10M | while read -r f; do warn "large file (>10 MB): ${f#$OUT/}"; done
lines=$(for f in LICENSE NOTICE.md Package.swift; do [ -f "$OUT/$f" ] || echo "missing $f"; done); report hard "licence / package files present" "$lines"
lines=$( [ -d "$OUT/docs/rea/evidence" ] && echo "docs/rea/evidence is present" || true ); report hard "evidence directory not exported" "$lines"
[ -f "$OUT/README.md" ] || warn "README.md is missing from the export (the public landing page)"
[ "$fail" = 0 ] || die "one or more gates failed; nothing was committed. Fix the source tree (not the export) and re-run."

# ---- 3. the single commit (and tag) ----------------------------------------------------------
export GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL"
export GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL"
SRC_HEAD=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo none)
git -C "$OUT" commit -q --no-gpg-sign -m "Initial public release" -m "$(cat <<EOT
ossover: a free, open-source CrossOver alternative for macOS (GPL-3.0-or-later; recipes CC0-1.0).

Single squashed commit exported from the private working tree with scripts/release/export-public.sh
(source tree at $SRC_HEAD, $(date -u +%Y-%m-%d)). No history is carried over. The REA evidence
records (docs/rea/evidence/) are published separately as a release asset; docs/rea/ has the ledger.
EOT
)"
if [ "$DO_TAG" = 1 ]; then
  git -C "$OUT" tag -a "$TAG_NAME" -m "ossover $TAG_NAME — first public alpha"
fi

identities=$(git -C "$OUT" log --format='%an <%ae>%n%cn <%ce>' | sort -u)
expected="$AUTHOR_NAME <$AUTHOR_EMAIL>"
[ "$identities" = "$expected" ] || die "unexpected identity in the export: $identities"
if [ "$DO_TAG" = 1 ]; then
  tagger=$(git -C "$OUT" for-each-ref --format='%(taggername) %(taggeremail)' "refs/tags/$TAG_NAME")
  [ "$tagger" = "$AUTHOR_NAME <$AUTHOR_EMAIL>" ] || die "unexpected tagger identity: $tagger"
fi

COMMIT=$(git -C "$OUT" rev-parse --short HEAD)
TREE_SIZE=$(du -sh -I .git "$OUT" 2>/dev/null | cut -f1 || true)
[ -n "$TREE_SIZE" ] || TREE_SIZE=$(du -sh --exclude=.git "$OUT" 2>/dev/null | cut -f1 || echo '?')

# ---- 4. helper files + the commands to run by hand -------------------------------------------
HELPERS="${OUT}-helpers"
mkdir -p "$HELPERS"
NOTES="$HELPERS/release-notes-$TAG_NAME.md"
ISSUE="$HELPERS/issue-epic-games-support.md"
CMDS="$HELPERS/gh-commands.sh"

cat > "$NOTES" <<EOT
# ossover $TAG_NAME

First public cut of **ossover**, a free and open-source alternative to CrossOver for running
Windows games on macOS (GPL-3.0-or-later; recipes and the compatibility data CC0-1.0).

## What works today (verified on an Apple M5 Pro, macOS 26.7.1)

- The \`ossover\` CLI: engines, renderer packs, bottles, \`run\`, recipes, \`steam fetch\`
  (steamcmd / DepotDownloader, no Steam client in the bottle), \`smoke\`, \`bench\`, \`doctor\`.
- The Witcher 3 4.04 (Steam \`next-gen\` branch, DirectX 11) reaches its main menu and is playable
  in an ossover bottle on the bootstrap engine (frankea Whisky Libraries v4.6.4-beta.1: Wine 11.16
  + CrossOver 26.3 LGPL patches + DXMT 0.80). A probe confirms DXMT is the Direct3D 11 provider;
  Metal HUD per-frame logging works.
- A static REA evidence pass on CrossOver 26.3.0 (bundle inventory + LGPL deep-dive only; nothing
  proprietary decompiled, nothing copied): 39 design decisions in \`docs/rea/decisions.md\`, each
  traced to a row of \`docs/rea/ledger.md\`.

## Not yet

- ossover's own engine build from CodeWeavers' LGPL source tarball (\`engine/\`) is in progress;
  the bootstrap engine is what runs today.
- No benchmark numbers have been measured, so none are claimed.
- CLI only; no GUI. Rosetta 2 is required (x86_64 Wine).

## Assets

- \`docs-rea-evidence-crossover-26.3.0.tar.xz\` (+ \`.sha256\`): the raw REA / shell records behind
  the ledger, minus everything derived from proprietary binaries (D3DMetal, libd3dshared,
  cxcompatdb.so). See \`README.txt\` and \`EXCLUDED.txt\` inside the archive.

ossover is an independent, open-source project and is not affiliated with, sponsored by or
endorsed by CodeWeavers, Apple, the Wine project, Valve, CD PROJEKT S.A., Epic Games or GOG.
CrossOver, Game Porting Toolkit, D3DMetal, Wine, Steam, The Witcher, Epic Games Store and GOG
are their owners' trademarks and are used only to describe compatibility.
EOT

cat > "$ISSUE" <<'EOT'
## Epic Games Store support

`ossover steam fetch` pulls a game's Windows depot into a bottle with steamcmd (or DepotDownloader)
and keeps the store client out of the bottle entirely. The Epic Games Store deserves the same
treatment: a lot of Mac players hold their library there (weekly free games, Epic exclusives), and
the Epic launcher itself is the fragile part under Wine (CEF, self-updates, EOS overlay).

### Proposal

- `ossover epic fetch --app <catalog item> --bottle <name>`, mirroring `ossover steam fetch`: the
  download tool runs in the user's own terminal, ossover never sees credentials or tokens, and a
  fetched app is pinned (re-fetching needs `--allow-update`).
- Backend: [Legendary](https://github.com/derrod/legendary) (GPL-3.0, Python, no launcher needed)
  as the first provider, the way steamcmd / DepotDownloader are for Steam. `ossover doctor`
  reports whether it is installed.
- One `recipes/epic-<game>.json` per verified title (CC0 like the others) with the launch
  arguments Epic builds expect (`-EpicPortal`, EOS overlay off) and any launcher-config fallback
  the game ships.
- Document what does **not** work: titles that need Easy Anti-Cheat or EOS online services.

### Acceptance

- A DRM-free (or Epic-DRM-light) title fetched with Legendary launches through `ossover run` on
  the bootstrap engine with DXMT.
- No Epic launcher in the bottle, no stored tokens in the bottle, no credential handling in ossover.
- `ossover doctor --json` lists the Legendary check; a recipe + known-issues block exists for the
  first verified game.

### Out of scope for the first cut

- Running the Epic Games Launcher inside a bottle (fallback only, like `recipes/steam.json`).
- EAC / EOS anti-cheat titles.
EOT

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
  printf '#!/usr/bin/env bash\n'
  printf '# Generated by scripts/release/export-public.sh — read every line before running.\n'
  printf '# Nothing below was executed by the export script.\n'
  printf 'set -euo pipefail\n'
  printf 'cd %s\n' "$(sq "$OUT")"
  printf 'gh auth status\n'
  printf 'gh repo create %s --public --source . --push --remote origin \\\n' "$GH_REPO"
  printf '  --description %s\n' "$(sq "Free, open-source CrossOver alternative for macOS: Wine + DXMT + msync, designed from evidence (The Witcher 3 is the benchmark)")"
  printf 'gh repo edit %s --add-topic macos --add-topic wine --add-topic dxmt --add-topic metal --add-topic gaming --add-topic crossover --add-topic swift --enable-issues --enable-discussions\n' "$GH_REPO"
  if [ "$DO_TAG" = 1 ]; then
    printf 'git push origin %s\n' "$(sq "$TAG_NAME")"
    printf 'gh release create %s --repo %s --prerelease --title %s --notes-file %s \\\n' "$(sq "$TAG_NAME")" "$GH_REPO" "$(sq "ossover $TAG_NAME")" "$(sq "$NOTES")"
    printf '  %s %s\n' "$(sq "$EVIDENCE_ARCHIVE")" "$(sq "$EVIDENCE_ARCHIVE.sha256")"
  else
    printf '# (no tag was created: re-run export-public.sh with --tag to get the release command)\n'
  fi
  printf 'gh issue create --repo %s --title %s --label enhancement --body-file %s\n' "$GH_REPO" "$(sq 'Epic Games Store support: Legendary-style depot fetch, no Epic launcher in the bottle')" "$(sq "$ISSUE")"
} > "$CMDS"
chmod +x "$CMDS"

TAG_DESC=""; [ "$DO_TAG" = 1 ] && TAG_DESC=", tag $TAG_NAME"
ROLE_DESC="author, committer"; [ "$DO_TAG" = 1 ] && ROLE_DESC="author, committer, tagger"
info ""
info "== export ready =="
info "directory: $OUT ($TREE_SIZE, $n_copy files, commit $COMMIT$TAG_DESC)"
info "identity:  $expected ($ROLE_DESC)"
info "helpers:   $HELPERS"
info ""
info "Review the tree, then run these by hand (nothing was pushed or created on GitHub):"
info ""
sed 's/^/  /' "$CMDS"
info ""
info "Reminders:"
info "  - build the evidence asset first: scripts/release/package-evidence.sh (expected at $EVIDENCE_ARCHIVE)"
info "  - the identity gate read $PRIVACY_SOURCE; keep that file under local/ (gitignored), never in the tree"
info "  - gh repo create --push pushes the branch only; the git push line above pushes the tag"
info "  - the checklist is docs/release-checklist.md"
