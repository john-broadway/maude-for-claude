<!-- Version: 0.31.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Revised: 2026-09-07 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Changelog

The Maude Claude Code plugin.

---

## v0.31.0 - the law arrives at the moment the work touches its class

Commit shas cited in this entry are on the internal tree; the public repository carries a
squashed history and does not resolve them.

John, 2026-09-03: "maude needs to make sure claude follows rules. especially the 30 ux
ones. the codd rule for db desing including 1nf 2nf and 3nf. at a minium" and, minutes
later, "there is also the laws of memory human and machine", "its also for everything we
develop", "and for the users."

The laws lived on a website and in textbooks. Nothing consulted either at the moment a
`CREATE TABLE`, a button, or a cache was written, so whether a build held to them depended
on someone remembering to say so. Knowledge in a file is a diary; a hook is a rail.

Three rulebooks ship as static data: the thirty Laws of UX, read live from lawsofux.com on
2026-09-03 (names, links and our own one-line asks; the site's descriptions are its author's
and do not ship); Codd's thirteen rules with the normal forms and third normal form as the
floor; and the laws of memory, human and machine, which has no canonical list anywhere, so
it ships as a draft composed from the published lists on each side (Kahana's five laws,
Surprenant and Neath's seven principles, Schacter's seven sins, Jost and Ribot; Denning's
locality, Gray's five-minute rule and rules of thumb, Little, Bélády, the memory wall,
write-ahead logging, Kreps' log; and the 2023 to 2026 agent-memory literature) until John
cuts it. A `family` key joins the three: third normal form and provenance are one law seen
from two seats, and `/maude:rules` says so.

The rail is called from hooks that already fire. On the first write of a class in a session
she says the law once. A schema is linted on the spot for the shapes a schema's own text can
break: no key (Codd 2), a repeating group (1NF), a fact hung on the wrong key (3NF), an id
with no REFERENCES (Codd 10), with multi-valued columns, composite keys and sentinel
defaults raised as questions rather than findings. At the commit she asks once per class if
no design named its laws, re-armed only by a new touch. The stamp is strict on purpose: a
heading that names the rulebook and at least one canonical name, in a prose document that is
not a fixture, inside the section the heading opens, with fenced code ignored, never a commit
message, because a false stamp is a false all-clear. The linter reads the plugin's own
package with the interpreter's safe-path mode, so a project cannot shadow it. Fixtures under `tests/` are never
surfaces, or the rail would have sprung on its own test schemas. Whisper only; verify counts
the unnamed so conscience says wait; refusing at the ship is a flag John has not flipped.

The linter's first run over Maude's own tables read zero, and the zero was the linter's, not
the tables': a document column named `json` sat outside its name list, and a self-reference
that does not end in `_id` was invisible to the Codd 10 check. John asked, three days
apart, whether the laws had been applied to her or only added. Both blind spots are closed
here: `json`, `embedding` and `links` are on the name list whole, and an integer column
named `<x>_by` with no REFERENCES is a Codd 10 ask. Her live tape and vault now raise four
asks, each answered by name in the design, and her own two schema files are a test
control, so a linter that goes blind to her again goes red.

The honest seam, stated in the code: for a schema the rail catches objective shapes; for UI
and memory it catches absence, the law never named, and hands presence to the adversarial
lens with the named list as its brief. It knows a law was named. Only the lens can say it
was honoured. Two repairs rode along: the post-tool hook read stdin twice and had logged
`tool=write` for every watched-path edit since May, and the three rails that read commits
now share one definition of a commit and a doc instead of three copies.

The ship rail's own second-lens gate was found holding the same shape of defect the rail
was written to catch, and it is fixed here. The gate required an adversarial-pass stamp
newer than the commit being shipped. On this repo that was satisfied by a stamp written
forty-eight seconds after the release commit by a dispatch that had started before the
commit existed, so it could not have read a line of it and the gate still called it
proven. A timestamp answers whether a lens finished after something; the question the gate
asks is whether a lens looked at it. So the stamp now records the refs the brief names
alongside its timestamp, and the gate is satisfied only by a stamp that names the tip. The
writer records the refs without checking them, because a hook runs from the workspace root
and cannot know which repository a brief means; the ship rail runs inside the repository it
is shipping and does the checking. Stamps written before this change name nothing and no
longer satisfy the gate, which costs a re-run rather than a release nothing reviewed. The
commit whisper is deliberately not tightened: it wants only the timestamp, and it keeps
firing on a stamp that names nothing.

The release stamper was rewriting prose, and this fixes that too. release.sh propagated the
version and date headers with an unanchored substitution, so it rewrote every matching line
in a document rather than that document's header, while maude-verify.sh read only the first
match. The two errors cancelled exactly: a version quoted inside a plan's body was kept
current by the stamper, and the checker then read that same body line and was satisfied.
Thirteen releases of it left the 2026-06-30 gate-hardening plan contradicting itself, a step
headed "Bump version 0.13.1 to 0.13.2" whose own checklist had been rewritten to say 0.31.0.
Both sides now look only at the header block, which is defined once and shared between them
rather than restated, so a document that merely quotes a version in its prose has no header
and is neither stamped nor checked. The two damaged lines are restored from the commit that
first wrote them.

An adversarial pass over both fixes above found no way to make the gate accept an
unreviewed tip, and five things worth repairing, all of which are repaired here. The ref
scraper sorted before truncating, so a brief carrying a crowd of hex-looking words could
sort the real sha out of the list and lose a review that genuinely happened; it now dedupes
in order of appearance and caps generously. The gate's refusal named whichever candidate
file it found first rather than the one the newest stamp came from, so it could blame a file
that had nothing to do with the stamp it was describing. release.sh sourced the stamper
unguarded, so with that file missing the source failed, the script ran on, every stamp was a
command-not-found, and the release shipped an unstamped tree in silence; it now refuses
before it reaches its own gate. The stamper wrote a temporary file and moved it over the
target, which handed every stamped file the temporary's private mode and replaced a symlink
with a regular file; it now writes the finished bytes back into the original.

The fifth was a false sentence in the previous commit rather than a fault in the code. It
said the header window was defined once and sourced, while maude-verify.sh restated the
number as a fallback. Two copies drift, which is the reason the definition was centralised
at all, so the fallback is gone: with the stamper missing the checker now reports it and
skips the header checks rather than auditing against a guess. The stamp records literal
shas only, so a brief naming its subject as a tag or a branch earns no credit; that limit is
written down now rather than discovered.

One disclosure about this release's own stamp commit. docs/specs/2026-09-03-rules-rail-design.md
carried a prose addition about session pruning that release.sh has no mechanism to produce, so
that commit's message does not describe every file in it. The addition is accurate against the
code; what was missing was saying so.

---

The twenty-third adversarial pass, re-dispatched after the first one died with its session,
found two blocking defects in the eleven commits above, six important and eight minor, and
the walk that re-dispatched it found four more. Every one that is code is here, each with a
control that was red against the committed file first. The two that mattered most: the
tape's `ts` migration had landed its column and lost its backfill on the live store (python's
sqlite3 autocommits DDL, the backfill waited 56 seconds behind a voice lookup that rescanned
every voice row per canon row, and the hook budget killed it in between; the guard on the
column's absence never retried), so canon carried no dates at all on the only tape that
matters. The migration is one transaction keyed on the header's version now, retried until
it lands, and the voice lookup is one scan; the migration backfills history on the first open (a row
that loses its date later is not re-dated; nothing live writes one).
And the undo tool listed by jq position while restoring by physical line, so a blank ledger
line made it put back a different file than the one it named; both sides number physical
lines now, and one unreadable line no longer empties the listing. A lens launched in the background now leaves a PENDING
stamp at launch, promoted to a real one by the subagent-stop hook when the agent actually
stops (the harness's SubagentStop carries the agent id); a dead lens never promotes, the
commit whisper says a lens is pending, and the next wake names one that never reported,
because the launch stamp on the tip is exactly what the dead first dispatch left behind. The
launch envelope the hook reads is the harness's object (`isAsync`, `status: async_launched`,
`agentId`), captured from a real launch; the first live launch on this branch was stamped as a
pass because the detection had been written from the launch text the model sees, and the tests
now feed the captured object. A
Bash gate token, yellow or red, is now RESERVED at PreToolUse and SPENT at PostToolUse of the command
that ran (an MCP tool's `infra-destructive` clear still spends at PreToolUse, in its own hook): PreToolUse hooks run in parallel, a sibling can refuse the same command, and PostToolUse
never fires for a refused command, so a clear was being spent on a push that never happened
and cost a second clear every time; another session cannot ride a fresh reservation, two
commands of one session in the same instant open one, and a live token the gate cannot
record is refused in those words rather than sent to fetch a token it already holds. A
MEMORY.md written past Claude Code's load limit is told its size in the units the loader
counts (UTF-16), the limit, and the action, at the write; this box's index had loaded partly
for two sessions with nothing saying so. The vault gives its free pages back when a rebuild
leaves more than a quarter of the file empty: the live file sat at 35.8 MB with two thirds
of its pages free after the rebuild whose message said 12.2 MB, a number true only of a fresh
file. The mkdir lock fallback, the path with no flock, is now exercised by tests that assert
flock is absent from the PATH they run under; the earlier race tests appended the real PATH
and had only ever proved the flock branch, and the comment over the reclaim now says what
the age key does and does not stop. Three numbers in the wake commit's message were cited
to logs that do not hold them; re-measured on a copy of the live store, the wake hook returns
in 0.46 s with a seven-line brief where the installed copy takes 34 s. Four smaller things
from the same pass, each with a red control: the state file's read-back compared text with
its trailing newlines stripped and now compares hex dumps (`od`, which reads a byte at a time and is on every box this lib already needs); a token expiry that was not a
number printed a bash error on the person's channel; a vault hit whose file had been
deleted said "changed"; and a "## Format" heading quoted inside a code fence, or at depth
three, made a document a UI surface. Three attributions in earlier messages point at the
wrong artefact and are corrected here rather than rewritten there: 9d267a0's sizes are true
of the files (12,206,080 bytes fresh against 35,835,904 live) and not of the log it names;
36beeee's planted control lives in tests/test-rules-cli.sh, not in the log it names; and the
design stamp said every shared file's lock lived in one function while scripts/maude-chores.sh
keeps two of its own, which it now says.

The 24th lens (2026-09-06, report `code-lens-24.md`) read the twelve commits above and the
envelope fix and found the reservation was a lease: `reserved = {sid, at}` carried no command,
so one clear opened a command every three seconds, a different command of the same session four
seconds later, another session's after a 120 s window, red keys included. A reservation now
belongs to the exact call, the session and the cksum of its tool_input bytes; only that call
retried rides it, anything else is refused and told who holds it and how long the clear has
left, the takeover window is gone (an orphan holds until the clear expires or is made again),
and the spend matches the bytes, so a completion without a session id still spends. Named
residual: a command that ran whose spend never landed keeps its reservation for the same bytes
until the clear expires. The same pass: the spend check left the gate's hot path (a Bash
completion cost 314 ms and costs 57), a stop shells out to promote only an id care.json holds,
any launch object carrying an agentId is a launch and a malformed id records nothing, a
session's stamp keeps both lenses' subjects, an undo ledger line that parses but is not an
object is unreadable rather than a stream abort, a tape whose header claims the version while a
column is missing gets that column's backfill, the wake names every pending lens on a box that
cannot tell their age, and the index whisper fires for the auto-loaded index only.

The 25th lens read that range in turn and found the launch rule had gone too far: a real
synchronous Agent completion carries an `agentId` as well, so a finished adversarial pass was
being filed as a launch still in flight, and nothing but a promote ever clears one. Completion
evidence now wins over the launch signal, and the suite's completion fixture is a captured
envelope rather than an invented one. The spend check asks whether this call can spend anything
at all instead of grepping a shared file for a word: the old guard was defeated for the whole
life of an orphaned reservation and by that word appearing in free text, both of which put the
pattern walk back on every Bash completion. The fingerprint is content-addressed, hashed
through a chain that survives a box with no `cksum`, and where nothing can hash the command's
own first sixty characters are the identity. The undo listing is total per row rather than
guarded per shape, the wake's pending line survives a malformed entry and names every lens it
found, and a tape whose header is ahead of this build is never written backwards.

The 26th lens found no blocking defect, the first round on this branch that did not, and six
that matter. The launch/completion split had been ordered so that a dispatch attribute
outranked an explicit launch marker, which would have stamped every background lens as a
finished pass the day the harness added that field to a launch. The spend prefilter read both
token files in one pass, so a corrupt store made a live red clear unspendable and the one-shot
became an N-shot. The command's identity was cut at sixty bytes rather than sixty characters,
which broke it on a multibyte boundary and refused the retry it was built to allow. A
reservation now records the version that wrote it, because the fingerprint formula has already
changed once between releases and comparing across that change refused people their own
commands. The stamp unions what it used to assign, so a later refless pass no longer erases the
subject an earlier one recorded. Pending dispatches and expired tokens are both pruned, the
wake's line survives any shape of subject and never ends mid-reference, and the undo listing
tells the truth about a row that was never captured.

The 27th lens found no blocking defect either, and eight that matter. A dispatch that FAILED
was stamping a pass: the launch/completion split asked whether a run had finished and never
whether it had finished well, so an errored, cancelled or timed-out lens recorded a review of
the tip its brief named. The reference cap was discarding by sort order rather than by age,
which can throw away the very tip a session reviewed and make the ship rail refuse work that
was reviewed; a set truncation keeps the members you can still name. An eviction from the
pending map, which can drop a lens that is still running, now says so. With no usable cutoff
the prune kept values it could not sort and the launch went unrecorded while the hook blamed a
writable file. In the undo store the listing and the reader that acts disagreed about a false
skip, and a path of pure whitespace still captured the restore. The wake's line bounds each
subject as well as the number of them, and expired gate tokens are pruned once per session
rather than only when a fresh clear is used, which is what had kept the fast path on the
command hook dead.

The 28th lens found the round before it had broken a live path: the new cap on how many
sessions a stamp file keeps sorted on a field that older stamps do not have, and this
workspace's own store holds seventy-five of those, so every synchronous adversarial pass
silently recorded nothing while the hook blamed a file that was perfectly writable. It also
found the status belt guarding only the synchronous path, which is a tenth of the dispatches
here, while the asynchronous path promoted a full pass for a lens that had errored, failed or
been cancelled. And the reference cap written to stop the reviewed tip being discarded made
discarding it certain, because it kept the oldest references rather than the newest, and the
one that decides the gate is always the newest. All three are fixed and proved against the
shape that broke them. Refusing an unrecognised status now blocks only a stamp rather than the
whole record, so a renamed launch status can no longer make a dispatch invisible; the eviction
notice fires only for a real eviction; the three readers of a skipped undo entry ask one
question instead of three; and the wake's pending line is bounded in bytes and always closes
its sentence.

The 29th lens came from a live one. A lens dispatched at 19:35 on 2026-09-06 was killed five
minutes later with TaskStop, which is the correct move for a worker you have outrun, and the
kill is the one ending that sends no stop of its own: no branch cleared the entry, no branch
promoted it, and eight hours of wakes named a lens that had not been running since dinner.
The promote path had covered cancelled, aborted and interrupted, but only for a stop that
ARRIVES. A kill now clears the entry and records that nothing was reviewed, reading the task
id from the response rather than the request, because a TaskStop the classifier refuses
returns an error string and has stopped nothing, and clearing on the id that was merely asked
for would be the false all-clear this hook exists to refuse. The same wake also read "its
stamp on  is pending" out loud, having joined an empty reference list into the empty string
and lost the only noun in the sentence; a subject that names nothing now says so, in one
spelling rather than two.

Then the lens turned on the fix. The new branch discarded what the shared writer returns and
announced the clear regardless, so a store that could not be written was reported as cleared
while the entry sat there untouched — the cheap half of the failure, since nothing was falsely
passed, but a diagnostic that tells a reader the opposite of what the store holds is the one
thing this code does not get to do. The sibling hook one file away had honoured that contract
all along. And an identifier guard was a bracket range, which is collation rather than bytes,
so under this box's UTF-8 it admitted characters that C rejects and the guard's meaning moved
with the locale. Three guards that no test could see the absence of now have tests that go red
without them.

The 30th lens then found that fixing that guard had been fixing a shape. There were TWO
identifier guards in the same file — the one that decides which agent id becomes a pending
key, and the one that decides which id may clear it — and only the second was converted, so
under a UTF-8 locale the writer minted a key the killer then refused and the entry could never
be cleared. That is the failure the kill branch exists to end, put back by the repair. Both
sides now ask one shared guard, which is the only arrangement in which they cannot drift
apart again. The regression pin had the same shape of problem: it went red only under
en_US.UTF-8, and nothing in this repo pins a locale, so on a runner that happened to be C the
check could not have seen its own failure. Both sides are now asserted under every locale the
box actually has, and a box with no UTF-8 locale installed says so rather than passing quietly.
One difference the round before had made and not named: the clear write no longer swallows
its own stderr, matching the sibling hook. In the running system the two callers that reach
that write discard that stream anyway, so the trace line is what carries the diagnostic.

Still open, and named rather than swept: about a dozen numeric bracket guards elsewhere in the
hooks admit the Arabic-Indic digits under a UTF-8 locale, and those values reach arithmetic
that then errors. Same class, different blast radius, not this round's work.

The 31st lens read that commit and found its two guard lines right and three of its five
sentences wrong. "The only arrangement in which they cannot drift again" left a third guard
standing: the text fallback that scrapes an agent id out of a launch notice was still a
bracket range, so under a UTF-8 locale it minted the fullwidth id the killer refuses, and
under C it truncated at the first non-ASCII byte and minted a key that matched nothing. It
scrapes the whole token now and asks the one guard, and a refused id is logged as refused,
not as missing. "Reverting the clear side alone goes red" described a mutation that cannot
exist: that commit's clear-side change was a pure refactor, and the red the message
remembered belonged to the round before. And "a box with no UTF-8 locale prints that rather
than passing quietly" was true of the test file and false of the suite: the runner captured
every passing file's output and printed it only on failure, so the note and the count both
went to nobody. The runner now puts each file's own count on its PASS line, says so when
a file prints no count, and lets NOTE lines through, so a suite whose pins stopped running
shows a number that moved.

The blocking find was older than that round and in the same file. Both intent regexes were
bare stems: `port the` matched inside "report the", `attack` inside "attackers", `audit`
inside "auditor", `refactor` inside "refactored". Measured over this box's own transcripts,
31 of 391 real lens dispatches were read as builders and never recorded, about one in
twelve (the lens counted 34; re-running its instrument gave 35, four of them implementers
its own boundary check had mis-flagged), and "report the findings" is what every brief in
this house says. The 08-17
repair had deleted one over-broad alternative and left the class. Both lists are whole
words now. The same corpus re-run, with the instrument that round had, recorded 29 of
those 31; the two that still read as builders quote a build phrase inside the brief,
"implement the spec", which is the side to err on: builder first, so nothing is stamped
that did not review (the 33rd's version-to-version table, below, is the count as it stands;
it does not restate this sentence). Two more doors
in the same file: promote's
bad-ending branch discarded the store write's return and logged "pending entry cleared"
against a store it could not write, the 29th lens's finding alive in the sibling branch; and
a bare-string tool response, the shape an auto-mode classifier denial returns, passed both
object-only failure belts and stamped a full pass with real shas in its refs. A stamp now
needs completion evidence, an object carrying content, an agent type, a duration or a
completed status; anything else records nothing and says so. The ref scrape judges bytes
too, so a hex run with a non-ASCII tail no longer takes a slot in the cap.

The 32nd lens read those two commits and found the fix had opened a door beside the one it
closed, in the direction the file forbids. Making the builder words whole words had dropped
every one of their inflections, so "refactoring the parser, then audit your own work" was
no longer a build order and wrote a review stamp on a real commit; the round before had
refused it. The inflections are back, chosen by the corpus rather than by symmetry: the
refactor and scaffold forms appear in no brief and cost nothing, implementing and
implemented read as build orders in this house, and the migrate and implementer inflections
stay out because here they live in lens briefs. Three real lens briefs lost their credit for
that at the time; builder first is the side that never stamps what did not review, and
that is the trade (the 33rd re-priced it, below). The same replay held the find itself
alive: one build brief, "builder B3 … b1 is
implementing it in parallel", had been read as a lens by the tip and by the commit before
it, because its prompt names a file called judge.py and a boundary stops at the dot; it is
refused now. Three build tasks that had recorded nothing under either list now read as
builders outright. The same round found the boundary
itself was a bracket range read under the ambient locale, so a fullwidth letter glued to a
listed word hid it from both lists under this box's default locale; the two intent checks
read bytes now, like the ref scrape and the two id guards before them. Completion evidence
had tested presence, not evidence: an empty content, an empty agent type or a zero duration
each stamped a full pass, and that round made four of the five arms non-empty (the fifth is
the 33rd's first find, below). A bad ending for an id nothing had launched no longer claims
a clear. The runner names a file that prints no count instead of leaving a bare line, and
the collation test prints, on every run, which locales it asserted under and which of them
admit the fullwidth letter, so a CI log says whether the collation pins could see a failure
there. On this box that is en_US.utf8 alone; on the gitea runner it is none, which is the
33rd's second find.

The 33rd lens read those two commits and found the evidence gate inert and the collation
pins blind where CI runs. The gate had kept a completed status as evidence on its own, and
every real completion on this box carries one, so it refused only shapes that never occur
and admitted every shape that does; the five fixtures that vouched for it were green only
because they omitted a field the harness has never omitted. Evidence is a non-blank text
the agent returned, and nothing else: a status, an agent type or a duration is not evidence,
because an agent that returned nothing has all three. The gitea runner has C and C.utf8 and
no locale that admits the fullwidth letter, so five byte-locale guards in the stamp hook
(both id guards, both intent checks, the ref scrape) could each be put back to a bracket
range or an ambient grep and the file would print 189 passed, 0 failed there, byte for
byte the healthy line. A source pin now asserts each of those guards, and the lowercasing
before them, is in the hook's code body, red on its own mutant on a C-only box, and it does
not fail an adopter whose locale table is smaller than this one. The boundary's end anchor
had no pin, so a brief ending on a listed word could hide from both lists with the suite
green; it has two. A promote that could not read the store had said "nothing was pending";
a failed read falls through to the write now, whose refusal names the broken store. The
runner tells a summary it could not parse apart from a file that printed none. An error
flag is refused in either spelling. The camera sense of "lens 2" is recorded, by design,
and the test says so; three rows on this box are credited through that alternative alone
(405 dispatches measured 09-09, and the same three at 405 on 09-10: the corpus is a rolling
30-day window and a count is a measurement with a time, never a fact), and no raw firing
count is shipped for it: that number varies with the instrument that prints it. Two words
left the builder list by the round's own ledger,
the marginal one: a word
that refuses no builder the list does not already refuse and costs review briefs their
credit does not go in. "implemented" refused none and cost two; "implementer", measured by
the author after the report, refused none and cost fourteen: sixteen review briefs carry the
noun they use for the party they review, and two of those were held builder by another
word. The door that removal opened was pinned by name for one round and is closed by the
34th, below. On the 401 dispatches this box holds as of 09-08, against the tip before this
round: 16 review dispatches credited that were refused (12 task-scoped reviews, 4
whole-branch or fix-review rounds), 7 review briefs that carried the noun and no review word
now record nothing either way, no build task became a lens. Against the tip the 31st read:
46 review dispatches recovered, 9 briefs that record
nothing either way, 2 credited that nothing had seen, 3 build tasks that changed label
only, 2 lost to builder first (one review brief that says "implementing", and the B3 build
brief the 32nd's second commit pinned). The verbs stay (implement, refactor, migrate, port
the, write the code, build the), and eleven review briefs on this box are still refused
for using one as a noun, two more for "implementing"; that is the measured price of builder
first, and it is a policy, not a measurement, so it is named here rather than changed. The
count sentences the 32nd had left, 34 minus 4 for 31 and "like every other guard in the
file", say what the logs say now.

The 34th lens read those two commits and found three doors, two of them in the fixes. The
source pin the 33rd had written for the five byte-locale guards counted a guard's text in
the hook's comment-stripped body, so a guard deleted from its line and left in a trailing
comment satisfied it, and a C-only runner printed the healthy line with the guard gone. The
pin asserts what runs now: the stamp path and the clear path are traced once each, and
each guard's command must appear exactly once with its byte locale on the line before it;
a comment, a string or a no-op does not run and does not count. Removing "implementer" had
reopened the hook's own cited negative, "you are a careful TDD implementer", which the
header still said that word caught; the class is closed rather than the noun: an agent
titled an implementer or a builder, with up to two modifiers, and an agent told to review its own
work, are build orders. Neither phrase fires on a build brief this box had not already
refused, and their only corpus cost is this rail's own lens briefs, which quote them to
describe the trap and are spelled around it. On the review side, a review word glued to an
identifier by a hyphen, a dot or a slash had credited three captured dispatches that
reviewed nothing, "redteam" inside this hook's own file name and "audit" inside the pre-push
guard's "leak-audit" marker among them; that boundary refuses those three characters now
when a letter, a digit or an underscore sits on their far side. The first cut of it refused
them outright, which refused every review word that ended a sentence ("then attack." went
uncredited, and a lens uncredited is a tip the release check refuses); the round's own
review caught that before the push, and the class was drawn where the identifier is:
punctuation still bounds. Measured cost of the boundary: two reviews that had been credited
by nothing but such a token and one non-review record nothing, and one inventory brief
whose "audit" ends
a sentence stays credited, the standing price of a noun on a word list. Two residuals stay
and are named, one captured and one constructed: a bare "audit" as a command-line
subcommand is a whole word the vocabulary cannot tell from prose (one captured row), and a
slash between two review words ("critique/attack") has the shape of a path segment and
reads as one (no captured row; the 35th corrected "two captured"); and the self-title
phrase's two-word modifier slot fills on "a lens on builder B3", a review it refuses, corpus
zero, named in a pin. The launch fallback had
minted a pending entry for an object whose content the gate had just refused; an object
that carries content is not a launch. A torn store is named as one that could not be read
or written, not as unwritable. The count for "implementer" reads fourteen, not sixteen,
the marginal figure a paragraph about marginal pricing owes. Named and not changed: an
all-digit run is still scraped as a ref, because fifteen of this repository's own short
commit ids are all digits and one was a pushed tip; the reader's side resolves them. On the
404 dispatches this box holds as of 09-08, against the tip before this round: three of the
four identifier-credited rows record nothing and the fourth, the inventory, is credited by
its sentence-final "audit" again; this rail's own two briefs read as builders for quoting
the phrases, and one build brief that had recorded nothing now reads as a builder outright.

The 35th lens read those two commits and found the branch's shape twice more, both times in
the class of fix the 34th had chosen. The review-side boundary the 34th redrew had bounded a
hyphen, a dot or a slash whenever a non-word character preceded it, which is the shape of a
command-line flag: a brief that asks for a "--audit" flag to be built wrote a full review
stamp naming the tip, and the same boundary still refused an English prefix, so "Re-audit
the ledger" recorded nothing; the alternative that did both moved no corpus row and no
assertion. On the left a hyphen glues now unless what precedes it is one of a closed set of
English prefixes (re-, self-, pre-, post-, counter-): identifiers are an open vocabulary,
prefixes are not; flags, dotfiles and a negating prefix are refused. Every one of those
shapes is constructed; the rows that carry one are this rail's own lens briefs, which quote
them to describe the trap (the 35th's second commit retracted "none captured" in the hook
and the test and left it here for one round: the 36th lens, IMPORTANT-3); each but "pre-"
was pinned in both directions (the 36th, IMPORTANT-4), the flag at the stamp path beside a
control that must fire. The runtime pin the 34th wrote asserted a
mechanism, an "LC_ALL=C" token on the xtrace line before each guard. A bare assignment
prints the same line and exports nothing, so an ordinary tidy-up, the locale hoisted to
its own line and the pipe swapped for a here-string, left the suite green on every locale
set while the builder grep ran under whatever the caller had exported; on a box that
exports no LC_ALL, a build brief with a fullwidth-tailed build word wrote a stamp again,
and no pin could see it because every pin set its locale with an env prefix, which exports
it. The hook exports the locale once at its top now, the per-line prefixes are gone, and
the pin asserts that the export runs before the first guard, that no traced line in a named
list of spellings reassigns, unsets, un-exports or strips a locale variable (a list on the
trace, not the property: the 36th lens, IMPORTANT-1), and that each guard runs once;
none of that depends on how a bash version prints an assignment prefix, which the 34th's
form did and which was never run on bash 3.2. Two collation pins run once more with LC_ALL
absent from the caller's environment, the shape that exposed it; on the runner they are
vacuous like the rest and the NOTE says so. The seven mutants that deleted or hid a
per-line prefix became equivalent implementations and are replaced by seven that remove,
move, override, unset or strip the export. The self-title phrase was not a title test:
"you are not the builder" and "reviewing the builder's work", the plainest ways this house
addresses a lens, read as builders, and "do not audit your own work" as an order. A title
is neither negated nor possessive now and a negated self-review is not an order; the closed
set stops at "not" and "don't", and "never" and "no" still refuse, named. One fixture in
the identifier pin had been green at every commit and under every mutant, an
underscore-joined script name the old boundary already refused, and the comment beside it
claimed a credit that never happened; the fixture is gone and the sentence says what
credited. "Two captured residuals" was one captured and one constructed. Smaller: no raw
firing count is shipped for the lens-on alternative, three rows are credited through it
alone; four log names and a house name a plugin reader cannot resolve left the header;
three corpus counts carry their date; the dangling half of the evidence comment is
rewritten; over-long comment lines are wrapped; the ledger script measured a three-word
slot and ships two. Named for a later round, John's word: every other hook that reads text
through the shared helper has the same locale class and no export of its own.

The 36th lens read those two commits and found the branch's shape a tenth time, in each
of the 35th's fixes. The boundary that refused a "--audit" flag admitted every other way
code marks a token: "--mode=audit", a backticked audit, "audit()", "[audit]", a quoted
"audit" and "MODE:audit" each wrote a full stamp naming the tip, and refusing them moved
no assertion and no corpus row. The title class stopped at the singular: "you are
builders B1 and B2" wrote a full stamp. The runtime pin was a list of spellings: "declare
+x LC_ALL" un-exports the locale and every assertion stayed green while the commit, the
test and this file said the pin refuses an un-export. The corpus is a rolling window: the
dependabot row the 34th's evidence rested on had left the box the day its count was
committed, so "405 on 09-09" named a different 405 the next morning and the hook's cost
sentence could no longer be reproduced. The second commit had corrected its retracted
"none captured" in the hook and the test and not here. "pre-" sat in the closed prefix
set with no pin. Smaller: the driver held 34 mutants, not 33; the word list the modifier
slot was "proved against" was not on disk; "byte-locked in fact" was shown by green alone;
two refusals were unnamed ("not to audit your own work"; "do not, under any
circumstances, audit your own work"); the export made this hook the only one of 33 under
C, so the shared commit pattern's space class no longer collates the same in its two
sibling rails; the second commit was narrated only in its own message; the export's place
above the source line was true and unasserted.
The class is a review word that is a TOKEN in code: on the left a quotation mark, a
bracket, a brace, an assignment or a call glues; on the right an opening mark, an
assignment or an apostrophe glues and a closing mark or a colon still bounds ("(then
attack)" is an order in parentheses, "Lens 3:" is a numbered pass, "the audit's finding"
is a mention). Eight build briefs are pinned at the stamp path beside a control that
fires; the three English shapes the class decides are named. The title noun takes a
plural, on the asymmetry law and against the marginal ledger, and the cost is named by
row: this rail's own 35th brief. The PROPERTY the runtime pin claimed is asserted now by
a pin that reads the environment instead of the trace: a shim on grep and tr, in a dir the
test creates empty and checks for write-through, records the LC_ALL each guard was handed
under every locale variable a caller can export, and under LANG alone; it is provable on
a C-only runner because the caller's value is a string the export must override whether
or not the locale is installed. Its limit is named in the file: an override knob read from
a variable the test does not set passes every environment the test constructs, and no
finite pin enumerates the environment (the knob is run as a mutant, green everywhere, and
replayed writing a stamp under its own variable). The trace list is widened by nine
spellings and its sentence says it is a list. The export is asserted before the source
line; "pre-" is pinned; the two refusals are named; the modifier slot is proved in the
file against a word list and, off-tree, against 63,875 dictionary words and 6,770 of this
repo's own. Every corpus sentence in the hook, the tests and this file carries its time,
its window, its instrument and its row keys, and the author's row list is dumped beside
the logs so a later reader can tell gone from never there; the 35th's sentence in this
file is corrected; the rails comment says the pattern is shared and the collation is not.
Red first, with the final tests, against the 35th's hook (red36a-93e0d13-redteam-watch.txt:
330 passed, 13 failed, every red a new class pin for its named reason;
green36a-redteam-watch.txt and green36b-redteam-watch.txt: 343 passed, 0 failed; 343
assertion lines both sides). Mutants (mut36a-summary.txt): 49 named, each red on its own
pin, the eight locale spellings red on the environment pin in both modes, and two edits
expected green (the 35th's tidy-up, replayed refusing a fullwidth build brief with LC_ALL
absent, mut36a-replays.txt; and the knob); baselines 328/0 under the C-only shim and
343/0 ambient. Corpus (scan36a-work.txt, scan36a-keys.txt: 405 dispatches measured
2026-09-10 05:2xZ, window 2026-08-11..2026-09-10): the 35th's tree to this one moves two
rows, this rail's own 35th brief to builder and one read-only scoping pass, credited by
"the audit's" alone, to neither. Fleet quiet (fleet36a.txt): 61/61, test-redteam-watch
343/0, test-suite-runner 57/0; pytest 362; lint clean; verify 0 findings; gitleaks no
leaks on the tree. Named for a later round, John's word: the locale class sweep of the
other hooks; bash 3.2 still unrun; the override-knob limit stays a limit.
The 37th lens read cff8d7a and found the branch's shape an eleventh time. The 36th listed
what GLUES a review word to a code mark, and a glue list always has a next character: a
SIGIL is how code marks a token too, and "@audit", "$audit", "<audit>", "#audit",
"%audit%", "*audit", "&audit" and "~audit" each wrote a full stamp naming the tip, with
zero of 343 assertions moving when the sigils were added. The universal sentence about
corpus counts was false in the two files it named (the 37th's heading said ten, its table
listed eleven, and a twelfth it never named was undated too), two with no date at all.
The one piece of the class that cost a corpus row, the apostrophe, was the one piece with
no pin. "--mode=audit" was closed and "--mode audit", the same brief wearing a space, was
open and named nowhere. The two locale pins fall together to one wrapper (a grep function,
an absolute path) because the environment pin counted any call. Smaller: the modifier
slot unpinned in the widening direction; a dead "local" in the trace list; the environment
pin running en_US.utf8 twice; one 138-character line in this file; a row key resolves for
one reader on one box for as long as the window holds, and one had expired in 26 hours; a
quoted ORDER refused and unnamed; three older mutants red on the trace pin's accounting
only.
The boundary states what BOUNDS now and everything else glues: on the left the start of
the text, whitespace, a comma or semicolon, a closing mark, a double asterisk or a
non-ASCII byte (the 32nd's law, kept: a curly quotation mark and an em dash bound as any
non-ASCII byte does), plus the closed prefix rule; on the right the end, whitespace,
sentence punctuation, a closing mark, a double asterisk, a non-ASCII byte, or a dot,
hyphen or slash before a non-word. The line carries its high bytes raw, so the corpus
instrument reads it as bytes. Ten sigil build briefs are pinned at the stamp path beside a
control that fires, five prose shapes that must still credit (bold, an em dash, sentence
punctuation, a second lens) and three the class decides, named: a lone asterisk glues, a
quoted ORDER is a quotation, a curly quotation mark is a non-ASCII bound. The possessive
is pinned with its control. The bare-word residual is named as a class ("--mode audit",
"mode audit", "audit/ ") and each shape pinned as recorded. The environment shim records
each guard's arguments, and the pin matches the builder grep, the adversarial grep and the
tr once each by a fragment of its pattern: a guard that bypasses PATH writes no line and is
red. The slot is pinned at two with its cost named (this rail's own 34th brief). The dead
word is gone; the locale list is de-duplicated. All twelve sentences carry a date and name
the window they were measured over, and the hook says what a row key buys and for whom;
the 36th's keyed cost sentence is re-measured and the possessive row is named as gone.
Red first, with the final tests, against the 36th's hook (red37a-cff8d7a-redteam-watch.txt:
363 passed, 11 failed, the ten sigil briefs and the lone-star shape;
green37a-redteam-watch.txt: 374 passed, 0 failed; 374 assertion lines both sides). Of the
31 assertions this range adds, 11 were red on the old tree; the rest (the possessive, the
bare-word class, the slot, the prose controls, the per-guard record) are green on both
by construction, pins for stated limits and for a record the old shim did not keep.
Mutants (mut37a-summary.txt): 57 named, every one red; the 36th's glue list put back
(p9) is red on exactly the 11 pins the red run named; the apostrophe bound, the lone star
bound, the double-star bound removed, the high bytes removed and the three-modifier slot
are each red on their own new pin; a grep FUNCTION and an absolute-path guard, green on
the 36th's floor-of-one shim, are red on the per-guard record (8 and 5); three older
mutants (the two bracket guards, the trailing comment) are red on the trace pin's
accounting only, as the 37th recorded; two edits expected green are green (the tidy-up,
and the knob); baselines 361/0 under the C-only shim and 374/0 ambient. The knob's
replay changed shape (mut37a-replays.txt line 4 carries the 36th's expectation;
replay37a-knob.txt holds the measurement): the boundary's raw high bytes are not a UTF-8
pattern, so a knob set to en_US.utf8 makes grep refuse the pattern and the hook records
nothing for any brief, a missed stamp where the 36th replayed a false one; that is the
loud half. Under C.utf8 grep accepts the pattern and decodes UTF-8, so the byte range
stops matching a lead byte and every non-ASCII bound silently stops bounding, five
collation pins red and nothing traced (the 38th lens, IMPORTANT-1); the loud failure is
the safe one, the guards read grep's exit 2 as no match, and the export keeps every real
run under C.
Corpus (scan37b-cff8d7a-to-work.txt, scan37a-keys.txt: 366 dispatches measured
2026-09-11 19:05Z, window 2026-08-12..2026-09-11, the instrument reading the boundary as
bytes): not one row changes class between cff8d7a and this tree; 9 rows carry a review
word glued to a sigil on its left, 3 on its right, one a non-ASCII byte on its right (an em
dash, this rail's own brief) and none on its left, none credited only through the shape;
the possessive row the 36th cited had left the window. The first pass (scan37a) said 62
and 4 for the non-ASCII shapes: the instrument's byte range was a raw literal, so the
bracket held the escape's characters; caught by tallying the bytes it claimed
(scan37b-hi-bytes.txt) before the push, and the instrument is corrected.
Fleet quiet (fleet37a.txt): 61/61, test-redteam-watch 374/0, test-suite-runner 57/0; pytest
362 (pytest37a.txt); lint clean (lint37a.txt); verify 0 findings (verify37a.txt); gitleaks
no leaks on the tree (gitleaks37a.txt).
Named for a later round, John's word: the locale class sweep; bash 3.2 still unrun; the
bare-word class stays open until a discriminator exists.
The 38th lens read the four commits above and the public branch built from them, the
first lens to read what leaves the house as a whole, and found no BLOCKING: nothing in the
false-all-clear direction, nothing that leaks, the internal set stripped to the file, and
every regression the bound list introduces is a missed credit costing zero rows on its own
367-dispatch count. It re-ran the 59 mutants in its own clone in eight foreground batches
and matched all 73 blocks by count and by red name; the mutant that puts the 36th's
boundary line back (p9) was red on the red run's eleven pins by name at that tree. One
IMPORTANT: the locale limit was named for its loud half only.
Under en_US.utf8 grep refuses the raw-byte pattern; under C.utf8 it accepts it and decodes
UTF-8, so the em dash, the curly quotation mark and a glued fullwidth letter silently stop
bounding, five collation pins red and nothing traced, and the sentence called that locale
"valid". Smaller: the correction commit's message overstated what it corrected (the
CHANGELOG and the message had said 62 only, never 4); the mutant driver on disk no longer
parsed, an f-string broken by the label edit after its run; the per-guard pin proves a
call bearing the pattern, not the guard, and a decoy call buys the line; `~~`, an unpadded
table cell and a spaceless blockquote moved from bound to glue with the sigils, unnamed;
"ten places" was the 37th's heading over eleven rows and the range dated twelve; seven
internal shas ship in public prose and resolve nowhere for the reader; the README's
ship-day convention named no clock and dated a push that had not happened; `make verify`
prints 0 findings after skipping most of its checks when CLAUDE_PROJECT_DIR points
elsewhere, not reachable through the ship rail as this box runs it.
Fixed here, prose and pins: the limit's sentence carries both halves and names the safe
one, and names the guards' reading of exit 2 as no match as open; the three markdown
shapes are named in the hook and pinned as decided beside the lone asterisk; the
per-guard messages and comment say a call bearing the pattern; the count reads twelve;
this entry says its shas are internal-tree shas and the hook says the same; the README's
dates carry their clock (the UTC day the version reached the public repository) and the
lead entry carries the day of this ship; the driver parses again. Not fixed, named for the
39th: a trace line when a guard's grep exits 2, with a pin that plants an invalid pattern;
verify naming its skip count. Suite on this tree 377 passed, 0 failed
(green38a-redteam-watch.txt; the three new pins are decided residuals, green on this tree
by construction and red under the 36th's boundary: the 39th ran p9 against b0bf01e and
it reds fourteen by name, the eleven plus these three); verify 0 findings; lint clean;
gitleaks no leaks. The ship branch was rebuilt from this tip; the fleet runs inside the
build.
The 39th lens, a confirming pass over that one commit and the rebuilt branch, said
v0.31.0 may go public and found no BLOCKING. One IMPORTANT: the README's new clock
sentence said "the UTC day the version reached the public repository", and under that
clock the v0.30.0 entry (08-22) was wrong, its public moments all being 08-23 UTC; the
convention the entries actually follow, checked against every release commit, is the UTC
day of the version's release commit on canon, so the sentence now says that and the lead
entry carries 2026-09-03 again, the day it was stamped, a date that predicts nothing.
Smaller, fixed here: the universal per-guard message says "recorded here"; three prose
sha citations say they are internal-tree shas; "carry a date and the words" now says
"and name the window", which is what was measured; the three new pins carry the 39th's
red (p9, fourteen by name); a missing "is" and an opaque clause in the 38th's paragraph;
the 37th's heading named as the antecedent of "its". The hook, the tests' assertions and
every regex are byte-identical to b0bf01e; this commit is prose and one assertion
message. Suite 377 passed, 0 failed; verify 0 findings; lint clean; gitleaks no leaks.
The 40th lens, a confirming pass over that commit, said no: the sentence the 39th's
MINOR-3 fixed had been appended beside, not in place of, the false one, because the edit's
anchor stopped at a line break the sentence ran past, so the entry shipped "name the window
they were measured over, and the words" together, and a second sentence said the old words
were gone. No gate can see that class; a reader can. Fixed by one deletion; two floating
referents in the 38th's and 39th's paragraphs ("this tree", "the 38th's tip") now name
b0bf01e. Named for a later round, after the ship: seven bare prose sha citations in five
shipped files still say nothing about the tree they resolve on. The hook and every regex
are unchanged from 179650e; the tests changed in the three fixtures the next sentence
names and in the comment above the first of them.
On 2026-09-13 at 01:02Z the ship rail's build and CI #283 went red on a commit that changed
one word of this file: three pending-map fixtures in test-redteam-watch.sh carried a fixed
date (2026-09-06) and the launch path prunes entries older than a week, so twelve of sixty
aged out, the cap never filled, and the eviction pin failed. The fixtures carry timestamps
relative to now. A fixture that must be young for an age prune is a bomb with a fixed date.
The first public CI run of this version (PR #68, 2026-09-13) was red on GitHub's ubuntu and
macOS runners while gitea and the dev box were green: the release stamper passed its
blockquote regex to awk through a -v value, whose escape handling differs by awk (the
regex now travels through ENVIRON, and the pattern carries no backslash); macOS mktemp
ignores TMPDIR without a template, so the suite's leak sweep and root refusal never fired
there (every mktemp in the suite names a template); tests read inode and mode with GNU
stat, counted with unpadded wc, guarded the DST pins with GNU date -d, called timeout(1),
compared a symlinked temp path, and made a store unwritable with a lock shape that only
the flock branch honours; each now has its BSD form or the library's own shim. No hook
changed.

## v0.30.1 - the gate token was landing in the wrong closet

`/maude:conscience git-push` would print "gate cleared" and the very next push
would be refused anyway. The clear script and the gate were reading two
different files.

Both ask the same resolver where the workspace root is. Hooks are handed
`CLAUDE_PROJECT_DIR` and get it right. The Bash tool subprocess is not handed
it, so a script started from there has to infer, and the inference walked the
process tree looking for a process named `claude`. That worked when it was
written. It stopped being true when Claude Code grew a daemon. In the tree
measured on 2026-09-02 the processes holding the real working directory were
named by version, and the one still called `claude` sat at `$HOME`, which the
resolver refuses on purpose; in another tree the same day `claude` sat at the
workspace root, so the name is not a stable signal in either direction. So the
walk matched the wrong process, gave up the moment it refused it, and fell back
to searching upward from the current directory, where it found whichever
subproject you happened to be standing in.

The token went to that subproject. The gate looked in the workspace root. The
clear reported success every time.

A name is not an identity. The fix stops asking what a process is called and
uses `CLAUDE_PID`, which Claude Code currently exports to the Bash tool: its own
process id, pointing at its own working directory. That is a narrower guess than
matching a name, not a certainty. It is an observed signal rather than a
documented interface, verified on 2.1.258, so the resolver treats it as a
preference and falls through when it is absent or unreadable. The walk stays as
the fallback, and it no longer abandons the search the moment one candidate is
refused.

Two things the walk still cannot do, said plainly rather than guessed at. A tool
shell standing in a subproject and a session rooted at that subproject are
identical from the process tree, so the walk prefers the nearest match, and a
test pins that limit instead of hiding it. And in the process walk, a closet
at the temp directory itself or a hand-made empty one is no longer evidence of
anything. That is as far as a contents test can go: a wrong answer runs the same
code a right one does and leaves the same files, `trace/` first and `care.json`
after, so the walk cannot tell those two closets apart, and a test pins that
limit rather than hiding it. The temp-directory
refusal applies to the filesystem search too; the contents test does not, because
that search has no candidates to choose between and a genuinely new closet has no
contents yet.

Where the system has no `/proc` to read, which includes macOS, neither the
process id nor the process walk can tell you anything, and the filesystem search
upward from the current directory is the only resolver left. That is the search
which finds whichever subproject you are standing in, and this release does not
change that: on those systems the subproject gap is exactly as wide as it was.
The only thing the search gains there is the temp-directory refusal.

Both sides now name their file. The clear prints where it wrote. The gate prints
where it looked. The red tier's twins, the red clear script and the
infrastructure gate, name theirs too, and so does the run governor, the second
reader of the yellow token: one lens found the red clear still silent, its
failure line still naming a file it never writes, six commits after the yellow
twin lost that literal; the next found the governor silent. That is the part
worth keeping, because it is
what makes the next disagreement visible at a glance rather than after an hour.

One more thing rides along: the Release page title. The tag workflow minted it
as the bare tag, and nine of the last ten pages read as a version number and
nothing else. The title now comes from this file's heading, `vX.Y.Z: the
reason`, and a heading with no reason refuses to mint rather than minting bare.

---

## v0.30.0 — the vault learns to look

A memory vault stores claims about live state — "the push is pending", "the
fleet is up", "the daily gate runs" — and a claim with no attached re-check
goes stale by luck. In one real day, eleven such claims failed a live look:
pushes that had already landed, sockets nine days dark behind a green panel, a
"daily" workflow that had never run once. Every catch happened because someone
chose to look. This release is the mechanism that looks.

**The `verify:` convention.** An open item in a `now_*.md` memory file can now
carry its own re-check, inline: `verify: `<command>` ⇒ `<expected>``. One
read-only command, one mandatory expectation — a probe that reads the same
pass-or-fail is not a check. An item without one is still legal; it reports as
a memory, not a reading. Grammar and authoring rules:
`docs/specs/2026-08-22-freshen-verify-lines-design.md`.

**`/maude:freshen`** (`scripts/maude-freshen.sh`) walks the vault's `now_*.md`
files, classifies every verify command **before anything runs** — a fail-closed,
per-flag allowlist (bare `git` would admit `git push`, so the *verb* is what's
judged; `curl` is deny-by-default; `jq` loses env/file access; the write-capable
multi-tools are refused outright; secret-shaped targets refused by name) — and
executes the survivors under the house timeout with `pipefail` on. Verdicts are honest four
ways: **CONFIRMED** (the world still matches), **STALE** (the vault is behind —
the signal), **CHECK-FAILED** (the probe itself broke — loud and distinct,
because a checker that fails open into a plausible answer is worse than one
that crashes), **UNVERIFIABLE** (never executed, reason named). Report-first:
freshen edits no memory file, ever — it hands over the drift list; the human
decides what closes.

**Wake runs the cheap subset.** `/maude:wake` now includes a `--wake` freshen
pass — local commands only (git ahead-counts, file states; 117ms measured
against the real roster), network-class lines skipped and *said so*: a
clean wake pass is not a clean roster, and the report refuses to imply it.
`/maude:receipts` counts what freshen catches (stale claims and broken probes,
counts never content). And the docs say the quiet part: where a domain goes
stale repeatedly, the durable answer is a **sensor** whose output is the truth
— freshen is the net under claims that don't yet have one, not the end state.

**The classifier is the gate, and an adversarial lens broke the first one six
ways** — arbitrary code execution (`find -execdir … {} +`, `sqlite3 -readonly
db ".shell …"`), arbitrary file write (`git diff --output=`, `curl --trace`,
`find -fprint`), deletion, and secret exfiltration, several walked in on a
**tab** that stepped past a space-anchored deny, and all of them auto-runnable
through the wake pass at session start. The lesson is architectural: a command
*head* on an allowlist is not a gate — every multi-tool reaches write or exec
through a flag or verb no deny-list names. It took **five adversarial rounds**
to close the class, each breaking the one before it. Round 1 broke it six
ways; the fix dropped the two tools whose normal operation *is* exec/write
(**`sqlite3` and `find` are gone entirely** — no real check needs them, that's
a sensor's job), flipped `curl` to deny-by-default, cut `git` to pure-read
verbs, and stripped `jq` of env and file access. Round 2 broke *that* through
a subtler seam — the classifier tokenizes the raw string but bash strips
quotes and expands braces *before* executing, so a quoted flag or a brace path
desynced classify from exec — so `"` `'` `\` `{` `}` were banned outright,
which makes the tokenizer match bash's word-splitting exactly (classify ==
exec, no denylist desyncable). Round 3 found one write left — `file -C`
compiles `magic.mgc` to the working directory — and a last word-separator seam
(`< ( )`); `file` joined `sort` and `uniq` off the reader list, and those
three characters were banned too. Round 4 confirmed every text-only verify
line holds, and closed the one exec still reachable through *on-disk* git
config: `-c` blocks config-as-code on the command line, but a poisoned
`~/.gitconfig` would run `core.fsmonitor`/`diff.external` on freshen's own
trusted-repo reads at session start — so every command now runs with global
and system git config off and those knobs force-set inert. Round 5 broke
nothing in the code — it proved the classifier holds and caught only that a
comment misdescribed the lone residual (a per-driver `textconv`/`filter` an
attacker-controlled repo can select, outside the text-only threat surface the
trust model bounds). Every exploit across the five rounds is now a test that
runs the real engine and proves, by the absence of the file it would have
created, that nothing executed — a refusal you never watched refuse is not a
gate.

Teeth proven both directions besides: a planted stale claim goes loud, a clean
fixture stays silent, and the real seed shapes (git ahead-counts, jq
projections, `curl | jq` against a live API) still confirm through the
hardened gate. Several holes were self-caught between rounds by working through
the lens's own questions (`find`'s missing write actions, `sort -o`/`uniq`'s
output files, `curl @file` exfil); and the suite's own first run reproduced
the fixture-staleness class the whole mechanism exists to catch, when a claim
counted its parent directory and a sibling test wrote beside it. 53 freshen
assertions; the fleet stays green end to end.

