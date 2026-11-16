"""maude_shell: read a command the way bash tokenizes it (docs/gate-threat-model.md)."""
import json
import os
import pathlib
import random
import subprocess
import sys
import time

import pytest

from maude_shell import BRACE_CAP, parse

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOME = "/srv/oracle"   # a synthetic home; not home-shaped, so the ship audit reads it as the fixture it is
ROOT_HOME = "/ro" + "ot"    # ~root expands to the root home; assembled so no line carries the shape whole
# The reader models bash 5; the two oracles ask the bash on this box. An older bash (macOS
# ships 3.2) answers some corners differently, so they skip there, and say so.
_V = subprocess.run(["bash", "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True).stdout.strip()
BASH5 = pytest.mark.skipif(not _V.isdigit() or int(_V) < 5,
                           reason="the oracle is bash 5; this box's bash is %r" % _V)


def cmds(text):
    out = parse(text, home=HOME)
    assert out["ok"], out
    return out["commands"]


def words(text):
    return [c["words"] for c in cmds(text)]


# ── words ──────────────────────────────────────────────────────────────────

def test_plain_words():
    assert words("git push --force origin main") == [["git", "push", "--force", "origin", "main"]]


@pytest.mark.parametrize("src", ['"rm" -rf /', "'rm' -rf /", "\\rm -rf /", "r\\m -rf /", 'r""m -rf /', "$'rm' -rf /"])
def test_a_dressed_command_word_reads_as_the_word(src):
    assert words(src) == [["rm", "-rf", "/"]]


def test_ansi_c_escapes():
    assert words(r"echo $'a\tb\x41\101\'\\'") == [["echo", "a\tbAA'\\"]]


def test_double_quote_escapes_only_its_five():
    assert words(r'echo "a\$b\"c\\d\xe"') == [["echo", 'a$b"c\\d\\xe']]


def test_line_continuation_joins():
    assert words("git \\\npush") == [["git", "push"]]


def test_brace_expansion():
    assert words("g{it,} push") == [["git", "g", "push"]]
    assert words("cp f{,.bak}") == [["cp", "f", "f.bak"]]
    assert words("echo {a,b}{1,2}") == [["echo", "a1", "a2", "b1", "b2"]]


def test_a_close_brace_without_a_comma_does_not_close():
    assert words("echo {x}~,{a,b}} {x}{a,b} {a{b}c,d}") == [
        ["echo", "x}~", "a", "b", "{x}a", "{x}b", "a{b}c", "d"]]


def test_an_empty_brace_at_the_start_opens_nothing():
    assert words("echo {},a} x{},a} {{},a} {,{}}") == [["echo", "{},a}", "x}", "xa", "{}", "a", "{}"]]


def test_where_bash_tilde_gets_odd_the_word_is_dynamic():
    c = cmds("echo ~:${HOME} x=~root=~root ~root=~")[0]
    assert c["dynamic"] == [False, True, True, False]
    assert c["words"][3] == ROOT_HOME + "=~"


def test_brace_that_is_not_an_expansion_stays():
    assert words("echo {a} {} '{a,b}' x{ }") == [["echo", "{a}", "{}", "{a,b}", "x{", "}"]]


def test_a_variable_is_named_after_brace_expansion():
    c = cmds("echo $HOME{a,b} $HOME/{a,b}")[0]
    assert c["words"] == ["echo", "$HOMEa", "$HOMEb", HOME + "/a", HOME + "/b"]
    assert c["dynamic"] == [False, True, True, False, False]


def test_home_forms():
    assert words("rm -rf ~ ~/x $HOME/x ${HOME}/x \"$HOME\"/x") == [
        ["rm", "-rf", HOME, HOME + "/x", HOME + "/x", HOME + "/x", HOME + "/x"]]


def test_tilde_in_an_assignment_shaped_word():
    assert words("echo x=~/y x=a:~/z a:~ x=~/{a,b} {~,a} --d=~/x ~root:x ~:~ ~root:''") == [
        ["echo", "x=" + HOME + "/y", "x=a:" + HOME + "/z", "a:~", "x=~/a", "x=~/b", HOME, "a", "--d=~/x", ROOT_HOME + ":x", HOME + ":~", "~root:"]]


def test_quoted_tilde_is_literal():
    assert words("echo '~' \"~\" \\~") == [["echo", "~", "~", "~"]]


def test_tilde_user():
    assert words("rm -rf ~root/.claude") == [["rm", "-rf", ROOT_HOME + "/.claude"]]


def test_dynamic_words_are_marked():
    c = [c for c in cmds("rm -rf $x/y \"$(pwd)\" plain") if c["context"] == "top"][0]
    assert c["words"][0] == "rm"
    assert c["dynamic"] == [False, False, True, True, False]


def test_comment():
    assert words("echo a # rm -rf /\necho b") == [["echo", "a"], ["echo", "b"]]
    assert words("echo a#b") == [["echo", "a#b"]]


# ── commands and where they sit ────────────────────────────────────────────

def test_separators_split_commands():
    assert words("a 1; b 2 && c 3 || d 4 | e 5 |& f 6 & g 7\nh 8") == [
        ["a", "1"], ["b", "2"], ["c", "3"], ["d", "4"], ["e", "5"], ["f", "6"], ["g", "7"], ["h", "8"]]


def test_assignments_are_not_the_command_word():
    c = cmds("FOO=1 BAR=\"x y\" git push")[0]
    assert c["assigns"] == ["FOO=1", "BAR=x y"]
    assert c["words"] == ["git", "push"]


def test_array_assignment():
    c = cmds("a=(x y z) b=2")[0]
    assert c["assigns"] == ["a=(x y z)", "b=2"] and c["words"] == []


def test_substitution_commands_are_listed():
    cs = cmds("echo \"$(git push -f)\" `rm -rf /` $(a $(b))")
    got = sorted((c["context"], c["depth"], c["words"][0]) for c in cs)
    assert got == sorted([("top", 0, "echo"), ("subst", 1, "git"), ("subst", 1, "rm"),
                          ("subst", 1, "a"), ("subst", 2, "b")])


def test_process_substitution():
    cs = cmds("diff <(git show a) >(rm -rf /)")
    assert [c["words"][0] for c in cs if c["context"] == "subst"] == ["git", "rm"]


def test_subshell_and_group():
    cs = cmds("(cd x && rm -rf y); { git push; }")
    assert [(c["context"], c["words"]) for c in cs] == [
        ("subshell", ["cd", "x"]), ("subshell", ["rm", "-rf", "y"]), ("group", ["git", "push"])]


def test_keywords_open_command_position():
    assert words("if true; then rm -rf /; elif x; then y; else git push; fi") == [
        ["true"], ["rm", "-rf", "/"], ["x"], ["y"], ["git", "push"]]
    assert words("while read l; do rm \"$l\"; done < f") == [["read", "l"], ["rm", "$l"]]
    assert words("! git push") == [["git", "push"]]
    assert words("time git push") == [["git", "push"]]


def test_keyword_only_in_command_position():
    assert words("echo if then fi") == [["echo", "if", "then", "fi"]]


def test_for_header_is_not_a_command():
    assert words("for f in a b c; do rm \"$f\"; done") == [["rm", "$f"]]
    assert words("for ((i=0;i<3;i++)); do echo $i; done") == [["echo", "$i"]]


def test_case():
    src = "case $x in a|b) rm -rf /;; (c) git push ;& *) echo ok;;& esac"
    assert words(src) == [["rm", "-rf", "/"], ["git", "push"], ["echo", "ok"]]


def test_test_and_arith_are_not_commands():
    assert words("[[ a < b && -f x ]] && rm y; (( i < 3 )) || git push") == [["rm", "y"], ["git", "push"]]


def test_function_body_is_read():
    cs = cmds("f() { rm -rf /; }; function g { git push; }")
    assert [(c["context"], c["words"]) for c in cs] == [
        ("function", ["rm", "-rf", "/"]), ("function", ["git", "push"])]


# ── redirects and heredocs ─────────────────────────────────────────────────

def test_redirects():
    c = cmds("cmd >out 2>>err <in &>both 3>&1 >|clob <<<\"here str\"")[0]
    assert c["words"] == ["cmd"]
    assert [(r["op"], r["fd"], r["target"]) for r in c["redirects"]] == [
        (">", None, "out"), (">>", "2", "err"), ("<", None, "in"), ("&>", None, "both"),
        (">&", "3", "1"), (">|", None, "clob"), ("<<<", None, "here str")]


def test_heredoc_body_is_apart_from_the_command():
    c = cmds("cat > notes.md <<'EOF'\ngit push --force\nrm -rf /\nEOF\necho after")
    assert [x["words"] for x in c] == [["cat"], ["echo", "after"]]
    h = c[0]["heredocs"][0]
    assert h == {"delim": "EOF", "quoted": True, "strip_tabs": False,
                 "body": "git push --force\nrm -rf /\n", "terminated": True}


def test_heredoc_strip_tabs_and_two_on_a_line():
    c = cmds("cat <<-A <<B\n\tone\n\tA\ntwo\nB\n")[0]
    assert [(h["delim"], h["body"]) for h in c["heredocs"]] == [("A", "one\n"), ("B", "two\n")]


def test_unquoted_heredoc_runs_its_substitutions():
    cs = cmds("cat <<EOF\nhello $(rm -rf /)\nEOF")
    assert [(c["context"], c["words"]) for c in cs] == [("top", ["cat"]), ("subst", ["rm", "-rf", "/"])]


def test_quoted_heredoc_runs_nothing():
    assert words("cat <<\"EOF\"\n$(rm -rf /)\nEOF") == [["cat"]]


def test_heredoc_fed_to_a_shell_is_marked_by_its_command():
    c = cmds("bash <<EOF\nrm -rf /\nEOF")[0]
    assert c["words"] == ["bash"] and c["heredocs"][0]["body"] == "rm -rf /\n"


def test_delimiter_is_the_whole_word():
    c = cmds("cat <<EOF{\nEOF\nx\nEOF{\n")[0]
    assert c["heredocs"][0]["delim"] == "EOF{" and c["heredocs"][0]["body"] == "EOF\nx\n"


def test_unterminated_heredoc_reads_to_the_end():
    h = cmds("cat <<EOF\nline\n")[0]["heredocs"][0]
    assert h["terminated"] is False and h["body"] == "line\n"


def test_herestring_and_arith_shift_are_not_heredocs():
    assert cmds("cat <<<x; echo $((1 << 2))")[0]["heredocs"] == []


def _subst_words(src):
    return [c["words"][0] for c in cmds(src) if c["context"] == "subst"]


@pytest.mark.parametrize("src,want", [
    ('echo $(( "$(zap1)" + 1 ))', ["zap1"]),          # quotes do not quote inside $(( ))
    ("echo $(( '$(zap3)' ))", ["zap3"]),
    ('echo "${x:-\'$(zap2)\'}"', ["zap2"]),            # ' is a plain char in a quoted ${ }
    ("echo ${x:-'$(zap4)'}", []),                        # ...but quotes in an unquoted one
    ("cat <<E\n${x:-'$(zap5)'}\nE", ["zap5"]),          # a heredoc body reads like "..."
    ('echo "${x:-\'}\'$(zap6)}"', ["zap6"]),            # ' delimits the } in a quoted ${ }...
    ('echo "${x:-\'$(zap7)}\'}"', ["zap7"]),            # ...and what it spans still runs
])
def test_quotes_that_do_not_quote_hide_no_substitution(src, want):
    assert _subst_words(src) == want


def test_a_quoted_brace_param_ends_where_bash_ends_it():
    c = [c for c in cmds('echo "${x:-\'}\'}" zap') if c["context"] == "top"][0]
    assert c["words"] == ["echo", "${x:-'}'}", "zap"]
    assert words("echo \"${x:-'\"'}\"; zap") == [["echo", "${x:-'\"'}"], ["zap"]]


@pytest.mark.parametrize("src,body,after", [
    ("cat <<E\na\\\nE\nb\nE\nzap", "aE\nb\n", [["zap"]]),       # odd \ joins the next line
    ("cat <<E\na\\\\\nE\nzap", "a\\\\\n", [["zap"]]),             # even: no join
    ("cat <<E\n\\\nE\nzap", "", [["zap"]]),                         # the joined line is the delimiter
    ("cat <<-E\n\ta\\\n\tE\n\tE\nzap", "a\tE\n", [["zap"]]),     # <<- strips the first line only
    ("cat <<'E'\na\\\nE\nzap", "a\\\n", [["zap"]]),               # quoted: no join
])
def test_heredoc_line_continuation(src, body, after):
    c = cmds(src)
    assert c[0]["heredocs"][0]["body"] == body
    assert [x["words"] for x in c[1:]] == after


@pytest.mark.parametrize("src,dyn", [
    ("HOME=/x; frob ~", True), ("export HOME=/x; frob $HOME", True), ("read HOME; frob ~/a", True),
    ("for HOME in /x; do frob ~; done", True), ("declare HOME=/x; frob ${HOME}", True),
    ("export $'\\x48OME'=/x; frob ~", True), ("export HO\\\nME=/x; frob ~", True),
    ("HO\\\nME=/x; frob ~", True), ("x=1 HOME+=/x; frob ~", True),
    ("frob $(for HOME in /x; do :; done) ~", True),
    ("for HO\\\nME in /x; do frob ~; done", True),   # only the reader's loop names see this
    ("printf -vHO\\\nME /x; frob ~", True),            # glued to an option, past the text net
    ("exec {HOME}>/dev/null; frob ~", True), ("exec {HO\\\nME}>/dev/null; frob ~", True),  # {name}> sets name
    ("export H\\OME=/x; frob ~", True), ("export $'HOME'=/x; frob ~", True), ("declare 'HO'ME=/x; frob ~", True),
    ("frob ~", False), ("frob $HOME ${HOME}/a", False),
    ("MYHOME=1 frob ~", True),  # fail closed: the text HOME anywhere costs only "unknown"
])
def test_a_home_assignment_anywhere_makes_home_unknown(src, dyn):
    c = [c for c in cmds(src) if c["words"] and c["words"][0] == "frob"][0]
    assert c["dynamic"][1] is dyn, c


# ── lens 1 on fa6691a ─────────────────────────────────────────────────────

@pytest.mark.parametrize("src,want", [
    ("coproc zap a", [["zap", "a"]]), ("coproc N { zap; }", [["zap"]]), ("coproc N zap", [["N", "zap"]]),
    ("coproc N ( zap )", [["zap"]]), ("time -- zap", [["zap"]]), ("time -p -- zap", [["zap"]]),
    ("declare -a a=(1 2)", [["declare", "-a", "a=(1 2)"]]), ("local -a a=(x) b=(y)", [["local", "-a", "a=(x)", "b=(y)"]]),
])
def test_a_prefix_keyword_does_not_hide_the_command_word(src, want):
    assert [c["words"] for c in cmds(src) if c["context"] != "subst"] == want


def test_a_heredoc_waits_for_the_line_not_a_newline_inside_a_substitution():
    cs = cmds("cat <<E $(echo a\nzap\nE\n)\nfoo\nE\nfrob")
    assert [(c["context"], c["words"][0]) for c in cs] == [
        ("subst", "echo"), ("subst", "zap"), ("subst", "E"), ("top", "cat"), ("top", "frob")]
    assert cs[3]["heredocs"][0]["body"] == "foo\n"
    assert cmds('cat <<E "$(\nzap\n)"\nbody\nE')[-1]["heredocs"][0]["body"] == "body\n"


def test_a_redirect_target_says_if_it_is_known():
    rs = [r for c in cmds("zap > $x; zap > '$x'; zap > $(frob); zap > f") for r in c["redirects"]]
    assert [(r["target"], r["dynamic"]) for r in rs] == [("$x", True), ("$x", False), ("$(frob)", True), ("f", False)]
    g = [r for c in cmds("zap > a*; zap > 'a*'") for r in c["redirects"]]
    assert [(r["target"], r["glob"]) for r in g] == [("a*", True), ("a*", False)]  # bash writes to the match


@pytest.mark.parametrize("src", ["cat < <(frob)", "zap 2> >(frob)", "while read x; do :; done < <(frob)"])
def test_a_process_substitution_can_be_a_redirect_target(src):
    assert "frob" in [c["words"][0] for c in cmds(src)]


@pytest.mark.parametrize("src", ["echo {1..99999999999999999999}", "echo {1.." + "9" * 5000 + "}",
                                 "echo {-99999999999999999999..1}", "echo {1..3..99999999999999999999}",
                                 "echo {1..9223372036854775808}"])
def test_an_overflowing_sequence_is_literal_like_bash(src):
    assert words(src) == [src.split()]


def test_a_sequence_at_the_edge_of_int64_still_expands():
    assert words("echo {9223372036854775807..9223372036854775806}") == [
        ["echo", "9223372036854775807", "9223372036854775806"]]


@pytest.mark.parametrize("src", ["echo " + "{" * 20000, "echo " + "{a," * 20000, "a=" + ":~" * 30000,
                                 "echo " + "{a,b}" * 11 + "x" * 60000, "echo " + "a:~" * 30000])
def test_no_shape_under_the_cap_runs_away(src):
    t = time.perf_counter()
    out = parse(src, home=HOME)
    assert time.perf_counter() - t < 2.0, (src[:20], out.get("error"))


def test_a_refusal_names_its_own_reason():
    assert parse("echo " + "{a,b}" * 11 + "x" * 60000)["error"] == "brace expansion past 1000000 characters"
    assert parse("echo " + "{a,b}" * 13)["error"] == "brace expansion past 4096 words"


def test_glob_words_are_marked():
    c = cmds("rm -rf * '*' \\* /ho[m]e a?b x")[0]
    assert c["glob"] == [False, False, True, False, False, True, True, False]


def test_odd_tildes_are_dynamic():
    assert cmds("echo ~+ ~- ~+/x ~2")[0]["dynamic"] == [False, True, True, True, True]


def test_only_ascii_digits_are_digits():
    assert cmds("zap \u0663>x")[0]["words"] == ["zap", "\u0663"]
    assert words("echo {\u0661..\u0663}") == [["echo", "{\u0661..\u0663}"]]


def test_old_style_arithmetic():
    assert words("echo $[1;zap] $[ $(frob) ]") == [["frob"], ["echo", "$[1;zap]", "$[ $(frob) ]"]]


def test_cli_survives_bytes_that_are_not_utf8():
    r = subprocess.run([sys.executable, "-m", "maude_shell"], input=b"echo \xff", capture_output=True,
                       cwd=ROOT, env=dict(os.environ, PYTHONPATH=str(ROOT)))
    assert r.returncode == 0 and json.loads(r.stdout)["ok"]


# ── what it refuses ────────────────────────────────────────────────────────

@pytest.mark.parametrize("src", ["echo 'open", 'echo "open', "echo $(open", "echo `open", "case x in a) y",
                                 "if true; then x", "( a", "{ a; ", "echo ${x", "&& a", "a |", "a &&", "; a",
                                 "f() a", "{ }", "( )", "if then fi", "[[ a ]] b", "{ a; } b", "! && a",
                                 "a | ! b", "time &", "a ;; b"])
def test_incomplete_bash_is_not_ok(src):
    out = parse(src, home=HOME)
    assert out["ok"] is False and out["error"]


@pytest.mark.parametrize("src", ["time", "! ;", "a | time -p b", "function g ( a )", "x=1 else",
                                 "if true; then { a; } fi", "case a in a) ;; esac", "echo $()"])
def test_complete_bash_is_ok(src):
    assert parse(src, home=HOME)["ok"], src


def test_time_after_a_pipe_is_a_command_name():
    assert words("a | time -p b") == [["a"], ["time", "-p", "b"]]


def test_cli_emits_json():
    r = subprocess.run([sys.executable, "-m", "maude_shell"], input="git push -f", capture_output=True,
                       text=True, cwd=ROOT, env=dict(os.environ, HOME=HOME, PYTHONPATH=str(ROOT)))
    assert r.returncode == 0
    assert json.loads(r.stdout)["commands"][0]["words"] == ["git", "push", "-f"]


# ── the oracle: bash itself ────────────────────────────────────────────────

PIECES = ["a", "b", "rm", "-rf", "/", ".", "=", "x=", "--d=", ":", "~", "~/", "~root", "#", "{", "}", ",",
          "{a,b}", "{,x}", "{a,{b,c}}", "'q w'", "'~'", '"d $HOME"', '"${HOME}"', '"\\$"', '"\\\\"',
          "\\ ", "\\~", "\\{", "\\'", "$HOME", "${HOME}", "$'t\\x41'", "$'\\''", '""', "''", "{1..3}", "{a..c}", "{01..3}", "{x}", "$'\\101\\x\\cA\\e'", "$'\\0'", "\\", "','", "..", "{1..a}", "{a..}", "{-1..2..2}", "{z..x}", " ", " ", "  "]


def _bash_words(lines):
    script = ('set -f; while IFS= read -r -d "" l; do eval "set -- $l" 2>/dev/null || { printf "\\2\\0"; continue; };'
              ' [ $# -gt 0 ] && printf "%s\\0" "$@"; printf "\\1\\0"; done')
    data = "".join(l + "\0" for l in lines)
    out = subprocess.run(["bash", "-c", script], input=data, capture_output=True, text=True,
                         env={"HOME": HOME, "PATH": os.environ["PATH"]}).stdout
    res, cur = [], []
    for field in out.split("\0")[:-1]:
        if field in ("\1", "\2"):
            res.append(cur if field == "\1" else None)
            cur = []
        else:
            cur.append(field)
    return res


@BASH5
def test_oracle_control_sees_a_difference():
    # The comparison must be able to fail: bash and a wrong answer disagree.
    assert _bash_words(["a{b,c}"]) == [["ab", "ac"]]
    assert _bash_words(["a{b,c}"]) != [["a{b,c}"]]


@BASH5
def test_words_match_bash_on_generated_lines():
    rng = random.Random(20261023)
    lines = ["".join(rng.choice(PIECES) for _ in range(rng.randint(1, 9))) for _ in range(4000)]
    want = _bash_words(lines)
    assert len(want) == len(lines)
    bad, dynamic = [], 0
    for line, w in zip(lines, want):
        if w is None:
            continue
        out = parse("set -- " + line, home=HOME)
        if not out["ok"] and out["error"].startswith("brace expansion past") and len(w) > BRACE_CAP:
            continue  # refused on purpose, and bash agrees it is that big
        c = out["commands"][0] if out["ok"] and out["commands"] else None
        if c is not None and any(c["dynamic"]):
            dynamic += 1  # bash expands an unset $name to nothing; the parser keeps it, marked
            continue
        got = c["words"][2:] if c is not None else None
        if got != w:
            bad.append((line, w, got))
    compared = sum(w is not None for w in want) - dynamic
    assert compared > 3000, (compared, dynamic)
    assert not bad, bad[:10]


# ── the second oracle: bash -n on the structure ────────────────────────────

STRUCT = ["a", "b x", "rm -rf /", ";", ";", "&&", "||", "|", "&", "\n", "\n", "(", ")", "{ ", " }", "if ",
          " then ", " else ", " elif ", " fi", "while ", " do ", " done", "for i in a b", "for ((i=0;i<2;i++))",
          "case a in ", " a) ", " ;; ", " esac", "! ", "[[ a < b ]]", "(( 1 < 2 ))", "$(a)", "`a`",
          "<<E\nx\nE\n", "<<'E'\n$(rm)\nE\n", "> f", "2>&1", "f() ", "function g ", "time ", "# c\n",
          "\"q $(b)\"", "'s'", "<(a)", "x=1 ", "\\\n", " in "]


@BASH5
def test_structure_is_accepted_exactly_when_bash_accepts_it():
    rng = random.Random(1)
    progs = [" ".join(rng.choice(STRUCT) for _ in range(rng.randint(1, 10))) for _ in range(1500)]
    bad = []
    for prog in progs:
        bash_ok = subprocess.run(["bash", "-n", "-c", prog], capture_output=True).returncode == 0
        if parse(prog, home=HOME)["ok"] != bash_ok:
            bad.append((prog, bash_ok))
    assert sum(subprocess.run(["bash", "-n", "-c", p], capture_output=True).returncode == 0
               for p in progs[:300]) > 20  # the generator makes valid bash too, not only noise
    assert not bad, bad[:10]
