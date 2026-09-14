<!-- Version: 0.32.0 -->
<!-- Created: 2026-09-03 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# The rules rail — she checks the work against the named laws

## Why

John, 2026-09-03: *"maude needs to make sure claude follows rules. especially the 30 ux
ones. the codd rule for db desing including 1nf 2nf and 3nf. at a minium"* — and minutes
later, *"there is also the laws of memory human and machine."*

The day before he had told a UI build to "use UX laws". That design named six of the
thirty by name and its probe swept a 3 by 3 grid across every button it checked (Fitts).
It worked because a person said the words at the right moment. Nothing in the house says
them when nobody remembers to: the laws live on a website and in textbooks, and nothing
consults either at the moment Claude writes a `CREATE TABLE`, a button, or a cache.

Knowledge in a file is a diary. A hook is a rail. This is the redteam-watch lesson applied
to three bodies of design law: the rail fires at the moment the work touches the class the
law governs, once, and again at the commit if the law was never named.

## What was read, not remembered

- **The thirty Laws of UX.** Live read of lawsofux.com on 2026-09-03: the homepage renders
  thirty law cards. A first slug regex counted 29 because one slug is percent-encoded
  (Law of Prägnanz). The list below is the live one, with the fetch date pinned.
- **Codd's twelve rules** are thirteen, numbered 0 to 12 (Computerworld, October 1985). They
  evaluate a database management *system*, not a schema. The rules a schema's own text can
  honour or break are 1 (values in tables, one way), 2 (every value reachable by table,
  key, column), 3 (missing means NULL, systematically) and 10 (integrity constraints live in
  the catalog, not the application). Rule 12 is touched when application code bypasses the
  declared constraints. The rulebook carries all thirteen because they were asked for; the
  linter enforces the schema-touching subset plus the normal-form floor and says which. A
  docstring the code falsifies is worse than none.
- **"The laws of memory, human and machine"** has no canonical published list the way the
  UX laws do. The vault, this repo and the tape hold nothing by that name. Section 3.3 is a
  source-cited draft. It becomes canon on his word, not on this file.

## 1. The shape

Three rulebooks, one rail, one linter, one command, one verify check.

**Scope: everything we develop.** His words, 02:59Z the same night: "its also for everything
we develop." The rail is not a Maude-repo rule. Maude's hooks fire in every workspace she is
installed in, so the classify, stamp and check run wherever a schema, a UI surface or a
memory surface is written: every repo in this estate and every adopter's. The rulebooks are
product laws that travel with her; nothing in them names this house's projects.

**And for the users.** His next line, 02:59Z: "and for the users." Two readings, both
held. The adopters: she is released to the world because "everything I ask of our
relationship we put into maude", so the rail and all three rulebooks ship in the plugin and
run for every user's Claude, not only ours. The people using what we build: the UX laws and
the human half of the memory laws are laws about *them*, and every `ask` in those two
rulebooks is asked on the user's behalf, never on the builder's.

| piece | what | where |
|---|---|---|
| rulebooks | static data, stdlib-readable, zero egress | `rules/laws-of-ux.json` · `rules/codd-and-normal-forms.json` · `rules/laws-of-memory.json` |
| rail | classify on Write/Edit, check on `git commit`, stamp when a design names laws | `hooks/scripts/maude-rules-watch.sh` |
| linter | Codd subset + 1NF/2NF/3NF over `CREATE TABLE` text | `maude_rules/schema.py` (python3 stdlib) |
| command | print a rulebook as a naming checklist; run the linter | `commands/rules.md` + `scripts/maude-rules.sh` |
| verify | linter findings and unnamed classes count as findings | a `## Design rules` section in `scripts/maude-verify.sh` |

No `hooks.json` change. Registry entries are cold until `/reload-plugins`, which is how the
mission rail sat dead for twenty days. `classify` is called from `maude-post-tool-use.sh`,
`check` from `maude-bash-watch.sh` beside the redteam call, and both of those already fire.

## 2. The rulebooks