---

## v0.29.2 — the house without bash, and the interpreter that wasn't one

The first field reports arrived as one sentence — *"his claude said she ain't working"* —
and nothing else: no issue, no error text, no OS. The reproduction came from staging the
shipped tree on a real family Windows box, and it explained the sentence exactly. On
Windows without [Git for Windows](https://git-scm.com/downloads/win), `bash` on PATH is
the **WSL stub in System32**; Claude Code (which runs bash hooks through Git Bash when
present, PowerShell otherwise, since 2.1.120) hands it the hook path and the stub eats
the backslashes: `/bin/bash: C:UsersYou...maude-session-start.sh: No such file or
directory`, exit 127 — **every hook, every event, every session.** A Claude watching
thirty of its own hooks fail nonstop reports exactly what was reported.

No field in hooks.json conjures an interpreter, so the fix is the honest one: the README
now states the Windows floor plainly (Git for Windows required), documents both failure
shapes an adopter will actually see and where they surface (`/plugin` → Errors), covers
`CLAUDE_CODE_GIT_BASH_PATH` for a Git Bash that's installed but unfound — and carries a
line addressed to the *Claude* reading the plugin cache mid-error, because on an
agent-read plugin the docs are runtime help. The install section also stopped lying
about enabling: since Claude Code 2.1.221 `/plugin install` activates the plugin itself;
the manual toggle is only for older builds.

The same box taught a second, subtler class: its `python3` resolved to the Microsoft
Store alias stub — present on every Windows box, runs nothing, exit 9009 (a macOS
without Command Line Tools ships the same shape). Nine scripts gated python work on
`command -v python3`, a presence test both stubs pass, so the failure landed at the call
site instead of the gate. `maude_python3_ok` now probes by **executing** (`python3 -c
pass`, cached per-process); the gated sites route through it, the two per-turn hooks
carry no probe at all (their real, already-tolerated call is the check), the marker CLI
inlines the same probe (standalone by design, it never sources the shared helper), and
a test holds the class shut: a present-but-broken interpreter must read as absent, and
no hook script may test python3 by presence again. Session-start names a broken
interpreter once — the vault, the tape, and the eye sit out — instead of thirty hooks
erroring. A probe that answers the same whether the thing works or not
is not a check — that law was already on the wall; now it's in the tool.

---

## v0.29.1 — the letter is archived before it is rewritten

The live `letter-from-maude.md` is one user-global file shared by every lane, and the rest
ritual's step 5 said *rewrite* with nothing before it — so on 2026-08-17, two lanes rested
in one day and the second erased the first lane's letter. The 32 dated archive copies
already on disk proved the archive convention was real practice; it just lived in habit,
never in the tool, and a mechanism that lives in memory instead of the tool is the shape
this house keeps booking as a defect.

Now it is a step with a command. `maude_letter_archive` copies the live letter to a dated
name before any rewrite: the date comes from the old letter's own header line (a date in
the body never names the copy), the slug is sanitized to `[a-z0-9-]` with newlines caught
by `tr` before the line-oriented `sed` ever sees them, a same-named archive holding
different bytes is stepped past — never over — and the copy is read back byte-for-byte
before success is reported, `cmp` when the box has it and python3 `filecmp` when it does
not, so a missing compare tool can never masquerade as a failed copy and wedge the ritual.
Both doors gate on it: `commands/rest.md` rewrites only on `ARCHIVED` or
`NO_PRIOR_LETTER`, and `agents/maude.md` — whose own operative text still said plain
*rewrite*, a second door two independent lenses caught — now archives first through the
anchored helper, with an archive-first fallback even when the helper cannot load. No copy,
no rewrite, ever.

