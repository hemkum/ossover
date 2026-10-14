#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/release/package-evidence.sh — package docs/rea/evidence as a GitHub Release asset.
#
# Why
#   docs/rea/evidence/ (~65 MB, 172 files) must not enter the public git tree as-is. It holds
#   string / nm / otool dumps and signature / Mach-O records of Apple's proprietary D3DMetal and
#   libd3dshared and of CodeWeavers' proprietary cxcompatdb.so, plus multi-megabyte Ghidra
#   pseudocode JSON of LGPL binaries (publishable, but far too heavy for a source repository).
#   export-public.sh drops the directory from the public tree; this script builds the archive a
#   GitHub Release carries instead, and docs/rea/README.md points readers at that asset.
#
# What it does
#   1. EXCLUDES every file whose *name* matches the ERE  D3DMetal|d3dmetal|libd3dshared|cxcompatdb
#      (override with --exclude). This also drops the LGPL ntdll/winemac records whose name carries
#      one of those words (ntdll-function-cxcompatdb-dlopen-site.*, ntdll-xrefs-cxcompatdb-so-fmt.*,
#      winemac-xrefs-d3dmetal_client_surface.*); EXCLUDED.txt inside the archive lists every drop.
#   2. KEEPS the LGPL ntdll / winemac / winemetal / wineloader / wineserver records, the DXMT (MIT)
#      string dumps, the sources-pass / text-tooling records, the cli-* self-reports and the two
#      inventories (file listings and hashes only).
#   3. Rewrites, inside every text/JSON file: "$HOME" and "/Users/<user>" -> "~"; the session
#      scratchpad path "<Claude Code scratchpad under /private/tmp>/-Users-<user>-.../<uuid>/scratchpad" ->
#      "<scratchpad>"; any leftover "-Users-<user>-" -> "-Users-<user>-" placeholder; the owner
#      column of `ls -l` lines ("lrwxr-xr-x@ 1 <user> wheel …") -> "<user>". Binary files are
#      copied byte-for-byte (today there are none). It then re-greps the staged tree for the home
#      path, the bare user name as a word, the generic secret shapes and the operator's identity
#      literals from the gitignored local/privacy-patterns.txt (or $OSSOVER_PRIVACY_RE; the
#      script dies when neither exists, see privacy-re.sh) and refuses to package on any hit.
#   4. Writes README.txt, MANIFEST.txt (sha256, size, rewritten?, path), EXCLUDED.txt and
#      SHA256SUMS into the archive root; builds <out>/docs-rea-evidence-crossover-<ver>.tar.xz
#      (sorted members, no AppleDouble / xattr noise); writes <archive>.sha256 and
#      <archive>.manifest.txt beside it; prints the sha256 and the manifest.
#
# Usage
#   scripts/release/package-evidence.sh [--out DIR] [--evidence DIR] [--version 26.3.0]
#       [--exclude ERE] [--user NAME] [--dry-run] [--keep-tmp]
#
#   --out DIR        where the archive goes (default: <repo>/dist; *.tar.xz is gitignored, add
#                    /dist/ to .gitignore or keep --out outside the checkout)
#   --evidence DIR   source directory (default: <repo>/docs/rea/evidence)
#   --version V      CrossOver version in the archive name (default: 26.3.0)
#   --exclude ERE    file-name exclusion pattern (default above)
#   --user NAME      operator user name to scrub (default: `id -un`)
#   --dry-run        stage, rewrite, verify and print the manifest, but write no archive
#   --keep-tmp       keep the staging directory for inspection
#
# Environment
#   OSSOVER_PRIVACY_RE   identity regex to use instead of <repo>/local/privacy-patterns.txt
#
# Nothing here touches the network or GitHub: attaching the archive to the release is the
# operator's step (docs/release-checklist.md). Needs bash 3.2+, perl, tar (bsdtar or GNU), xz,
# shasum. Print-only reminders at the end show the `gh release upload` form to run by hand.

set -euo pipefail

