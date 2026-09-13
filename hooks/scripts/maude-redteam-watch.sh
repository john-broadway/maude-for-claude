#!/usr/bin/env bash
# Maude redteam-watch hook — the adversarial-pass tripwire.
#
#   stamp   (PostToolUse · any tool, called from maude-trace.sh) — if an Agent/Task
#           dispatch that just COMPLETED was adversarial in intent, record in care.json
#           `.last_redteam_iso[sid]` an ISO timestamp AND the git refs the brief named:
#           `{"ts": "...", "refs": ["7e36d82", ...]}`. ship.sh checks the refs against
#           the tip it is shipping; the commit whisper below uses only the timestamp.
#   check   (PreToolUse · Bash, called from maude-bash-watch.sh) — on a `git commit`,
#           if CODE files were edited since the last adversarial pass, whisper once.
#
# ALWAYS exits 0. Whisper, never block.
#
# WHY THIS EXISTS
# John's standing expectation (2026-07-30): every build gets an adversarial pass before it
# is called done, Claude launches it, using OUR sub configs — "we were doing it before
# antrhopic pushed" · "we are always dogfooding".
#
# Maude already HELD that preference. ~/.claude/maude/identity.md carries the tiering
# correction verbatim — "redteams use models for the tasks dont lock us down that small" —
# and the uniform-bar rule beside it. On 2026-07-30 three builds shipped with ZERO
# adversarial passes anyway, because identity.md is 86KB read at wake and nothing consults
# it at the moment a build finishes. Knowledge in a file is a diary. A hook is a rail.
# Build the gate, not the wardrobe.
#
# THE ASYMMETRY THAT MAKES A TEXT HEURISTIC SAFE HERE
# A MISSED stamp costs one extra advisory whisper. A FALSE stamp manufactures "you're
# covered" when nothing reviewed the work. Those are not symmetric, so every judgement call
# below leans the same way: don't stamp unless it plainly reads adversarial, and whisper
# whenever in doubt. Same shape as maude-verify-watch.sh's failure-sniff, and for the same
# reason.
#
# HONEST SEAM: intent is read from the dispatch's own description/prompt text. A redteam
# worded in some way this pattern doesn't recognise won't stamp — the cost is a spurious
# whisper, never a false all-clear. It also cannot tell a thorough lens from a lazy one; it
# knows an adversarial pass was RUN, not that it was any good. The refs have the same shape
# of honesty: they are what the brief SAID it was reviewing, not proof of what the reviewer
# read. And they are LITERAL SHAS ONLY: a brief that names its subject as a tag, a branch or
# HEAD scrapes nothing and earns no credit at the gate, because this hook has no repository
# to resolve a name against. That costs a re-run with the sha spelled out, which is the
# direction to fail in, and ship.sh's refusal says which sha it wanted. That is still
# strictly more than a bare timestamp, which said nothing about the subject at all — and it
# makes a brief that never names its subject visibly uncredited.

set +e
# Every guard in this file that reads text or an id is a byte test, and the file says so
# ONCE, here, before anything else runs: a bracket range, a tr fold and a grep are collation
# under a UTF-8 locale, and a per-line `LC_ALL=C` prefix is a thing a tidy-up loses (a bare
# `LC_ALL=C` on its own line is not an export, and the guard below it runs under whatever the
# CALLER exported; the 35th lens, BLOCKING-2). The export makes the property the file's own,
# whatever the invoking process had in its environment. The sourced helpers run under it too
# (the tests trace the export before the source line, and a shim on grep and tr records the
# LC_ALL the guards were handed: the 36th lens, IMPORTANT-1 and MINOR-8).
export LC_ALL=C

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

MODE="${1:-}"
INPUT="$(cat 2>/dev/null)"
CARE="$(maude_self_dir)/care.json"

# PER SESSION. care.json and the trace are BOTH shared by every session at a project root —
# five lanes were live here on 2026-07-30 (proximo, maude, pacioli, maximus, +). Unscoped,
# this rail would count a sibling lane's edits and whisper about work that was never yours,
# which is the crying-wolf failure the mission pin had committed that same night. Same 8-char
# `sid` the trace writes (maude-trace.sh:57), so the two agree on identity.
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
SID="$(printf '%s' "$SID" | cut -c1-8)"
[ -n "$SID" ] || SID="default"

