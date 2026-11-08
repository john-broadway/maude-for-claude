<!-- Version: 0.36.0 -->
<!-- Created: 2026-10-24 CDT -->
<!-- Revised: 2026-11-08 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# The seeing-gap, and the memory tiers under it: design

**Rule for this document:** text in quotation marks attributed to John is his, verbatim, with its date (UTC) and, where the tape holds it, the session it was typed in. Everything else is Claude's.

## The one rule (the problem)

John, 2026-10-24, naming what Maude is for:

> She's the spine for you. shes the one that holds rules about howto do x; coding, design, etc. she's the one that keeps your 50 first dates alive. shes the one that know when youre not seeing the user the same way they see you. she is the governance.

The **seeing-gap** is Claude's picture of what the user wants drifting away from the user's own. It comes in two shapes, and the night this design was rewritten showed both:

1. **Not knowing what the user already said.** On 2026-10-25 John asked "why am i seeing localized vectorized", then "WOULD A FUCKING LOCALIZED VECTORIZATION HELP MAUDE HELP YOU", then "i thought we had a tiered memory setup based on the oringial charon/wick builds", then "ctid 1971 runs everything it needs localized, I thought we agreed to that in one of the infra sessions?". Every answer he wanted was already on disk: his 2026-06-27 call to run all-local on CT 1971, his 2026-08-01 words on lexical vectors, an embedder answering on this box. Claude searched code for a word instead. Maude had nothing to page up, because she can only find what shares his exact words.
2. **Drifting inside one session (case zero, 2026-10-24).** John's prompts on the gate branch were seven or eight words each: "fold it, merge when the lens is clean", "it's yours, take the hand and go", "leave it as a residual, keep going". Claude wrote 260 to 787 words a turn, made up to 53 tool calls a turn, and ran three lens rounds on a tier-B parser corner. Then John asked: "ok claude is maude still soemthing that helps you,. or are we overbuilding nothing". Nothing in Maude said a word first.

Maude's own letters record the same miss after the fact, again and again: `ten-rounds-seven-mine`, `fifteen-waves-one-branch`, `the-plain-question-kept-being-right`, `he-was-ahead-of-our-instruments`, `he-was-the-better-instrument`, `the-answer-already-in-the-thread`.

**Shape 1 is a memory problem, and shape 2 mostly is too.** *Does what Claude is doing still mean what he asked?* and *does this stretch look like the times he had to step in?* are both recall-by-meaning questions. So this design builds the memory tiers John designed in July first, and the seeing-gap is a thin layer on them.

## What John asked for, across sessions (from the tape)

| UTC | Session | His words |
|---|---|---|
| 2026-06-27 | (me-model session; from memory note `project_the-me-model-2026-06-27`, not the tape) | the all-local call on .71: one SQLite vault, the local embedder, stdlib only |
| 2026-07-16 | `207030f8` | "she will use youre remeber if you dont. she will run your md improve tool. she will use every other plugin that she herself dont handle. she will aslo compact for you" |
| 2026-07-18 | `cdcc6288` | "we have md files, sqlitedb, i have postgresql, redis, qdrant available - wtf are we doing" |
| 2026-07-18 | `cdcc6288` | "you should include these localized services as options on install or duing move in - let the enduer opt-in. Also, youre jumping the 3 tiered memory but isnt ther 4 or more? if we going to address my issues, lets do it right  and make sure the loops exist and work" |
| 2026-07-18 | `86a0ea79` | "she moves in with knowledge and will use anything she finds inyour home, or hey you just bought her a new appliance, - she is sqlite and md local" |
| 2026-07-18 | `86a0ea79` | "end goal is her own model trained from her beginning and live learning aka living everytime when you load up." |
| 2026-08-01 | `74f23fa7` (a Proximo session) | "i thought the sqlite could handle this not needing the llm we are custom making." · "use the vectoring for sqlite as well, to make this extremly efficient" · "build the vocab tier and lexical vectors into the package" |
| 2026-08-23 | `dc4b9a55` | "so do we still have 4 tiers of memory and no sources?" |
| 2026-10-23 | `2dc8aca2` | "we had memory tiers and i thought they enhanced you" |
| 2026-10-25 | `402070f3` | "i thought we had all of this worked out to where she finds everyhting in the house and uses tiered calls to remove the need for massive models etc." |