die()  { printf 'package-evidence: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'package-evidence: warning: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=scripts/release/privacy-re.sh
. "$SCRIPT_DIR/privacy-re.sh"

OUT="$REPO/dist"
EVIDENCE="$REPO/docs/rea/evidence"
VERSION="26.3.0"
EXCLUDE_RE='D3DMetal|d3dmetal|libd3dshared|cxcompatdb'
USER_NAME=$(id -un 2>/dev/null || basename "${HOME:-/nonexistent}")
DRY_RUN=0
KEEP_TMP=0

usage() { sed -n '3,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

need_value() { [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out)      need_value "$@"; OUT=$2; shift 2 ;;
    --evidence) need_value "$@"; EVIDENCE=$2; shift 2 ;;
    --version)  need_value "$@"; VERSION=$2; shift 2 ;;
    --exclude)  need_value "$@"; EXCLUDE_RE=$2; shift 2 ;;
    --user)     need_value "$@"; USER_NAME=$2; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --keep-tmp) KEEP_TMP=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

for tool in perl tar xz shasum find sort; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[ -d "$EVIDENCE" ] || die "evidence directory not found: $EVIDENCE"
[ -n "$USER_NAME" ] || die "cannot determine the user name to scrub (use --user)"
IDENTITY_RE=$(load_privacy_re "$REPO")   # dies when the gitignored pattern file is missing
[ -n "${HOME:-}" ] || warn "HOME is unset; only /Users/$USER_NAME will be rewritten"

NAME="docs-rea-evidence-crossover-$VERSION"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ossover-evidence.XXXXXX")
cleanup() {
  if [ "$KEEP_TMP" = 1 ]; then info "staging kept at: $STAGE"; else rm -rf "$STAGE"; fi
}
trap cleanup EXIT
TOP="$STAGE/$NAME"
mkdir -p "$TOP/evidence"

LIST="$STAGE/files.txt"
(cd "$EVIDENCE" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort) > "$LIST"
[ -s "$LIST" ] || die "no files under $EVIDENCE"

ROWS="$STAGE/manifest.rows"; : > "$ROWS"
EXROWS="$STAGE/excluded.rows"; : > "$EXROWS"
n_in=0; n_ex=0; n_rw=0; bytes_in=0

