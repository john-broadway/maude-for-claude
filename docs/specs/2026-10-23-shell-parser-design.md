<!-- Version: 0.36.0 -->
<!-- Created: 2026-10-23 -->
<!-- Revised: 2026-11-08 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# A shell parser for the gate: design

> **Design doc (2026-10-23).** The design as planned. The parser's tests are the authority on what it does; this page rots in place by design. Scope and tiers: `docs/gate-threat-model.md`.

## The problem

`maude-gate.sh` reads bash with regular expressions over cleaned-up copies of the command. Reading bash and judging it are mixed in one place, so every fix to the reading changes the judging, and each review round finds the corner the last fix opened. Most BLOCKING findings since October were the gate and bash disagreeing about where a word, a command or a heredoc ends.

## The answer

Split the two jobs. `maude_shell` reads a command the way bash tokenizes it and returns plain data. The gate (on a later branch) judges that data with a short rule table. This branch lands the reader only. The gate does not change here.

Python 3 stdlib only (locked decision 4). Floor: Python 3.8, so no `match` and no `X | Y` types.

The gate header records that a hand-rolled JSON parse once brought back the v0.1.6 self-block. The answer to that is the oracle below: this reader is checked against bash itself, not by eye.

## What it returns

`python3 -m maude_shell` reads a command on stdin and writes one JSON object:

```json
{"ok": true, "commands": [
  {"words": ["git", "push", "--force"], "dynamic": [false, false, false], "glob": [false, false, false],
   "assigns": [], "redirects": [], "heredocs": [], "context": "top", "depth": 0, "sep": null}
]}
```

- `words`: each word after quote removal, escapes, ANSI-C `$'…'` decoding, brace expansion, and tilde and `$HOME` / `${HOME}` expansion. These are the only expansions it does, because they are fixed by the text alone.
- `dynamic[i]`: true when word `i` holds something only known at run time (`$x`, `$(…)`, a backtick, `$((…))`). The word keeps its source spelling for that part. Tier C lives here: the judge sees that it cannot know, instead of guessing.
- `glob[i]`: true when word `i` holds an unquoted `*`, `?` or `[…]` that bash may expand against the filesystem. The reader never expands it.
- `assigns`: leading `NAME=value` words. `redirects`: `{op, fd, target, dynamic, glob}`, where `dynamic` says the target is only known at run time (`> $x` against `> '$x'`) and `glob` that bash may expand it (`> a*` writes to the one match). `heredocs`: `{delim, quoted, strip_tabs, body, terminated}` with the body kept apart from the command.
- `context` and `depth`: where the command sits. `top`, or inside `subst` (`$(…)`, backticks, `<(…)`), `subshell`, `group`, `function`. Commands inside a substitution or an unquoted heredoc body's `$(…)` are listed too, because bash runs them.
- Keyword structure (`if`, `while`, `for`, `case`, `[[ ]]`, `(( ))`, `!`, `time`) is read, so the command after `then` or `do` is a command in its own right, and a `for` header or a `[[ ]]` test is not a command.
- `{"ok": false, "error": "…"}` when the text is not complete bash (an open quote, an unclosed `$(`, a missing `esac`). The gate will treat that as "cannot read" and keep today's behaviour, never pass it.

## The oracles

Two, both bash itself, so a reader that disagrees with bash fails a test instead of passing a review:

- **Words.** A generated word list with no command substitution goes through `eval "set -- …"` under a pinned `HOME`, and the reader must hand back the words bash prints. The suite runs 4,000 lines; a 100,000-line run over 25 seeds compared 94,707 lines with 0 mismatches. A line where the reader marks a word dynamic is skipped (bash expands an unset name to nothing, the reader keeps it marked), and a line the reader refuses past the brace cap counts only when bash's own count is past it too.
- **Structure.** Random programs built from shell syntax (keywords, operators, heredocs, substitutions, functions) go to `bash -n`, and the reader must accept exactly what bash accepts. The suite runs 1,500; a 48,000-program run had 2 disagreements, both named below.

Both skip, and say why, on a bash older than 5 (macOS ships 3.2): they ask the bash on the box, and the reader models bash 5.

Hand-written cases cover what bash cannot be asked without running something: which commands a substitution or heredoc body holds, where each command sits, keywords. The 809 distinct commands the gate's own tests feed it all parse or refuse in agreement with `bash -n` (794 and 15), with no crash.

What the oracles taught, each now in a test:

- Brace expansion is a line-for-line port of bash 5.2 `braces.c` (`brace_expand`, `brace_gobbler`), read from the source after guessing from outside kept missing corners. A `}` closes only after a top-level `,` or `..`; a quoted comma counts in the amble check; a `{` at the start with `}` right after opens nothing.
- An unquoted `$name` is named after brace expansion: `$HOME{a,b}` is `$HOMEa $HOMEb`.
- Tilde: the `x=~` rule only holds for a word brace expansion left alone; a user name ends at `:` or `=~`. Where bash gets odd (an unquoted `$` inside a tilde prefix, a second `=~` in an assignment) the word is marked dynamic instead of modelled: the gate is told it cannot know.
- `$'…'` stops at an escaped NUL, as bash's C strings do.
- `time` and `!` are reserved only at the start of a pipeline; after `|`, `time` is a command name and `!` is an error.

The automated security review on the first commit found four more, each confirmed against bash (a DEBUG trap under `extdebug` lists what bash would run and skips it) and each now in a test:

- Inside `$(( ))` quotes do not quote: `"$(x)"` and `'$(x)'` both run there.
- Inside a double-quoted `${…}`, and in an unquoted heredoc body, a `'` is a plain character, so `"${x:-'$(x)'}"` runs `x`.
- A command that sets `HOME` itself (`HOME=`, `export HOME`, `read HOME`, `for HOME in`, `${HOME:=…}`) makes every `~` and `$HOME` in it unknown. `HOME=/; rm -rf ~` must not read as the user's home.
- In an unquoted heredoc a line ending in an odd run of `\` joins the next line, and the delimiter is compared on the joined line.

Its second round, on that fix, found two more, folded the same way: a `HOME` handed to a builtin through quotes or escapes (`export H\OME=/x`, `declare 'HO'ME=…`, `$'HOME'`) now makes `HOME` unknown too; and inside a double-quoted `${…}` a `'` still delimits the closing `}` (bash keeps a `"` inside it protected), while what it spans still expands. Its third claim, that a quoted `)` inside `$(( ))` could end the arithmetic early, held: every such input is refused, so the gate keeps today's behaviour and nothing is hidden. It is listed below.

A third round found `HOME` set through `$'\x48OME'` and a line continuation (`HO\⏎ME`). Rather than widen the text scan again, the check now also reads the reader's own resolved output, which the word oracle shows is bash-exact: if any resolved word, assignment or loop name holds the text `HOME` (a read like `$HOMEx` excepted), the command is read again with `HOME` unknown. The fourth round widened that from a whole word to the bare text, for a name glued to an option (`printf -vHOME`); the fifth confirmed `{HOME}>f` (a named fd assigns its name), which both nets already caught. A false hit (`MYHOME=1`) only marks `~` unknown. The text scan stays as a second net. The same round's other claim, that `set -o posix` changes how a `'` reads inside a quoted `${…}`, is a shell option only known at run time: tier C, listed below.

The lens on the first commit (one hostile pass, scored against the threat model) reported 0 BLOCKING, 9 MAJOR and 10 MINOR. Four of the MAJOR were already closed by the rounds above (quotes in `$(( ))`, `'` in a quoted `${…}`, the heredoc continuation, `HOME` set in the command). The rest are folded, each with a test and a replanted revert that goes red:

- `coproc zap` and `time -- zap` no longer hide the command word (a `coproc` name is only a name before a compound command).
- A heredoc opened before a multi-line `$(…)` on the same line is read after that line, not at a newline inside the substitution.
- A redirect target says whether it is known (`dynamic`), and a process substitution can be one (`cat < <(x)`, an everyday idiom that was refused).
- A sequence past `int64` (`{1..99999999999999999999}`) is literal, as in bash, where it crashed the reader.
- Four shapes that ran for seconds to minutes, or took 482 MB, now refuse in under 160 ms: a word with thousands of braces (bash's own scan is quadratic too), an expansion past a million characters, and a long `a=:~:~…` (now one pass).
- Cheap MINORs taken with them: `declare -a a=(…)` reads, `~+ ~- ~N` are unknown, only ASCII digits count as digits, `$[ … ]` is arithmetic, a word's unquoted glob is marked, and bytes that are not UTF-8 no longer crash the CLI.

## Residuals

- Accepted though bash refuses (the reader is wider, so the gate sees more, never less): `a=(1 2) 2>&1 a=(1 2)`, and a pipe whose right side opens with a heredoc redirect and then holds reserved words.
- Accepted though bash refuses, from the lens (none hides a command): `> #f`, an empty `[[ ]]`, `;` inside `[[ ]]`, a bare `$[`.
- Refused though bash accepts (the gate keeps today's behaviour): a quoted `)` inside `$(( ))` or `]` inside `$[ ]`, nesting past 64 levels, more than 330 nested `if`s (Python's recursion limit; bash takes 500), a brace expansion past 4,096 words or a million characters, a word whose braces times its length pass two million, and extglob patterns (`@(x)`, `+(a|b)`), which bash only reads after `shopt -s extglob`.
- Words the reader splits where bash does not: `a<(zap)` is two words to the reader, one to bash. The substitution is listed either way.
- Globs are marked, never expanded: which files `/ho[m]e` names depends on the filesystem at run time.
- `trap '…' EXIT`, `eval`, aliases and sourced files run text the reader never sees as commands: tier C.
- Shell options only known at run time (`set -o posix`, `POSIXLY_CORRECT`, `shopt` compat levels, `extglob`) can change how bash reads the same text. The reader models default bash 5: tier C.
- A `HOME` set through a name only known at run time (`HO${x}ME`, `eval`, a sourced file) is tier C: the reader cannot see it.
- The reader models bash. Claude Code may hand a command to another shell (zsh on macOS); the wiring branch names it a residual in the threat model and does not chase it.

## Cost

Measured on this box, end to end through `python3 -m maude_shell`: a short command 34 ms median (50 ms worst of 20); the largest gate test command (119 KB) 330 to 420 ms; the worst shape found under the gate's 128 KB cap (65,536 one-word commands) 1.3 s with a 9.5 MB answer. Every shape the lens found to run away now refuses in under 160 ms. The gate's budget is 5 s.

## The wiring (2026-10-24)

The gate does not read the parse. `maude_shell/judge.py` judges it in the same process and prints one line (`block KEY WORDS`, `pass`, `unreadable`), so the 9.5 MB answer never crosses a pipe. The gate calls it through `maude_shell_judge` (`_maude-common.sh`): `python3 -I -S -c` with the plugin root put first on the path by hand, under a 2 s cut, only when no table above it matched, before the wrapped-payload walk (which leaves early on a payload it cannot read). Messages stay in the gate, by key; the trace gets `parser=KEY`. Keys covered, wrappers read, and the judge's residuals: `docs/gate-threat-model.md`.

Why `-I -S` and not `cd` plus `PYTHONSAFEPATH`: `-I` drops the working directory, the user site and every `PYTHON*` variable on every Python back to 3.8, with no `cd`; `-S` skips `site` and a distro's `sitecustomize`. A test plants `re.py` (the reader's first stdlib import the interpreter has not already loaded) in the working directory and on `PYTHONPATH`; dropping `-I` makes it run inside the gate, and the test goes red.

What it changed, measured:

- 29 commands the tables passed now block, each one bash would run as the gated command: dressed command words (`"git" push`, `\git`, `r\m`, `$'rm'`), braces (`{git,push}`), wrappers (`time`, `nice -n 5`, `timeout -s KILL 5m`, `xargs -n 1`, `env -u`, `uv run --with`, `sudo -u`), keyword bodies (`if … then git push`, `for … do`, `{ …; }`), `eval git push`, a here-string or `echo … |` fed to `sh`, `rm -rf /*`, `rm -rf ~`, `"${HOME}"`, `~/*`, and `bash -c "$x"; \rm -rf /`. Several are tier A plain forms the tables missed.
- Over every command the 69 suite files feed the gate, the judge was asked 338 times (only where no table matched) and blocked 42. All 42 run the gated command (a shell fed a heredoc, `sh -c`, `eval`). 40 were already blocked further down by the wrapped-payload walk; the 2 that changed were the pinned limitation-#3 tests (`bash <<EOF` holding `rm -rf /` or `git push`), flipped to expect a block.
- Mutation: 4 planted breaks in the wiring (no `-I`, no block, no timeout, the opaque exit first) and 10 in the judge's rules, each caught by a red test.
- Cost: 30 interleaved runs of `git status` through the whole gate, median 182 ms on main, 221 ms on the branch (p90 250 / 315). Worst shapes under the 128 KB cap: `$HOME` every word 2.1 s (main 1.8 s), 65,536 one-word commands 1.6 s (0.4 s). The ceiling is the tables' ~2 s plus the judge's 2 s cut, inside the 5 s budget.