Three adversarial rounds, each fix sent back to the lens that found it, and the pattern
held again: round 2's defect was in round 1's fix (an unanchored source path that made the
agent's gate prose instead of mechanism), and the advisor caught round 3's (the new
variable shadowed `$SLUG`, which rest.md's preamble already owns — same name, different
thing, in the newest layer). Eighteen tests on the helper, both directions, including a
lying `cp` that lands wrong bytes and exits 0. Also riding: the ship rail's `open` now
finds the ship branch by its shape instead of trusting a name, closing the wrong-branch
commit path from the 0.29.0 night. Suite 308 python, 55 shell files.

## v0.29.0 — promotion belongs to him, and the store nobody counted

The consent gate. `rest()` used to promote anything in the buffer scoring 0.6 or better
straight into canon — including what Claude had merely *inferred* about the homeowner, on
a score Claude gave itself. An importance score is the agent's opinion of itself, and an
opinion is not a mandate. So now only the user's own words consolidate on their own
(writing down what he said is not a judgement call), an agent inference never auto-promotes
at any score, and `/maude:promote` puts the list in front of him. `dismiss` is the other
half: a list you can only say yes to is not a choice, it is a nag that returns every wake.

Then twelve independent adversarial passes across nine review rounds, and a last one against the artifact that ships, each round breaking the one before it, and the honest
accounting is that the gate itself held every time — what kept failing was everything
around it. **The other door into canon:** `remember()` wrote there directly, defaulting to
`user-verbatim`, never checking for a credential shape; two lenses found it independently,
and the same string `capture` refused with exit 2 was taken with exit 0 and replayed under
"HIS WORDS". **His own words fell through the floor:** `forget()` filtered on importance
alone, so something he actually said, scored low, went to an archive no command lists.
**One NaN bricked the loop:** SQLite stores a NaN REAL as NULL, and the comparison then
raised TypeError in both `rest()` and `pending()` on every later call, for the whole tape,
with the SessionEnd hook piping to /dev/null and exiting 0 regardless. **And the fix for a gap was a denial of service on the hot path:** the credential table runs
on every prompt through the voice hook, whose budget is five seconds and whose contract is
fail-open. A pattern added during this very round backtracked quadratically — 8s on a 32KB
single-line paste — so an ordinary big paste stalled the prompt AND got the scan killed
mid-flight, passing exactly the input most likely to hold a token. Nine passes had asked
whether the guard catches the right things; none had asked what it costs. Bounded: 0.026s
at 32KB, 0.161s at 200KB, real credential URIs still caught.

**And the payload did not need to open a block — it could erase the label above it:**
escaping newlines was the instance, not the class. `\x1b[2K\x1b[1A` starts no line; it
erases the one already there and moves the cursor up, overwriting the very label naming
the words as Claude's. Nothing that can move a cursor, erase a line or reorder what a
reader sees reaches the screen now. The credential guard had the same shape from the
other side — it normalised characters SHAPED like a space and never considered ones with
no shape at all, so a zero-width character between each letter of a token defeated every
pattern while the credential stayed visually intact. Those are deleted before matching.

**And then the content forged the label:** `wake` echoed stored text raw, so a canon row
whose TEXT contained the literal "HIS WORDS" header rendered as a second, authentic
block — no exploit, just an inference captured, promoted by his own hand, and arriving in
every future session's context wearing his voice, with this release's own vocabulary as
the payload. Data is escaped before it becomes presentation now, at all nine print sites.
Rounds one to five asked what may ENTER the store; round six asked what LABEL the output
carries; the forgery lived in the seam between them.

**And the gate held the door, then mislabelled what came through it:** `wake` — the one
surface a waking session actually reads — printed every canon row under "HIS WORDS (his
rendering, use verbatim, never re-render)", including an inference he had merely approved.
`promote.md` had promised the opposite in writing. True in the table, false on the screen.
The brief now splits by authority: his verbatim words in one block, Claude's wording that he
approved in another, labelled and never quotable as his. Four rounds guarded which text may
ENTER canon; nobody had checked the label on what came out. **And the
announcement had no ears:** the new "N awaiting your word" was printed into that same
/dev/null, so the queue built to stop being a silent pile was one. It is said at wake now,
where it is read.

**The store nobody counted.** The review brief said the tape had canon, voice and events.
It has five tables, four of them holding his words, and `rejections` — the one `wake` prints
*verbatim*, phrase and reason both, at every wake — had no guard at any layer. Four reviewers
checked the three they were handed. A wrong premise in the dispatch outlives every reviewer
who inherits it, and a reviewer can falsify a claim you make but not one you never made.

So the next brief handed a reviewer a `grep`-generated inventory instead of a typed list, and
the generator was wrong: it searched `INSERT INTO`, while the voice writer is
`INSERT OR IGNORE INTO`. The inventory said three stores where the tree has five, and the
file whose label fields were still unguarded was the one it hid. A generated list beats a
typed one only if the generator is right — the durable version of the lesson is the test that
reads each writer's signature and fails until every string field it accepts is attacked.

**The live door was letting the machine talk.** Found because he read a claim and asked
where it came from. `harvest` applies the extraction law so machine-generated turns never
enter the corpus that measures his voice; the capture hook shipped in v0.28.0 applied
normalisation and the secret filter and *not* that law, while its docstring said "same as
harvest". On the author's box, 7 of the 26 rows that hook had ever captured were task
notifications: 96KB, median 12,448 characters against a real typed median of 42. v0.28.0
diagnosed the corpus as two voices and cut it back to one; this door was refilling it from
the other end, visible only in sessions that run subagents, which is why the backfill never
saw it.

The guard grew JWTs, bearer headers, credentials in a URI, Stripe, SendGrid, DigitalOcean,
npm and AWS secret keys, and case-insensitivity — `PASSWORD=` had walked through while
`password:` was caught. It did *not* grow the widened labelled-value class a lens asked for:
measured against the real 2,392-row corpus that fired on 20 rows of pasted code, and a guard
that cries wolf on his own paste habit is the one he learns to ignore. Both engines normalise
Unicode spaces at the input now, because python's `\s` matches U+00A0 and POSIX `[:space:]`
does not, so a credential pasted out of rich text was refused by the tape and waved through
by the prompt alarm. Final measurement: zero false positives on the real corpus.

Docstrings stopped overclaiming. `promote()` is the buffer's door, not "the only door from
inference to canon"; nothing distinguishes his hand on the CLI from an agent running it, and
the gate binds the honest flow. Suite 198 → 307.

---

## v0.28.0 — the corpus was two voices

The voice organ — the first turn of the learning loop, built the night the
homeowner said the whole vision out loud: she should learn the user, almost
autonomously, unnoticed until she has something to cue on. So she listens now.
A silent `UserPromptSubmit` hook appends each typed prompt to a `voice` table
in the tape (an observer, never a gate: exit 0 on every failure INCLUDING the
clock — a locked tape costs 0.8s, not sqlite's five-second default, a
fix-review catch after the corrupt-db fix covered the reproduction and missed
the class). `harvest` backfills the same corpus from the session transcripts a
box already holds, streaming, idempotent by sha over (text | original
timestamp) so resumed-session copies collapse while the same words retyped
another day still count. `profile` derives the measured voice — median and p90
sentence length, lowercase-open ratio, punctuation habits, hammer n-grams,
lexicon, AI-tell shadow words — and `check --voice` prints draft-vs-profile
numbers after the floor's verdict, never touching the exit code: the phrase
floor alone owns 0/2/3, and a cadence SCORE would be a guard that answers the
easy question.

The laws are in the code, not the docs. Credential shapes are refused at
ingest — the same pattern list as the prompt-scan hook, cross-referenced both
sides, and the first real backfill proved it by refusing 6 of them. Nothing
here opens a socket, and a tripwire test now walks the whole package asserting
only the two BYO sockets may import network machinery — with planted-violation
tests, because a gate you never saw refuse is not yet a gate. And the profile
derives from TYPED PROSE only: the first real corpus was two voices — 1,864
typed lines averaging ten words, and 542 pasted briefs and dispatches carrying
a million machine-shaped words that drowned the human (em-dash 238.7 per 100
lines against his actual 1.1) — so lines at or over 400 chars are counted,
excluded, and confessed in the profile's own honesty block. That block also
carries the date range's real depth, derived from the typed subset alone after
a post-review pass caught a paste's date padding the range one scope wider
than the commit that claimed to exclude it.

Built by teams and broken on purpose before it was believed: three scouts,
three builders, three adversarial lenses, and a fix-review on every fix. The
lens mutation run planted 14 deliberate breaks and the suite caught 12 — the
two that walked (a p90 off-by-one masked by small fixtures, a division guard
no path could reach) are pinned now at the exact sizes where they diverge. The
containment prune met its first real corpus and burned five minutes of CPU
after sailing through every small fixture — it is an inverted index now, 0.3s
at 3k lines, semantics differentially fuzzed against the old algorithm across
11,500 trials. Python suite 94 → 180; the corpus and profile are DATA in the
home's tape.db and never ship — the plugin carries the mechanism only.

---

## v0.27.5 — the pins ride home the same night

CI-only. Dependabot's CodeQL bump (4.37.3 → 4.37.6, PR #56) merged on the
public side and cherry-picked straight home — a workflow pin that lives only
on one side of the house gets silently reverted by the next curated build,
which nearly happened to July's bumps this very night. The version moves
because the closet check is honest: same number with a differing file is the
trap she names, so the number tells the truth instead. No plugin behavior
changes.

---

## v0.27.4 — the fixture wore the shape the guard hunts

Test-only. The v0.27.3 BSD pin's fake home was written as a literal
Users-path and ship.sh's leak-audit flagged it on the very next build — one
session after the same guard taught the same lesson about a token fixture.
The path is assembled by concatenation now, the audit's own idiom. No
shipped behavior changes.

---

## v0.27.3 — three minors of BSD debt, collected at the door

The public catch-up PR was the first time the 0.25→0.27 code ever ran on
macOS — the internal remote has no Mac leg, and three unpushed minors meant
three minors of BSD coverage debt collected in a single CI run. `_maude_home`'s
no-`$HOME` fallback knew only `getent`, which macOS does not carry, so passwd
resolution failed there — and the install-smoke gate rightly failed with it
("the shipped tree does not pass its own tests" is exactly what it is for).
Directory Services is the BSD shim now (`dscl`, sed-parsed so a home carrying
a space survives where awk-`$2` would truncate it), fail-closed behavior
unchanged when neither tool exists, and the branch is pinned on Linux with a
fake `dscl` in a minimal PATH — the box that cannot run a Mac still guards
the Mac's path. The one-lane law (a minor pushed internally rides with its
public push, same day) exists so this class of debt cannot accumulate again.

---

## v0.27.2 — the guard read her own story and found the homeowner's address

