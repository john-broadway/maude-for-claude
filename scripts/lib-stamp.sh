#!/usr/bin/env bash
# lib-stamp.sh — stamp a header field in a markdown file. Sourced by release.sh.
#
# THE ONE RULE: stamp the FIRST occurrence, and only the first.
#
# release.sh used to stamp with a bare `sed -E "s|<!-- Version: ... -->|...|"`, which
# rewrites every matching line in the file. maude-verify.sh reads the header with
# `grep -m1`, the first match only. The writer touched all, the checker read one, and the
# gap between them was invisible to both: a version string quoted in a document's BODY got
# silently rewritten to the current release on every run, and nothing ever reported it.
# Thirteen releases of that left docs/superpowers/plans/2026-06-30-gate-bypass-hardening.md
# contradicting itself — a step headed "Bump version 0.13.1 -> 0.13.2" whose checklist had
# been rewritten to say 0.31.0. Found by the v0.31.0 release-diff lens, 2026-09-04.
#
# So the writer is pointed at the same occurrence the checker reads. Not a line window,
# which would be a guess about where headers live; the FIRST match, which is the checker's
# own definition of the header. Writer and checker cannot disagree about their subject when
# construction makes them the same subject.
#
# awk, not `sed -i` with GNU's `0,/re/` address: that address does not exist in BSD sed and
# this plugin runs on macOS. `1,/re/` is not a substitute — POSIX starts its search at line
# 2, so it would skip a header on line 1, which is exactly where headers live here.

# THE HEADER BLOCK. Metadata lives at the top of a file, and this is the one definition
# of "the top" — maude-verify.sh sources this file rather than keeping a second copy,
# because two verbatim copies of a rule drift and this repo has caught that before.
#
# Ten is generous against the measured convention (2026-09-04): of the 19 markdown version
# headers in this repo, 18 are HTML comments on line 1 and one is a blockquote on line 3,
# under a title. Nothing legitimate sits below 3. Ten leaves room for a longer preamble
# without coming near a document's prose.
: "${MAUDE_HEADER_LINES:=10}"

# stamp_header FILE ERE REPLACEMENT
#   Replaces the first ERE match WITHIN THE HEADER BLOCK of FILE with REPLACEMENT
#   (literal text, not a template: no `&` or backreference expansion, so a replacement
#   containing them is safe). A file whose only match is further down has no header and is
#   left byte-identical, as is a file with no match at all. Non-zero only on I/O failure.
stamp_header() {
  local f="$1" re="$2" rep="$3" t target link hops mode
  [ -f "$f" ] || return 1

  # Resolve a symlink to the file it names, so the stamp lands on the TARGET and the link
  # stays a link. Done with a bounded loop rather than `readlink -f`, which is GNU-only and
  # this plugin runs on macOS. The hop limit stops a symlink cycle spinning here.
  target="$f"; hops=0
  while [ -L "$target" ] && [ "$hops" -lt 32 ]; do
    link="$(readlink -- "$target")" || break
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname -- "$target")/$link" ;;
    esac
    hops=$((hops + 1))
  done
  # RUNNING OUT OF HOPS MEANS THE TARGET IS UNKNOWN, AND UNKNOWN MUST REFUSE. This used to
  # fall through, and because the kernel resolves the rest of the chain the `-f` test below
  # still passed: it stamped whichever intermediate link it was holding, destroyed that link
  # by replacing it with a regular file, never touched the real target, and returned 0.
  # Reproduced with a 35-link chain, 2026-09-04.
  [ -L "$target" ] && return 1
  [ -f "$target" ] || return 1

  # THE TEMPORARY LIVES BESIDE THE TARGET, which is what makes the replace atomic: `mv`
  # within one directory is a rename, while a temp in /tmp can land on another filesystem
  # and degrade to a copy, reopening the very window this exists to close.
  t="$(mktemp "$(dirname -- "$target")/.stamp.XXXXXX")" || return 1

  # `stamped` guards the whole file, so a second match is never touched; the NR bound is
  # what keeps prose out of reach entirely. substr() splices the replacement in literally —
  # index/RSTART arithmetic rather than sub(), because sub() would expand `&` in the
  # replacement into the matched text.
  # `re` and `rep` travel through ENVIRON, never -v: every awk processes escape sequences
  # in a -v value, and which ones differs by awk (`\*` reached this box's mawk intact and
  # reached the GitHub runners' mawk and BSD awk as `*`, so the blockquote regex stopped
  # matching there, 2026-09-13, PR #68). ENVIRON is the one channel none of them touches.
  if MAUDE_STAMP_RE="$re" MAUDE_STAMP_REP="$rep" awk -v maxln="$MAUDE_HEADER_LINES" '
        BEGIN { re = ENVIRON["MAUDE_STAMP_RE"]; rep = ENVIRON["MAUDE_STAMP_REP"] }
        NR <= maxln && !stamped && match($0, re) {
          $0 = substr($0, 1, RSTART - 1) rep substr($0, RSTART + RLENGTH)
          stamped = 1
        }
        { print }
      ' "$target" > "$t"; then
    # Carry the mode on the TEMPORARY, then rename. An earlier attempt did the opposite and
    # wrote the finished bytes back into the original with `cat -- "$t" > "$f"`: that kept
    # the mode but the shell opens the target with O_TRUNC before the command runs, so a
    # failure part-way through the copy left a truncated file and the original was
    # unrecoverable. It traded losing a permission bit for losing the file. rename(2) is
    # the only step that touches the target, and it either happens or it does not.
    # OWNERSHIP IS NOT CARRIED, deliberately. The rename puts the temporary in place, so the
    # stamped file ends up owned by whoever ran the release, not by whoever owned it before.
    # Restoring it would need root, and this tree has a single owner, so the cost of getting
    # chown wrong outweighs the case it covers. Stated here because a previous commit
    # message claimed this was documented when nothing said it anywhere.
    mode="$(stat -c %a "$target" 2>/dev/null)"                 # portability-shim (GNU)
    [ -n "$mode" ] || mode="$(stat -f %Lp "$target" 2>/dev/null)"  # portability-shim (BSD)
    [ -n "$mode" ] && chmod "$mode" -- "$t" 2>/dev/null
    if mv -- "$t" "$target"; then
      return 0
    fi
  fi
  rm -f -- "$t"
  return 1
}