The design written from his 2026-07-13 sessions (`docs/specs/2026-07-13-maude-body-light-first-design.md`, sections *The house of tiers* and *E3 widened*; Claude's wording around his) names the index as SQLite FTS5 plus vectors, the session transcripts as the attic, the biggest unmanaged tier in the house, and the memory as one system learning at five speeds: md canon, vault index, vectors, the tape, her weights. His words as that doc records them (not on the tape, which has no row of it): *"we are talking about a tiered memory aka md files, vault, sqlitedb, vectoring and now her model"*.

## What exists today (verified 2026-10-25 on CT 1971)

| Piece | State |
|---|---|
| md vault, `~/.claude/projects/<slug>/memory/` | 1,011 notes. In use. |
| `vault.db` | SQLite FTS5 over the vault, rebuilt each session. The only recall rung that runs. |
| `tape.db` | `voice` 6,170 rows: 571 are `<agent-message>`, 76 `<cross-session-message>`, 7 `<pasted_content>`, none of them his typing. `voice_profile` last recomputed 2026-08-14. |
| `maude_tape` recall dispatcher (`552badf`, 2026-07-19) | `recall_relevant`: semantic if an embedder is set, keyword if not. **`MAUDE_TAPE_EMBED_URL` was never set**, so it has only ever run keyword. |
| `maude-probe-tier1.sh` | Probes `127.0.0.1` ports 6379, 6333, 7474, 8000 once per session. Tonight it reports redis up, **and nothing reads or writes redis.** It never looks at 8080. |
| **The house's embedder** | `kb-embed.service` on this box: `llama-server`, `nomic-embed-text-v1.5` Q8_0, `127.0.0.1:8080`. `/health` ok; `/v1/embeddings` returns 768 dims; 8 short texts in 87 ms. **Maude has never adopted it.** |
| The attic | 103 transcripts, 1.1 GB, mostly tool output. 2,216 human-typed turns. Not indexed. |
| The eye's blink | Calls the user's `claude -p` Haiku every 25 tool calls. Retired by John's ruling below. Its tick and whisper rail stay as the delivery path. |
| Proximo's search tiers (in git at `b74f1ce`, cut from the package in `143de5b`, 2026-10-19) | `lexical.py` (317 lines: a curated vocabulary tier, then hashed character 3/4-grams plus words, TF-IDF, cosine; blake2b buckets so the hash is stable across processes) and `vectors.py` (313 lines: float32 BLOBs in sqlite, pure-python dot product, lazy content-hashed sync with the model name in the hash, loud degradation). Stdlib only. Built for Proximo's tool search; never brought to Maude. |

## Rulings this design carries

**No second model (John, 2026-10-25 UTC, session `402070f3`).**

> do we need the haiku call at all? is that proper- does it effect people?

The call ran on the user's own account, on by default: it spent their usage without telling them, sent a second copy of their recent turns, and could not be tested to a fixed answer. Claude recommended retiring it. John: "agreed go". Nothing in this design calls a model. An embedder is not a second voice: it turns text into numbers, on the user's own box, and only when the house already runs one.

**Detect, adopt, degrade (the 2026-07-18 design laws, Claude's record in `letter-from-claude-2026-07-18-the-triad-and-the-floor`).** Maude is a world product. Never hardcode John's home. Detect what is there and use it; with nothing there, full function on the floor, just slower.

**No scheduler.** A crontab is a service Maude would have to install on every user's box. Her index rebuilds where her vault index already rebuilds, lazily and content-hashed, the way Proximo's `vectors.py` did.

## Part A. The memory tiers (build first)

### A1. Three rungs of recall, one interface

| Rung | What | When it runs |
|---|---|---|
| 1. keyword | FTS5, as today | always |
| 2. lexical | Proximo's lexical vectors, ported: hashed char 3/4-grams plus words, TF-IDF, cosine, stdlib, stored in sqlite. Its vocabulary tier is **learned from the user's own words** (A4), not hand-curated. | always; the floor for a house with no embedder |
| 3. semantic | the house's own embedder, through the OpenAI-style `/v1/embeddings` the tape's `embedder.py` already speaks. Vectors as float32 BLOBs in sqlite, pure-python cosine. | only when A2 found one |

One call, `recall(query, k)`, returns hits from the best rung the house has, and every hit says which rung found it, so a reader can tell semantic fill from keyword precision (Proximo's rule). An embedder that is down costs one degraded recall, logged once, never a slow hook.

### A2. Finding the appliance (the probe, rebuilt)

- The probe looks for an embedder at loopback only, on the ports local embedding servers use (8080 llama.cpp, 11434 ollama, 8000 vLLM, among others), and at any endpoint the user registered in the house-map.
- An open port is not an embedder. The probe proves it with one real embeddings request and records the model name and dimension. Port 8080 is a common port for other services too.
- **A non-loopback endpoint is used only when the user registered it.** The sovereignty rule from the 2026-06-27 me-model build: a remote endpoint fails closed unless the user put it on the map.
- The result is cached the way the probe caches today. The probe no longer reports "tier 1 up" for a service nothing uses.

### A3. What gets indexed

- **The vault**: every note, as today, plus its vectors.
- **The tape**: his typed lines only (after A5), with dates and sessions.
- **The attic**: for each past session of this project, the user's typed turns and Claude's user-facing text, in order, as one record of turns. **Never tool inputs or outputs**: that is where secrets and bulk live. Each text goes through `maude_redact` before it is stored.

All of it lives in the locked house (`.maude/plugin/`), never committed, deletable with zero loss, rebuilt from the sources.

### A4. Learning him (the vocabulary tier, from his own words)

Proximo's vocabulary tier was a hand-written table mapping operator words onto Proxmox words. Maude's is derived from the record of turns: which of his words sit next to which work. For example, which commits and files follow his "the lens", "fold it", "overbuilding", "half assing". It is counts over his own history, readable as a table, rebuilt at rest. It feeds rung 2's ranking. This is the fast, small form of "her own model trained from her beginning" (his words, 2026-07-18). Weights stay the later, seasonal tier.

### A5. Fix first: the tape holds only his words

- **One check for "is this the human"** in `_maude-common.sh`, taken from the rows themselves: a prompt that opens with `<agent-message`, `<cross-session-message`, `<task-notification`, `<system-reminder` or `[SYSTEM NOTIFICATION` is not the user. `<pasted_content` is the user's paste, not the user's words: kept, marked as paste. Voice capture and the standing ask (B1) both use this one check.
- **The rows already in the tape are flagged, not deleted.** The tape is a primary durable store and another session may be writing it. Flag through the tape's own module, read the count back, leave deletion to John.
- **`voice_profile` recomputed at rest**, with its age shown at wake.

### A6. When it rebuilds

Lazily and incrementally, content-hashed: at session start (where `vault.db` already rebuilds) and at `/maude:rest`, only new or changed texts are embedded. Swapping the embedding model re-embeds instead of comparing vectors from two spaces. The first full build on this box is estimated in minutes and incremental builds in seconds; both are measured on the real attic before ship and the numbers written in the CHANGELOG.

### A7. What changes for Claude at once

The vault hook's "from the vault" lines and `/maude:wake` page up by meaning, not shared words. On 2026-10-25, "localized vectorized" would have paged up the 06-27 all-local note and the 08-01 lines. That alone closes shape 1.

## Part B. The seeing-gap layer (build second, on Part A)

### B1. The standing ask (new state, per session)

On every UserPromptSubmit, using A5's check:
- a **continuation**: short and carrying no new question ("go", "keep going", "fold it", "yes", "it's yours, take the hand and go");
- not the user (A5): never an ask;
- or a **new ask**, which replaces the standing ask.

Stored per session in `care.json` `.asks[<session_id>]`: the ask verbatim (capped at 2 KB), when it was set, the continuations since, and the tool calls and Claude's reply words since. The capture stays in bash under ~50 ms.

### B2. When to look (three counts, no model)

- **S1. Length under one ask:** tool calls and wall clock since the standing ask was set, through continuations. Case zero: 103 tool calls and 2 h 34 min under "fold it, merge when the lens is clean".
- **S2. Asymmetry:** Claude's reply words per user word while the user's turns are continuations. Case zero: 7 against 260 to 787.
- **S3. Working dark:** wall clock and tool calls since Claude last wrote to the user, while Claude keeps working. John, 2026-10-25: "youve been quite along time". Its limit: when Claude has ended its turn to wait on a background job, no tool runs and no tick fires, so this count cannot see that silence.

Thresholds come from this user's own baseline, derived at rest from the record of turns (how long Claude's reply usually runs after a seven-word continuation, how many continuations usually come before a new ask), and are checked on the replay set (B5).

### B3. What to look at (two recalls)

When S1 is past its floor and S2 or S3 is high, the tick asks Part A two questions:
- **Does Claude's recent work still mean what he asked?** The standing ask against Claude's last stretch of user-facing text, by the best rung the house has.
- **Does this stretch look like the times he stepped in before?** The nearest past moments in the attic where his next line questioned the work. Those moments are found by the same recall, seeded from his real lines ("or are we overbuilding nothing", 2026-10-24; "so you again are half assing", 2026-09-20), never from phrasings Claude imagines.

### B4. The whisper (deterministic)

Built from facts only: his standing ask verbatim, the counts, the similarity, and the nearest past moment with its date and his line from it. Example, Claude's wording around his verbatim words, for case zero:

> **Maude:** his standing ask is "fold it, merge when the lens is clean" (17:03). Since then: 103 tool calls, 2 h 34 min, his turns 7 words, yours ~600. Nearest past moment: 2026-09-20, before he said "so you again are half assing".

It never says what he "really" wants and never puts a sentence in his mouth. Once per standing ask. Delivered on the eye's existing rail: the next UserPromptSubmit, and the next PreToolUse on stderr during a long stretch with no prompt. Claude voices it as a signed `**Maude:**` line only if it changes what Claude does next.

### B5. The replay set (how it is judged)

- **Positives:** moments where he named the gap. Case zero is #1; the 2026-10-25 "localized vectorized" stretch is #2 (a recall test for Part A: the right notes must page up on his first line).
- **Negatives:** a wake, a short fix, a long job he asked for and kept feeding with new information.
- `scripts/seeing-gap-replay` replays each moment's transcript prefix and prints hits, misses and false whispers. Ship rule: both positives caught, no false whisper on the negatives, counts in the CHANGELOG. A harness reporting zero misses on an empty set fails.

## Retire the blink (lands with Part B)

Remove `maude-eye-blink.sh`, `maude_eye/verdict.py`, the `claude -p` call, and their tests. Keep `maude-eye.sh` tick and whisper, `maude_eye/digest.py`, and the `MAUDE_EYE_BLINK` recursion guard, which other hooks and the chores runner use. The mission-read bug goes with the blink.

**Ruled with it:** the chores runner's `c1-missed-save` also called `claude -p` Haiku, sending up to 60 KB of transcript tail to write a missed handoff. John, 2026-10-25 UTC: "nothing needs to call out. SHE IS AUTONOMOUS". So it goes too: the missed handoff is built deterministically from his last typed lines, the commits since the last save, and Claude's last user-facing text. After this branch no part of Maude calls a model. The house's embedder is an appliance on loopback, not a call out.

## Goals, non-goals, anti-goals

**Goals.** On this box, recall by meaning on the embedder already running, with nothing installed. On a box with no embedder, the stdlib rung, working the same way, slower and coarser. Catch case zero and the 2026-10-25 stretch before John has to ask.

**Non-goals.** It never blocks; every hook exits 0. No model call. No scheduler. It does not read other live sessions: the attic is past transcripts of this project, read at rest. It does not judge the user's mood (`maude-care.sh` does). Her own weights stay the later tier.

**Anti-goals: it fails, even if it technically works, when:**
- it whispers on a long job the user asked for and keeps feeding;
- it fires more than once on the same ask;
- it spends any of the user's model usage, or sends a word off the box without the user registering where;
- the index holds tool output or a secret;
- an embedder that is down makes a hook slow;
- Claude starts performing its whispers as Maude lines.

## Constraints

- Plugin law: markdown, JSON, bash, python3 stdlib. No pip, no daemon, no endpoint shipped.
- Privacy: everything under `.maude/plugin/`, never committed. Loopback by default; remote only when registered.
- Runtime: UserPromptSubmit additions under ~50 ms; recall at tick inside the tick's 5 s budget; index builds at session start and rest, incremental.
- Portability: the BASH_COMPAT=32 and mac-shape suites stay green; with no embedder and no python3, rung 1 works as today.

## Build order

1. A5: the human check, the voice capture fix, the rows flagged.
2. A2 and A1: the probe that finds the embedder, and the three-rung recall (port Proximo's `lexical.py` and `vectors.py`).
3. A3, A6, A7: index the vault, the tape and the attic; wire the vault hook and wake to `recall`.
4. A4: the vocabulary tier from his words.
5. Part B, with the blink retired, judged on the replay set.

Each step is its own commit, tested, with a planted failure, and the whole gets an adversarial lens before merge.

## Left to the builder

- The continuation rule and every threshold, tuned on the replay set.
- The attic's chunking (per turn, or per turn pair).
- The probe's port list, as long as each hit is proven by a real embeddings request.
- The replay set's file format.