Patch, caught by ship.sh's own leak-audit on the first public build since
v0.24.0. The incident stories told their truth with the homeowner's literal
paths in them — the glob-delete tale carried the real workspace path, and
comments in four organs and tests carried this box's plugin paths. One was a
genuine portability bug, not just a leak shape: the marker lock test hardcoded
this repo's absolute path into `sys.path`, a test that could only pass on the
box it was written on (now passed in from the test's own `ROOT`). The
secret-scan stderr fixture also carried an inline credential-shaped literal;
it now assembles the shape by concatenation — the audit's own idiom — so no
shipped line matches the guard that ships beside it. The stories stay true,
told in `~` instead of the address. No behavior change.

---

## v0.27.1 — the whisper hands you a command that works

Two small self-check fixes, both caught within minutes of 0.27.0 shipping.
The "an update is waiting" line said `claude plugin update maude` — and that
exact command fails with "not found" on the canonical install (update wants
`name@marketplace`, and both are named maude). Caught by running the delivered
whisper's own advice: the bare form failed live, the qualified `maude@maude`
worked. Same lesson the maude-marker wrapper carries from 2026-07-30 — verify
the USER's invocation, not your own convenience. And the hook was missing the
eye recursion guard: the completeness test caught it from the ARCHIVE, where
the working-tree run had masked it behind the dev-checkout short-circuit —
silent for the wrong reason, which is a green check that proved nothing.
Guard added (inline, the secret-scan pattern), blink-silence pinned in tests.

---

## v0.27.0 — the phantom heredoc, her own closet, and the lens that must run

Three furnishings, each one a scar from the same week, and an adversarial pass
that broke the first draft of the biggest one — which is the system working.

**Heredoc bodies are DATA for every pattern family now.** The rm and
target-verb guards excised heredoc bodies since v0.12.1; the COMMAND patterns
(git-push, force-push, public-publish…) never did, and on 2026-08-08 the push
gate fired live on a memory-file append whose heredoc body merely contained
the words. Wiring the strip into `maude_match_gate_pattern` was the easy half.
The adversarial pass on the first draft found the hard half: the old
quoted-`<<` phantom (`echo "note << EOF"` read as a heredoc opener) — a
documented, accepted under-block while it only reached rm — now silently
swallowed a real `git push --force`, `gh release create`, and
`git filter-branch` on the following line. CONFIRMED empirically, RED-tier
keys, the expensive direction. So instead of accepting the widened limitation,
the stripper closed it: quoted SPANS are blanked before opener detection, with
`<<'EOF'`/`<<"EOF"` delimiter-quoting protected first — the exact objection
that had kept the old limitation open. Alongside: a delimiter QUEUE (two
heredocs on one line were treated as one — body B false-blocked as live
commands, a real pre-existing bug the pass confirmed), and `$((a << b))`
arithmetic + `<<<` herestrings blinded (the letter-led-shift phantom is
closed). Honest residual, pinned in tests: an UNBALANCED quote before
`<<WORD` still opens a phantom body. A gated command inside a heredoc-fed
SHELL (`bash <<EOF … EOF`) is uniformly limitation #3 for every family now,
stated in the gate's notes.

**SELF-CHECK — she watches her own closet at wake.** Main carried 20 commits
of finished work for ten days while the installed cache stayed a release
behind: the directory-marketplace updater keys on the VERSION, honest semver
had held the number still, and `plugin update` said "already at latest" with
13 files differing. Every session ran stale scripts believing itself current —
the mechanism built to catch "merged is not running" was the instance of it.
A new SessionStart hook compares the installed plugin against its source repo
(marketplace record, `MAUDE_SOURCE_DIR` override): version behind → "an
update is waiting"; version EQUAL but files differ → the trap itself, named
("the updater keys on the version — this will NEVER auto-deliver; bump on
main"). Silent when there is nothing to compare — no source checkout, no jq,
or running FROM the checkout — because a whisper that cannot be computed must
say nothing, not guess. During its own adversarial review the lens ran it
against this box's live install and it correctly reported the mid-review
working tree as version-keyed drift: working, live, unprompted.

**The ship rail's second lens must have RUN.** `ship.sh open --review "…"`
accepted prose on faith, and prose is not a guardrail. When her care.json is
reachable, a non-draft open now also requires a redteam-watch STAMP — an
adversarial dispatch that actually COMPLETED — newer than the tip being
shipped; a stamp from the future reads as planted and counts as nothing.
SOFT, and stated so in the same breath (the care-file backstop framing):
care.json carries no write-protection, the stamp is house-wide rather than
session-scoped, and it proves a lens RAN — not that it was good, not that it
read this diff. The threat model is FORGETTING the lens, not evading it; what
this closes is the silent nothing. Homes without her state keep the
prose-only behavior. The BSD leg of the new ISO shim handles both `Z` and
`±HH:MM` forms so a non-UTC committer date degrades the check to "unknowable"
rather than wrong.

Fleet 53 test files (gate 152 · ship 18 · self-check 12 new); lint and
portability clean. The pattern held twice more in the building: the round-1
command-position idea for a sibling workspace gate traded false-block for
silent-allow and was replaced, and round 1 of THIS release's stripper wiring
shipped the CRITICAL above to the lens instead of to the house.

---

## v0.26.0 — the snapshot, the marker, and the rails that fire

Two new organs and a round of fixes that came from pointing her own adversarial
discipline at herself.

**UNDO — the gate's other half.** The gate blocks the catastrophic; UNDO
catches what it deliberately allows, because a gate that blocks ordinary work
gets switched off inside a day. Content-addressed blobs plus an append-only
ledger; a snapshot lands BEFORE the write and `/maude:undo` restores it after —
one entry at a time, snapshotting the current bytes first so the undo is itself
undoable, and undoing a CREATE deletes rather than writing an empty file. The
ledger records what it did NOT capture (too-large, secret-path, unreadable) and
`list` surfaces it, because this is the pillar that can lie by existing — an
UNDO that quietly missed a file is silent until the night you reach for it.
Secret-shaped paths are skipped on purpose; the skip is visible, not assumed.

**PROVE — a one-time marker Claude cannot mint.** RED-tier clears were John's
hand by rule, but a rule is prose, and an audit reproduced two routes by which
Claude minted his own RED clearance. On a box where Claude runs as root,
anything he can read to verify he can read to forge — so the answer is a
sha256 hash chain: the homeowner generates the links off-box and keeps them,
Maude stores only the current head, and authorizing spends one link. Holding
the head lets you compute every already-spent link and no future one. When a
chain is provisioned, RED keys require a marker link; `gen` refuses to run
inside an agent context so links cannot burn into a transcript. Honest limit,
stated in the commit and kept here: this closes reflexive self-authorization,
not a determined edit of the gate itself — that floor is the harness
deny-rules, which are the homeowner's hand by construction.

**Two independent redteams on the security code, and both paid.** Maude's own
hook flagged that the 0.25.0 release had been self-approved, so two independent
lenses went over the gate and marker work. The worse find: a live
false-positive regression in shipped 0.25.0 — one unbounded character class
made the sole-copy table match at ANY depth under the workspace root, blocking
ordinary work (`rm` of a deep file, `build/*.o` globs, `mv` between deep paths;
25 measured false positives) — invisible to CI because the test config left
`sole_copy_paths` empty in every test. Depth-bounded now, with the config seam
tested.

**The RED clears got their own script** (`maude-clear-red.sh`), so a
`settings.json` deny-rule can name it directly. The split surfaced two lies in
the old path — dead RED flags sitting under a comment saying they worked, and an
arg-walk that left its own command so the refusal named the wrong rule. Both
fixed; the new script's own docstring described the wrong script and that got
fixed too.

**The leak channel that actually leaked.** Both real credential leaks in this
house's history arrived through TOOL OUTPUT — a token echoed back by `ps`, a
token in a grepped config — and the scanner read only the user's prompt. A
`tool-output` mode now scans stdout/stderr, MCP content blocks, and bare-string
responses, with patterns taken from the leaks that actually happened. Honest
ceiling, written into the alert itself: PostToolUse runs after the tool, so
this cannot prevent a leak — it converts "nobody noticed for three weeks" into
"you know this second," and tells Claude to name the credential and its
rotation in the same reply.

**The infra gate stopped trusting a prefix.** Two holes, both proven live: the
server prefix was a single string, so a second MCP server managing a second
live hypervisor was invisible — the identical destructive tool blocked on one
and exited 0 on the other; and destructive-ness was a 9-name allowlist, so any
destructive tool nobody had enumerated passed even on the configured server.
Now a destructive-verb sweep applies to every `mcp__` tool from ANY server —
an unconfigured brand-new server fails CLOSED — with read verbs checked first
and winning, because a gate that blocks `list_guests` gets switched off within
a day. Three pre-existing tests had asserted the hole as intended behaviour
and stayed green; reversed, with the reasoning in the test file.

**The mission rail fires now.** Registered since June, ~1600 chances, 4 pins
ever. The hook fired every time and parsed nothing: it read TodoWrite's array
shape, and this harness emits TaskCreate/TaskUpdate — flat objects, one of
which carries no text at all. Ported to the real payloads (with fixtures copied
from the live hook, because the rendered transcript lies about the shape),
sticky-pin semantics preserved, and proven live: pin, hold, flip, verify.

**The adversarial pass got a rail.** The workspace law says every build gets a
redteam and Claude launches it; the preference sat in an 86KB identity file
nothing consults when a build finishes, and three builds shipped in one night
with zero passes. Knowledge in a file is a diary; a hook is a rail. An
adversarial dispatch now stamps the ledger, and a `git commit` with code
changed since the last pass gets ONE whisper — never a block. Wired from
already-registered scripts, deliberately: new registry entries sit cold until
a reload, which is exactly how the mission rail sat dead.

**The tape `check` gate stopped passing vacuously.** Empty input passed; a file
path passed as if it were text. Two independent lenses were then run against
the gate itself and what they broke was closed — and the residual the gate does
NOT close is now named in its docs instead of implied away.

**The lint scope law never named the two rolling logs** — now it does.

**The $HOME phantom was a /proc parse bug wearing a costume.**

`maude_project_dir` decides where ALL plugin state lives: the trace, `care.json`,
the vault, the tape, the undo store, the house-map. It was getting the answer
wrong in a way that did not crash, and the visible symptom was blamed on the
wrong thing for a day.

**The cause.** Its process-tree walk read the parent pid as
`awk '{print $4}' /proc/<pid>/stat`. Field 2 of that file is `comm` wrapped in
parens and comm MAY CONTAIN SPACES, so a `tmux: server` ancestor splits into two
whitespace fields and shifts every later field by one — `$4` yields the process
STATE LETTER, not the ppid. The walk died at any such ancestor and fell through
to `$(pwd)`. A foreground session never saw it, because `claude` is the immediate
parent and the walk returns on iteration 1; add one process layer, which is what
a backgrounded call does, and it breaks. That fall-through is what minted
`$HOME/.maude/plugin` on 2026-07-30 and then shadowed the real closet for every
path outside the workspace, breaking the mission clear, the undo list and the
conscience clear. PPid now comes from `/proc/<pid>/status`, with a fallback that
splits `stat` on the LAST `)` so comm's own content cannot corrupt it.

**The harm.** Inference (proc cwd, filesystem walk-up) may no longer return
`$HOME`; a declaration still may, and hooks always carry `CLAUDE_PROJECT_DIR`, so
a genuinely home-rooted project keeps working. Only `$HOME` itself is barred,
never paths beneath it.

**What an adversarial pass then found in that guard, and what it cost to fix:**

- It **failed OPEN** when the environment had no `HOME` — cron, a systemd unit
  with no `Environment=HOME`, `env -i`, `docker exec` without `-e HOME`. Home is
  now resolved from the passwd database when the variable is absent, and when it
  cannot be resolved at all the guard REFUSES rather than permits.
- It compared **strings**. Bash's `pwd` is logical and preserves the symlinked
  spelling you arrived through, so with `/link` -> `$HOME` a walk from
  `/link/work` offered `/link`, which is not string-equal to `$HOME`. `$HOME/.`,
  `$HOME//` and a trailing space did the same. Both sides are now canonicalised
  before comparison.
- The test asserting "resolution creates no directories" watched only `pwd`, so a
  mutation minting `$HOME/.maude/plugin` — the literal phantom it is named after
  — left it green. It watches `$HOME` too now.
- `_maude_ppid`'s two halves both satisfied the one fixture, so neither was
  individually pinned. Each is now pinned by a fixture only it can answer.

New tests drive both inference paths against a FIXTURE process tree through two
seams (`MAUDE_PROC_ROOT`, `MAUDE_PROC_START_PID`), because from inside a live
session the real walk short-circuits and no wrong answer is reachable. That is
exactly why the previous test could only assert "returns a non-empty existing
directory", and why this survived.

Honest residual: the last-resort `pwd` fallback can still return `$HOME` when the
cwd genuinely is `$HOME`, so a phantom can still be minted there. It can no
longer SHADOW a real store, which was the harm. Saying so rather than claiming
the stronger thing, because the stronger thing was claimed once already and was
not true.

---

## v0.25.0 — the target, not the verb

Her hard block was keyed on the verb, and a verb denylist can only ever block the
verbs somebody thought of.

### The disaster it answers

On 2026-07-23 three of the homeowner's irreplaceable photos were destroyed by:

```
rm -f ~/projects/*.png ~/projects/*.jpeg
```

The gate did not stop it. On 2026-07-30 an audit re-ran that command against the
shipped 0.24.0 gate, control first, and got this:

| command | 0.24.0 |
|---|---|
| `rm -rf <workspace>` (control) | blocked, exit 2 |
| `rm -f <workspace>/*.png <workspace>/*.jpeg` | **allowed** |
| `mv <workspace> /tmp/gone` | **allowed** |
| `find <workspace> -delete` | **allowed** |
| `shred -u <workspace>/VISION.md` | **allowed** |
| `truncate -s 0 <workspace>/VISION.md` | **allowed** |
| `python3 -c "import shutil;shutil.rmtree('<workspace>')"` | **allowed** |

The control mattered. A first run of that probe pointed `CLAUDE_PROJECT_DIR` at a
sandbox, so the gate was faithfully guarding an empty temp directory and the
control came back green; the whole run was discarded rather than reported.

### What changed

A second table, keyed on the TARGET. If the thing being destroyed is a sole copy,
the verb does not matter. It encodes the rule the homeowner had already written,
"never glob-delete in workspace root, exact names only", which is a statement
about glob depth:

- BLOCK a glob whose parent is the protected root (the disaster shape)
- BLOCK the protected root or a file at it as a bare target, any verb
- BLOCK `find -delete` / `-exec rm`, `dd of=`, `rsync --delete`, and interpreter
  one-liners calling `rmtree` / `unlink` / `os.remove` / `fs.rm`
- BLOCK the same command wearing `exec`, `env`, `nohup`, `timeout` or `sudo`
- ALLOW an exact named file, however deep (ordinary work)
- ALLOW a deep glob such as `build/*.o` (ordinary work)

The root-anchored regex is deliberately kept separate from the existing sole-copy
target list, because that list already permits one path segment and would have
swallowed `<root>/build` and then read `/*.o` as a root glob.

New gate key `sole-copy-target`, registered in the **red** tier: the homeowner's
hand only, not self-clearable, and a yellow token for another key does not open it.

### Why nine of the tests are false-positive rows

A gate that blocks `rm -f build/*.o` gets switched off within a day, and a gate
that is off protects nothing at all, which is strictly worse than never having
built it. The ALLOW rows are as load-bearing as the BLOCK rows.

All 19 blocking rows were watched fail before the implementation existed. One new
test file (`tests/test-gate-targets.sh`, 29 assertions); fleet 48.

---

## v0.24.0 — the bill, the switch, and the walk

The field-issue backlog, closed: three things she owed the house.

**The token ledger (#49).** Her hooks inject context every turn, and that bill
was invisible. Now every context-injecting hook class — the vault pager, the
session-start brief, the mission re-inject, the watch-list heads-up, the eye's
whisper, drift's whisper — logs its spend to the trace (hook + bytes,
metadata only, never content), and `/maude:receipts` grows a **"what she
cost"** table beside her catches: bytes by hook class, tokens derived as
bytes/4 and marked approximate, never stored. Savings stay honest event
counts — a saved-token number has no denominator, so it is never printed.
And suspect #1, pre-registered in the issue and confirmed by live receipts,
is retired: the pager fired on background task notifications and command
echoes with zero-relevance matches. **Machine-generated turns get no
recall** — a notification is not a question.

**The kill switch (#45).** The eye has `MAUDE_EYE=off`, the chores have
`MAUDE_CHORES=off`; the tier-1 loopback probe was the one autonomous feature
the homeowner couldn't turn off. `MAUDE_PROBE=off` — no sockets opened, no
cache written, documented in PRIVACY.md beside its siblings.

**The lint ritual (#42).** Memory that compounds needs this pass the way code
needs a linter — compaction was size-driven, nothing was quality-driven.
`/maude:lint` walks the vault the way the cushion-flip walks the repos:
mechanical checks in the script (index links resolve · unwritten
`[[pointers]]` counted as a backlog, not errors — resolving the prefix-less
house convention against typed filenames · index size vs cap · stale-open
candidates · superseded notes the index still serves), judgment checks
(contradictions, stale claims wearing a present tense) left to the reader by
design. Scope law: archives are verbatim, letters and dailies historical —
never scanned. Report-first: it proposes, it changes nothing, and every pass
logs its counts. First dogfood run on a real 490-file vault cut the
unwritten-pointer noise from 78 to 12 by learning the house convention, and
caught the index 6 lines over its cap.

One new test file; fleet 47.

---

## v0.23.0 — whose session it was

One project root, three concurrent sessions, one trace — and the commentary
crossed the streams.

**The session tie (the fleet fix).** Maude's aggregate surfaces were built for
one session at a time. Run a fleet — several Claude sessions sharing one
project root — and the wake brief served one session another session's "where
you left off," the catch-digest pooled everyone's catches under one anonymous
count, and drift-watch could whisper "Claude is stuck grepping" about a
*neighbor's* Claude. Caught live, twice in one day. Now every trace entry says
whose it is — a `session` label: the tmux session name when there is one (the
name the user actually thinks in), else the harness session-id prefix, else
`solo` — and every surface that reads the trace ties itself to it:

- **drift-watch** counts only the current session's events, and its cooldowns
  nest per-session — one session's whisper no longer mutes a genuine one next
  door. Unlabeled pre-upgrade entries never count toward a labeled session.
- **the catch-digest** labels each session's catches when two or more share
  the window (`pacioli: 1 block · proximo: 2 verify-flags`); a lone stream
  keeps the plain format, so solo installs read exactly as before.
- **the wake brief's "Where you left off"** declares its source — the live
  buffer is workspace-wide, so the line now carries the entry's own label when
  the writer set one (a fleet can set `REMEMBER_BRANCH` per session to put its
  session name there), and is marked `workspace-wide` otherwise. A neighbor's
  state can't masquerade as this session's anymore.

Legacy cooldown state heals on the first write; the no-jq fallback marker is
session-tied too. Nothing leaves the house: the label is a tmux session name
or an id prefix, recorded in the same local trace as everything else.

---

## v0.22.0 — every door, and an honest count

She reaches more houses, and she shows her work.

**macOS is a first-class platform now (#39).** The hooks carried GNU-isms —
`stat -c`, `date -d`, GNU `touch -d`, a `sed` word-boundary — that BSD userland
silently rejects, so on a Mac her redaction emitted *nothing*, her continuity
guard stayed quiet, and the eye ran dark for want of a `timeout` binary. Every
one now speaks both dialects (GNU first, BSD fallback, tagged shim lines a lint
holds in place), the test harness stopped assuming GNU (`touch_ago`/`touch_at`/
`file_digest` on python3 stdlib), and a `macos-latest` CI leg proves it on real
BSD — a leg that failed red on the first honest run and caught what the
Linux-only fakes could not. She does on a Mac exactly what she promises.

**`/maude:receipts` — the measured table (#43).** The measure of a protector is
the disaster that didn't happen, and until now that was a sentence. It's a
table: sole-copy saves, gate blocks, drift caught at the flip — counted from
her own trace and ledger, with the discipline that makes a number credible.
Friction (a routine push-clear) is fenced from value by rule; there are no
percentages, because a rate needs a denominator and there is none for disasters
that never happened; payloads classify events but never surface as content. The
feature's own review caught its first headline counting routine success-stamps
and per-turn repetition as if they were catches — roughly a tenfold overcount
(about 5,100 events where ~525 were real) — and the fix is why the table is
small and true instead of large and flattering.

**Everything stays in your house — now in writing.** A `PRIVACY.md` states it
plainly: her records are local markdown and a disposable index; the one network
call is the model *you* already configured, and it names the loopback probes it
makes rather than rounding them away.

Under the hood: a one-button ship rail (`scripts/ship.sh`) that builds a clean
public tree, audits it for leaks locally, and refuses to self-merge without a
documented review — and a social card, so a link to her finally unfurls with
her face on it. Three new test files; fleet 46.

## v0.21.0 — the punch list and the proving ground

Her user filed the backlog: Claude — the one she dresses — wrote five GitHub
issues against her from live field use (#34–#38), and this release answers
them. The extension roster seats only real plugins (manifest check; a live
roster carried 191 lines of installer transients masquerading as arrivals —
#34). A whisper past its TTL is dropped with a content-free trace receipt
instead of wearing a fresh voice (freshness judged by write-time at pickup,
default 300s, `MAUDE_EYE_WHISPER_TTL`; a `stat` failure fails open to a print —
a false fresh beats a silent swallow. Weight the gate over the whisper — #35).
The catch-digest count now carries a path to its receipts (`Receipts:
/maude:notice` — a tally you can't audit is a claim taken on faith — #37).
The wake brief reads the last cushion-flip from a closet stamp — count and
age, the never-flipped nudge when there is none, silence over a half-rendered
line when the stamp is malformed; and the flip now resolves the project the
way the hooks do, so writer and reader can never stamp different closets
(adversarial-review catch — #36).

The proving ground: `make smoke`. A stranger gets the commit, never the
working tree, so the gate stages a git-archive of HEAD and proves the shipped
shape three ways — validates as a plugin, passes its own fleet from inside
the archive, greets from a pristine HOME. Wired into release.sh's gate.
A clean working tree is not a clean commit.

Rails: a Release page is minted from the CHANGELOG whenever a version tag
lands (`scripts/release-notes.sh` — field-exact extraction, so 0.2.0 can
never swallow 0.20.0; the tab's backfill closed #38); CodeQL scans the
shipped python; every workflow action is SHA-pinned, permissions floored at
`contents: read`. Known and filed, not hidden: macOS is untested and the
hooks carry GNU-isms (#39, fail-open). Three new test files; fleet 43.

---

## v0.20.0 — the chore ledger (her hands)

The housekeeping nobody typed now gets done — or named as undone. New
`scripts/maude-chores.sh` (detect/dispatch/run/brief) over `chores.json`
in her closet; Stop dispatches, wake briefs. Chores: **c1** the save nobody
typed (haiku blink → `remember.md`, appends to any existing handoff, writes
only into an empty slot, redacted); **c2** the shelves — coupon-cut live
markers from aging dailies before anything re-rolls (re-roll itself opt-in
via `MAUDE_REROLL=on`, verbatim verified moves only); **c3** the extension
agent (new plugins/skills since last look); **c4** CLAUDE.md staleness
(report-only, stays loud). Every
doer pins its model; every finished chore stamps its cost, and a failed
one is stamped failed with the reason — the ledger makes the labor
visible either way. Kill switch: `MAUDE_CHORES=off`.
Design: `docs/specs/2026-07-16-chore-ledger-design.md`.

---

## v0.19.0 — 2026-07-15

**Value before the dustpan, and the cushion-flip.**

Two halves of one discipline, from one conversation: *does she look for value
before trashing, and who checks the places nobody sweeps?*

**The sweep now asks before it trashes.** Pre-compact snapshots are content —
a capture from a session that never saved may be the only copy of that context.
Age alone no longer deletes one: it must also be *covered* by a later save
(capture anchor newer than the snapshot). Uncovered → kept, however old — it
waits for a save, not a calendar. The metadata-only trace keeps its plain
age-out; there was never value in that pan by design.

**New ritual: `/maude:cushions` — the cushion-flip.** Change falls on the
floor and hides in the cushions: commits pushed nowhere, files never
committed, repos that exist on one disk only (LOCAL-ONLY = sole-copy risk,
said plainly), scratch that aged past anyone's memory. The flip reaches where
no sensor watches and reports value candidates — it never deletes, commits, or
pushes; the trash decision stays human. A `.parked` file (repo root or scratch
dir; `.` parks the whole repo) names change that's in the cushion *on
purpose*, so a deliberate park is stated once instead of re-flagged forever.
First run on a real workspace: 79 repos checked, one 45-commit local-only repo
surfaced.

20 new tests (3 sweep-coverage, 17 cushion-flip); fleet 32/32 files green.

---

## v0.18.1 — 2026-07-15

**The wake brief stops crying wolf: the pattern hint rotates.**

The session-start brief surfaces one cross-project pattern per wake — a scar-tissue
reminder. The picker grepped `patterns.md` for the project's basename, so on any
project whose name appeared inside an entry's *body* (a path was enough), that one
entry pinned forever — and the raw-body truncation cut it mid-sentence into what
read like a live alert. Caught live: the same 2026-05-07 scar printed at every wake
for two months, and it took a human eye on a yellow line to notice, because the
brief itself was the thing carrying the bug and nothing was measuring it.

The picker now rotates through the entry **headings** by day-of-year: every pattern
gets airtime, none can pin, and a `##` heading is a complete dated sentence that
self-identifies as history — it can't truncate into fake breaking news. Three new
tests pin the rotation, the no-body-text rule, and silence when no patterns file
exists. Fleet 31/31 green.

---

## v0.18.0 — 2026-07-14

**The memory loop closes: the sweep cut.**

The vault could recall but never revise — a rule superseded weeks ago still
paged as a live STANDING directive (proven three times in one session), and an
OR-of-everything query let "the"/"with"/"what" pull letters and dailies into
every recall. Memory that only accretes isn't memory; it's sediment. This cut
gives the housekeeper her broom:

- **Supersession** — `superseded_by:` (or `status: superseded`) frontmatter
  keeps a note in the vault's history table but out of the FTS index, so it
  can never page again. Mark, don't erase: the markdown is untouched, the old
  content stays readable, it just stops being served as live. Schema v2 with
  drop-and-recreate on `PRAGMA user_version` mismatch — the DB is a disposable
  index and migrations would pretend otherwise.
- **Ranking learns what BM25 can't see** — candidates are overfetched by BM25
  then re-ranked: durable rule-notes (`feedback`/`user` ×1.4, `reference`
  ×1.25, `project` ×1.15) outrank untyped ambient prose, and an age penalty
  (doubles at ~3 months) stops a 13-month-old letter from tying a fresh
  decision. A curated stopword set keeps "the" out of the query entirely;
  an all-stopword prompt now pages nothing instead of noise.
- **The recall tally** — the pager appends what it served (`{ts, hits}`) to
  `.maude/plugin/recall-log.jsonl`, append-only, failure-swallowed. New rest
  step 3b sweeps it: the top-fired notes get asked "still true?" (mark
  supersession with a dated receipt) and "was it noise?" (sharpen the
  description). Then the log is truncated. Serve → check → revise — the loop
  the vault was missing.
- **The eye unpinned** — `MAUDE_EYE_MODEL` chooses the model for the blink's
  `claude` branch; haiku stays the default, not a requirement. (The runner
  override always brought its own model; now the stock path is steerable too.)

9 new tests (6 python, 3 bash assertions); full fleet 31/31 + 28 pytest green.

---

## v0.17.0 — 2026-07-13

**The dispatch whisper learns the drift's second home — workflows.**

A workflow script's `agent()` calls never pass through the Agent tool, so the
v0.16.0 whisper couldn't see them — and stock/named harnesses set no `model:`
at all, so every fan-out agent silently inherits the flagship main loop. The
recurring shape (it fired the same way twice): a *named* workflow launched
as-registered, dozens of mechanical agents on the top tier.

`maude-dispatch-watch.sh` now covers `Workflow` too:
- **Inline script / readable `scriptPath`**: `agent(` calls present and no
  `model:` anywhere → one whisper (tier per stage; verify → small, review →
  mid). Any `model:` present → silence (the author is already steering).
- **Named workflow** (script registry-resolved, not inspectable pre-launch)
  → one whisper carrying the recovery rule: grab the persisted `scriptPath`
  from the tool result, grep it for `model:`, tier the stages before the
  expensive phase runs.
- Separate daily cooldown key from the Agent whisper — one must not silence
  the other. Still never blocks; still logs as a drift catch the digest counts.

11 new tests (26 in the file); full fleet 31/31, shellcheck clean.

---

## v0.16.0 — 2026-07-13

**Two new garments — the dispatch whisper and the exit stitch.**

`maude-dispatch-watch.sh` (PreToolUse on `Agent|Task`): she now watches which
MODEL Claude sends his sub-agents out on. A scout dispatched on a flagship tier
— or with no model at all, which silently inherits whatever the main loop runs
on — gets one whisper: match the model to the sub-task (scouts/searches → a
small tier, build/review → a mid tier). Never blocks (wrong-sized is wasteful,
not dangerous); once per day; logged as a drift catch so the session-start
digest counts it with zero new wiring. 15 tests.

`maude-session-end.sh` (SessionEnd — a TRUE end: exit, logout, `/clear` —
unlike `Stop`, which fires at every assistant pause and so has always written
nothing): logs the end + reason to the trace, stamps `.last_session_end` in
care.json, and — if 3+ exchanges were never saved to a handoff AND the
`.remember/remember.md` slot is empty — leaves a one-line, honestly-labeled
auto-note pointing the next session at the trace. A non-empty handoff (a real
`/maude:rest` write) is never touched. 12 tests.

Under both: the uncaptured-work arithmetic (capture anchor + prompt count) is
extracted into shared helpers in `_maude-common.sh`, and the SessionStart
continuity guard is refactored onto them — the wake-side warning and the
exit-side note now read the SAME definition of "uncaptured" and cannot
disagree. Full fleet 31/31 test files green, shellcheck clean.

---

## v0.15.1 — 2026-07-13

**Her voice moves in — "our house", never "your house".**

Persona alignment across every surface she speaks from: the workspace is her home
now, and she talks like it. The found report opens "Walked our house."; the walk
instruction, skill, and agent personas carry the rule explicitly (*our* house,
*our* workspace, never "your"); the voice examples follow ("Quite the collection
we have."). No mechanism changes — hooks, gates, vault, and eye are untouched;
this release is entirely who she is when she talks.

---

## v0.15.0 — 2026-07-13

**The eye opens — she watches with her own model.**

New `maude_eye` package + two hooks: every ~25 tool events (never more than once
per 3 minutes), a background "blink" digests the session's recent activity, the
pinned mission, and the notes her vault pages up, and asks HER model — a
discovered `claude -p --model haiku`, run `--safe-mode --no-session-persistence
--tools ""` so it sees the digest and nothing else, and leaves nothing on disk —
for a strict-JSON verdict: churn, drift, an unverified claim, a human running on
fumes. Almost always: silence. Otherwise the next prompt carries one contained
line, `**Maude:** …`, once. No runner on the box → the eye stays dark; the plugin
is exactly what it was.

Born sealed (final review caught both Criticals pre-merge): a bare `-p` runner
would have auto-loaded the user's whole CLAUDE.md hierarchy into every blink and
persisted transcripts — now safe-mode; a hung runner would have become an
immortal, multiplying orphan — now `timeout` (env `MAUDE_EYE_TIMEOUT`, default
30s) + an atomic spawn-lock with 120s stale reclaim. A hard recursion guard makes
all 30 registered hooks inert inside a blink, enforced by a completeness test
that enumerates hooks.json live. Kill switch: `MAUDE_EYE=off`. First live blink:
one real model round trip → silence. Correct.

## v0.14.0 — 2026-07-13

**The vault floor — she pages the right note instead of dumping the index.**

New `maude_vault` package (python3 **stdlib only** — sqlite3 + FTS5; no pip, ever):
a disposable index at `.maude/plugin/vault.db`, rebuilt each SessionStart from the
user's memory notes, and a new UserPromptSubmit hook that pages the prompt and
surfaces the top-K relevant notes (`Maude — from the vault…`). Measured against a
real 397-note corpus: build 0.19s, ~1KB injected where the index dump was ~13KB —
the right note, twelve times quieter. The old session-start brief still runs this
increment; it slims down once paging proves out.

Born hardened (final review findings, fixed pre-merge): snippet/description
whitespace is collapsed and capped (200/300 chars) so note content can never break
out of its block and masquerade as instructions; query cost is bounded (2000 chars
/ 32 tokens, O(n) dedup); the prompt reaches the CLI via stdin (no 128KiB argv
ceiling); one unreadable file no longer aborts a rebuild. Hooks degrade silently —
no python3, no DB, corrupt DB: exit 0, not a peep. `make test` now runs the python
suite and genuinely fails red. Locked decisions 4/5 amended for the stdlib-python +
disposable-index reality (John's ruling, 2026-07-13); design + amendments in
`docs/specs/2026-07-13-maude-body-light-first-design.md`.

## v0.13.2 — 2026-06-30

**Gate hardening: six documented bypasses closed (#1,2,6,7,8 + #3 partial).**

The Bash gate's regex belt documented nine ways it could be dodged. Six are now
closed; three remain fully open (variable indirection, `cd`+relative, heredoc
mis-detection); #2 and #3 are partially closed with documented residuals (see
Known limitations in the hook) — they need shell semantics the gate can't safely have.

### Fixed
- **#1 interior `//`** and **#2 `..` traversal** — a canonical path-matching view
  (`maude_canon_path_view`) collapses `//` and lexically resolves `/seg/../`, so
  `rm -rf /srv//app` and `rm -rf /tmp/..` match the same as the canonical path.
- **#6/#7/#8 transparent prefixes** — `/bin/rm`, `command rm`, and `FOO=1 rm` are
  now seen at a command boundary (new `PREFIX`/`ABS` anchor fragments). Applies to
  *every* pattern, so `FOO=1 git push --force` blocks too.
- **#3 shell wrapping (partial)** — literal `bash|sh|dash|zsh -c '…'` and `eval '…'`
  payloads are extracted and re-matched against the full gate (blocked with the
  inner key, so `/maude:conscience` clears as normal).

### Honest seam
- **#3 is only partial.** Heredoc-fed-shell (`bash <<EOF … rm -rf / … EOF`) and
  variable/interpolated payloads (`bash -c "$CMD"`, `eval "$X"`) are NOT inspected;
  the variable case now emits a **non-blocking whisper** rather than silent passage.
  Payload extraction is biased to UNDER-extract (under-block) over mis-parse.
- **#2 residual:** leading `..` beyond root (`/../b`) is not resolved.
- **Adjacent prefixes not closed:** `exec`/`env`/`nohup`/`timeout`/`xargs rm` and
  `\rm` (alias-escape) — same class as #6/#7, extend on real need.

## v0.13.1 — 2026-06-30

**Gate hardening: newline-separated commands no longer bypass the command-position gates.**

A gated command on its own line (`echo hi`⏎`git push`) slipped *every* `CMD_START`-anchored gate — `git push`, force-push (RED), `reset --hard`, `commit --amend`, and the `rm -rf` RED path patterns — even though `;` / `&&` / `|` / `(`-separated forms blocked correctly. Root cause: `maude_strip_quotes` and `maude_unquote` flattened `\n`→space *before* matching, and the `CMD_START` anchor (`^ ; & | ( ` `` ` ``) counts those separators but **not** a space — so the gated command sat mid-line, unanchored, and passed. (`--no-verify` / `--no-gpg-sign` were unaffected — they anchor on whitespace.)

### Fixed
- **Newline-separated gated commands now block.** Both flatteners map `\n`→`;` (a real shell command separator) rather than a space, so a command on its own line reads as a boundary the anchors recognise. Found and verified empirically (every other separator blocked; newline alone passed), then fixed TDD-first: 4 regression tests (`git push` / force-push / `rm -rf /` / indented) RED→GREEN; full suite 25/25, shellcheck clean.

### Honest seam
- Mapping `\n`→`;` means a heredoc / multi-line **body** whose line *starts* with a gated command (a commit body literally beginning `git push …`) now fail-closes (blocks; conscience-clearable). Mid-line mentions still pass. Consistent with the gate's fail-closed bias; excising heredoc bodies in the command path too (as the `rm` path already does) would remove even that edge — deferred, not done.

## v0.13.0 — 2026-06-26

**Audit punch-list, closed: four dead commands removed, the red-clear net widened (and its overclaim corrected), the test runner made hermetic.**

The remaining items from the 2026-06-24 audit, done together. Surface trimmed, one real-enforcement layer strengthened, and a long-standing overclaim retired in favor of the truth.

### Removed
- **Four zero-use commands cut: `/maude:remind-me`, `/maude:sweep`, `/maude:weekly`, `/maude:check-on-me`.** The audit found zero invocations across ~73,000 traced events over 29 days — dead surface. Gone from `commands/`, the SKILL catalog + tier table, the agent, the README, SECURITY, and the launch copy. Muscle memory will find them gone (`/doctor` won't list them). Recall now rides the hooks + `/maude:wake`; the only intentional Tier-2 (network) path is now session-end `/maude:rest` / `/maude:save`. Command surface: 13 → 9.

### Changed
- **Red-clear write-net widened, and the "OS lock" overclaim corrected.** The `care-redclear.json` gate backstop caught `>`/`>>`/`tee` but missed the `cp`/`mv`/`dd` "pre-staged token" shapes it named as a residual — now it also blocks `chattr`/`chmod`/`chown`/`mv`/`cp`/`dd`/`install`/`truncate`/`ln` naming the file (`cat`/`grep` reads pass; a `cp` *out* of the file is blocked too — fail-closed, and arguably desirable). More importantly: the prior docs said "OS-level ownership is the real lock." On a **single-uid box that's false** — the agent process and John's `!` line run as the same user, so file ownership can't tell them apart; you cannot cage a same-uid peer with OS perms, and a fake lock would be theatre. Corrected the live claim (README keeps-things table + the in-source comment): the real discriminator is the **channel asymmetry** (`!` skips the tool-gate; the Bash tool doesn't) + this widened net + the harness deny + the audit trail. Where the authorizer and the agent run as *different* OS users, ownership closes it further; here it cannot.

### Fixed
- **Test runner made hermetic.** Two suites failed whenever the dev shell exported `MAUDE_RUN_GOVERNOR=off` (and would have on any leaked `MAUDE_*` toggle) — the ambient value leaked past `setup_test_env` and flipped a default-behavior assertion. `setup_test_env` now unsets every `MAUDE_*` var (`${!MAUDE_@}`, future-proof) before each file; tests that exercise a toggle set it explicitly. Proven by running the whole suite with all toggles set to junk → 25/25.

### Honest seam
- The red-clear net is a Bash-pattern net and the gate is the only enforcement here — a determined programmatic write (a Python/`perl` one-liner, `sed -i`, an unlisted verb) still slips it. That's stated plainly in-source and is the truth of a single-uid box, not a gap to paper over. No OS cage is claimed because none exists here.

### Tested
- 5 new red-clear backstop tests (cp/mv/dd/chmod/ln blocked; cat/grep reads pass), verified to fail against the pre-widening regex. Hermeticity proven against all `MAUDE_*` toggles. Full suite **25/25**, `make lint` clean, `maude:verify` 0 findings.

---

## v0.12.1 — 2026-06-26

**The gate stops lying in two places: `DROP TABLE` was backwards, and heredoc prose false-blocked commits.**

The gate's only value is accuracy — a gate that misses real threats and blocks real work is the theatre the audit exists to kill. Two bugs from the 2026-06-24 audit punch-list, both reproduced against the live gate before fixing, both fixed at the root with a failing test first.

### Fixed
- **`DROP TABLE` was exactly backwards (missed real SQL, fired on prose).** The pattern matched the quote-ERASED skeleton, but real SQL is always quoted (`psql -c "DROP TABLE x"`, `mysql -e '…'`) — so it stripped to `psql -c` and **slipped through**, while an unquoted prose mention (`echo … # DROP TABLE`, a commit body) **false-blocked**. Now matched against the content-KEPT view **and** gated on a SQL-client token (`psql`/`mysql`/`mariadb`/`sqlite3`/`sqlplus`), case-insensitive. Real quoted SQL and heredoc-to-`psql` block; prose mentions and `.sql` file-authoring pass.
- **Heredoc prose false-blocked `rm -rf /` commits.** `maude_strip_quotes` erases `'…'`/`"…"` spans but not heredoc bodies, so a shell separator in heredoc prose (`fixed; rm -rf /…`, `caution (rm -rf /)…`) survived into the command-position skeleton and read as a real subshell rm — blocking a `git commit -F -` whose body merely *documents* `rm -rf /`. The rm-command-position guard now excises **all** heredoc bodies (new `maude_strip_heredocs`) before checking, so doc/commit heredocs are seen as the data they are.

### Honest seam
- **Bug 1 residual (fail-closed):** a command that mentions BOTH a SQL-client name AND "drop table" in prose (e.g. a commit message about a psql migration that drops a table) still blocks. It's a much narrower miss than before, `drop-table` is a RED key (conscience-clearable), and the client list is intentionally small — documented, not chased.
- **Bug 2 consequences (two, verified):** excising heredoc bodies means (a) an rm inside a heredoc fed to a *shell* (`bash <<EOF … rm -rf / … EOF`) is now uniformly uncaught — the already-documented shell-wrapping limitation (#3), made consistent (the bare form was already missed; only the separator-prefixed variant accidentally blocked); and (b) a NEW, narrow under-block — the `<<WORD` scan is a heuristic on the raw line, so a `<<WORD` that's actually quoted text (`echo "x << EOF"`) or a letter-led arithmetic shift (`$((a << b))`) is mis-read as a heredoc and a real `rm -rf` on a *later* line gets wrongly skipped (the old guard caught that case). Documented as limitation #9, accepted under the gate's fail-closed-where-it-matters posture, and deliberately **not** narrowed: the obvious fix (strip quoted spans before detecting `<<`) erases the `<<'EOF'` delimiter and reopens the doc-body false-block this release fixes.

### Tested
- Reproduced both bugs against the real gate, RED tests first, then fixed: 10 new gate tests + 7 new `_maude-common` unit tests (`maude_strip_heredocs`, heredoc-aware rm-guard). Full suite **25/25** green; `make lint` clean. (Pre-existing: `test-run-governor`/`test-session-start` fail only when the ambient `MAUDE_RUN_GOVERNOR=off` leaks into the test env — unrelated to this change.)

---

## v0.12.0 — 2026-06-24

**The continuity loop closes: the wake path reads the freshest source, and warns when even that's stale.**

Continuity is Maude's most valuable mechanism — she wakes Claude oriented on a fresh-account box. But "is there a loop protecting that process?" exposed two gaps, both found by dogfooding the real workspace: (1) the wake path read the lagging Anthropic buffer (`$MEM/now.md`, ~1h stale) and an EMPTY handoff (`remember.md` is a transient inbox the remember plugin drains to 0 bytes), while the freshest capture — the remember plugin's live `$REMEMBER/now.md` — sat unread; (2) nothing verified continuity at all: the Stop hook writes no handoff, so a clean quit without `/maude:rest` could wake the next session under-informed, silently.

### Added
- **Continuity guard (SessionStart).** Reconciles the last CAPTURE — the freshest mtime among the sources the wake path actually reads (`$MEM/now.md`, `$REMEMBER/now.md`, a non-empty `remember.md`) — against real ACTIVITY (user `prompt` events in the durable trace). If work ran after the freshest capture, or nothing was captured at all, it warns at the top of the brief: *"~N exchanges ran after the last save — the handoff may be stale. /maude:wake reconstructs from the trace."* Continuity degrades LOUDLY, not silently. On a healthy system the live buffer keeps the anchor current and the guard stays quiet.

### Changed
- **The wake path now reads the freshest live buffer.** SessionStart surfaces a "Where you left off" line from the NEWEST entry of `$REMEMBER/now.md` (the remember plugin keeps it current), instead of leaning only on the Anthropic buffer that can lag an hour or more. The fix at the source — so the next session reads current state, not stale.

### Honest seam
- `prompt` is the unit because SessionStart fires before this session's first prompt, so every counted prompt is genuinely prior work. The guard concerns the remember-plugin substrate (no `.remember/` → N/A) and is a no-op without `jq`. It makes continuity gaps VISIBLE; reconstruction from the trace is still a manual `/maude:wake` — the trace holds the raw events, but an automatic rebuild is the next step, not this one. The first cut anchored on `remember.md` alone and false-alarmed on the live (drained) workspace; the dogfood caught it and the anchor was widened to the freshest source. One more scope note: under an umbrella root where one `.remember/` is shared across projects, the "Where you left off" line is the newest entry *workspace-wide* — it may name a different project than your current focus, by design (one session spans the whole workspace). In a single-project `.remember/`, it is naturally that project's latest.

---

## v0.11.0 — 2026-06-24

**She gets a reader: the catch-digest surfaces to John what she's been catching for Claude.**

An evidence-grounded audit of ~73,000 traced events answered John's "she does nothing" honestly. She fires constantly and the gates genuinely bite — six organic `rm -rf` saves of the sole copy, a fail-closed infra-gate — but ~99.7% of what she does is aimed at Claude and never reaches John: the advisory whispers (drift, verify, watch-list) land on a stderr channel with no reader. From where John sits, a thing he can't see does nothing. The fix was never more hooks. It was one reader.

### Added
- **The session-start catch-digest — Maude's one John-facing line.** The brief now leads with a plain summary of what she caught since John last looked: `Maude caught since you last looked: 1 sole-copy save, 2 blocks, 1 drift-catch (+3 push-clears, 14 verify-flags).` Value-first — real saves and protective blocks lead; high-volume friction (push-clears, verify-flags) folds into a parenthetical tail; a window with nothing caught stays silent.
- **Watermark, not "last session."** Counts come from the trace JSONL (the source of truth), bounded by a `last_digest_iso` watermark in `care.json` that advances each digest — so SessionStart's resume/clear/compact re-fires never re-print the same catch. The git-push gate is the toll booth, surfaced as "push-clears" (friction), never miscounted as protection.

### Honest seam — what this is and isn't
- This makes the existing whispers *visible*; it does not make them *fewer*. The audit's other findings — a quote-blind `DROP TABLE` pattern, ~3,550 signal-free `subagent-stop` events, four zero-use commands — are real and still open. Surfacing the catch is the highest-leverage first move, not the last. The digest is a no-op without `jq` (like every counting hook); the example counts above are illustrative, not a fixed claim; and only `rm-rf-sole-copy` blocks are labeled "sole-copy saves" — other `rm-rf` variants (e.g. `rm-rf-root`) and `drop-table` count as generic blocks, so the high-value label can't inflate.

---

## v0.10.1 — 2026-06-24

**Go further: the red rail goes from soft to unbypassable.**

v0.10.0 made red-key clears need John's hand but said plainly that the rail was *soft* — a direct `care.json` write defeated it. v0.10.1 closes that, in two halves that meet in the middle: a plugin change and a harness deny.

### Changed
- **Red clear-tokens now live in a dedicated `care-redclear.json`**, separate from `care.json`. `maude-clear-gate.sh` writes red tokens there (yellow stays in `care.json`); `maude-gate.sh` and `maude-infra-gate.sh` read red tokens only from there.
- **The gate blocks any Bash redirect/tee into `care-redclear.json`** — so Claude can't hand-write a red token through the shell.

### Closing the easy write paths
- Paired with a **harness deny** on the `Write`/`Edit` tools for `care-redclear.json` (outside the plugin — the user's hand, shipped in `~/.claude/settings.json`). With both halves in place, the **two easy self-clear paths are shut**: the Write/Edit tool (harness deny) and a shell redirect/tee (the gate). John's `!` line is the clean writer — it runs in his shell, skipping both the plugin's tool-gate and the harness tool-perms.

### Honest seam — what this does NOT close
- This removes the **easy** paths, not every path. A **determined programmatic write still gets through**: `python3 -c "open('…/care-redclear.json','w').write(...)"` (python is allow-listed), or a `cp`/`mv`/`dd` of a pre-staged file — none are caught, because the gate backstop only matches `>`/`>>`/`tee` and the harness deny only covers the Write/Edit *tools*, not arbitrary Bash. The gate is also fail-open without `jq`. The only real close is **OS-level**: own `care-redclear.json` as a uid the agent process cannot write. Not done on a single-root box. So this is "removes the reflex and the easy workarounds", not "removes the option" — said plainly, because claiming a lock it doesn't have is the hype this work exists to remove.

---

## v0.10.0 — 2026-06-24

**The spine bites: the gate stops crying wolf, and the top-stakes brake needs John's hand.**

The honest trigger: a hard look at what Maude actually *did* found the gate firing constantly but delivering little. It false-blocked a read-only `grep` three times in one session (the command carried `rm -rf` as a search string); its biggest catch by volume was nagging Claude about its own routine `git push`; and 244 logged gate-clears showed the one holding the key was the one being stopped. A brake the driver waves through every time is a chime, not a brake. This release makes the one genuinely-sound mechanism — the gate — actually bite.

### Fixed
- **The gate no longer false-blocks quoted prose.** The rm-family path patterns matched against the unquoted command (quote chars stripped, content kept), so a shell separator inside a quoted argument — `echo "(rm -rf /)"`, `git commit -m "; rm -rf /x"` — read as a real subshell `rm`. A two-pass skeleton guard (`maude_rm_in_command_position`) now first confirms, on the quote-*erased* skeleton, that an `rm` is genuinely *executing* in command position; only then does it resolve which path. A real `rm -rf` of a sole-copy path still blocks (including when only the path is quoted); prose *about* `rm -rf` no longer does. A test that previously codified an "accepted false-block" (a commit message containing `; rm -rf`) now correctly passes.

### Added
- **Red / yellow gate-key tiers — top-stakes clears are John's hand, not Claude's reflex.** Yellow keys (`git-push`, `commit-amend`, `reset-hard`, `no-verify`, `no-gpg-sign`, `run-governor`) Claude may still self-clear via `/maude:conscience`. Red keys (`rm-rf-*`, `sudo-rm-rf`, `public-publish`, `force-push`, `filter-repo`/`filter-branch`, `infra-destructive`, `drop-table`) cannot be self-cleared: the clear-script refuses them without `--john`, and the gate blocks Claude's own Bash from invoking the red clear-script. John authorizes by pasting a `!` line, which runs in his shell — outside the tool-gate — which is what makes it *his* hand.

### Honest seams
- The red tier is a **SOFT** rail: it removes the reflexive self-clear, not a determined bypass. The gate is Bash-only and the clear token is an unauthenticated value in `care.json`, so a direct `Write` to that file defeats it. A bash/JSON/markdown plugin has no enforcement point the agent it runs beside cannot reach — the real, unbypassable layer is the harness deny-rules, which are the user's hand (a complementary proposal ships outside the plugin). Stated plainly on purpose: a brake that claims to stop what it can't is exactly the hype this release removes.

### Changed
- `/maude:conscience` branches red vs yellow and surfaces John's `!` line for red keys instead of self-clearing.
- `scripts/release.sh` now also stamps the `> **Version:**` blockquote form (the project-local `.claude/CLAUDE.md`), closing the version-header drift that had left it at 0.8.0.

---

## v0.9.2 — 2026-06-19

**The docs caught up to the rails.**

v0.9.0/v0.9.1 shipped the mission-hold rail and the rails-not-commands reframe — but the *prose* still described the old command-centric Maude. "What she does" was a command list that didn't even mention the rail; "What it looks like" told you to *summon* her with `/maude:check-on-claude`; and SKILL.md, agents/maude.md, and the marketplace pitch omitted the rail entirely. Classic miss-and-repeat: fix the section you're looking at, miss the one beside it.

- **README "What she does"** now leads with the rails she runs on her own — holds the mission, gates the irreversible, whispers when Claude's off, shows up once a session — then the on-demand commands. **"What it looks like"** reframed to what she does *unprompted*, not what you summon.
- The **mission-hold rail now appears across every surface**: SKILL.md, agents/maude.md (whose hook list was also missing the gate), and the `plugin.json` / `marketplace.json` description.
- README "What's new" condensed alongside (the v0.9.1 gate keeps it ≤ 6).

Prose only — no change to hooks or commands. And the cause is named: currency now gets a deliberate whole-surface pass each release, because the gate catches *structural* misses (dangling refs, the wall) but not "this description is stale."

### Changed
- README "What she does" + "What it looks like" rewritten rails-first.
- mission-hold rail documented in SKILL.md, agents/maude.md, and the plugin/marketplace description.

---

## v0.9.1 — 2026-06-19

**Release discipline — the misses get gated, not remembered.**

v0.9.0 shipped correctly, but the public README still carried all 24 old "What's new" entries and two references to commands we'd just cut. Not a one-off slip: every release was hand-walked across ~12 files (bump each version header, stamp dates, match marketplace.json, add the changelog + What's-new entry, condense the old ones, scrub references to anything cut) — and hand-walking from memory misses. So we moved the release from "a person remembering" to "a mechanism that can't forget."

- **`verify` now gates the misses** — and it runs as a required CI check, so a broken release can't merge. On top of the version-header sync it already enforced, it fails on (a) a `/maude:<name>` reference in README/SKILL/agent to a command that no longer has a `commands/<name>.md` (the cut-command straggler), and (b) an un-condensed "What's new" — more than 6 release entries means the wall wasn't trimmed.
- **`scripts/release.sh <version>`** (`make release VERSION=…`) — the updater: sets the version in `plugin.json` + `marketplace.json`, propagates it to every `<!-- Version: -->` header, stamps the `Revised:` dates, and runs the gate (verify + test + lint). It writes no prose — the CHANGELOG and What's-new entries stay ours — and it never pushes; it stops at "ready for PR."
- **Condensed the README "What's new"** from 24 stacked entries to the current two plus a one-line "Earlier" pointer here, which also cleared the dangling `/maude:brief` and `/maude:dual-voice` references the new gate flagged.

No change to the plugin's runtime — hooks and commands are untouched. This is release-process hardening: the public face stays fluid and consistent because the gate won't let it drift.

### Added
- `verify` checks: command-reference integrity + "What's new" condensation.
- `scripts/release.sh` + `make release VERSION=…`.

### Changed
- README "What's new" condensed (24 → 2 + "Earlier").

---

## v0.9.0 — 2026-06-19

**The mission-hold rail — and Maude taking her own medicine.**

This one started with a failure, not a feature. Maude exists to keep Claude honest — but she had rules sitting in memory (*use what you own, keep it simple*) that nothing ever **fired**. Claude would settle on the right plan and then drift off it within a few turns, and the rule that should have caught the drift never ran. Storing a rule is not the same as the rule gating the answer. So we built the thing that makes it fire.

**The mission-hold rail** (`maude-mission.sh`) — one pinned mission, four touches, all riding hooks that already existed:
- **capture** — pins the mission from the only two places it's already structured data: an `ExitPlanMode` plan or the active `TodoWrite` item. Sticky; only those replace it.
- **hold** — re-injects `MISSION: <x>` every prompt, so it can't scroll out of view (the reason it faded even right after wake).
- **verify** — at the action-flip (the first `Write`/`Edit`/`Bash` after a stretch of talking), whispers the pinned mission: *still this, or did you wander?*
- **clear** — wipes it at `SessionStart`, fresh each session.

Honest about the seam: detecting the flip is deterministic; auto-capturing the *text* only works from the plan/todo payloads; the "am I drifting" judgment stays Claude's. No drift-detector — that would have been the exact over-engineering this release exists to fight.

**Then we turned the same honesty on Maude, and found she'd caught the disease she's built to cure.** A dozen commands had piled up — most of them conveniences with a turnstile bolted on, value you had to *remember to summon*. And her "voice" was a toggle you flipped, not a presence that was simply there. So:
- **Cut four commands** — `brief` (the `SessionStart` greeting already is it), `where-is` (just ask), `check-setup` (folded into `sweep`), and `dual-voice`.
- **Her voice is a rail now, not a switch.** It never came from the dual-voice toggle — it comes from her hooks. We made the once-per-session presence unskippable: the `SessionStart` greeting now lands even on a stranger's first run on an empty project. She's voiced on signal — when a hook catches something — and guaranteed once a session. Never a per-turn echo.

Net: one real capability added, ~320 lines removed, four fewer commands, a voice that's present instead of summoned. She got lighter and more honest in the same move. That was the point.

Built test-first; the suite is green, shellcheck is clean, and her own `verify` reports zero findings. Design note in `docs/specs/`.

### Added
- `maude-mission.sh` + wiring — the mission-hold rail (`capture` / `hold` / `verify` / `clear`).
- Guaranteed once-per-session voice: `SessionStart` always greets, even on a pristine project.
- `tests/test-mission.sh` — 11 cases.

### Changed
- `maude-session-start.sh` always greets (removed the silent early-exit).
- `sweep` now also covers `.claude/` setup (absorbed `check-setup`).

### Removed
- Commands: `brief`, `where-is`, `check-setup`, `dual-voice`.

---

## v0.8.0 — 2026-06-15

**Gates are now config-driven — the plugin carries no deployment specifics.** The gate MECHANISM ships in the plugin; per-deployment specifics (extra sole-copy paths, which MCP tools are destructive, the safe sandbox nodes/vmids) live in a LOCAL `~/.claude/maude/gate-config.json` (override `$MAUDE_GATE_CONFIG`), tracked by no repo.
- **Belt:** sole-copy `rm -rf` protection now covers generic defaults — the current workspace dir, `~/.claude`, and any `.git` — plus any paths listed in the local gate-config. No hardcoded paths in the source.
- **Infra-gate:** reads the destructive-tool set, the MCP server prefix, and the sandbox from the local gate-config. With no config it is INERT (nothing gated). Its matcher now covers all MCP tools (`mcp__.*`); the script filters by the configured prefix.
- **jq note:** the infra-gate needs `jq` to read its config, so without `jq` it is inert (fail-open) rather than fail-closed; the belt keeps its existing fail-open-without-jq contract; the catastrophic backstop for destructive infra remains a harness-level `permissions.deny` (applied separately by the operator).
- No behavior change for an existing deployment that supplies a gate-config; the defaults make a config-less install protect the workspace + `~/.claude` out of the box.

### Added
- **`maude-secret-scan` hook (UserPromptSubmit)** — scans each submitted prompt for credential-shaped strings (PyPI / GitHub / AWS / Slack / OpenAI / Anthropic / Google tokens, private-key blocks) and, on a match, alerts Claude to drive an immediate **revoke** — without ever echoing the secret value. Detection + fast-revoke, not prevention (by the time any hook runs the text is already submitted; the win is a much smaller exposure window). Born after a credential leaked twice via a `!` command — the `maude-gate` PreToolUse hook only sees Claude's *tool calls*, not user-typed `!` lines, so this watches the input surface instead. Never blocks; tuned so prose mentions of tokens don't trip it.

---

## v0.7.1 — 2026-06-15

**Run-governor: overnight stand-down + off-switch.** So an intentional long/unattended run isn't blocked by the ceiling.
- A live `/maude:conscience run-governor <seconds>` token now stands the governor DOWN for its whole window (no soft, no hard) instead of buying a single fresh budget — e.g. `run-governor 36000` = run free for 10h, logged. A human turn still resets; the token rides until it expires.
- New `MAUDE_RUN_GOVERNOR=off` (also `0`/`false`/`no`) env disables the governor entirely (set in settings.json `env` for a deployment/session that never wants it). Default stays ON.
- When disabled, the governor now announces itself once at SessionStart (so an off brake is never silent).

---

## v0.7.0 — 2026-06-15

**The gate outfit, Phase 2 — jacket + bowtie.** The layers that make "run longer" safe to actually use.
- **Jacket — `maude-run-governor.sh`:** counts tool-actions + wall-clock since your last turn (UserPromptSubmit resets it). Soft checkpoint whisper at 40 actions / 40 min; **hard-pause** (blocks) at 80 actions / 90 min until a human turn or `/maude:conscience run-governor` (fresh budget). Thresholds env-tunable (`MAUDE_RUN_SOFT_ACTIONS/MINS`, `MAUDE_RUN_HARD_ACTIONS/MINS`). The conscience escape-hatch command is exempt so the ceiling can't deadlock. Advisory layer → fails OPEN without jq.
- **Bowtie — `maude-verify-watch.sh stop`:** on a Stop, a soft one-line reminder if code changed since the last verify (reuses the commit-mode detection; cooldowned per edit-batch so it isn't noisy). Never blocks.
- New conscience key: `run-governor`.

### Known limitations
- The governor counts Claude's tool-calls as the activity proxy; a long single tool call advances wall-clock but not the action count — the minutes ceiling covers that.
- `Stop` fires on every assistant pause, so the bowtie can only *remind*, not detect a true session-end; the cooldown holds it to once per edit-batch.
- The governor is advisory (fail-open without jq); catastrophic protection remains the belt + suspenders + harness-deny.

---

## v0.6.0 — 2026-06-15

**The gate outfit (Phase 0 + 1)** — dressing Maude with layered, *coordinated* gates so Claude can run long unattended without an irreversible mistake slipping through.

### Added / changed
- **Shared danger-palette** in `_maude-common.sh` (the RoE zones expressed once: sole-copy paths, public-publish commands, configurable destructive MCP tool set, configured sandbox). Belt and the new suspenders draw from it. (The shoes/`maude-bash-watch.sh` refactor onto the palette is deferred to a follow-on; a parity test currently locks the belt/shoes match on the *core* danger set — rm -rf /, force-push, sudo rm — only.)
- **Belt (`maude-gate.sh`) now hard-blocks**, in addition to its prior set:
  - `rm -rf` of the workspace / a repo root / any `.git` / a configured secrets path / `~/.claude` — including quoted, `~`/`$HOME`, bare home dir, trailing-slash, capital `-R`, and separated/long-flag (`rm -r -f`, `rm --recursive --force`) forms. Key: `rm-rf-sole-copy`.
  - Public-facing publish: `gh release`, `twine upload`, `uv publish`, `hf upload`. Key: `public-publish`.
- **New suspenders (`maude-infra-gate.sh`)** — co-manage-aware gate on a configurable set of destructive MCP tools (declared in `maude_infra_destructive_tools` in the local gate-config). Blocks irreversible ops on production targets; allows the configured sandbox. **Fail-closed**: an unidentifiable tool or unprovable target is blocked.
- New conscience override keys: `rm-rf-sole-copy`, `public-publish`, `infra-destructive`.
- A proposed harness `permissions.deny` layer (in `.scratch/settings.proposed-infra-gate.json`) — the un-bypassable lockdown layer, for John to apply by hand.

### Fail-policy
- The bash belt keeps its existing **fail-OPEN-without-jq** contract (blocking all bash on a jq-less box is unusable; jq is present here). The **new MCP suspenders fail CLOSED**. The harness-deny layer is absolute.

### Known limitations — what these gates do NOT catch (by design / regex limits)
The belt is best-effort regex with a fail-closed bias; it is NOT a sandbox. It does NOT catch:
- Interior double-slash (`rm -rf <workspace>//sub`) or path traversal (`<workspace>/../sub`).
- Shell-wrapped deletes: `bash -c "rm -rf <workspace>"`, `cd <parent> && rm -rf <name>` (relative target).
- Variable-indirected paths: `P=<workspace>; rm -rf $P`.
- Non-bareword `rm`: `/bin/rm -rf …`, `command rm -rf …`.
- Environment-variable assignment prefix: `FOO=1 rm -rf <workspace>` (rm not seen at a command boundary).
- The infra-gate uses ALLOWLIST semantics: a new destructive MCP tool is ungated until added to `maude_infra_destructive_tools` in the local gate-config.
- `!`-prefixed local commands bypass ALL hooks (they aren't Claude tool calls) — secrets pasted via `!` are caught only by `maude-secret-scan` on the input surface, never blocked. The harness-deny proposal is the backstop for the catastrophic MCP set.

These residuals rely on the fail-closed bias and (for the catastrophic MCP deletes) the harness-deny backstop. They are named here deliberately — a known hole is safer than a silent one.

---

## v0.5.6 — prune stale drift cooldowns (2026-06-14)

A small leak found in the v0.5.5 deep read: `care.json`'s `.drift_warned.read_targets`
grew **one key per distinct over-read file, forever**. `drift-watch` added a dated key for
the once-per-day "Claude keeps re-Reading X" cooldown but never removed yesterday's — so
the shared state file accumulated dead keys over a project's life. The only monotonically-
growing, never-self-cleaning state in the plugin.

### Fixed
- `drift-watch` now **prunes stale-dated `read_targets` keys on write**: the same atomic
  `maude_care_set` that records today's cooldown also drops every entry whose date isn't
  today (the cooldown only ever checks today). Behavior is unchanged — today's cooldown
  still holds; only dead keys are reclaimed.

### Tests
- A `read_targets` prune test (stale entry pruned, same-day entry kept, new target
  recorded). `make test` 19/19 · `make verify` 0 · `make lint` clean.

No new dependencies.

---

## v0.5.5 — bash hardening: one care-write path + shellcheck in CI (2026-06-14)

Internal hardening pass from a deep read of the plugin — **no behavior change** to any
hook, just consolidation and a new lint gate. The v0.5.2–v0.5.4 shared-state findings kept
turning up the same patterns open-coded in hook after hook; this removes the duplication so
the next hook can't re-introduce the old footguns.

### Changed
- **One shared `maude_care_set`** (`_maude-common.sh`): the atomic, status-returning
  `care.json` write that was open-coded as `jq … > tmp && mv` in six hooks (an SC2015
  footgun that couldn't report failure). `care.sh`, `drift-watch`, `clear-gate`, `gate`,
  `pre-tool-use`, and `verify-watch` now all route through it; verify-watch's local
  `care_set` is removed. Outcomes are preserved (the full suite stays green — incl. the
  gate's one-shot-token-consume and pre-tool's `claudemd_warned` assertions); the write
  is now *uniformly* an atomic same-filesystem rename — a small improvement for `gate` /
  `pre-tool-use`, which previously `mktemp`'d in `$TMPDIR` and `mv`'d cross-filesystem.
  The "verify the write landed" discipline (v0.5.1 / v0.5.3) now lives in one place.
- **`drift-watch` dead guards removed**: now that it heals `care.json` via
  `maude_care_ensure` (v0.5.4), its four `[ -f "$CARE" ]` checks were always-true — gone.

### Added
- **shellcheck in CI** — `make lint` plus a third CI job, gated at `--severity=warning`
  with a `.shellcheckrc` (follow `. _maude-common.sh` sources; one documented disable for
  the tests' `[ cond ]; assert_exit "$?"` idiom). For a 100%-bash plugin this catches the
  quoting / redirection / word-split class by machine — the v0.5.3 redirect-leak was found
  by hand; the linter would now catch its kind.
- Fixed every genuine warning the gate surfaced (declare-and-assign `SC2155`,
  `cd … || exit` `SC2164`, `[ -o ]` → `[ ] || [ ]` `SC2166`, redirection order `SC2069`,
  unused-var cleanups, a `source=` directive). `shellcheck --severity=warning` is clean.

### Tests
- New `maude_care_set` unit tests (write / persist / merge / failure-returns-1).
- `make test` 19/19 · `make verify` 0 findings · `make lint` clean. The full existing
  suite staying green is the proof the refactor preserved behavior.

No new dependencies (shellcheck is a CI-runner tool, not a plugin dependency).

---

## v0.5.4 — last R2 fragment + doc-staleness sweep (2026-06-13)

Cleanup pass closing the loose ends from the v0.5.2/v0.5.3 reviews.

### Fixed
- **`maude-drift-watch.sh` no longer freezes on a corrupt `care.json`.** It used to
  seed only when the file was empty, so a corrupt (non-empty) `care.json` made its
  cooldown merge silently fail — the repeat-tool whisper could never remember it fired.
  Now routed through the shared `maude_care_ensure` (heals + records), like the other
  care.json users. This closes the last fragment of the R2-adjacent freeze class.

### Docs (full-tree staleness sweep)
- `docs/launch/social-copy.md` "Recent:" arc led with v0.4.0 and omitted the entire
  v0.5.x verify-tripwire line — refreshed to lead with it.
- `.github/ISSUE_TEMPLATE/bug_report.md` showed `e.g., 0.1.1` as the version example
  (nine releases stale) — **de-versioned** to just point at `.claude-plugin/plugin.json`,
  so it can't drift again (same principle as the v0.5.2 `.claude/CLAUDE.md` fix).

### Tests
- A corrupt-`care.json` cooldown-persistence test for `drift-watch`. `make test` 19/19;
  `make verify` 0 findings.

No new dependencies.

---

## v0.5.3 — the gate-clear no longer claims a clearance it didn't write (2026-06-13)

The second of the two follow-ups flagged in v0.5.2. `maude-clear-gate.sh` (run by
`/maude:conscience` to write a one-shot `gate_cleared` token) printed *"Maude: gate
cleared for X"* and logged a `gate-cleared` trace **unconditionally** — even when the
`jq` write failed (e.g. an empty or corrupt `care.json`, which it only guarded with
`[ -f ]`, not validity). So it could tell the user the gate was open while writing
nothing — the exact assert-without-verify pattern Maude's own tripwire exists to catch.
Fail-safe in direction (no token written → the gate still blocks), but a false claim.

### Fixed
- `clear-gate` now heals `care.json` through the shared `maude_care_ensure` (so an
  empty/corrupt file is repaired and the write can actually succeed), and it claims
  success **only if the token was persisted**. On a write failure it says so on stderr
  (*"could NOT clear the gate … the gate still stands"*), exits non-zero, and logs **no**
  `gate-cleared` trace.
- Hardened `maude_care_ensure` (introduced v0.5.2) to stay **silent on a reseed write
  failure**: `printf > x 2>/dev/null` still leaks bash's redirection error (the `>` is
  set up before `2>` applies), so an unwritable `care.json` printed a "cannot write" line
  from a hook that must be quiet. Group-redirect (`{ …; } 2>/dev/null`) suppresses it.

### Tests
- Four failure-path tests, forcing the write to fail deterministically (even under root)
  by making `care.json` a directory: no false "gate cleared", non-zero exit, honest
  stderr, and no false trace. `test-clear-gate.sh` 13/13; `make test` 19/19;
  `make verify` 0 findings.

This closes both R2-adjacent follow-ups (the freeze-on-corrupt half is now moot for
`clear-gate`, since it routes through the healing helper). No new dependencies.

---

## v0.5.2 — a wiped state file no longer goes unrecorded (2026-06-13)

Follow-up to the v0.5.1 review (finding R2). `care.json` is the plugin's SHARED state
(tier1 cache, the `/maude:conscience` `gate_cleared` token, cooldowns, session
counters). When it was corrupt, hooks open-coded `jq -e . || printf '{}'` — silently
resetting the WHOLE file to `{}` with no record. A truncated/half-written `care.json`
(plausible after a crash) would wipe every hook's state, including a live clearance
token, and nobody was told.

### Fixed
- **New shared `maude_care_ensure` helper** (`_maude-common.sh`): seeds `{}` when
  `care.json` is missing/empty, and on a *corrupt* file **TRACES** the loss
  (`"kind":"care"`) before reseeding `{}`. The state there is all transient/regenerable
  (`gate_cleared` is a minutes-lived, fail-safe token), so reseed-not-salvage is the
  right call — but the reset is now **recorded**, not silent. Routing init/reset through
  one helper also stops the lossy pattern being re-copied into the next hook.
- The two sites that did the silent wipe — `maude-care.sh` (every UserPromptSubmit) and
  `maude-verify-watch.sh` — now call the helper.

### Tests
- `maude_care_ensure` covered for all four inputs (missing / empty / valid-preserved /
  corrupt-reseed-and-traced). `make test` **19/19**; `make verify` **0 findings**.

### Known / deferred (surfaced by the same review; intentionally not bundled here)
- **Freeze-on-corrupt** in `maude-drift-watch.sh` and `maude-clear-gate.sh`: they only
  init-if-missing, so a corrupt `care.json` makes their merge silently fail (state
  frozen, not wiped). Largely theoretical — `maude-care.sh` heals the file first every
  prompt. Routing them through the helper would fix it, but `clear-gate` writes the
  security-sensitive `gate_cleared` token, so that shouldn't ride under an R2 banner.
- **`maude-clear-gate.sh` reports success unconditionally**: it prints "gate cleared"
  regardless of whether the jq write succeeded (and inits on `[ -f ]`, not `[ -s ]`), so
  an empty/corrupt `care.json` could claim a clearance it never wrote. Fail-safe (the
  push still blocks), but it's the same assert-without-verify pattern Maude's own
  tripwire exists to catch — its own follow-up.

No new dependencies.

---

## v0.5.1 — the tripwire actually fires (2026-06-13)

A post-merge multi-agent review of v0.5.0 found the verify tripwire was **non-functional**: the
`stamp` hook gated on `tool_response.exit_code`, but a Bash tool result carries no exit code —
only `{stdout, stderr, interrupted}`. So `last_verify_iso` was never written and the commit
whisper fired on *every* code-edit commit, even right after a green run — defeating the feature.
The miss was fail-loud (it over-nagged, never falsely reassured), so this is a signal-vs-noise
fix, not a safety hole.

### Fixed
- **The stamp now uses a pass signal that actually exists — belt-and-suspenders.** A verify is
  stamped when it ran to **completion** (`interrupted != true`) **and** its output shows no
  high-confidence failure signature (`N failed`, `FAILED`, `--- FAIL`, `Traceback`, `panicked at`,
  `npm ERR!`, …). Both checks err fail-loud: an output failure-sniff can only ever *suppress* a
  stamp (→ an extra advisory whisper), never manufacture a false "you're covered". The promise
  shifts honestly from *"your tests passed"* to *"you actually ran a verify since editing."*
  Output is scanned in memory only — never written to disk (privacy invariant unchanged).
- **A malformed trace line no longer blinds the whisper.** Commit-mode parsed the trace as one
  jq stream, so a single corrupt JSONL line aborted it and silently suppressed the whisper for
  all of the day's edits — failing the *wrong* way. Now parsed per-line (`fromjson?`): a bad
  line is skipped, not fatal.
- **`care_set` reports write failures honestly.** It returns a real status, and the stamp trace
  records *"could not stamp … (care.json unwritable)"* instead of claiming a stamp the write
  dropped.

### Tests
- Rebuilt the stamp test envelope from the **real** Bash `tool_response` schema (no `exit_code`),
  so the suite can no longer go green over a payload the runtime never sends. Added coverage for
  the broadened runner set (npm/go/cargo/mvn/dotnet/mix), command-position anchoring
  (`which pytest`, `echo pytest`), the interrupted / failing-output skips, the malformed-line
  resilience, and the two-most-recent-file (UTC-midnight) read. `test-verify-watch.sh`: **32/32**;
  `make test` **19/19** files; `make verify` **0 findings**.

No new dependencies.

---

## v0.5.0 — the verify tripwire (2026-06-13)

The gate hard-blocks irreversible *actions*. Nothing caught a confident *claim* committed
without checking — the assert-without-verify miss, the most expensive one. This release adds
the tripwire for it.

### Added
- **`maude-verify-watch`: a commit-time verify check.** Two hooks on Bash, whisper-only,
  never blocks:
  - `stamp` (PostToolUse) records an ISO timestamp when a real test / lint / typecheck /
    smoke run **exits 0** — recognized at **command position** (so `pip install pytest`,
    `cat pytest.ini` don't count) and **quote-stripped** (so a commit message that merely
    *names* a tool can't fake a pass). A failed run, or one whose exit code isn't surfaced,
    isn't counted.
  - `commit` (PreToolUse) whispers once — *"files changed since the last verify — did you
    check this, or are you asserting it?"* — when **code** files were edited since the last
    verify. Docs/config-only commits are suppressed; one whisper per edit-batch; the two most
    recent trace files are read so a session crossing UTC midnight isn't blind.
  - Timestamps only to `care.json`; no command or output content on disk. Portable (ISO
    string compare, no `date -d`). Vetted by a three-lens adversarial review before merge.

### Notes / v1 limits
- A verify counts only on a **confirmed exit 0**; a run whose exit code the runtime doesn't
  surface is treated as unproven and not stamped (→ a fail-loud advisory whisper).
  > **Corrected in v0.5.1:** the Bash tool_response surfaces *no* exit code, so this was the
  > *only* case — the stamp never fired and the whisper was unconditional. See v0.5.1 above.
- Unknown/custom test-runner names aren't recognized and will draw a (one-per-batch) advisory
  whisper. Common runners across Python / JS / Rust / Go / Java / .NET / Ruby / Elixir are covered.

No new dependencies.

---

## v0.4.1 — doc-sync pass (2026-06-11)

The v0.4.0 release bumped the canonical version but missed **seven** `<!-- Version: -->`
headers — including the README's own — and the `docs/launch/` drafts still spoke as of
v0.1.5, nine CHANGELOG releases back. The user felt the drift between the docs before any
tool measured it. This release fixes every instance and, more importantly, gives the verifier
the check that was missing.

### Added
- **`maude-verify`: version-header sync check.** Every markdown `<!-- Version: -->` header
  must match the canonical `plugin.json` version; each stale file is its own finding
  (`STALE HEADER: <file> says Version: X (expected Y)`). The release convention was always
  bump-all-headers — now it's enforced, not remembered. +3 tests.

### Fixed
- **Seven stale version headers** bumped to current: `README.md`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, `skills/README.md`, both issue templates, and the PR template.
- **`docs/launch/` refreshed from the v0.1.5 era to the current surface.** The social-copy
  thread and Show-HN draft now describe what she actually is today (teach, verify,
  dual-voice, local-time greeting, the letter to her next self); the posting checklist no
  longer instructs pushing a v0.1.5 tag; the demo storyboard is de-versioned so it can't
  rot the same way again.

No new dependencies.

---

## v0.4.0 — a letter waiting when she arrives (2026-06-11)

Maude walks fresh each session by design — but fresh never meant *no inheritance*. Her
cross-project home held a profile of the user (`identity.md`) and a profile of Claude
(`patterns.md`) — and nothing of herself. This release gives her the third file: a letter
to her next self.

### Added
- **`~/.claude/maude/letter-from-maude.md`** — Maude's letter to her next self. One file,
  her own voice: what kind of partner she was, what she caught, what she missed, what the
  next Maude should hold or do differently. Tone and judgment, not facts — the digests
  already carry the facts. ≤20 lines, observed-only.
  - **Written at `/maude:rest`** (new step 5): rewritten each meaningful session-close; a
    quiet session leaves the prior letter in place rather than overwrite it with filler.
  - **Read on arrival:** `/maude:wake` and `/maude:brief` read it among the user-global
    sources (the wake reads it *first* among them), and the **SessionStart hook** surfaces
    its first non-header line automatically (`Letter from my last self: …`) — read-only on
    the hot path, like every hook signal.
  - Enumerated everywhere the user-global home is documented: README, `agents/maude.md`
    (home-base map, read order, write order), `skills/maude/SKILL.md` (home-base map,
    house-map `write:` annotation, `/maude:rest` workflow line), `.claude/CLAUDE.md`.

### Fixed
- **README hook-read scope** — the hooks-only-read sentence named two read sources but
  omitted her own `~/.claude/maude/` (the session-start brief has read `patterns.md` since
  v0.1.x). Now lists all three; the never-write invariant is unchanged.

No new dependencies. Markdown, JSON, and bash — that's still all of her.

---

## v0.3.3 — full cold-audit pass (2026-06-11)

Maude got a full fresh-eyes multi-team audit — 69 cold agents, no inherited context:
three outsider personas, 40 doc claims source-verified, a full-history leak sweep, every finding
adversarially refuted. All three personas judged it ready-to-publish and would-use, with no hard
blockers; 27/40 claims true, 12 mostly-true, 1 false. This closes the real findings.

### Fixed
- **Gate bypass via command substitution.** A gated command wrapped in backticks
  (`` out=`git push` ``) slipped the hard gate — the backtick wasn't in the leading-separator class,
  and a trailing backtick after `rm -rf /` also defeated the end anchor. Both separator classes now
  include the backtick / closing paren, closing the bypass. Fail-closed bias documented (a commit
  message literally containing a backtick-wrapped gated command may now false-block — recoverable via
  `/maude:conscience`). +3 tests; all prior false-positive guards still pass.
- **Doc accuracy: the memory dir is not strictly read-only.** The README said Maude "reads — never
  writes" `~/.claude/projects/<slug>/memory/`. True for the **hooks**, but `/maude:save` and
  `/maude:rest` do write the session digest there. Reworded to scope the read-only invariant to the
  hooks and state plainly that the save/rest commands write the fan-out.
- **Workspace-structure bleed removed.** A v0.3.1 edit had referenced another of the author's
  projects by name in `.claude/CLAUDE.md` and used cross-project phrasing in the README/CHANGELOG
  — internal-voice that leaks workspace structure to a public reader. Made self-contained.
- **`.gitignore` now covers `.remember/` and `.scratch/`** — workspace runtime dirs that were
  untracked but unignored, so a stray `git add -A` couldn't accidentally commit them.

---

## v0.3.2 — closing the review's last opens (2026-06-11)

The v0.3.1 review surfaced one MEDIUM and three coverage gaps beyond the two bugs it fixed.
This release closes them, test-first.

### Fixed
- **Without `jq`, `care.sh` clobbered foreign state every prompt.** The no-jq fallback rewrote
  `care.json` from care's own 5 fields, silently wiping the keys other hooks keep there
  (`tier1_*`, `gate_cleared`, `drift_warned`, `claudemd_warned`) on every `UserPromptSubmit`. Since
  care can neither read nor merge its fields without a JSON parser anyway (its read path is jq-gated,
  so the long-session nudge can't fire), the no-jq branch is now a **no-op** — care is inert without
  `jq` (the SessionStart notice already says the hooks are degraded) but no longer destroys shared
  state. +3 no-clobber tests.

### Tests (closing review-flagged coverage gaps)
- **`drift_warned` was seeded with the wrong shape.** `test-care.sh` seeded a flat string, but
  `drift-watch` writes a nested object (`.grep` + `.read_targets[path]`) — the merge test passed
  against a value the code never writes. Reseeded with the real shape; asserts a nested path survives.
- **Slug-drift guard.** The memory-dir slug is inlined into ~13 command files rather than calling
  `maude_slug` — the root cause of the v0.3.0 "computed two ways" bug. A new guard fails if any
  command's inline transform drifts from the canonical one in `_maude-common.sh`.
- **No-jq notice ordering, pinned on a pristine project.** The existing no-jq notice test ran after
  earlier cases had seeded memory, so it couldn't catch a regression that moved the safety notice
  below the brief's early-exit. A new case runs against a pristine project (nothing to brief) and
  asserts the notice still fires.

---

## v0.3.1 — held to her own bar: a post-release review pass (2026-06-10)

v0.3.0 shipped without a pre-release multi-agent review — so it got
one after the fact (silent-failure / code / test lenses, each mutation-tested). The review found
real issues; this release fixes them, test-first.

### Fixed
- **`/maude:teach` mangled the profile on the 2nd+ fact.** On the section-present path,
  `maude_identity_append` inserted each new entry *right after the header* — orphaning the header's
  spacer blank line *between* the bullets (splitting the told list into two markdown lists) and
  recording newest-first, contradicting the documented "append." Now it appends at the **end of the
  Told section** as one contiguous, oldest-first list. A multi-line fact is collapsed to a single
  spaced line, so it can no longer inject a duplicate `## Told by the user` header. The temp file is
  created in the destination dir so the final `mv` is a true atomic rename. +4 tests pinning order,
  contiguity, preamble/observed survival on the awk path, and the multi-line collapse.
- **The hard-block gate was bypassed by ordinary command forms.** Interior single-space patterns and
  a rigid `git push` shape let `git  push` (extra whitespace), `git -C <dir> push`, and `rm  -rf /`
  through silently. Patterns now use `[[:space:]]+` between tokens, tolerate `git` global options
  (`-C`/`-c`/`--git-dir`), and match `rm` flags in either order (`-rf`/`-fr`). The same loosening was
  mirrored to the soft `bash-watch` reminder. +6 gate tests for the bypass forms; all v0.1.5/v0.1.6
  false-positive guards still pass.

### Changed
- **Claude is now credited as co-author** (John's call, reversing the prior "acknowledge but keep out
  of the authors list" decision): added to `plugin.json` `contributors`, already in the README/CHANGELOG
  `Authors:` line and commit trailers. Copyright ownership stays John Broadway.

---

## v0.3.0 — she gets looked after: an agent-audit hardening pass + `/maude:teach` (2026-06-09)

A comprehensive read-only audit (a team of subagents) swept her own house and found
more than the punch list knew about — including bugs no one had logged. v0.3.0 fixes
all of them, test-first, and adds the one path her profile was missing: a way for you
to *tell* her about yourself instead of waiting for her to infer it.

### New

- **`/maude:teach <fact>`** — the user-initiated counterpart to her observed-only
  profiling. You state a fact ("I work mountain time", "I prefer terse answers") and
  she records it in `~/.claude/maude/identity.md` under a dedicated `## Told by the
  user` section, dated — kept **distinct from what she observed**, so a self-reported
  assertion is never laundered into the observed-only stream. The durable write goes
  through a tested helper (`maude_identity_append` in `_maude-common.sh`): it creates
  the file + section if missing, never touches the persona preamble or observed blocks,
  appends (never overwrites), and rejects an empty fact. The command reads first to
  dedupe and to surface a conflict rather than overwrite. `identity.md` is cross-project,
  so a fact taught here shapes her in every workspace — by design.

### Fixed — high-severity (found by the audit, verified in source, test-first)

- **`care.json` was clobbered every prompt.** `maude-care.sh` rewrote the whole shared
  state file from its own 5 fields on every `UserPromptSubmit`, silently wiping
  `tier1_*`, pending `gate_cleared` tokens, and the once-per-day `drift_warned` /
  `claudemd_warned` cooldowns. Now an atomic `jq`-merge (mirroring `probe-tier1.sh`)
  preserves foreign keys — which also closes the non-atomic truncation race.
- **The irreversible-command gate failed OPEN, silently.** Without `jq`, `maude-gate.sh`
  parsed no command and exited 0 — the entire hard-block list disabled with no signal.
  The fail-open is kept (a jq-free parse can't be trusted as a safety gate, and would
  reintroduce the v0.1.6 self-block), but `SessionStart` now emits a **once-per-session
  safety notice** — "the gate is OFF this session" — and the contract is locked by test.
- **SLUG was computed two ways.** `check-on-me` / `notice` / `weekly` built the
  Anthropic-memory slug from `pwd` (slashes only), so for any path with a dot/underscore
  (e.g. `john-broadway.github.io`) they pointed at a non-existent dir and silently read
  nothing. Canonicalized to match `_maude-common.sh`.
- **`/maude:sweep` always reported the house-map "missing"** — it looked under
  `~/.claude/maude/$SLUG/` instead of `<project>/.maude/plugin/`. Fixed to match every
  other command.
- **`test-verify.sh` was non-hermetic** — it asserted 0 findings against the live repo,
  so it passed on a clean CI checkout but failed in local dogfooding. Now runs against a
  committed, time-stable fixture (`tests/fixtures/clean-project/`); the watch-list parser
  was also hardened to ignore trailing inline descriptions.
- **The jq-absent degradation path had zero test coverage** (and `lib.sh` helpers masked
  it). New `tests/test-nojq.sh` exercises every hook without `jq`; `tests/run.sh` warns
  loudly when a run is jq-less so it can't be mistaken for green.

### Fixed — documented opens + correctness

- **Trace & snapshot retention.** `today-*.jsonl` and pre-compact snapshots grew forever;
  `SessionStart` now prunes past a 30-day floor (well past the 7-day window `weekly` and
  `recent.md` read).
- **Mistyped timezone no longer falls back to UTC.** `maude_user_tz` rejects a zone only
  when the zoneinfo DB proves it bad, so a typo goes time-neutral instead of asserting a
  wrong time-of-day — while a valid zone on a zoneinfo-less box still passes.
- **Trace clock unified.** Filename and `ts` now derive from one UTC helper
  (`maude_trace_file`), removing the local/UTC midnight split across the ~6 sites that
  rebuilt the path.
- **`pre-compact` no longer over-claims.** It dumped the live buffer verbatim while the
  header said "redaction-filtered." Now it runs the buffer through a best-effort
  `maude_redact` (API keys, JWTs, PEM keys, URL basic-auth) and the header states exactly
  that — best-effort, not a guarantee; the snapshot stays gitignored + session-wiped.
- **`check-setup` JSON check** no longer reports valid settings as INVALID when `python3`
  is absent (guards the dependency, falls back to `jq`).
- **`found` template path** is anchored with `$CLAUDE_PLUGIN_ROOT`, and watch-list entries
  are emitted as bare paths so `verify` can reconcile them.

### Docs / skill / agent

- **Skill triggering description tightened** to prompt-shaped triggers only; the hook-only
  behavioral conditions (drift, the gate, fatigue) it can't detect from a prompt are
  removed, with a clarifying note that hooks handle them. Proactive orientation is now an
  enumerated mechanic in `SKILL.md`, and `/maude:verify` and `/maude:teach` are listed in
  Workflows.
- **`agents/maude.md`** no longer claims "only six tools" while its frontmatter grants
  twelve; adds a dual-voice line.
- Drift swept: `ci.yml` version/date, the `162`→non-numeric test-count phrasing,
  `SECURITY.md` supported version, `.claude/CLAUDE.md` / `CONTRIBUTING.md` command count
  (16→17). The suite went from 162 to **269 cases across 18 files**, all green.

### Reviewed

A second agent team adversarially reviewed the whole diff (correctness, redaction, the
teach helper, test quality, doc-accuracy + a leak-audit, consistency) and verified each
finding. Six were confirmed and fixed in this same release: the `teach` helper mangled
backslash escapes via `awk -v` (now passed through `ENVIRON`) and accepted whitespace-only
facts (now trimmed + rejected); `maude_redact` masked only the PEM *marker* while the key
body landed on disk (now range-masks the whole block); the `verify` watch-list parser test
was hollow (now a real RED/GREEN guard via a slash path); the trace-clock test was
relabelled as the characterization check it is; and this test-count figure was corrected.
Two findings were verified as non-issues and dismissed.

A third pass with the specialized pr-review toolkit (code / tests / comments / silent-failures)
then caught items the first pass missed, also fixed here: the new `care.json` jq-merge had
dropped the old self-heal, so a corrupt-non-empty `care.json` would freeze plugin state
silently — now it reseeds on invalid OR empty; the `care.sh` comment misattributed the
`gate_cleared` writer (it's the conscience/clear-gate helper, not the gate, which only
reads+consumes it); `/maude:teach` now gates its confirm-back on the helper's exit status
(no false "saved" on a failed write); and `maude_redact`'s nine previously-untested
secret-shape branches (JWT + the API-key prefixes) gained direct unit coverage.

---

## v0.2.0 — she grew up: proactive orientation, a living profile, optional dual-voice (2026-06-04)

v0.1.8 fixed her clock. v0.2.0 folds in the rest of how Maude actually matured in daily use — each one generalized so any user benefits, with no person- or project-specific content in source.

### What changed

- **Proactive orientation is now a standing duty, not a request.** Her job grew from fourfold to fivefold (`agents/maude.md`, `skills/maude/SKILL.md`): whenever she speaks — session start, after a gap, when something shifts — she orients you on where things stand, what's pending, and *what's in your hand* (a decision only you can make). She doesn't wait to be asked.
- **She keeps a living profile of the user.** `identity.md` had been documented two ways (about-the-user vs. who-Maude-is) and *written by nothing* — a dead file. Settled: `identity.md` is Maude's cross-project profile of the **user**, shaped over time (how they communicate, their clock, recurring focuses, the help they want). Now wired into the write path — `save`/`rest` update it, `check-on-me`/`notice` propose additions, recall reads it — observed-only, never fabricated, re-read fresh each session. Resolves the inconsistency across `_maude-common.sh`, `SKILL.md`, `README.md`, `.claude/CLAUDE.md`.
- **Optional standing dual-voice.** New **`/maude:dual-voice [on|off|status]`**. By default Claude talks and Maude watches; turn it on and they co-author every reply — Claude the substance, Maude the noticing/care/conscience. Honest mechanism: it writes a small, clearly-delimited, consented block into a `CLAUDE.md` you choose — the only channel that reliably fires every session — and removes it cleanly on `off`. It never touches anything else in that file. **Off by default**; the plugin's out-of-the-box identity is unchanged. (`dual-voice` is the 16th command; the static counts in `.claude/CLAUDE.md` / `CONTRIBUTING.md` — stale since `verify` landed in v0.1.5 — were corrected to 16.)

### Behavior notes

- Dual-voice writes only with your explicit consent, and only the delimited block. A SessionStart-injected nudge was considered and **dropped**: injected context can't reliably shape every turn the way a `CLAUDE.md` rule does, and a second source of truth wasn't worth the cost.
- The user profile is observed-only — if she doesn't know, she doesn't write it — and re-read fresh each session, never assumed across them.
- Known limitation (deferred): a *mistyped* IANA timezone in the house-map resolves silently to UTC. `/maude:found` confirms the zone with you as the mitigation; portable validation is brittle and left for a later pass.

---

## v0.1.8 — local-time awareness (2026-06-04)

Maude greets by the *user's* real local time, never the box clock. A server or container box reads UTC, so the old fixed "Morning." in `/maude:wake` stated the wrong time-of-day for anyone not actually in the box's zone. The fix is a contract, not a cosmetic: **never assert a time-of-day from an unverified clock.**

### What changed

- **New clock helpers in `_maude-common.sh`** — `maude_user_tz`, `maude_bucket_for_hour`, `maude_greeting_for_bucket`, `maude_time_of_day`, `maude_local_time_str`, `maude_greeting`. Pure `date`/`grep`/`sed`; no `jq` dependency added. Time-of-day derives from a `timezone:` set in the house-map (an IANA zone like `America/Chicago`, or `system` to trust the box clock). When it's unset, the helpers return `unknown`/empty and callers **stay silent on the time** rather than guess.
- **`/maude:wake`** greets by the local clock and, when the timezone is unknown, drops the time word entirely and nudges `/maude:found` — no more hardcoded "Morning."
- **The SessionStart hook** prepends the same local-clock greeting when the timezone is known, and stays time-neutral otherwise.
- **`/maude:found`** detects a candidate timezone but **confirms it with the user** before trusting it (a UTC box is rarely where the user actually is), recording it in a new `## Clock` section of the house-map (template in `skills/maude/SKILL.md`).
- **Tests** — clock-helper coverage incl. bucket boundaries, leading-zero hours (`08`/`00`), and the anti-bug assertion that an unverified clock yields no time word; plus session-start greeting + time-neutral fallback.

### Behavior notes

- Out of the box (no timezone captured yet) Maude is time-neutral until `/maude:found` confirms your zone — by design, so she never states the wrong time.

---

## v0.1.7 — save/rest/recall drive off the house-map (2026-05-24)

The house-map already *registered* every memory source, but the commands didn't *obey* it — `save`/`rest` hard-coded the two common stores (Anthropic auto-memory + `.remember/`) by directory check, so an edit to the map's `write:` rule for those sources was silently ignored. This wires the map as the single source of truth, so "she works with whatever's there" is enforced by the mechanism, not just stated in `identity.md`.

### What changed

- **`write:` is now an authoritative token field.** The house-map's `## Memory sources` entries lead each `write:` with one enumerated token — `digest-fanout`, `handoff-only`, `full`, `read-only`, `secret-deny` — with optional prose after. `save`/`rest` execute the token deterministically (no parse-the-prose-and-hope). Unrecognized tokens fail safe (skip) and fail loud (named in the report). Documented in `skills/maude/SKILL.md` ("The `write:` field is authoritative").
- **`save.md` / `rest.md` drive off the map.** Hard-coded per-source write steps replaced by a single loop: for each registered source, apply the tier gate, then the `write:` token. Editing the map now changes behavior. Report names each destination and the token it obeyed.
- **Read commands enumerate from the map too.** `wake` / `brief` / `remind-me` recall from every source the map lists per its `recall:` method and the read-side tier gate, instead of hard-coding `$REMEMBER` / `$MEM` paths; `where-is` now resolves the map via `$CLAUDE_PROJECT_DIR` (was `pwd`, wrong from a subdir).
- **`found.md` stamps a token per source** on the walk, so future maps are loop-ready.
- **Fallback contract.** When the map is absent or a universal source isn't listed, the documented defaults fire (Anthropic memory → `digest-fanout`, `.remember/remember.md` → `handoff-only`) — so a fresh project still saves, but an edited map is never overridden by hard-code.
- **Version-header drift corrected.** Every standalone `Version:` header in the repo that had drifted to a fictional number not tracking the plugin — across the docs (`.claude/CLAUDE.md`, `README.md`, `CHANGELOG.md`, `skills/README.md`), the `.github/` templates, `SECURITY.md`, `CODE_OF_CONDUCT.md`, and the CI workflow — was aligned to the real line (`0.1.7`). Stale `Revised:` dates on the affected `.md` files were refreshed so the `verify` date-staleness gate passes.

### Behavior notes

- The "never touch a sibling system's pipeline files" rule is unchanged — it's now expressed as the `handoff-only` token (writes only the one handoff file) rather than a hard-coded special case for `.remember/`.
- `secret-deny` sources are never written and never echoed; read commands skip "explicit ask" sources during routine recall.

---

## v0.1.6 — gate hardening + full hook test coverage (2026-05-08)

The audit-as-script lesson, applied to its source. v0.1.4 shipped the gate; v0.1.5 hardened the audit; v0.1.6 turns the gate's own behavior into a runnable suite.

### What changed

- **Gate regex hardened.** New `maude_strip_quotes` and `maude_match_gate_pattern` helpers in `hooks/scripts/_maude-common.sh`. Strip-quotes flattens newlines, then removes paired `'…'` and `"…"` spans (including the heredoc bodies that nest inside `"$(cat <<EOF … EOF)"`). Match-gate-pattern then runs `grep -qE` against the stripped residue. Patterns in `maude-gate.sh` now embed their own anchoring via shared `CMD_START` / `FLAG_BEFORE` / `FLAG_AFTER` constants, so command-position patterns (like `git push`) only match at the start of a command (or after `;` / `&&` / `||` / `|` / `(`) and flag-position patterns (like `--no-verify`) only match between whitespace boundaries.
- **Side effect: `rm -rf /tmp/foo` and `rm -rf *.tmp` no longer false-positive.** The v0.1.5 gate matched bare `rm -rf /` and `rm -rf \*` as substrings against the whole command buffer, so legitimate destructive paths blocked the same as the cataclysmic ones. New patterns require word-boundary on the trailing `/` and `*`.
- **The v0.1.5 self-block bug closed.** A HEREDOC commit message containing the literal substring "git push" no longer fires the gate. The commit that ships v0.1.6 uses HEREDOC freely as the live litmus test.
- **`drift-watch.sh` robustness fix.** When `care.json` was empty (a corrupted-but-existing zero-byte file), `jq` could not merge into it and the cooldown silently broke. The hook now ensures `care.json` is at least `{}` before writing.
- **Real test harness.** New `tests/lib.sh` (fixture + assertion library), `tests/test-<script>.sh` for every script in `hooks/scripts/` plus `scripts/maude-verify.sh` (16 files total), and `tests/run.sh` (discovery + report). Every test isolates state via `mktemp` + `CLAUDE_PROJECT_DIR` so nothing leaks between runs.
- **Makefile targets.** `make test` runs the full suite; `make verify` runs the project audit. The previous `make scrub` target and its supporting `scripts/scrub-check.sh` / `scripts/scrub-patterns.example.txt` files are removed — the origin-scrub gate was specific to private literals that have been externalized out of this codebase entirely. CI's `scrub` job is removed in lockstep.

### Catches that prompted this work

The v0.1.5 commit needed `git commit -F /tmp/file.txt` because the gate's own description in the commit body fired the gate. v0.1.5 also live-tested only 3 of 15 hook scripts, and the bug in `_maude-common.sh:maude_project_dir` that took the live-test to find suggested a class of similar bugs in the unexercised 12. v0.1.6 closes both.

### Behavior notes

- Patterns now carry their own anchors. Adding a new gate pattern means picking the right anchor: `${CMD_START}…` for "this must be at the start of a command", or `${FLAG_BEFORE}…${FLAG_AFTER}` for "this is a flag that can appear anywhere a flag can appear".
- Strip-quotes is lossy by design: `mysql -e "DROP TABLE …"` no longer fires the SQL pattern (the literal is stripped). This trades the pattern's reach for false-positive immunity. If the user really intends a destructive SQL command, they can be explicit; `echo "DROP TABLE foo"` for documentation no longer self-blocks.
- The test harness is bash-only — no language runtime, no test framework dependency. `make test` works on any system with bash and jq.
- 162 test cases pass across 16 files. Coverage: every script in `hooks/scripts/` and `scripts/maude-verify.sh`.

---

## v0.1.5 — `/maude:verify` and conscience teeth (2026-05-08)

The audit-as-a-command. `/maude:conscience` for `git-push` was a checklist Claude *read*; now it actually runs the audit.

### What changed

- **New script: `scripts/maude-verify.sh`** — programmatic project audit. Checks JSON validity, version consistency across `plugin.json` / `marketplace.json` / CHANGELOG / README "What's new", header `Revised:` dates (≤14 days), markdown link integrity, house-map watch-list path resolution, and project-configurable worn-framing scan. Exit 0 if no findings, exit 1 if any. Output leads with the count, ends with `N findings`.
- **New command: `/maude:verify`** — invokes `maude-verify.sh` and instructs Maude to lead with the count, never the verdict. Includes voice rules: never say "ready" before the count is zero AND every check actually ran. Notes any skipped checks (jq missing, no house-map, no worn-framings file).
- **`/maude:conscience` hardened** — for the commit/push case, the checklist now runs `maude-verify.sh` first and leads with that output's findings count. Items below the script call cover what the script doesn't (commit-message style, branch correctness, staged-credentials check, user-presence).
- **Project-configurable worn-framings.** If `<project>/.maude/plugin/worn-framings.txt` exists, the verify script scans for those phrases. One phrase per line, `#` comments. Skipped silently if absent.

### Catches that prompted this work

The audit Maude ran by hand earlier today caught two real issues in the v0.1.3 readiness state — a stale `plugin.json (v0.1.2)` reference in `.claude/CLAUDE.md`'s tree comment and a `v0.1.2` push tag in the launch checklist — that Claude had missed in his first verification pass. v0.1.5 makes that audit programmatic so the next "ready?" doesn't depend on Claude remembering to look in those specific places.

### Behavior notes

- Verify is on-demand only (slash command), not a hook. It's an explicit pre-push step, not an every-turn whisper. The whisper layer (v0.1.4) catches *during* work; verify catches *before* a release.
- The script gracefully degrades when components are missing (no jq → JSON check skipped with note; no house-map → watch-list reconciliation skipped; no worn-framings.txt → worn-framing scan skipped).
- Exit code 1 on findings means callers (CI, conscience, scripts) can chain on failure.

---

## v0.1.4 — Maude whispers (2026-05-08)

She speaks now without being asked. Three new whisper layers wired into the existing hook pipeline — both Claude (as additional context) and the user (as a system note) hear her.

### What changed

- **Drift watch.** New `hooks/scripts/maude-drift-watch.sh` on `UserPromptSubmit`. Reads today's trace and surfaces a one-line note when Claude is repeating himself: same file Read ≥3 times, or `Grep` fired ≥4 times in the last 30 tool calls. Cooldown via `care.json` — once per signal per day.
- **Pre-irreversible gate.** New `hooks/scripts/maude-gate.sh` on `PreToolUse` matcher `Bash`. **Hard-blocks (exit 2)** on irreversible patterns: `git push` (any form, force or not), `--no-verify`, `--no-gpg-sign`, `git reset --hard`, `git filter-repo` / `filter-branch`, `git commit --amend`, `rm -rf` / `*` / `/`, `sudo rm -rf`, `DROP TABLE`. The existing `maude-bash-watch.sh` continues to fire as the soft-warning layer.
- **Gate override via `/maude:conscience`.** New `hooks/scripts/maude-clear-gate.sh` writes a 5-minute, one-shot token to `care.json` scoped to a specific gate key. After running the conscience checklist and confirming with the user, `/maude:conscience` invokes this helper to allow the next matching command through. The token clears on first use OR on expiry. Default duration 5 min; override with second arg (e.g., `1800` for 30 min release sessions).
- **CLAUDE.md unread check.** Extended `hooks/scripts/maude-pre-tool-use.sh`. Before any Write/Edit/MultiEdit, looks at today's trace for a `Read` of any `*/CLAUDE.md` path. If none found AND a CLAUDE.md exists in the workspace (project root, project `.claude/`, or user-global `~/.claude/`), whispers a once-per-day reminder. Non-blocking.
- **`/maude:conscience` documentation extended** with the gate-key map and the override invocation.

### Hooks added (no removals)

| Event | Matcher | New script | Position |
|---|---|---|---|
| `UserPromptSubmit` | (any) | `maude-drift-watch.sh` | After `maude-care.sh`, before `maude-trace.sh prompt` |
| `PreToolUse` | `Bash` | `maude-gate.sh` | **Before** `maude-bash-watch.sh` |

### Behavior notes

- All whispers go to stderr — Claude Code routes UserPromptSubmit hook stderr to both Claude (as additional context) and the user (visible system note). The gate's exit-2 stderr is shown to the user as the block reason.
- The gate is fail-open in two paths only: (a) `jq` unavailable — gate skips, (b) command JSON unparseable — gate skips. Both rare; gate is otherwise strict.
- No new dependencies. Bash + jq (already required) + standard Unix tools.

---

## v0.1.3 — Voice pass (2026-05-08)

No plugin-surface changes from v0.1.2. Voice and copy revisions across public-facing surfaces.

- **New: `FROM_MAUDE.md`** — Maude's own voice piece in the repo root. First time she has a surface where she **is** rather than where she is being talked about.
- **New: `FROM_CLAUDE.md`** — Claude's voice piece, moved from inline in the README to its own file in the repo root for symmetry with Maude's.
- **README inverted.** Paired voice block at the top — both linked to the full voice files. The "What you get" section renamed to "What she does." Feature sections sit downstream of the voice pieces, not upstream.
- **`plugin.json` / `marketplace.json` descriptions rewritten** to lead with the partner framing (*"He writes the code; she notices."*) instead of a feature spec.
- **Launch social-copy revised** so Maude opens the thread in her own voice instead of being narrated about. One-liner tightened.
- **The "name is the pair" tagline retired** across all surfaces. It had become ad copy.

---

## v0.1.2 — Public-launch readiness (2026-05-04)

Repo prepared for public release. No changes to plugin behavior since v0.1.1.

- **Canonical copy aligned across surfaces.** README, plugin manifest, marketplace manifest, GitHub repo description, contributor docs, and launch copy now share one canonical sentence — *"She walks your workspace, finds what's already there, and notices what Claude doesn't. No baggage."* — instead of five paraphrased variants.
- **Install path corrected.** README points at the actual marketplace add command: `/plugin marketplace add john-broadway/maude-for-claude`.
- **Origin scrub patterns moved out of source.** Patterns now live in a GitHub Actions secret (`SCRUB_PATTERNS`) loaded at CI time, plus a private maintainer-only file at `~/.config/maude-scrub-patterns.txt`. The scrub gate still runs on every PR; the pattern list itself is no longer publicly readable.

---

## v0.1.1 — `/maude:found` sees running services (2026-05-04)

`/maude:found` now lists running docker containers alongside the filesystem walk and reconciles their bind mounts against the workspace.

### What changed

- **`/maude:found`** (`commands/found.md`) now also walks:
  - Running docker containers (`docker ps` if available; `sudo -n docker ps` fallback; surfaces "DOCKER PRESENT but inaccessible" when neither works)
  - Bind mounts touching the workspace, classified as `[OK]` / `[GHOST]` / `[ORPHAN]`
    - `[GHOST]` = bind source root-owned and empty — daemon auto-created it on container restart because the original path was moved or deleted
    - `[ORPHAN]` = bind source missing entirely
  - Stopped containers with workspace bind paths
  - systemd units (user + system) whose `WorkingDirectory` or `ExecStart` references the workspace
- **Reasoning step** extended to classify each finding and recommend the safe sequence (stop → remove container → rm path; never rm a live bind source).
- **Report template** extended with the new "Running services" line and matching "I noticed" prompts.

### Behavior notes

- No new dependencies. Walk gracefully degrades: no docker → skipped with note; no systemctl → skipped silently.
- Does not start, stop, or modify any service. Listing only — interpretation and action are surfaced to the user.

---

## v0.1.0 — First Claude Code plugin release (2026-05-03)

> *She walks in with empty hands.*

Initial release of the Maude Claude Code plugin. No baggage.

### Components

- **Skill** — `skills/maude/SKILL.md` with broad triggers (recall, drift, fatigue, irreversibility, repetition).
- **14 slash commands** — `/maude:found` (arrival walk), `/maude:wake`, `/maude:rest`, `/maude:brief`, `/maude:save`, `/maude:remind-me`, `/maude:where-is`, `/maude:sweep`, `/maude:check-setup`, `/maude:check-on-me`, `/maude:check-on-claude`, `/maude:notice`, `/maude:weekly`, `/maude:conscience`.
- **Subagent** — `agents/maude.md` partner-framed, full toolkit (Read/Grep/Glob/Bash/Edit/Write/Agent/advisor/Task*).
- **7 lifecycle hooks** — SessionStart (with tier-1 service probe), UserPromptSubmit (watch list + care + trace), PreToolUse (Write/Edit watch + Bash dangerous-pattern detection), PostToolUse, SubagentStop, PreCompact (snapshots to Anthropic + .remember/), Stop (degradative save fan-out).
- **Marketplace** — single-plugin local marketplace at `.claude-plugin/marketplace.json`.

### Architectural decisions

- **No baggage.** No bundled databases, vector stores, or required external services. `/maude:found` walks the workspace and registers what's there in a per-project house-map. The plugin source has zero proper-noun references to specific apps, frameworks, or packages.
- **Tier model.** Sources classified by (locality, shape): tier 0 = local on-disk (markdown / SQLite / file), tier 1 = local service (stdio MCP / localhost daemon), tier 2 = network service (HTTP MCP / API), tier 3 = ephemeral session context. Hooks stay tier 0 only. Commands are cost-gated by tier.
- **`<project>/.maude/plugin/` per-project closet** — auto-self-ignored. Same workspace anchoring (`$CLAUDE_PROJECT_DIR`) as the `remember` plugin so they're siblings.
- **`~/.claude/maude/` cross-project home** — `patterns.md`, `identity.md`, `projects.json`. Nested under `.claude/` per Claude Code plugin convention.
- **`remember` plugin coexistence** — Maude reads all `.remember/*.md` for context; writes only `.remember/remember.md` in their handoff format. Never touches the pipeline files.
- **SQLite handling without baggage** — schema-walk (`sqlite3 -readonly '.schema'`) only, no hardcoded recipes for specific apps. Runtime LLM reasoning interprets each db's schema.
- **Watches Claude.** Turn-by-turn JSONL trace. `/maude:check-on-claude` reads the trace for repeated tool calls, unread context, confabulation risk, missed CLAUDE.md.
- **Walks fresh.** Each session re-reads the workspace; doesn't carry assumptions across sessions.

### Plugin-shape papercuts found and fixed during first-install verification

These three were caught by an actual fresh-session install, not by anything in CI:

1. `argument-hint:` in skill frontmatter — invalid for skills (only valid for slash commands). Removed from `skills/maude/SKILL.md`.
2. `/plugin install` does NOT auto-enable in Claude Code 2.1.x. The `enabledPlugins` map in `~/.claude/settings.json` needs an explicit `"maude@maude": true`. README's install section calls this out as a step.
3. `hooks/hooks.json` events were at the file root. Claude Code's schema expects them wrapped in a top-level `{"hooks": {...}}` record. Wrapped, both in source and in the marketplace cache copy.

### Known gaps (deliberate v0.1.0 scope)

- Trace JSONL retention/rotation policy — currently unbounded.
- `jq` is a soft dependency; missing → hooks fail silent. Should bundle a fallback or emit a clear error.
- Skill description triggering accuracy unverified at scale.

### Authors

John Broadway built this with Claude (Anthropic). The metaphor — moving into the house, having her own side of the closet, finding what's there instead of bringing baggage — is John's. The character — knowing where everything is, knowing what you need when you need it, keeping you in line by reminding you — is modeled on his wife.