# Adversarial intent. Deliberately narrow: these are the words this house actually uses
# when it dispatches a lens (measured 2026-08-17 over the then-held window of transcripts —
# "Adversarial review of the federation rename", "Haiku cadence judge … a second lens").
#
# WHOLE WORDS, in plain ERE. Both lists were bare stems, and a stem matches inside a longer
# word: `port the` inside "report the", `refactor` inside "refactored", `attack` inside
# "attackers", `audit` inside "auditor", `judge` inside "judgement". Measured 09-07 over
# the then-held window (the 31st lens, BLOCKING-1): 31 of the 391 real dispatches the box
# held that day were lenses the builder check dropped on a word inside a word, one in twelve
# (the lens counted 34; re-running its instrument gave 35, four of them implementers its
# own boundary check had mis-flagged), and "report the findings" is what every lens brief
# in this house says. The 08-17 repair deleted one over-broad alternative and left the
# class. `\b` is a GNU extension; the text is already lowercased, so a boundary is "not a
# lowercase letter, digit or underscore". Inflections are spelled OUT, never stemmed: a
# stem with a boundary after it is the trap in reverse (`migrat\b` matches nothing). The
# greps that consume these run under the file's LC_ALL=C export above: a bracket range is
# collation, and under en_US.utf8 a fullwidth letter glued to a listed word collated inside
# a-z and hid the word from BOTH lists (the 32nd lens, BLOCKING-2).
_RE_WB='(^|[^a-z0-9_])'; _RE_WE='([^a-z0-9_]|$)'
# The REVIEW side's boundary also refuses `-`, `.` and `/`: a review word glued to an
# identifier is part of the identifier. `redteam` inside this hook's own file name and
# `audit` inside the pre-push guard's `leak-audit` marker had credited three captured
# dispatches that reviewed nothing, one with a real sha in its refs (the 34th lens,
# BLOCKING-3). On the RIGHT, the three characters glue only when a letter, digit or `_`
# follows: `judge.py` is an identifier and "then attack." is a sentence, which the first cut
# refused, the most ordinary English there is (the 34th round's own review, before the
# push). On the LEFT, a hyphen glues UNLESS what precedes it is one of the English prefixes
# this list can follow, a CLOSED set (re-, self-, pre-, post-, counter-): identifiers are an
# open vocabulary (`leak-audit`, `pip-audit`, `shape-audit`), prefixes are not. The 34th's
# second cut had bounded any of the three characters that followed a non-word character,
# which admitted `--audit` and `.audit` (a brief that asks for a CLI flag to be built wrote
# a full stamp) and still refused `Re-audit` (the 35th lens, BLOCKING-1). The 35th's cut
# refused the flag and left every other way code marks a token open: `--mode=audit`, a
# backticked `audit`, `audit()`, `[audit]`, a quoted `"audit"` and `MODE:audit` each wrote
# a full stamp naming the tip (the 36th lens, BLOCKING-1). The 36th's cut listed those
# marks as what GLUES, and a SIGIL is how code marks a token too: `@audit`, `$audit`,
# `<audit>`, `#audit`, `%audit%`, `*audit`, `&audit` and `~audit` each wrote a full stamp
# naming the tip (the 37th lens, BLOCKING-1). A glue list always has a next character, so
# the boundary now names what BOUNDS and everything else glues. The class is a review word
# that is a TOKEN in code; a token is glued to its mark, and prose is not. On the LEFT a
# review word is bounded by the start of the text, whitespace, a comma or semicolon, a
# closing mark, a double asterisk (markdown emphasis) or a non-ASCII byte (the 32nd's law:
# a non-ASCII letter glued to a listed word is still a boundary, both sides; a curly
# quotation mark and an em dash are non-ASCII bytes and bound too), plus the closed
# English-prefix rule below. On the RIGHT it is bounded by the end, whitespace, sentence
# punctuation (, ; : ! ?), a closing mark, a double asterisk, a non-ASCII byte, or a dot,
# hyphen or slash followed by a non-word: "(then attack)" is an order in parentheses,
# "Lens 3:" is how this house numbers a pass, and "the audit's" (an apostrophe glues) is a
# noun's possessive, a mention. Every one of those shapes is constructed. Named residuals:
# a lone asterisk glues ("*attack*" loses credit), and so do a `~~` pair (strikethrough),
# a table cell with no padding ("|audit|") and a blockquote with no space (">attack"),
# each bounded under the 36th and none carried by a credited row (the 38th lens,
# MINOR-4); a quoted ORDER is a quotation; a review word bare beside whitespace in code
# ("--mode audit", "audit/ ") credits.
# `non-`/`un-` are left out on purpose, they negate; a double hyphen glued to a review
# word's front ("fix--attack it") reads as a flag and is refused, named in the tests.
# A corpus count is a MEASUREMENT over a window that rolls, never a fact (the 36th lens,
# IMPORTANT-2: a row the 34th cited left the box the day its number was committed): it
# carries its time, its window, its instrument and its row keys, or it is not checkable.
# The older counts in this file and the tests carry a date and the words "then-held
# window": measured that day over the transcripts the box held, keyed by nothing, and
# not reproducible at a later count (the 37th lens, IMPORTANT-1). They stay because the
# DECISION each one carried was made on it; none of them is a claim about the box today.
# A row key resolves on the author's box alone, for as long as the window holds the row,
# and for no other reader: it buys falsifiability there and then, and the dump beside the
# logs is what makes gone tell from never there (the 37th lens, MINOR-5).
# Measured 2026-09-10 05:2xZ over the 405 dispatches this box held (a 30-day transcript
# window, 2026-08-11..2026-09-10; scan33.py and scan36a-keys.txt, the author's instrument
# and row list, off-tree): 20 rows carry a review word beside a code mark and none was
# credited only through it under the 35th's boundary; the rows carrying the flag or the
# prefix shapes are this rail's own 35th and 36th briefs (99539428:3335, 8de87643:565),
# which quote them to describe this trap. Cost of the whole review-side boundary against
# the 33rd's tree (dcf8f04), same measurement: two task-scoped reviews credited by nothing
# but an identifier token (6b036e55:1061, acd45355:745) and one read-only scoping pass
# credited by a noun's possessive alone (55499a8a:153, "the audit's finding") record
# nothing; a fourth row the 34th measured (713290c7:322, a dependabot fold credited
# through `leak-audit`) left the window on 2026-09-09; one inventory "for the estate-CI/
# canon audit." (afefdec1:2032) stays credited by its sentence-final noun.
# Measured again 2026-09-11 19:05Z over the 366 dispatches then held (window 2026-08-12..
# 2026-09-11; scan37.py and scan37a-keys.txt, the same instrument reading the boundary as
# bytes): the possessive row (55499a8a:153) had left the window, the other three named
# above were present; not one row changes class between the 36th's boundary (cff8d7a, an
# internal-tree sha, as every sha in this file is) and
# this one; 9 rows carry a review word glued to a sigil on its left (6 of them markdown
# bold, `**attack**`), 3 on its right, none a non-ASCII byte on its left and one on its
# right (an em dash, this rail's own brief), and none of them is credited only through
# the shape. The first pass of that count said 4 and 62: the instrument's byte range was
# a raw literal and the bracket held the characters of the escape instead; caught by
# tallying the bytes it claimed to have found (scan37b-hi-bytes.txt).
# The builder side keeps the wider boundary: builder first is the side where wider is safer.
_RE_AWB=$'(^|[][:space:],;)}\x80-\xff]|\\*\\*)((re|self|pre|post|counter)-)?'; _RE_AWE=$'([][:space:],;:!?)}\x80-\xff]|\\*\\*|[./-]([^a-z0-9_]|$)|$)'
# `lens on …` / `lens 3:` is the noun this house uses for a pass ("Claims lens on the
# release text", "Confirmation lens on the frozen leg" — real dispatches credited only by
# a stem inside a word, or not at all). A bare `lens` is not: three L-walk research
# dispatches carried the word and were not reviews (09-07, then-held window).
ADVERSARIAL_RE="${_RE_AWB}(red[- ]?team(s|ed|ing)?|adversarial(ly)?|second lens|lens (on|[0-9])|refute[sd]?|falsif(y|ies|ied)|break this|find the (bugs|gaps|holes)|attack(s|ed|ing)?|hostile|poke holes|try to (break|defeat)|judg(e|es|ed|ing)|critique[sd]?|audit(s|ed|ing)?)${_RE_AWE}"

