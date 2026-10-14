#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/release/privacy-re.sh — sourced by export-public.sh and package-evidence.sh.
#
#   load_privacy_re REPO     prints the operator's identity regex (an extended regex, used
#                            case-insensitively) and dies when there is none, so the
#                            personal-data gate can never silently run empty.
#   privacy_re_source REPO   prints where that regex came from (for the final report).
#
# Sources, in order:
#   1. $OSSOVER_PRIVACY_RE, when set and non-empty (a one-off override, e.g. on another machine);
#   2. REPO/local/privacy-patterns.txt: one extended-regex alternative per line, joined with "|"
#      (escape dots: example\.com). /local/ is gitignored and export-public.sh skips it, so the
#      literals (work e-mail domain, <first-name>@, old handles, /Users/<user>) never enter a
#      file that goes public. docs/release-checklist.md §1 shows how to create it.
#
# The generic token shapes (GitHub / OpenAI / AWS tokens, PEM private-key headers) and the forms
# derived from `id -un` stay in the scripts themselves; only identity literals belong here.
#
# The caller must define die().

privacy_re_source() {
  if [ -n "${OSSOVER_PRIVACY_RE:-}" ]; then printf '$OSSOVER_PRIVACY_RE'; else printf '%s' "$1/local/privacy-patterns.txt"; fi
}

load_privacy_re() {
  local repo=$1 file re src rc
  file="$repo/local/privacy-patterns.txt"
  src=$(privacy_re_source "$repo")
  if [ -n "${OSSOVER_PRIVACY_RE:-}" ]; then
    re=$OSSOVER_PRIVACY_RE
  elif [ -f "$file" ]; then
    re=$(grep . "$file" | paste -sd '|' -)
  else
    die "missing $file (gitignored; one extended-regex alternative per line: work e-mail domain, <first-name>@, old handles, /Users/<user>; see docs/release-checklist.md §1) and OSSOVER_PRIVACY_RE is unset. The identity gate would be empty; refusing to run."
  fi
  [ -n "$re" ] || die "the identity pattern from $src is empty; refusing to run"
  case "$re" in
    '|'*|*'|'|*'||'*) die "the identity pattern from $src has an empty alternative (it would match every line): $re" ;;
  esac
  rc=0; printf '' | grep -qiE -e "$re" 2>/dev/null || rc=$?
  [ "$rc" -le 1 ] || die "the identity pattern from $src is not a valid extended regex: $re"
  printf '%s' "$re"
}