Each file is a JSON object: `name`, `source` (URL or citation), `read_on` (ISO date of the
live read), `floor` where one applies, and `laws[]` of `{id, name, aliases[], ask, url}`.
`ask` is Maude's own one-line question in her words. The descriptions on the source sites
are their authors' text; none of it ships in the file. `aliases` is what the stamp detector
matches ("Fitts", "Hick", "Pragnanz" without the diaeresis, "3NF").

### 2.1 `rules/laws-of-ux.json` — thirty entries, read 2026-09-03

Aesthetic-Usability Effect · Choice Overload · Chunking · Cognitive Bias · Cognitive Load ·
Doherty Threshold · Fitts's Law · Flow · Goal-Gradient Effect · Hick's Law · Jakob's Law ·
Law of Common Region · Law of Prägnanz · Law of Proximity · Law of Similarity · Law of
Uniform Connectedness · Mental Model · Miller's Law · Occam's Razor · Paradox of the Active
User · Pareto Principle · Parkinson's Law · Peak-End Rule · Postel's Law · Selective
Attention · Serial Position Effect · Tesler's Law · Von Restorff Effect · Working Memory ·
Zeigarnik Effect.

Each carries its lawsofux.com URL. The `ask` lines are ours, for example Fitts: *"is every
control pressable across its whole box, and is the box big enough to hit?"*; Hick: *"how
many choices does this screen put in front of someone at once?"*; Doherty: *"does anything
between the click and its effect take longer than four hundred milliseconds?"*

### 2.2 `rules/codd-and-normal-forms.json`

- Codd 0–12, each with its name, our paraphrase, and a `schema_touching: true|false` flag.
- Normal forms 1NF, 2NF, 3NF flagged `floor: true`; BCNF, 4NF, 5NF flagged `floor: false`
  with the note "above the floor: say when you stop short and why".
- `floor: 3` at the top. `MAUDE_NF_FLOOR` can raise it in a later rung; v1 has no checks
  above 3NF, so raising it only changes the whisper's wording.

### 2.3 `rules/laws-of-memory.json` — looked up 2026-09-03, awaiting his cut

His second ask, the same night: "look up the laws of memory for humans and machine." Looked
up, not recalled. There is no single canonical list by that name on either side. What exists,
read from the sources on 2026-09-03 (every URL and fetch status is in the house vault; a
source marked "excerpt" refused the fetch and is cited from its abstract page):

**Human: three published lists and four classical laws.**

| source | the list |
|---|---|
| Kahana, Diamond & Aka, "Laws of Human Memory" (PsyArXiv, draft 2022-07-01) | five candidate laws: **recency, contiguity, similarity, primacy, repetition**; "apparent violations occur when different effects come into conflict, as in opposing physical forces" |
| Surprenant & Neath, *Principles of Memory* (2009) | seven principles: **cue-driven, encoding–retrieval, cue overload, reconstruction, impurity, relative distinctiveness, specificity** |
| Schacter, "The seven sins of memory" (American Psychologist 1999; update, Memory 2022) | **transience, absent-mindedness, blocking, misattribution, suggestibility, bias, persistence** |
| Ribot 1881 and Jost 1897, via Wixted (Psychological Review 2004) | Ribot: the newest memories are the most fragile, so memories need time to consolidate. Jost: of two memories of equal strength, the older decays more slowly and gains more from one more repetition |
| Ebbinghaus 1885 | the forgetting curve; the spacing effect |
| Miller 1956; Cowan's revision | working memory holds about seven plus or minus two chunks; about four on the later estimate |

**Machine: the published rules of the memory hierarchy.**