# Perl rewrite program. PE_HOME / PE_USER come from the environment; every pattern is
# quotemeta'd, and a rule is skipped when its input is empty so nothing can match "".
PERL_REWRITE='
BEGIN {
  our $h = (defined $ENV{PE_HOME} && length $ENV{PE_HOME}) ? quotemeta($ENV{PE_HOME}) : undef;
  our $u = (defined $ENV{PE_USER} && length $ENV{PE_USER}) ? quotemeta($ENV{PE_USER}) : undef;
}
if (defined $u) {
  s{/private/tmp/claude[-]\d+/-Users-${u}-[^/"\s]*/[0-9a-fA-F-]{36}/scratchpad}{<scratchpad>}g;
}
if (defined $h) { s{${h}(?![A-Za-z0-9._-])}{~}g; }
if (defined $u) {
  s{\\/Users\\/${u}(?![A-Za-z0-9._-])}{~}g;   # JSON-escaped form ("\/Users\/<user>\/…")
  s{/Users/${u}(?![A-Za-z0-9._-])}{~}g;
  s{-Users-${u}-}{-Users-<user>-}g;
  # owner column of `ls -l` output: "lrwxr-xr-x@  1 <user>  wheel  4 Oct 13 22:01 autorun -> wine"
  s{^([ldbcps-][rwxsStT-]{9}[@+]*\s+\d+\s+)${u}(\s)}{$1<user>$2};
}
'

while IFS= read -r rel; do
  base=${rel##*/}
  if printf '%s\n' "$base" | grep -Eq -- "$EXCLUDE_RE"; then
    printf '%s\t%s\n' "evidence/$rel" "name matches exclude pattern '$EXCLUDE_RE' (proprietary-binary record)" >> "$EXROWS"
    n_ex=$((n_ex + 1))
    continue
  fi
  src="$EVIDENCE/$rel"
  dst="$TOP/evidence/$rel"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  chmod u+w "$dst"
  rewritten=no
  if [ -s "$dst" ] && grep -Iq . "$dst"; then
    before=$(shasum -a 256 "$dst" | cut -d' ' -f1)
    PE_HOME="${HOME:-}" PE_USER="$USER_NAME" perl -pi -e "$PERL_REWRITE" "$dst"
    after=$(shasum -a 256 "$dst" | cut -d' ' -f1)
    if [ "$before" != "$after" ]; then rewritten=yes; n_rw=$((n_rw + 1)); fi
  fi
  sum=$(shasum -a 256 "$dst" | cut -d' ' -f1)
  size=$(wc -c < "$dst" | tr -d ' ')
  printf '%s\t%s\t%s\t%s\n' "$sum" "$size" "$rewritten" "evidence/$rel" >> "$ROWS"
  n_in=$((n_in + 1)); bytes_in=$((bytes_in + size))
done < "$LIST"

[ "$n_in" -gt 0 ] || die "every file was excluded; check --exclude"

# ---- verification: the staged tree must carry no trace of the operator ----------------------
if grep -rInE -e '\\?/Users\\?/'"$USER_NAME" -e "-Users-$USER_NAME-" "$TOP/evidence" | cut -c1-200 | head -20 | grep .; then
  die "operator path survived the rewrite (see lines above); fix the rewrite rules before packaging"
fi
if [ -n "${HOME:-}" ] && grep -rIlF -- "$HOME" "$TOP/evidence" | grep .; then
  die "HOME path survived the rewrite in the files above"
fi
# The bare user name as a word (ls -l owner columns, prompts, …): nothing may survive.
if grep -rInwF -- "$USER_NAME" "$TOP/evidence" | cut -c1-200 | head -20 | grep .; then
  die "the user name '$USER_NAME' survived as a bare word (lines above); add a rewrite rule or scrub the source file"
fi
# Generic secret shapes (bracketed so this script never matches itself) + <user>@ + the operator's
# identity literals from local/privacy-patterns.txt or OSSOVER_PRIVACY_RE (never written here).
SECRET_RE='ghp[_]|github[_]pat_|sk-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|PRIVATE[ ]KEY|'"$USER_NAME"'@|'"$IDENTITY_RE"
if grep -rIniE -- "$SECRET_RE" "$TOP/evidence" | cut -c1-200 | head -20 | grep .; then
  die "secret/identity pattern hit in the staged evidence (lines above); exclude or scrub the file"
fi

# ---- archive-root files ----------------------------------------------------------------------
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_DESC=$(git -C "$REPO" describe --always --dirty 2>/dev/null || echo unknown)

{
  printf 'ossover — REA evidence archive for CrossOver %s\n' "$VERSION"
  printf '==============================================\n\n'
  printf 'Built %s by scripts/release/package-evidence.sh from ossover checkout %s.\n\n' "$STAMP" "$GIT_DESC"
  cat <<'EOT'
What this is
  The raw records behind docs/rea/ledger.md, decisions.md and the sibling reports in docs/rea/ of
  the ossover repository (https://github.com/hemkum/ossover): REA (rea-agents 6.4.0) tool output,
  plain-shell observations (strings / nm / otool / objdump on the unzipped CrossOver 26.3.0 trial
  bundle) and the sources-pass records from CodeWeavers' crossover-sources-26.3.0.tar.gz (LGPL).
  Static analysis only; nothing from the target trees was executed. Every ledger row cites one of
  these files by name (and `file:line` for the text dumps), so the archive lets a reader check a
  claim without re-running the pass.

Scope and licensing
  * Records of LGPL-2.1+ binaries (ntdll.so, winemac.so, winemetal.so, wineloader, wineserver) and
    of DXMT (MIT at 0.80) are included. CodeWeavers' LGPL sources are quoted by file:line only.
  * Anything derived from a proprietary binary — Apple's D3DMetal / libd3dshared (Game Porting
    Toolkit) and CodeWeavers' cxcompatdb.so — is NOT in this archive; see EXCLUDED.txt. The
    public ledger keeps the facts those files supported (symbol names, import lists), not the dumps.
  * No code was copied from CrossOver's proprietary components; behaviour was observed.
  * "CrossOver" is a CodeWeavers trademark; "Game Porting Toolkit" and "D3DMetal" are Apple's.
    ossover is an independent, open-source project, not affiliated with or endorsed by either.

Privacy rewrites applied to text/JSON files (MANIFEST.txt column 3 says which files changed)
  * the operator's home directory ("/Users/<user>", also JSON-escaped "\/Users\/<user>") -> "~"
  * the Claude Code per-session scratchpad path under /private/tmp -> "<scratchpad>"
  * the owner column of `ls -l` lines                           -> "<user>"
  Hashes in MANIFEST.txt / SHA256SUMS are of the rewritten files as packaged. The REA Evidence IDs
  (ev_…) and artifact hashes recorded inside the files are unaffected.

Verify
  shasum -a 256 -c SHA256SUMS

Layout
  README.txt      this file
  MANIFEST.txt    sha256  size  rewritten(yes/no)  path   for every packaged file
  EXCLUDED.txt    files of docs/rea/evidence deliberately left out, with the reason
  SHA256SUMS      shasum -a 256 lines for README/MANIFEST/EXCLUDED and evidence/*
  evidence/       the records, same names as in the repository's docs/rea/evidence/
EOT
} > "$TOP/README.txt"

{
  printf '# ossover REA evidence manifest — %s — %d files, %d bytes, %d rewritten, %d excluded\n' "$NAME" "$n_in" "$bytes_in" "$n_rw" "$n_ex"
  printf '# sha256\tsize\trewritten\tpath\n'
  cat "$ROWS"
} > "$TOP/MANIFEST.txt"

{
  printf '# files of docs/rea/evidence not packaged (%d)\n' "$n_ex"
  printf '# path\treason\n'
  cat "$EXROWS"
} > "$TOP/EXCLUDED.txt"

(cd "$TOP" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256 > SHA256SUMS)

if command -v xattr >/dev/null 2>&1; then xattr -cr "$STAGE" 2>/dev/null || true; fi

info "staged: $n_in files ($bytes_in bytes), $n_rw rewritten, $n_ex excluded by name"
info ""
info "== EXCLUDED.txt =="
cat "$TOP/EXCLUDED.txt"
info ""
info "== MANIFEST.txt =="
cat "$TOP/MANIFEST.txt"

if [ "$DRY_RUN" = 1 ]; then
  info ""
  info "dry run: no archive written (staging: $TOP)"
  exit 0
fi

# ---- tarball ----------------------------------------------------------------------------------
mkdir -p "$OUT"
ARCHIVE="$OUT/$NAME.tar.xz"
MEMBERS="$STAGE/members.txt"
(cd "$STAGE" && find "$NAME" | LC_ALL=C sort) > "$MEMBERS"
TAR_NORECURSE=--no-recursion
TAR_EXTRA=""
if tar --version 2>/dev/null | grep -qi bsdtar; then
  TAR_NORECURSE=-n
  if tar --help 2>&1 | grep -q -- '--no-xattrs'; then TAR_EXTRA="--no-xattrs"; fi
fi
# shellcheck disable=SC2086
(cd "$STAGE" && COPYFILE_DISABLE=1 tar -cf - $TAR_NORECURSE $TAR_EXTRA -T "$MEMBERS") | xz -T0 -6 > "$ARCHIVE"
(cd "$OUT" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
cp "$TOP/MANIFEST.txt" "$OUT/$NAME.manifest.txt"
ARCHIVE_SIZE=$(wc -c < "$ARCHIVE" | tr -d ' ')

info ""
info "== archive =="
info "path:    $ARCHIVE"
info "size:    $ARCHIVE_SIZE bytes"
info "sha256:  $(cut -d' ' -f1 "$OUT/$NAME.tar.xz.sha256")"
info "sidecar: $OUT/$NAME.tar.xz.sha256"
info "manifest copy: $OUT/$NAME.manifest.txt"
info ""
info "Next (operator, by hand — this script never uploads):"
info "  xz -dc '$ARCHIVE' | tar -tf - | head          # eyeball the member list"
info "  gh release upload <tag> --repo hemkum/ossover '$ARCHIVE' '$OUT/$NAME.tar.xz.sha256'"
info "  (or pass both files to the gh release create command printed by export-public.sh)"