# Words that mark a BUILDER, not a lens. Checked FIRST: a dispatch that implements is not a
# review of the implementation, however carefully it is worded. Measured negative from a
# real transcript: "Build 7e first-light wiring TDD" / "You are a careful TDD implementer".
# `build the` used to sit in this list and was measured wrong on 2026-08-17 (then-held
# window): of 8 real
# adversarial dispatches, 7 asked the reviewer to "build the table"/"build the list" of
# findings and were read as implementers, so the ship rail's second-lens gate went unfed.
# The motivating negative ("Build 7e first-light wiring TDD") does not contain the phrase
# at all, so it cost real stamps and earned nothing. What catches that one now is the
# SELF-TITLE and SELF-REVIEW phrases at the end of the list, not the noun `implementer`
# (removed below): "you are a careful TDD implementer" and "judge your own work" are each
# a build order on their own (the 34th lens, BLOCKING-2). Replaced with build-verbs bound
# to things you BUILD, not things a lens writes. `implement ` keeps its trailing space on
# purpose: it is the VERB with an object after it. As a whole word it read "the code
# doesn't implement," in two real lens briefs as a build order (measured 09-07, then-held
# window), which is the drop this change exists to end.
#
# Which BUILDER inflections are spelled out was decided by the corpus, not by symmetry with
# the list above (the 32nd lens, BLOCKING-1: the first whole-word cut dropped EVERY builder
# inflection, so "refactoring the parser, then audit it" wrote a review stamp). Measured over
# the 397 real dispatches this box held on 09-07 (then-held window): `refactor*`/`scaffold*`
# inflections occur in no brief at all, so they cost nothing and close the door;
# `implementing` is kept on its MARGINAL ledger (the 33rd lens, IMPORTANT-2, measured the
# same day): four build
# briefs it alone refuses, one of which (the B3 row pinned below) carries a review word and
# would have stamped, against two review briefs lost; builder first is the side that never
# stamps what did not review. Plural build objects likewise. `implemented` was added by the 32nd's
# fix on a raw frequency (7 build : 2 lens) and removed by the 33rd's marginal ledger: it
# refused ZERO builders the list did not already refuse and cost two review briefs, and a
# past tense is a description, not an order. `implementer` went the same way by the same
# ledger, measured by the author after that report: sixteen review briefs on this box say
# "the implementer's report"; fourteen were refused for that word alone (two were held
# builder by another word), and no build brief needed it. The door that removal opened
# ("you are the implementer of X; audit your own work" stamped for one round) is closed by
# the two phrases that end this list, each its own alternative because each needs a tail
# the shared boundary cannot give it: "you are"/"as", an optional article, up to two
# modifiers none of which is "not", then implementer/builder, singular or plural, NOT
# followed by a possessive ("you are not the builder" and "reviewing the builder's work" are
# how a lens is addressed, and read as builders for one round: the 35th lens, IMPORTANT-1;
# "you are builders B1 and B2" wrote a full stamp for one round: the 36th lens, BLOCKING-2);
# and a review verb before "your own work" unless the word before the verb is "not" or
# "don't". Still refused, by a closed set that stops there: "never", "no", "now the
# builder", and a "not" one word further from the verb ("not to audit your own work"; "do
# not, under any circumstances, audit your own work"), named in the tests. Both phrases
# fire on no build brief this box had not already refused; their only corpus cost is this
# rail's own lens briefs, which quote the phrases to describe this trap and are spelled
# around it. The plural went in on the ASYMMETRY law at the top of this file and against
# the marginal ledger below: it refuses no captured build brief (B1, B2, B3 are singular)
# and costs one lens, this rail's own 35th brief (99539428:3335); a false stamp is the
# failure that matters, and the disagreement between the two laws is decided here, not
# left implicit.
# NOT added, because in this house they live in LENS briefs: `migrated`/`migrates`/
# `migration` (2 build : 10 lens, raw sums on 09-07, then-held window), `implementers`
# (0 : 2), `implements` (0 : 4), `rebuilt` (0 : 6). A word that lives in lens briefs alone
# does not go in. The
# verbs that stay (`implement `, `refactor`, `migrate`, `port the`, `write the code`,
# `(re)build the`) each still refuse review briefs that use them as nouns ("the refactor",
# "bench migrate", "does the branch implement the spec"): eleven on this box, and two more
# for `implementing`, the measured price of builder first. The ledgers were measured over
# the author's own session transcripts, which are private and stay off the shipped tree on
# purpose; the CHANGELOG carries the numbers and the instrument's shape.
# A lowercase word that is not "not" (plain ERE has no lookaround; the five alternatives
# are: starts a-m/o-z; starts n but not no; starts no but not not; not + more letters; n or no).
_RE_MOD='([a-mo-z][a-z]*|n[a-np-z][a-z]*|no[a-su-z][a-z]*|not[a-z]+|no?)'
BUILDER_RE="${_RE_WB}(implement |(implementing|write the code|(re)?build (the )?(feature|module|package|service|app|api|cli|endpoint|integration|wiring|pipeline|harness|scaffold)s?|scaffold(s|ed|ing)?|refactor(s|ed|ing)?|port the|migrate)${_RE_WE})|${_RE_WB}(you are|as) (the |an? )?(${_RE_MOD} ){0,2}(implementer|builder)s?([^a-z0-9_']|$)|(^ ?|[^a-z0-9_ ]|[^a-z0-9_'] |(^|[^a-z0-9_'])${_RE_MOD} )(judge|audit|review|check|critique|attack|test|verify|assess)(s|ed|ing)? your own (work|code|change|changes|fix|fixes|output|implementation|diff)${_RE_WE}"