| source | the rule |
|---|---|
| Denning, "The Locality Principle" (CACM 2005) | programs cluster references to small subsets of their address space for extended periods; everything from caches to working sets follows |
| Gray & Putzolu 1985; Gray & Graefe 1997; Graefe 2007 | the five-minute rule: cache a randomly accessed page that is re-used within five minutes (one minute for sequential); the interval moves with the price ratio of memory to storage |
| Gray & Shenoy, "Rules of Thumb in Data Engineering" (ICDE 2000) | Amdahl's balanced-system law (a bit of IO per second per instruction per second), memory law (MB per MIPS about one, rising), IO law (one IO per 50,000 instructions); the rules are folklore that must be re-measured as the technology moves |
| Little 1961 | L = λW: what is in the system equals arrival rate times time spent |
| Bélády 1969 | the anomaly: more memory can mean more faults under a bad replacement policy; a good policy never gets worse with more |
| Wulf & McKee 1995 (excerpt) | the memory wall: processor speed outruns memory speed until the processor is always waiting on memory |
| write-ahead logging (ARIES family) | the log reaches stable storage before the data change it describes |
| Kreps 2013, "The Log" (excerpt) | an append-only, totally ordered log is the simplest storage abstraction, and every other copy is a follower derived from it |
| Karlton, via Fowler | cache invalidation is one of the two hard things |

**Agent memory: the 2023 to 2026 literature.**

| source | the rule |
|---|---|
| CoALA (Sumers, Yao, Narasimhan, Griffiths 2023) | working memory plus long-term episodic, semantic and procedural memory; the tape already sits on this |
| "Memory in the Age of AI Agents" (survey, arXiv 2512.13564) | three axes: forms (token-level, parametric, latent), functions (factual, experiential, working), dynamics (formation, evolution, retrieval) |
| "Remember the Decision, Not the Description" (arXiv 2605.10870) | keep the distinctions between histories that change a decision, not descriptive accuracy about the past |
| SSGM, "Governing Evolving Memory in LLM Agents" (arXiv 2603.11768) | the risks: leakage into persistent storage, semantic degradation from repeated summarisation, corruption; the mechanisms: verify consistency before consolidation, decay by age, control what enters long-term memory |
| "Are We Ready For An Agent-Native Memory System?" (arXiv 2606.24775) | four modules (representation and storage, extraction, retrieval and routing, maintenance); no architecture dominates; localized maintenance beats global reorganisation |
| Mem0, State of AI Agent Memory 2026 (2026-04-01) | write asynchronously; retrieve on several signals; record who wrote each memory; keep high-relevance facts fresh while low-relevance ones decay; token cost is a first-class axis |

**This house's own, earned.** Append, never overwrite, and read back · a window is not a
history · the index is not the content · move the source of truth and let followers follow ·
promotion is his: his words and an inference are never the same row · supersede, never erase.

**The rulebook I propose from these, for him to cut.** Each `ask` is ours; each entry carries
its source line from the tables above.