# Shared with verify-watch and rules-watch through _maude-common.sh so the rails agree on
# the PATTERN. Since the export at the top of this file they no longer share the
# collation: `[[:space:]]` in the shared pattern is a locale class, this hook reads it
# under C and its two siblings read it under the caller's locale (the 36th lens, MINOR-6;
# a thin or ideographic space between `git` and `commit` matches there and not here).
# The sweep that gives every hook its own export is a later round, John's word.
COMMIT_RE="$(maude_commit_re)"
DOC_RE="$(maude_doc_re)"

case "$MODE" in
  stamp)
    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"

    # A lens KILLED with TaskStop emits no SubagentStop for its own id, so the promote
    # path below — which already clears on cancelled/aborted/interrupted — never runs at
    # all: a kill is the one ending that reports nothing. The entry then sat pending
    # until the 7-day age prune and every wake in between named a lens that was not
    # running (live on this box: ad21d0f7, launched 2026-09-06T19:35:14Z, killed by
    # TaskStop 5m27s later, still named at the wake eight hours after that). Killing a
    # lens you outran is the CORRECT move; doing the correct thing must not leave a
    # false alarm behind.
    #
    # The id comes from the RESPONSE, never the request. A TaskStop the auto-mode
    # classifier refuses returns an error STRING and stops nothing, and clearing on the
    # id that was merely ASKED for would manufacture "that lens is dealt with" while it
    # is still running — the same false all-clear the asymmetry note at the top of this
    # file is built to refuse. The request says what was wanted; only the response says
    # what happened.
    if [ "$TOOL" = TaskStop ]; then
      STOPPED="$(printf '%s' "$INPUT" \
        | jq -r 'if (.tool_response | type) == "object" then ((.tool_response.task_id // "") | tostring) else "" end' 2>/dev/null)"
      # A bracket range is COLLATION, not bytes. Under this box's en_US.UTF-8 the class
      # [!A-Za-z0-9_-] admits the fullwidth ａ (U+FF41) and the ligature ﬀ (U+FB00) by
      # collating them beside the ASCII letters, so what this guard MEANT moved with the
      # box's locale (the 29th lens, MINOR-3), so both sides of this file ask
      # maude_is_ascii_token instead — one guard, because two of them drifted the moment
      # one was fixed (the 30th lens, IMPORTANT-1). Honest seam: a trailing newline is
      # already gone before we get here — $() strips it — so an id differing only by one
      # is indistinguishable from the clean id at this layer, and clears the clean entry.
      maude_is_ascii_token "$STOPPED" || exit 0
      # The type check is belt, not mechanism: has() on a non-object already raises and
      # fails the -e. Kept because a jq that answered instead of raising would reach the
      # write. No test can see its absence, and it should not pretend otherwise.
      if jq -e --arg aid "$STOPPED" '(.redteam_pending // {}) | (type == "object") and has($aid)' "$CARE" >/dev/null 2>&1; then
        # maude_care_set returns 0 ONLY if the bytes landed, exactly so a caller can avoid
        # claiming a write that dropped (_maude-common.sh) — and the sibling one file away
        # (maude-verify-watch.sh) had honoured that all along while this branch discarded
        # it and logged the clear unconditionally (the 29th lens, IMPORTANT-1). The entry
        # survives a failed write, so the wake still names the lens and nothing is falsely
        # cleared; what broke was the DIAGNOSTIC, which told a reader the opposite of what
        # the store holds. Our code does not get to lie about its own writes.
        if maude_care_set "$CARE" --arg aid "$STOPPED" \
             'if (.redteam_pending // {})[$aid] then del(.redteam_pending[$aid]) else . end'; then
          maude_log_trace "redteam" "${STOPPED:0:8} was stopped before it reported: nothing reviewed, no stamp; pending entry cleared"
        else
          maude_log_trace "redteam" "${STOPPED:0:8} was stopped but could not clear its pending entry (care.json could not be read or written); the wake will still name it"
        fi
      fi
      exit 0
    fi

    case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

    # A killed dispatch reviewed nothing. Same belt as verify-watch's interrupted check.
    [ "$(printf '%s' "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)" = "true" ] && exit 0

    TEXT="$(printf '%s' "$INPUT" \
      | jq -r '[(.tool_input.description // ""), (.tool_input.prompt // "")] | join(" ")' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')"
    [ -n "$TEXT" ] || exit 0

    # Builder first — an implementer dispatch whose prompt happens to say "find the bugs"
    # is still an implementer, and stamping it would be the false all-clear.
    printf '%s' "$TEXT" | grep -qE -- "$BUILDER_RE" && exit 0
    printf '%s' "$TEXT" | grep -qE -- "$ADVERSARIAL_RE" || exit 0

    # THE REF THE BRIEF NAMES. A timestamp alone proves a dispatch FINISHED after a
    # commit, never that it SAW it: on 2026-09-04 the v0.31.0 release commit was covered
    # by a stamp written 48 seconds later by a dispatch that began before the commit
    # existed, and the ship gate read that as proven. So record what the brief points at.
    #
    # This side does NOT verify the refs resolve. The hook runs from the workspace root,
    # which is not a git repo, and it cannot know which repo a brief means. ship.sh runs
    # inside the repo it is shipping and is the only party that can judge them, so the
    # writer records an unverified claim and the reader does the checking.
    #
    # Seven is the floor because it is git's own shortest abbreviation and six is the
    # longest accidental hex run that turns up in ordinary prose. `-w` keeps a hex run
    # that is part of a longer token (a session id, a URL) from matching at all, and the
    # cap keeps a pathological brief from bloating care.json. Order of appearance is
    # preserved on purpose; see the note at the scrape itself.
    # `sort -u | head` was wrong here: it sorted BEFORE truncating, so a brief carrying a
    # crowd of hex-looking words could sort the real sha out of the list and the gate would
    # then refuse a review that genuinely happened. Dedupe in ORDER OF APPEARANCE instead,
    # because a brief names its subject early, and cap generously: the cap exists to stop a
    # pathological brief bloating care.json, not to ration honest refs.
    # Bytes, under the file's LC_ALL=C export: a bracket range is collation, and under
    # en_US.utf8 this one admitted a hex run with an Arabic-Indic tail, a garbage ref that
    # took a slot in the cap and the window (the 31st lens, MINOR-4a).
    # An all-digit run is scraped too: fifteen of this repo's own short shas are all
    # digits (8782231 was a pushed tip), so a scrape-time filter would drop real refs. A
    # decimal that is no commit resolves to nothing on the reader's side (the 34th lens,
    # MINOR-8; named, not changed).
    REFS="$(printf '%s' "$TEXT" | grep -owE '[0-9a-f]{7,40}' 2>/dev/null \
            | awk '!seen[$0]++' | head -64 | jq -R . | jq -sc . 2>/dev/null)"
    [ -n "$REFS" ] || REFS='[]'

    # A BACKGROUND LAUNCH IS NOT A COMPLETION. When the dispatch runs in the background
    # the Agent tool returns at launch and this PostToolUse fires then, with the launch
    # notice as the whole response; a stamp written here would be a LAUNCH stamp. On
    # 2026-09-06 the 23rd lens died with its session three minutes after dispatch and
    # care.json still named the tip as reviewed. So a launch notice records a PENDING
    # entry under the agent id it carries, and `promote` (from the subagent-stop hook,
    # whose stdin carries agent_id) turns it into the stamp when that agent actually
    # stops. A notice without an id can never be promoted: record nothing, which costs
    # one whisper and never a false all-clear.
    #
    # The launch envelope is an OBJECT, captured 2026-09-06 19:14Z from this box's own
    # transcript (the harness's toolUseResult is this hook's tool_response):
    #   {isAsync:true, status:"async_launched", agentId:"…", description, resolvedModel, prompt}
    # It is not the "Async agent launched … agentId: …" text the model reads. The first
    # live launch on this branch (the 24th lens) was stamped as a PASS because this block
    # read text shapes only. The object is read first; the text is a fallback. Any object
    # that carries an agentId AND NO COMPLETION EVIDENCE is a dispatch: an unrecognised
    # shape leans toward PENDING, never toward a false pass (the rule at the top of this
    # file; the 24th lens, IMPORTANT-1: a rename of `status` must not bring the 19:14:41Z
    # stamp back). An id that is not a plain token could never be promoted (MINOR-3).
    # A SYNCHRONOUS completion carries an agentId too — captured 2026-08-13 from this
    # box's transcripts: {status:"completed", agentId, agentType, content, totalDurationMs,
    # …, no isAsync} — so the id alone filed a finished pass as a launch nothing could ever
    # promote, and the wake named it forever (the 25th lens, BLOCKING-1). Completion
    # evidence — content, agentType, totalDurationMs, status "completed" — makes it a
    # completion, but ONLY where the envelope does not say outright that it is a launch:
    # `agentType` is a property of the dispatch, so ranking it above `isAsync: true` would
    # stamp every background lens as a finished pass the moment it was dispatched, which is
    # the 2026-09-06 failure this file exists to refuse (the 26th lens, IMPORTANT-1).
    # A lens that ERRORED reviewed nothing. "Completion evidence" said a dispatch had
    # finished and never asked whether it finished WELL, so a failed, cancelled, timed-out
    # or errored run stamped a pass on the tip its brief named — and since the stamp unions
    # its refs, nothing could take it back (the 27th lens, IMPORTANT-1).
    #
    # Two separate questions, and the first version answered them with one test. A KNOWN
    # failure means nothing ran: no stamp and no pending entry. An UNRECOGNISED status is
    # not a failure — the belt refused those too, so a harness that renames its launch
    # status would leave every background dispatch with no stamp, no pending entry and
    # nothing for the wake to name, which is the dead-lens-nobody-can-see failure this file
    # was built to end (the 28th lens, IMPORTANT-7). So: block on a named failure, and
    # otherwise let the launch/completion split below decide; only the COMPLETION branch
    # additionally insists on a status it recognises.
    RSTAT="$(printf '%s' "$INPUT" | jq -r '.tool_response | if type=="object" then ((.status // "") | tostring) else "" end' 2>/dev/null)"
    # Any is_error that is not false/absent is an error, whatever its type (MINOR-7).
    RERR="$(printf '%s' "$INPUT" | jq -r '.tool_response | if type=="object" then (if ((.is_error // .isError // false) | tostring) | . == "false" or . == "null" then "no" else "yes" end) else "no" end' 2>/dev/null)"
    case "$RSTAT" in
      failed|cancelled|error|errored|timeout|timed_out|aborted|expired|rejected)
        maude_log_trace "redteam" "dispatch ended \"$RSTAT\": nothing reviewed, nothing recorded"; exit 0 ;;
    esac
    if [ "$RERR" = yes ]; then
      maude_log_trace "redteam" "dispatch reported an error: nothing reviewed, nothing recorded"
      exit 0
    fi

    META="$(printf '%s' "$INPUT" | jq -r '.tool_response
      | if type=="object" then
          (if (.isAsync == true) or (.status == "async_launched") then "async"
           elif (((.content | type) == "array" and any(.content[]?; ((.text? // "") | tostring | test("\\S"))))
                 or ((.content | type) == "string" and (.content | test("\\S")))) then "object"
           elif (.agentId != null) and (.content == null) and (.status != "completed") then "async"
           else "none" end)
          + "\t" + ((.agentId // "") | tostring)
        else "text\t" end' 2>/dev/null)"
    # KIND: "async" = a launch; "object" = a completion carrying evidence; "none" = an object
    # carrying none; "text" = a string or an array. Only "object" may stamp (below).
    # Evidence is a NON-BLANK TEXT the agent returned, and nothing else. `status`, `agentType`
    # and `totalDurationMs` are not evidence: every real completion on this box carries all
    # three, and so does one whose content is empty, so a gate that accepted any of them
    # refused only shapes that never occur and admitted every shape that does (the 33rd lens,
    # BLOCKING-1; the 32nd's IMPORTANT-6 had made four arms non-empty and left `status`
    # sufficient on its own). An all-empty completion that carries `agentId` and `status`
    # "completed" is "none", not a launch: a pending entry minted for it would never clear.
    # The launch fallback (an agentId, no content at all, and no completed status; a status
    # this build does not know is still a launch, the 28th lens) is the last branch for the
    # same reason: an object that CARRIES content the gate has just judged empty is not a
    # launch either (the 34th lens, IMPORTANT-2). `test()` needs a jq built with regex support;
    # without it the whole expression fails, KIND is empty, and nothing stamps: the safe
    # direction, and the test file goes red first.
    KIND="${META%%$'\t'*}"; OBJ_AID_RAW="${META#*$'\t'}"; [ "$OBJ_AID_RAW" = "$META" ] && OBJ_AID_RAW=""
    RESP="$(printf '%s' "$INPUT" | jq -r '.tool_response
      | if type=="array" then map(.text // "") | join(" ")
        elif type=="object" then ((.text // .content // .stdout // "") | tostring)
        else tostring end' 2>/dev/null)"
    # A COMPLETION must carry a status this build recognises; a launch need not (IMPORTANT-7).
    if [ "$KIND" != async ]; then
      case "$RSTAT" in
        ""|completed) ;;
        *) maude_log_trace "redteam" "completion with an unrecognised status \"$RSTAT\": not stamped"; exit 0 ;;
      esac
    fi
    if [ "$KIND" = async ] || printf '%s' "$RESP" | grep -qiE 'async agent launched|agentId:'; then
      # ONE guard, asked ONCE, at the one place a pending key is minted — the same
      # question the clear side asks (maude_is_ascii_token; the 30th lens). The text
      # fallback scrapes the WHOLE token first: a bracket range here was a third guard
      # (the 31st lens, IMPORTANT-3) — under en_US.utf8 it admitted the fullwidth id the
      # killer refuses, and under C it TRUNCATED at the first non-member byte and minted
      # `a` for an agent named `aａ1`, which promote, keyed on the raw agent_id, could
      # never match either. A refused id is named as refused, not as missing.
      AID_RAW="$OBJ_AID_RAW"
      [ -n "$AID_RAW" ] || AID_RAW="$(printf '%s' "$RESP" | grep -oE 'agentId: *[^[:space:]]+' | head -1 | sed 's/^agentId: *//')"
      AID=""; maude_is_ascii_token "$AID_RAW" && AID="$AID_RAW"
      if [ -z "$AID" ]; then
        if [ -n "$AID_RAW" ]; then
          maude_log_trace "redteam" "background launch carried an id the guard refused: not stamped"
        else
          maude_log_trace "redteam" "background launch without an agent id: not stamped"
        fi
        exit 0
      fi
      maude_care_ensure "$CARE"
      # A lens that dies before its stop never promotes, and nothing else deleted its
      # entry: the wake named it forever and care.json — read by several hooks on every
      # tool call — grew without bound (the 26th lens, MINOR-3). Entries older than a week
      # go at the next launch, and the map is capped at the newest fifty. A box whose date
      # helper cannot make the cutoff prunes nothing, which is the loud direction.
      _PCUT="$(maude_epoch_iso "$(( $(date +%s) - 604800 ))" 2>/dev/null)" || _PCUT=""
      # What WOULD survive the age prune, computed with the same predicate the write uses:
      # the notice must fire for a cap eviction and stay quiet for an ordinary age prune,
      # which straddling the write could not tell apart (the 28th lens, IMPORTANT-6).
      _PKEPT="$(jq -r --arg pcut "$_PCUT" --arg aid "$AID" '
        [(.redteam_pending // {}) | if type=="object" then to_entries[] else empty end
         | select(((.value | type) == "object")
                  and (((.value.sid // "") | tostring) != "")
                  and (($pcut == "") or ((.value.ts | type) != "string") or (.value.ts > $pcut)))
         | select(.key != $aid)] | length' "$CARE" 2>/dev/null)"
      if maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SID" \
           --arg aid "$AID" --argjson refs "$REFS" --arg pcut "$_PCUT" \
           '.redteam_pending = ((.redteam_pending // {}) | if type=="object" then . else {} end
              | with_entries(select(((.value | type) == "object")
                                     and (((.value.sid // "") | tostring) != "")
                                     and (($pcut == "") or ((.value.ts | type) != "string") or (.value.ts > $pcut))))
              | .[$aid] = {ts: $ts, refs: $refs, sid: $sid}
              | (if (length > 50) then (to_entries | sort_by((.value.ts // "") | tostring) | .[-50:] | from_entries) else . end))'; then
        _PAFTER="$(jq -r '(.redteam_pending // {}) | if type=="object" then length else 0 end' "$CARE" 2>/dev/null)"
        maude_log_trace "redteam" "pending launch ${AID:0:8}"
        # The cap evicts the OLDEST entry, which may be a lens still running: its promote
        # then writes no stamp and a real pass is lost. Cheap side of the asymmetry, but it
        # must never be SILENT (the 27th lens, IMPORTANT-6).
        _PLOST=$(( ${_PKEPT:-0} + 1 - ${_PAFTER:-0} ))
        if [ "${_PLOST:-0}" -gt 0 ] 2>/dev/null; then
          maude_log_trace "redteam" "pending map full at ${_PAFTER}: $_PLOST oldest entr$([ "$_PLOST" = 1 ] && printf 'y' || printf 'ies') evicted; a lens still running may lose its stamp"
        fi
      else
        maude_log_trace "redteam" "could not record the pending launch (care.json could not be read or written)"
      fi
      exit 0
    fi

    # A stamp needs COMPLETION EVIDENCE: a non-blank text the agent returned (KIND
    # "object", decided above; a status, a type or a duration is not evidence). Both
    # failure belts above are object-only, so a bare STRING — the two real ones on this box
    # are auto-mode classifier denials that ran nothing — passed both and stamped a full
    # pass with real shas in its refs (the 31st lens, IMPORTANT-5). An array of bare
    # strings, or an object whose text blocks are all blank, has no more evidence than the
    # string. Nothing of that shape had ever been a completion in the 391 dispatches this
    # box held on 09-07 (then-held window); the unrecognised shape leans toward nothing recorded, never toward
    # a pass.
    if [ "$KIND" != object ]; then
      maude_log_trace "redteam" "dispatch response carries no completion evidence ($KIND): not stamped"
      exit 0
    fi
    maude_care_ensure "$CARE"
    if maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SID" \
         --argjson refs "$REFS" \
         'def keeprecent: reduce .[] as $x ([]; (. - [$x]) + [$x]) | .[-128:];
          def capsessions: if (length > 50) then (to_entries | sort_by(if (.value | type) == "object" then ((.value.ts // "") | tostring) else (.value | tostring) end) | .[-50:] | from_entries) else . end;
          .last_redteam_iso = ((.last_redteam_iso // {}) | if type=="object" then . else {} end
            | .[$sid] = {ts: $ts,
                         refs: ((((.[$sid] | if type=="object" then (.refs // []) else [] end)
                                  | if type == "array" then . else [] end) + $refs) | keeprecent)}
            | capsessions)'; then
      maude_log_trace "redteam" "stamped last_redteam_iso"
    else
      maude_log_trace "redteam" "could not stamp last_redteam_iso (care.json could not be read or written)"
    fi
    exit 0
    ;;

  promote)
    # SubagentStop: the agent named by agent_id has actually finished. If a background
    # launch left a PENDING entry for it, that entry becomes the stamp now, for the
    # session that launched it; the stamp's time is the stop, not the launch. A session
    # with two lenses out keeps both subjects on its stamp (MINOR-2: the second promote
    # used to overwrite the first's refs, and ship.sh reads them).
    AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)"
    [ -n "$AID" ] || exit 0
    [ -f "$CARE" ] || exit 0
    # The same belt the stamp arm carries. This is the ASYNC path — nine dispatches in ten
    # on this box, 366 of 404 on 09-08 (then-held window) — and it read nothing but the
    # agent id, so a lens that errored, failed,
    # was cancelled or was interrupted promoted a full pass on the tip its brief named (the
    # 28th lens, IMPORTANT-2). A dispatch that ended badly finished: drop its pending entry,
    # stamp nothing, and say so.
    PSTAT="$(printf '%s' "$INPUT" | jq -r '((.status // "") | tostring)' 2>/dev/null)"
    PERR="$(printf '%s' "$INPUT" | jq -r 'if ((.is_error // false) | tostring) | . == "false" or . == "null" then "no" else "yes" end' 2>/dev/null)"
    PINT="$(printf '%s' "$INPUT" | jq -r 'if ((.interrupted // false) | tostring) | . == "false" or . == "null" then "no" else "yes" end' 2>/dev/null)"
    _PBAD=""
    case "$PSTAT" in failed|cancelled|error|errored|timeout|timed_out|aborted|expired|rejected) _PBAD="$PSTAT" ;; esac
    [ -z "$_PBAD" ] && [ "$PERR" = yes ] && _PBAD="an error"
    [ -z "$_PBAD" ] && [ "$PINT" = yes ] && _PBAD="interrupted"
    if [ -n "$_PBAD" ]; then
      # Nothing pending for this id is its own sentence: the delete below is a no-op that
      # "lands", and announcing a clear for it told a reader an entry had existed (the 32nd
      # lens, MINOR-5). Read before write, under the same store the write will take. A read
      # that FAILED is not a store that said no: a torn care.json falls through to the write,
      # whose refusal names the broken store (the 33rd lens, IMPORTANT-5).
      _HAS="$(jq -r --arg aid "$AID" '(.redteam_pending // {}) | if type=="object" then has($aid) else false end' "$CARE" 2>/dev/null)"; _HRC=$?
      if [ "$_HRC" -eq 0 ] && [ "$_HAS" != true ]; then
        maude_log_trace "redteam" "${AID:0:8} ended $_PBAD: nothing was pending for it; nothing to clear"
        exit 0
      fi
      # The clear side's contract (the 29th lens, IMPORTANT-1), found unhonoured in THIS
      # branch by the 31st (IMPORTANT-4): announce the clear only when the bytes landed.
      if maude_care_set "$CARE" --arg aid "$AID" 'if (.redteam_pending // {})[$aid] then del(.redteam_pending[$aid]) else . end'; then
        maude_log_trace "redteam" "${AID:0:8} ended $_PBAD: nothing reviewed, no stamp; pending entry cleared"
      else
        maude_log_trace "redteam" "${AID:0:8} ended $_PBAD: nothing reviewed, no stamp; could not clear its pending entry (care.json could not be read or written); the wake will still name it"
      fi
      exit 0
    fi
    PSID="$(jq -r --arg aid "$AID" '.redteam_pending[$aid].sid // ""' "$CARE" 2>/dev/null)"
    [ -n "$PSID" ] || exit 0
    if maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg aid "$AID" \
         'def keeprecent: reduce .[] as $x ([]; (. - [$x]) + [$x]) | .[-128:];
          def capsessions: if (length > 50) then (to_entries | sort_by(if (.value | type) == "object" then ((.value.ts // "") | tostring) else (.value | tostring) end) | .[-50:] | from_entries) else . end;
          if (.redteam_pending // {})[$aid] then
            (.redteam_pending[$aid]) as $p
            | .last_redteam_iso = ((.last_redteam_iso // {}) | if type=="object" then . else {} end
                                   | .[$p.sid] = {ts: $ts,
                                                  refs: ((((.[$p.sid] | if type=="object" then (.refs // []) else [] end)
                                                           | if type == "array" then . else [] end)
                                                          + ($p.refs // [])) | keeprecent)}
                                   | capsessions)
            | del(.redteam_pending[$aid])
          else . end'; then
      maude_log_trace "redteam" "promoted ${AID:0:8} to last_redteam_iso"
    else
      maude_log_trace "redteam" "could not promote ${AID:0:8} (care.json could not be read or written)"
    fi
    exit 0
    ;;

  check)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
    printf '%s' "$CMD" | grep -qE -- "$COMMIT_RE" || exit 0

    TRACE_DIR="$(maude_self_dir)/trace"
    # Two most-recent trace files, lexical sort == chronological (mirrors verify-watch, so
    # an edit just before UTC midnight is still seen by a post-midnight commit).
    FILES="$(ls -1 "$TRACE_DIR"/today-*.jsonl 2>/dev/null | sort | tail -2)"
    [ -z "$FILES" ] && exit 0

    # Either stamp shape. `{ts,refs}` since 2026-09-04; a bare ISO string before that.
    # Rendered by `jq -r`, an object comes out as JSON text whose leading "{" sorts above
    # every timestamp, so a reader that missed this would read EVERY edit as older than
    # the pass and fall silent for all of them — a false all-clear, which is the one
    # outcome this hook must never produce.
    LAST_RT="$(jq -r --arg sid "$SID" '
      (.last_redteam_iso // {})
      | if type=="object" then (.[$sid] // "") else "" end
      | if type=="object" then (.ts // "") else . end' "$CARE" 2>/dev/null)"

    # Edits since the last adversarial pass. `fromjson?` per line so one corrupt line is
    # skipped rather than blinding the whisper — failing that way round would produce a
    # false "you're covered", which is the one outcome this hook must never produce.
    EDITS="$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && cat -- "$f"; done \
      | jq -rR --arg rts "$LAST_RT" --arg sid "$SID" '
      fromjson?
      | select(.kind=="tool"
             and (.tool=="Write" or .tool=="Edit" or .tool=="MultiEdit")
             and .target != null
             and ((.sid // "default") == $sid)
             and (.ts > $rts))
      | "\(.ts)\t\(.target)"' 2>/dev/null)"
    [ -z "$EDITS" ] && exit 0

    # Docs/config-only commits stay silent. A rail that nags on a README edit is a rail
    # that gets switched off, and a rail that is off protects nothing.
    printf '%s\n' "$EDITS" | cut -f2 | grep -qvE "$DOC_RE" || exit 0

    N="$(printf '%s\n' "$EDITS" | cut -f2 | grep -vE "$DOC_RE" | sort -u | grep -c .)"
    # A lens this session launched in the background and that has not stopped is not a
    # pass; say it is pending so the whisper is not read as "you forgot to launch one".
    PEND_NOTE=""
    PEND_N="$(jq -r --arg sid "$SID" '[(.redteam_pending // {}) | if type=="object" then to_entries[] else empty end | select(.value.sid == $sid)] | length' "$CARE" 2>/dev/null)"
    [ "${PEND_N:-0}" -gt 0 ] 2>/dev/null && PEND_NOTE=" A lens you dispatched has not reported; its stamp is pending."
    if [ -z "$LAST_RT" ]; then
      printf 'Maude: %s code file(s) changed and NO adversarial pass has run.%s Launch the redteam before you call this done — our own, tiered to the stakes.\n' "$N" "$PEND_NOTE" >&2
    else
      printf 'Maude: %s code file(s) changed since the last adversarial pass (%s).%s Launch the redteam before you call this done.\n' "$N" "$LAST_RT" "$PEND_NOTE" >&2
    fi
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