| # | law | ask |
|---|---|---|
| 1 | Recency and primacy (Kahana; Ebbinghaus) | is the important thing first or last, never buried in the middle, and is the recent thing findable? |
| 2 | Contiguity and similarity (Kahana) | is it stored next to what it will be recalled with, and is a look-alike that must stay separate kept separate? |
| 3 | Repetition and spacing (Kahana; Ebbinghaus) | is a thing that must stick re-surfaced on a schedule, not re-read once? |
| 4 | Cue-driven, encoding–retrieval (Surprenant & Neath) | is it stored under the cue it will be asked for under? |
| 5 | Cue overload and relative distinctiveness (Surprenant & Neath) | how many things share this cue, and does this one stand out among them? |
| 6 | Reconstruction and impurity (Surprenant & Neath; Schacter's misattribution and bias) | is a recalled thing marked as recalled, and does it carry its provenance? |
| 7 | Jost and Ribot | is the newest memory treated as the most fragile, and does consolidation get time before anything is trusted? |
| 8 | Working memory is small (Miller; Cowan) | how many things does this ask a person, or a context window, to hold at once? |
| 9 | Locality (Denning) | is the hot set small and near, the cold set cheap and far? |
| 10 | The five-minute rule (Gray) | what is re-used often enough to stay resident, and was that interval measured, not assumed? |
| 11 | Little's law | how much is in flight, and for how long? |
| 12 | Bélády | can adding memory make this worse under the policy chosen? |
| 13 | The memory wall (Wulf & McKee) | what waits on memory, and how often? |
| 14 | The log first (write-ahead logging; Kreps; this house) | is the write appended and read back before it is trusted, and is every other copy a follower? |
| 15 | Cache invalidation (Karlton; this house) | which copy is canon, and does every other copy know when it went stale? |
| 16 | Tiering (CoALA; the survey's three axes) | which tier and which function does this live in, and what promotes it? |
| 17 | Remember the decision (arXiv 2605.10870) | does what is kept preserve the distinctions that change a decision? |
| 18 | Governed consolidation (SSGM; Mem0) | is consistency verified before consolidation, does age decay it, and is what enters long-term memory controlled and attributed? |
| 19 | A window is not a history (this house) | does the reader know how far back it can see? |
| 20 | The index is not the content (this house) | does the index carry pointers only? |
| 21 | Promotion is his (this house) | whose words are these, and who may promote them? |
| 22 | Supersede, never erase (this house) | is a retired fact retired by a pointer, or by an erasure? |

Nothing here is canon until his word. The stamp detector for the memory class ships with
whatever survives his cut, and every entry's `url` is the one read on 2026-09-03.

## 3. The rail — `maude-rules-watch.sh`

### 3.1 `classify` (PostToolUse · Write/Edit/MultiEdit)

Reads the envelope once. From `file_path` and the written text (`content` for Write,
`new_string` for Edit), decides a class or none:

| class | by path | by content marker |
|---|---|---|
| `ui` | `.html .htm .css .scss .sass .less .vue .svelte .jsx .tsx .astro .qml`, templates (`.j2 .jinja .hbs .ejs .erb .tmpl`), path segments `/ui/ /components/ /views/ /templates/ /pages/` | `<button`, `<form`, `<input`, `onClick`, `addEventListener(`, `ImGui`, `imgui`, `tkinter`, `QWidget` |
| `schema` | `.sql .prisma .dbml`, path segments `/migrations/ /alembic/ /schema/` | `CREATE TABLE` in any language's string, `Column(`, `models.Model`, `SQLModel`, `Schema::create(` |
| `memory` | `MEMORY.md`, path segments `/memory/ /.remember/`, file stems `memory cache store tape vault` | `lru`, `ttl`, `evict`, `consolidat`, `retention`, `supersed`, `forgetting` |

Content markers match as identifiers with word boundaries: `ttl` never matches `throttle`,
`lru` never matches `pluralise`, `store` never matches `restore`. Path markers match whole
path segments or the file's stem, never a substring of a name. The same rule holds for the
`ui` and `schema` markers.

The ORM markers (`Column(`, `models.Model`, `SQLModel`, `Schema::create(`) are ordinary
identifiers in prose and in other languages, so they only count in a file whose extension is
`py`, `php`, `js`, `ts` or `rb`. A create-table statement still counts in any file: a schema
inside a string literal is a schema whatever the host language is.

The rail scans text and the rail is text, so every marker literal in
`rules_class_by_content` is written with one letter inside a one-character bracket. The
pattern matches a real marker and never itself, and a test writes the whole script through
`classify` to hold that true.

Classification may be a little generous: a wrong class costs one whisper per session per
class. The stamp (3.2) may not be, because a false stamp is a false all-clear.

**Fixtures are not surfaces.** Paths under `tests/` or `fixtures/`, and files named
`test_*`, `*_test.*` or `*.spec.*`, are never classified by the rail and never linted by
verify. This design's own planted `CREATE TABLE` bodies would otherwise spring the rail on
this repo the day they land: documenting a trap springs it. The boundary is deliberate and a
lens should be told so; a real schema living under `tests/` is a smell the rail declines to
police.

On the FIRST touch of a class in this session, one whisper to stderr:

> Maude: `orders.sql` declares a schema. Codd's rules and third normal form are the floor —
> name the forms each table holds to. `/maude:rules db` lists them.

> Maude: `race-card.html` is a UI surface. The thirty Laws of UX apply — name the ones this
> holds to, by name, in the design. `/maude:rules ux` lists them.

> Maude: `tape.py` is a memory surface. The laws of memory, human and machine, apply — name
> the ones this holds to. `/maude:rules memory` lists them.

Every touch, whispered or not, is recorded in `care.json` under
`.rules[sid].touched.<class>[]` (deduplicated, bounded to the last 50 paths). The check
reads only that store; the trace is not widened.

For `schema`, classify also runs the linter on the file as it now sits on disk (the write
has landed; that is the one copy) and whispers findings every time the finding set changes,
not once: findings are signal.

> Maude: `orders.sql` — 2 findings: `orders` has no PRIMARY KEY (Codd 2);
> `orders.customer_name` beside `customer_id` repeats `customers.name` (3NF).

### 3.2 `stamp` (inside `classify`)

A Write/Edit whose written text carries BOTH a heading line naming the rulebook
(`(laws? of ux|ux laws?)`, `(normal forms?|codd)`, `(laws? of memory)`, case-insensitive)
AND at least one canonical name or alias from that rulebook, both inside the section that
heading opens, stamps `.rules[sid].named.<class> = {ts, file, laws[]}`.

The rulebook's phrase matches on word boundaries: line start or a non-alphanumeric before
it, a non-alphanumeric or end of line after. `## Redux laws` is not a UX-laws heading; `##
The UX laws this holds to` is.

The only stamp source is prose: `.md .markdown .txt .rst .adoc`. The wider doc set that is
never a touch (json, yml, toml, lock, csv, svg, png, pdf, LICENSE and friends) is never a
stamp either, and is not read at all: a lockfile costs nothing and a binary is never
opened. A design doc that is a fixture (under `tests/` or `fixtures/`, or named `test_*.md`)
can never stamp.

Heading alone does not stamp. A law name alone does not stamp. A commit message never
stamps: `-m "fitts"` is the cheapest false all-clear there is, and no one reviews it.
Files only, which is where a design or a spec lives.

### 3.3 `check` (PreToolUse · Bash, on `git commit`)

For each class: **touched this session AND never named this session** → one whisper, once
per class per session at the check, re-armed only by a new touch of that class after the
last whisper. Three commits in a row must not produce three identical lines; that is the
switch-off failure the redteam-watch header warns about.

> Maude: 3 UI file(s) changed this session and no design names a Law of UX. Name the ones
> this holds to before you call this done. `/maude:rules ux`.

This predicate differs from redteam-watch on purpose. Redteam asks "edits since the last
stamp" because a review must come after the work. Here the design comes BEFORE the build,
so the stamp legitimately precedes every edit; copying the redteam predicate would whisper
falsely on the normal order.

For `schema`, the check also re-runs the linter over the schema files touched this session
as they sit on disk now and whispers the current finding count.

Docs-only classes are not touched: a Markdown edit is where the stamp lives, never a touch.

### 3.4 What it never does

Whisper only. A commit is reversible; gates are for the irreversible. Silent without `jq`
(like redteam-watch). Inert under `MAUDE_EYE_BLINK=1` (the recursion guard, by sourcing
`_maude-common.sh`). Per-session by the same 8-character session id `maude-redteam-watch.sh`
derives from the envelope; a sibling lane's UI edit never whispers into mine.
`MAUDE_RULES=off` silences the whole rail. A session's state ages out of care.json after seven days (`MAUDE_RULES_STALE_DAYS` overrides the number), pruned by the rail itself on its next run.

It also never remembers forever. Both `classify` and `check` prune every `.rules` entry
whose newest timestamp across `last_touch`, `whispered`, `named.*.ts` and `checked` is more
than seven days old, so a lane that ran once in April is not still an unnamed class in
September. The cutoff comes from the portable epoch helpers in `_maude-common.sh`, never
from `date -d`, which is GNU-only.

### 3.5 Two repairs in the files it lands in

- `maude-post-tool-use.sh` exits at `maude_have_map || exit 0` before doing anything. The
  rules call goes ABOVE that line, or a project with no house-map never gets the rail.
- The same file runs `jq` on stdin twice; the second read gets an empty stream, so `TOOL` is
  always empty and the trace's `write` default has been masking it. Read stdin once into
  `INPUT` and pipe, as pre-tool-use already does.
- `SEP`, `COMMIT_RE` and `DOC_RE` are duplicated verbatim in verify-watch and redteam-watch
  "so they agree". A third copy is the drift the comment warns about: hoist them into
  `_maude-common.sh` in this build and point all three rails at one definition.

## 4. The linter — `maude_rules/schema.py`

Python 3 stdlib only, like the vault and the tape. Input: file text. It extracts every
`CREATE TABLE [IF NOT EXISTS] name (...)` whether the file is SQL or the statement sits in
a string literal of any language, and parses columns (name, type, inline constraints) and
table constraints (`PRIMARY KEY (...)`, `FOREIGN KEY ... REFERENCES`, `UNIQUE (...)`).

| check | fires when | rule | level |
|---|---|---|---|
| no key | no `PRIMARY KEY` and no `UNIQUE NOT NULL` column | Codd 2 | finding |
| repeating group | two or more columns share a stem with a numeric suffix (`phone1, phone2`; `sales_2024, sales_2025`) | 1NF | finding |
| multi-valued column | name ends `_list _csv _json` or is `tags emails phones`; or type is `JSON JSONB ARRAY SET` | 1NF | ask |
| partial dependency | composite primary key and at least one non-key column | 2NF | ask ("state that every non-key column depends on the whole key") |
| transitive column | `<t>_<attr>` beside `<t>_id`, where table `<t>` or `<t>s` in the same text has column `<attr>` | 3NF | finding |
| integrity in the app | `<x>_id` with no `REFERENCES`, where table `<x>` or `<x>s` exists in the same text | Codd 10 | finding |
| sentinel default | `DEFAULT` of `'N/A' 'none' 'null' 'unknown' -1` | Codd 3 | ask |

`finding` is objective and counts in verify. `ask` is a question the whisper does not
raise on its own; `/maude:rules db` and verify list asks under their own heading.

Output: one line per hit, `table.column — text (rule)`. As a library it never raises; as
`python3 -m maude_rules schema <path>...` it exits 1 when there is at least one finding, so
verify and the ship rail can read it.

`--brief` says `PATH: clean` for a file the linter judged and `PATH: no CREATE TABLE found`
for a file it had nothing to judge. Those are different claims and calling an ALTER-only
migration clean is a pass the linter never earned; the rail neither whispers nor stores the
second, and verify does not count it. `--count` prints `PATH: N table(s)` and always exits
0: it says what was READ, so verify's line can be `N tables in M schema files linted` rather
than a file count that hides whether anything was looked at.

A table-level clause is recognised by SHAPE (a keyword, an optional index name, then a
paren), not by prefix. `UNIQUE (cols)`, `UNIQUE KEY name (cols)` and `UNIQUE INDEX name
(cols)` are unique groups; bare `KEY name (cols)` and `INDEX name (cols)` are indexes, which
say nothing about uniqueness and are ignored. A constraint name may be quoted and may carry
spaces.

Limits, stated in the module docstring so the code and the words agree: no dialect parser;
it cannot see functional dependencies, so 2NF and 3NF are name-shape heuristics and a false
hit costs one whisper; an unquoted column literally named `key`, `check`, `index` or
`unique` whose type carries a non-numeric parameter still reads as a clause (a numeric one
does not); ORM models, Prisma and DBML are later rungs (the rail classifies them today, the
linter does not read them); nothing above 3NF exists in v1.

## 5. `/maude:rules` and verify

- `/maude:rules ux|db|memory` prints that rulebook as a naming checklist, one line per law,
  the `ask` beside the name.
- `/maude:rules db <path>` runs the linter and leads with the count.
- `/maude:rules` with no argument reads `care.json` and says which classes this session
  touched and which are still unnamed.
- `scripts/maude-verify.sh` gains `## Design rules`: linter findings over the project's
  `*.sql`, plus this session's unnamed touched classes. They count in `N findings`, so
  `/maude:conscience` says wait, and asks are listed but not counted.
- Only THIS session's unnamed class is a finding. With `CLAUDE_CODE_SESSION_ID` set, that
  sid alone counts; every other sid, and every sid when there is no session id at all, is
  printed as an informational `note:` line and counted as nothing. A release run carries no
  session context and must not be jammed by a sibling lane working in the same tree.

## 6. Whisper or refuse — his call

House law: whisper at the commit. If "make sure" is to mean a refusal, the place is the ship
rail: `scripts/ship.sh open --review` already refuses without a redteam stamp newer than the
shipped tip, and can refuse the same way when the shipping diff carries UI, schema or memory
files and this session holds no naming stamp for that class. Not built until he says.

## 7. Tests — every check must be able to fail

- `tests/test-rules-watch.sh` (ends with the summary line and `exit "$FAILED"`): class by
  extension, by content marker, by path segment; a second edit of the same class is silent;
  another `sid`'s edit does not whisper for mine; stamp needs heading AND name (heading
  alone: none; name alone: none; commit message: none); check whispers when touched and
  unnamed; check is silent when the stamp came BEFORE the edits; docs-only is silent;
  `MAUDE_RULES=off` is silent; inert under blink; silent without `jq`; wiring rows prove
  post-tool-use calls classify above the map guard and bash-watch calls check with stderr
  delivered (the 2084-fires-into-a-void lesson).
- `tests/rules/test_schema.py`, wired into `make test-py`: for every check one planted
  schema that MUST produce the finding and one clean schema that MUST stay silent (the
  tape's own row: the clean input caught the bad regex, not the planted one); extraction
  from SQL, Python, Lua and JavaScript string literals; `UNIQUE NOT NULL` counts as a key;
  multi-table 3NF and Codd 10 cases; `IF NOT EXISTS` and quoted identifiers.
- The suite-wide tests already in place constrain the new script: it must be inert under
  blink and carry no GNU-only construct outside a `# portability-shim` line.

## 8. Ship

README bullet under "What she does around the house"; CHANGELOG entry; PRIVACY unchanged
(the rulebooks are static, the no-socket tripwire still covers the package). MINOR version
at build time, not here. Order: this spec → his go → linter first, TDD → the rail → command
and verify → adversarial rounds → canon → ship rail → his `!`.

## 8a. The laws this build holds to, by name

John, 03:59Z: "have you applied the laws to maude." The sections below are the stamp the rail
itself reads: a heading naming the rulebook and the canonical names inside it.

### UX laws

Maude's user interface is a whisper line and a command's output. The laws it holds to:

- **Miller's Law**, **Cognitive Load**, **Working Memory**: one whisper is one line, and a
  finding whisper names at most two findings before "+K more".
- **Serial Position Effect**: the count leads; the file name leads the whisper.
- **Von Restorff Effect**: she speaks once per class per session, so the line that appears
  is the one that differs from silence.
- **Doherty Threshold**: every hook call returns inside its 5-second registry timeout; the
  linter runs on one file, never the tree.
- **Postel's Law**: classify accepts any envelope shape (Write, Edit, MultiEdit, a missing
  field) and sends one line or nothing.
- **Jakob's Law**: the rail has the same shape as the redteam rail (stamp, check, whisper,
  care.json, per session), so a reader of one already knows the other.
- **Hick's Law**: one command, three seats; no flags to choose between.
- **Zeigarnik Effect**: a class touched and never named stays visibly unfinished, at the
  commit, in verify, and in the wake brief.
- **Tesler's Law**: the complexity that cannot be removed (classification, the stamp, the
  per-session store) lives in one script.
- **Paradox of the Active User**: the whisper carries the command that lists the laws, so
  nobody has to have read this document.

### Normal forms

The linter's own first run, 2026-09-03 03:59Z, over Maude's own schemas: six tables
extracted (the tape's `rejections`, `canon`, `events`, `voice`, `voice_profile`; the
vault's `notes`), every one keyed, zero findings, zero asks, and the same extractor fires
codd-2 on a planted keyless table in a Python string, so the clean result can fail. That
zero was the linter's, not the tables': a document column named `json` sat outside its
name list, and a self-reference that does not end in `_id` was invisible to the Codd 10
check. Both were named that hour and closed on 2026-09-06, when John asked whether the
laws had been applied to her or only added. The second run, over the live tape and vault
schemas on the dev box: four asks, zero findings, each answered below; and
`tests/rules/test_schema.py` holds her own two schema files as the control, so a linter
that goes blind to her again goes red.

- **1NF**: every cell in five of the six tables is one value. The sixth, `voice_profile`,
  is one row holding one JSON document (`json TEXT`), by design: derived, regenerable,
  recomputed whole, never edited by hand. That is the multi-valued-column ask, answered:
  it is a document, not relational data. `canon.embedding TEXT`, added in place by
  `maude_tape/tape.py` when a home brings its own embedder, is a vector: its one consumer
  reads it whole and never by element, so it is atomic to every query that touches it,
  and SQLite has no vector type. The vault's `notes.links TEXT` is a note's link list as
  the note wrote it; the vault is a follower of the markdown, never the canon of links,
  and rows for links would be a second copy of a fact the file owns. The linter now
  raises all three as asks (a column named `json`, `embedding` or `links` is on its name
  list, whole, not only as a suffix), and this paragraph is the answer.
- **2NF**: every key is a single column, so no partial dependency can exist.
- **3NF**: each non-key column depends on its own row's id and nothing else. `events` and
  `canon` are separate relations (a buffer awaiting consolidation, and the canon), each
  holding its own text; nothing is copied between them. `canon.superseded_by` is a
  self-reference to `canon.id` declared without REFERENCES. The linter now raises it as
  the Codd 10 ask (an integer column named `<x>_by` with no REFERENCES names a row without
  saying which table). The answer is a debt, stated: the chain's integrity is kept by
  `supersede()` in `maude_tape/tape.py`, which is the application, not the catalog; the
  tape does not set `PRAGMA foreign_keys`, and SQLite cannot add a constraint to a column
  that already exists (ADD COLUMN may carry REFERENCES; an existing column needs the table
  rebuilt), so closing the debt is a migration on every adopter's tape. John's call, not a
  whisper's.
- **Codd 2**: every value is reachable by table, key and column, which is what `wake` and
  `recall` do.
- **Codd 10**: the FTS index is derived from `notes` and rebuilt from it, never edited.
- The rail's own store, `.rules[sid]` in care.json, is a document keyed by session, not a
  relation; it holds no fact that lives elsewhere, and is stated here as such rather than
  claimed normal.

### Laws of memory

The rail's state is a small memory system, so the draft rulebook is applied to it first:

- **Provenance and authority** (promotion is his): every read and write is keyed by session
  id, and the stamp records which file named which laws.
- **Working memory is small** (Miller, Cowan): the touched list is unique and bounded to the
  last fifty paths.
- **Cue overload**: one whisper per class per session; a second touch of the same cue is
  silent.
- **Recency and primacy** (Kahana): the check compares the last touch against the last
  whisper, and a new touch re-arms it.
- **Supersede, never erase**: a file's findings string is replaced, and "clean now" is said
  once when it changes.
- **Consolidation before trust** (Jost, Ribot; the log first): a stamp is written only from
  a file that landed, never from a commit message that has not.
- **A window is not a history**: the state is per session; the wake brief says which
  classes last session left unnamed rather than pretending to a longer memory.
- **Locality** (Denning): the rulebooks are read from the plugin directory beside the
  script, and the linter reads one file, the one just written.

## 9. Open — his word

1. The laws-of-memory draft in 2.3: cut, add, or point at the list he means.
2. Whisper at the commit (house law, the default here) or a ship-rail refusal (section 6).
3. UI breadth: the table in 3.1 includes Lua UI and ImGui; widen or narrow.
