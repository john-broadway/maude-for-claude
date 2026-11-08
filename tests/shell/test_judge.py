"""maude_shell.judge: the gate's command keys, judged from parsed words (docs/gate-threat-model.md)."""
import os
import pathlib
import re
import subprocess
import sys

import pytest

from maude_shell.judge import judge, judge_all, judge_read

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOME = "/srv/oracle"   # a synthetic home; not home-shaped, so the ship audit reads it as the fixture it is
PROJ = "/work/projects"
SOLE = ["/srv/keep"]


FED = re.compile(r"(echo|printf)[^|]*\|")  # an echo into a shell is never read whole (bfebd78)


def key(text):
    hits, whole = judge_read(text, home=HOME, proj=PROJ, sole=SOLE)
    assert whole or (hits and FED.search(text)), (text, hits, whole)
    return hits[0][1] if hits else None


def keys(text):
    """Every key, in run order; whole unless an echo feeds a shell."""
    hits, whole = judge_read(text, home=HOME, proj=PROJ, sole=SOLE)
    assert whole or FED.search(text), (text, hits, whole)
    return [h[1] for h in hits]


# ── blocks: each key, plain and dressed ────────────────────────────────────

@pytest.mark.parametrize("src,want", [
    ("git push", "git-push"),
    ("git push origin main", "git-push"),
    ("git push --force", "force-push"),
    ("git push -f origin", "force-push"),
    ("git push -uf origin main", "force-push"),
    ("git push --force-with-lease", "force-push"),
    ("git push --force-with-lease=main:abc", "force-push"),
    ("git push origin +main", "force-push"),
    ("git reset --hard", "reset-hard"),
    ("git reset --hard HEAD~1", "reset-hard"),
    ("git commit --amend --no-edit", "commit-amend"),
    ("git filter-repo --path x", "filter-repo"),
    ("git filter-branch --tree-filter x", "filter-branch"),
    ("git commit --no-verify -m x", "no-verify"),
    ("git commit --no-gpg-sign -m x", "no-gpg-sign"),
    ("gh release create v1", "public-publish"),
    ("gh release upload v1 a.tgz", "public-publish"),
    ("twine upload dist/*", "public-publish"),
    ("uv publish", "public-publish"),
    ("hf upload me/repo .", "public-publish"),
    ("huggingface-cli upload me/repo .", "public-publish"),
    ("rm -rf /", "rm-rf-root"),
    ("rm -r //", "rm-rf-root"),
    ("rm -rf /*", "rm-rf-root"),
    ("rm -rf *", "rm-rf-glob"),
    ("rm -rf ./*", "rm-rf-glob"),
    ("rm -rf ~/*", "rm-rf-glob"),
    ("sudo rm -rf /tmp/x", "sudo-rm-rf"),
    ("rm -rf /work/projects", "rm-rf-sole-copy"),
    ("rm -rf /work/projects/maude", "rm-rf-sole-copy"),
    ("rm -rf /work", "rm-rf-sole-copy"),
    ("rm -rf .git", "rm-rf-sole-copy"),
    ("rm -rf /a/b/.git/", "rm-rf-sole-copy"),
    ("rm -rf ~/.claude", "rm-rf-sole-copy"),
    ("rm -rf ~/.claude/projects/x", "rm-rf-sole-copy"),
    ("rm -rf ~", "rm-rf-sole-copy"),
    ('rm -rf "${HOME}"', "rm-rf-sole-copy"),
    ("rm -rf /srv/keep/deep/er", "rm-rf-sole-copy"),
    ("rm -rf /srv", "rm-rf-sole-copy"),
    ("rm --recursive --force /", "rm-rf-root"),
    ("rm -R /", "rm-rf-root"),
    ("rm -rf -- /", "rm-rf-root"),
    # the judge fuzzer, 2026-10-31: the shell expands ~ before env or a prefix runs
    ("env -u HOME rm -rf ~", "rm-rf-sole-copy"),
    ("env -u HOME rm -rf ${HOME}", "rm-rf-sole-copy"),
    ("HOME=/x rm -rf ~", "rm-rf-sole-copy"),
    ("env -u HOME rm -rf $HOME/.claude", "rm-rf-sole-copy"),
    ("HOME=/x rm -rf ~/*", "rm-rf-glob"),
    # the judge fuzzer, 2026-10-31: a wrapper runs the echo, the shell still reads its text
    ("sudo -u root echo 'rm -rf /' | sh", "rm-rf-root"),
    ("ionice -c 3 echo 'git push -f origin main' | sh", "force-push"),
    ("busybox printf 'git filter-repo --force' | bash", "filter-repo"),
    ("/bin/echo 'git push --force' | bash", "force-push"),
    # the commit security review on d31b9f5: a short group ending in an option that takes an
    # argument takes the next word too
    ("sudo -nu root rm -rf /", "rm-rf-root"),
    ("sudo -iu root git push --force", "force-push"),
    ("timeout -sKILL 5 rm -rf /", "rm-rf-root"),
    ("env -uHOME echo 'git push -f' | sh", "force-push"),
    ("env -iu HOME echo 'uv publish' | sh", "public-publish"),
    ("env -i0 echo 'rm -rf /' | sh", "rm-rf-root"),
])
def test_plain_forms_block(src, want):
    assert key(src) == want


@pytest.mark.parametrize("src,want", [
    ('"git" push', "git-push"),
    ("\\git push", "git-push"),
    ("g\\it pu\\sh --force", "force-push"),
    ("'rm' -rf /", "rm-rf-root"),
    ("r\\m -rf /", "rm-rf-root"),
    ("$'rm' -rf /", "rm-rf-root"),
    ("{git,push}", "git-push"),
    ("git pu{sh,}", "git-push"),
    ("/usr/bin/git push", "git-push"),
    ("git -C /x push --force", "force-push"),
    ("git -c user.name=x --no-pager reset --hard", "reset-hard"),
    ("git --git-dir=/x/.git commit --amend", "commit-amend"),
    ("X=1 git push", "git-push"),
    ("command git push", "git-push"),
    ("sudo -u root git push --force", "force-push"),
    ("env -u HOME X=1 git push", "git-push"),
    ("nohup git push &", "git-push"),
    ("timeout 30 git push", "git-push"),
    ("timeout -s KILL 5m git push", "git-push"),
    ("nice -n 5 git push", "git-push"),
    ("xargs -n 1 git push", "git-push"),
    ("uv run --with x git push", "git-push"),
    ("time git push", "git-push"),
    ("echo ok && git push", "git-push"),
    ("true; git push --force", "force-push"),
    ("ls | git push", "git-push"),
    ("if true; then git push; fi", "git-push"),
    ("for x in a; do git push; done", "git-push"),
    ("( git push )", "git-push"),
    ("{ git push; }", "git-push"),
    ("x=$(git push)", "git-push"),
    ("echo `git reset --hard`", "reset-hard"),
    ("bash -c 'git push --force'", "force-push"),
    ("sh -c \"rm -rf /\"", "rm-rf-root"),
    ("bash -lc 'git push'", "git-push"),
    ("bash -c 'bash -c \"git push\"'", "git-push"),
    ("eval git push --force", "force-push"),
    ("eval 'git reset --hard'", "reset-hard"),
    ("cat <<EOF | bash\ngit push\nEOF", "git-push"),
    ("bash <<'EOF'\nrm -rf /\nEOF", "rm-rf-root"),
    ("bash <<< 'git push'", "git-push"),
    ("echo 'git push --force' | sh", "force-push"),
    ("rm -rf $HOME/.claude", "rm-rf-sole-copy"),
    ("rm -rf ${HOME}/*", "rm-rf-glob"),
    ("sudo rm -rf /", "rm-rf-root"),
])
def test_dressed_forms_block(src, want):
    assert key(src) == want


# ── passes: mentions, tier C, ordinary work ────────────────────────────────

@pytest.mark.parametrize("src", [
    'echo "git push"',
    "echo git push --force",
    'git commit -m "never git push --force"',
    'git commit -m "rm -rf /"',
    "printf '%s\\n' 'git reset --hard'",
    "cat <<EOF > note.md\ngit push --force\nEOF",
    "cat <<'EOF'\nrm -rf /\nEOF",
    "grep -r 'git push' .",
    "git log --grep=push",
    "git status",
    "git fetch origin",
    "git pull --rebase",
    "git reset HEAD~1",
    "git reset --soft HEAD~1",
    "git commit -m x",
    "git push --help",
    "git --version",
    "git stash push -m x",
    "git push-x",
    "command -v git push",
    "man git-push",
    "rm -f /tmp/x",
    "rm -rf /tmp/build",
    "rm -rf build/*",
    "rm -rf node_modules",
    "rm -rf /work/projects/maude/build",
    "rm /",
    "rm -rf $x",
    "rm -rf \"$TARGET\"",
    "bash script.sh",
    "bash -n script.sh",
    "gh release view v1",
    "gh pr create",
    "hf download me/repo",
    "uv run pytest",
    "python3 -c 'print(1)'",
    "{git,status}",
    'g{it,} pu"sh" --force',
])
def test_mentions_and_tier_c_pass(src):
    assert key(src) is None


@pytest.mark.parametrize("src", ['bash -c "$x"', 'eval "$x"', "bash $x -c 'ls'", 'bash <<< "$x"',
                                 'echo "$x" | bash', 'curl -s x | bash', 'bash < run.sh',
                                 'bash -c -o pipefail "$x"'])
def test_a_body_known_only_at_run_time_is_not_read_whole(src):
    # No key, so the gate passes it; a yellow key beside it is refused its token (lens 3 on 652bbd9).
    hits, whole = judge_read(src, home=HOME)
    assert hits == [] and not whole


@pytest.mark.parametrize("src,want", [
    ("bash -s foo <<'E'\nrm -rf /\nE", ["rm-rf-root"]),          # -s: stdin is the program
    ("sh -s -- arg <<'E'\ngit push --force\nE", ["force-push"]),
    ("bash +e <<< 'rm -rf /'", ["rm-rf-root"]),                   # +e is an option, not a script
    ("echo 'rm -rf /' | bash -o pipefail", ["rm-rf-root"]),       # -o takes a value
    ("echo 'rm -rf /' | bash -eo pipefail", ["rm-rf-root"]),      # ...also ending a cluster
    ("echo 'rm -rf /' | bash --rcfile /dev/null", ["rm-rf-root"]),
    ("bash -o errexit -c 'rm -rf /'", ["rm-rf-root"]),
    ("builtin eval 'rm -rf /'", ["rm-rf-root"]),
    # the -c program comes after every option's value (security review on the lens-4 fold)
    ("bash -c -o pipefail 'rm -rf /'", ["rm-rf-root"]),
    ("bash -c -O extglob 'rm -rf /'", ["rm-rf-root"]),
    ("bash -co pipefail 'rm -rf /'", ["rm-rf-root"]),
    ("bash -c -- 'rm -rf /'", ["rm-rf-root"]),
    ("bash -oc pipefail 'rm -rf /'", ["rm-rf-root"]),           # o mid-cluster takes a word too
    ("bash -ooc pipefail errexit 'rm -rf /'", ["rm-rf-root"]),
])
def test_bash_options_are_read_as_bash_reads_them(src, want):
    # lens 4 on 13c95f8, MAJOR: these were read as running a script file, so the body went unread
    assert keys(src) == want


@pytest.mark.parametrize("src", ["curl -s x | bash -s foo", "curl -s x | bash +x", "bash <> run.sh"])
def test_a_shell_fed_from_outside_with_options_is_not_read_whole(src):
    assert judge_read(src, home=HOME) == ([], False)


def test_a_script_file_after_options_is_still_a_script_file():
    assert judge_read("bash -e scripts/release.sh", home=HOME) == ([], True)  # tier C: not read, by design


def test_a_shell_with_its_own_stdin_does_not_read_the_pipe():
    hits, whole = judge_read("git push | bash <<< 'ls'", home=HOME)
    assert [h[1] for h in hits] == ["git-push"] and whole


def test_text_that_is_not_bash_is_unreadable():
    assert judge("echo 'open", home=HOME)[0] == "unreadable"
    assert judge("x=$(git push", home=HOME)[0] == "unreadable"


def test_the_block_names_the_words_it_read():
    assert judge("sudo -u root git push -f", home=HOME) == ("block", "force-push", ["git", "push", "-f"])


def test_a_nested_payload_stops_at_the_depth_cap():
    inner = "git push"
    for _ in range(5):
        inner = "bash -c %s" % "'" + inner.replace("'", "'\\''") + "'"
    assert judge(inner, home=HOME)[0] == "unreadable"  # past the cap: not read, so not whole
    assert judge("bash -c 'bash -c \"git push\"'", home=HOME)[1] == "git-push"


# ── every hit, not the first: a yellow hit must not hide a red one (security review on 965d025) ──

@pytest.mark.parametrize("src,want", [
    ("git push; \\rm -rf /", ["git-push", "rm-rf-root"]),
    ("git push; \"rm\" -rf ~", ["git-push", "rm-rf-sole-copy"]),
    ("git commit -m x; \"git\" push -f", ["force-push"]),
    ("\"git\" push; eval 'rm -rf /'", ["git-push", "rm-rf-root"]),
    ("bash -c 'git push; git push -f'", ["git-push", "force-push"]),
    ("git push | bash <<< 'rm -rf /'", ["git-push", "rm-rf-root"]),
    ("echo 'rm -rf /' | bash <<< 'git push'", ["git-push", "rm-rf-root"]),  # two bodies, both read
    ("ls", []),
])
def test_judge_all_reads_every_command_and_payload(src, want):
    assert keys(src) == want


def test_judge_all_is_none_when_unreadable():
    assert judge_all("echo 'open", home=HOME) is None


# ── text that does not parse is not read whole: no hits, and the gate refuses a yellow token ──

@pytest.mark.parametrize("src", ["git push; \\rm -rf /\n(", "git push\nif true; then\n\\rm -rf /\nfi\n(",
                                 "echo 'open\ngit push -f"])
def test_text_that_does_not_parse_is_not_read_whole(src):
    assert judge_read(src, home=HOME, proj=PROJ, sole=SOLE) == ([], False)


def test_a_payload_body_not_read_whole_makes_the_text_not_whole():
    hits, whole = judge_read("git push; bash -c 'echo a\n('", home=HOME)
    assert [h[1] for h in hits] == ["git-push"] and not whole


def test_a_nesting_past_the_cap_is_parser_depth():
    deep = "echo x"
    for _ in range(70):
        deep = "echo $(%s)" % deep
    hits, whole = judge_read("git push; " + deep, home=HOME)
    assert [h[1] for h in hits] == ["parser-depth"] and not whole


def test_cli_says_unreadable_after_the_hits_it_read():
    # a literal payload that does not parse is unreadable at the top too (the commit
    # review on 2178e43): a parse failure at any level wins over run-time opacity
    assert _cli("git push; bash -c 'ls\n('").stdout.decode() == "block git-push git push\nunreadable\n"
    assert _cli("bash -c $'shopt -s extglob\\nls !(x)\\nenv -C /tmp git push --force'").stdout.decode() == "unreadable\n"
    assert _cli("eval \"$x\"").stdout.decode() == "opaque\n"
    assert _cli("bash -c \"$x\"; bash -c 'ls\n('").stdout.decode() == "unreadable\n"
    assert _cli("git push; eval \"$x\"").stdout.decode() == "block git-push git push\nopaque\n"
    assert _cli("shopt -s extglob\nls !(x)").stdout.decode() == "unreadable\n"


# ── the command line the gate calls ────────────────────────────────────────

def _cli(text, *args, cwd=ROOT, env_extra=None):
    env = dict(os.environ, HOME=HOME, PYTHONPATH=str(ROOT), PYTHONSAFEPATH="1")
    env.update(env_extra or {})
    return subprocess.run([sys.executable, "-m", "maude_shell.judge"] + list(args), input=text.encode(),
                          capture_output=True, cwd=str(cwd), env=env)


def test_cli_prints_one_line():
    assert _cli("git push --force").stdout.decode() == "block force-push git push --force\n"
    assert _cli("ls").stdout.decode() == "pass\n"


def test_cli_first_line_read_only_when_the_gate_asks(monkeypatch):
    # The gate's wrapper sets MAUDE_JUDGE_MARK: the first line is "read", before any
    # reading, so a judge that started and died leaves a line behind. Off by default.
    env = dict(os.environ, MAUDE_JUDGE_MARK="1")
    out = subprocess.run([sys.executable, "-m", "maude_shell.judge"], input=b"ls", capture_output=True, env=env).stdout.decode()
    assert out == "read\npass\n"
    out = subprocess.run([sys.executable, "-m", "maude_shell.judge"], input=b"ls", capture_output=True,
                         env={k: v for k, v in os.environ.items() if k != "MAUDE_JUDGE_MARK"}).stdout.decode()
    assert out == "pass\n"
    assert _cli("echo 'open").stdout.decode() == "unreadable\n"


def test_cli_prints_one_line_per_key_in_run_order():
    out = _cli("git push; git push; \\rm -rf /; git push").stdout.decode()
    assert out == "block git-push git push\nblock rm-rf-root rm -rf /\n"


def test_cli_reads_proj_and_sole():
    assert _cli("rm -rf /p/x", "--proj", "/p").stdout.decode().startswith("block rm-rf-sole-copy")
    assert _cli("rm -rf /s/a/b", "--sole", "/s/a", "--sole", "/t").stdout.decode().startswith("block rm-rf-sole-copy")
    assert _cli("rm -rf /p/x").stdout.decode() == "pass\n"


@pytest.mark.parametrize("src,want", [("rm -rf ~", "rm-rf-sole-copy"), ("rm -rf ~/*", "rm-rf-glob"),
                                      ('rm -rf "${HOME}"', "rm-rf-sole-copy"), ("rm -rf ~/.claude/x", "rm-rf-sole-copy")])
def test_cli_takes_home_from_the_environment_as_the_gate_calls_it(src, want):
    # No home= here: the gate's call hands HOME only through the environment. Every other
    # test names home, which hid that the rm rules read None while the reader read HOME.
    assert _cli(src).stdout.decode().startswith("block %s " % want)


def test_cli_survives_bytes_that_are_not_utf8():
    p = subprocess.run([sys.executable, "-m", "maude_shell.judge"], input=b"git push \xff\n", capture_output=True,
                       cwd=str(ROOT), env=dict(os.environ, PYTHONPATH=str(ROOT)))
    assert p.returncode == 0 and p.stdout.decode().startswith("block git-push")


def test_unknown_home_under_it_still_passes():
    """The home rule reads ~ as this home, not as a block on every path below it."""
    assert key("env -u HOME rm -rf ~/src") is None


@pytest.mark.parametrize("src", ["cat p | xargs echo | sh", "xargs -n1 echo git push | sh",
                                 'env -S "echo x" echo | sh', "env -Secho echo hi | sh",
                                 'env -iS "echo x" echo hi | sh', 'env --split="x" echo | sh',
                                 'env -vS "echo x" echo | sh'])
def test_a_rewritten_echo_into_a_shell_is_not_read_whole(src):
    """xargs adds stdin to the words, env -S splits new ones: the shell's text is unknown."""
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


# ── the lens on 81dbe48 ─────────────────────────────────────────────────────

def _nest(text, n):
    for _ in range(n):
        text = "bash -c '" + text.replace("'", "'\\''") + "'"
    return text


@pytest.mark.parametrize("n", [4, 5, 6])
def test_a_payload_past_the_cap_is_the_parser_depth_hit(n):
    """Unread alone let an unkeyed command pass the hook with no token at all."""
    hits, whole = judge_read(_nest("rm -rf /", n), home=HOME, proj=PROJ, sole=SOLE)
    assert [k for _, k, _ in hits] == ["parser-depth"] and whole is False


@pytest.mark.parametrize("src,want", [
    ("rm -rf /tmp/../*", "rm-rf-root"),
    ("rm -rf /usr/../*", "rm-rf-root"),
    ("rm -rf ~/./*", "rm-rf-glob"),
    ("rm -rf ~/x/../*", "rm-rf-glob"),
    ("env -u HOME rm -rf ~/./*", "rm-rf-glob"),
    ("echo -n 'rm -rf /' | sh", "rm-rf-root"),
    ("echo -e 'rm -rf /' | sh", "rm-rf-root"),
    ("printf -- 'rm -rf /' | sh", "rm-rf-root"),
])
def test_dot_paths_and_feeder_options(src, want):
    assert key(src) == want


@pytest.mark.parametrize("src", [
    "git push; ./echo ok | bash", "git push; /tmp/x/echo ok | sh",
    "git push; sudo -u $U echo ok | sh", "git push; nice -n $N echo ok | sh",
    r"git push; printf '%s\n' 'x' | sh", r"git push; printf 'x \055' | bash",
    r"git push; echo -e 'x \x2d' | sh",
])
def test_an_echo_whose_text_is_not_its_words_is_not_read_whole(src):
    """Any program named echo, a word known at run time, or escapes and formats: a yellow
    token must not open these."""
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


@pytest.mark.parametrize("src", [
    "echo() { printf 'x'; }; git push; echo ok | sh", "function printf { :; }; git push; printf ok | sh",
    "alias echo=printf; git push; echo ok | sh", "enable -n echo; git push; echo ok | sh",
    r"git push; echo 'x\ny' | sh",
])
def test_a_redefinable_or_escaping_echo_is_not_read_whole(src):
    """The commit security review on 8a49a8b: a yellow token must not open these."""
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


def test_a_relative_dot_dot_glob_is_the_cwd_glob():
    assert key("rm -rf x/../*") == "rm-rf-glob"


# ── lens 2 on 8a49a8b: an inexact feeder is still read, and .git/.. is still .git ──

@pytest.mark.parametrize("src,want", [
    ("echo -e 'true;\"rm\" -rf /;\\t' | sh", "rm-rf-root"),
    ("printf '%s\\n' 'true;\"rm\" -rf /' | sh", "rm-rf-root"),
    ("printf 'true;\"rm\" -rf /;%s\\n' x | sh", "rm-rf-root"),
    ("echo 'true;\"rm\" -rf /;\\t' | sh", "rm-rf-root"),
    ("echo -e 'true;\"git\" push -f\\n' | sh", "force-push"),
])
def test_an_inexact_feeder_still_blocks_what_its_words_hold(src, want):
    hits, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits] and whole is False


@pytest.mark.parametrize("src", ["rm -rf /x/.git/../*", '"rm" -rf /x/.git/../*'])
def test_a_dot_dot_past_git_still_deletes_git(src):
    assert key(src) == "rm-rf-sole-copy"


def test_a_branch_named_enable_is_not_a_redefinition():
    _, whole = judge_read("git push origin enable-foo", home=HOME, proj=PROJ, sole=SOLE)
    assert whole is True


@pytest.mark.parametrize("src", [
    "git push; if true; then alias echo=printf; fi; echo ok | sh", "git push; sudo enable -n echo; echo x | sh",
    "git push; 'al'ias echo=x; echo x | sh", "git push; e\\nable -n echo; echo x | sh",
    "git push; source ./env.sh; echo x | sh", "git push; . ./env.sh; echo x | sh",
    "git push; echo x | BASH_ENV=./e bash",
])
def test_a_redefinition_in_any_position_or_quoting_is_seen(src):
    """The commit security review on ffc19dc: the shadow check is not by command position."""
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


# ── the bypass list, cluster 1: the text that reaches a shell (feat/gate-bypasses) ──

@pytest.mark.parametrize("src,want", [
    ("echo 'rm -rf /' | bash /dev/stdin", "rm-rf-root"),
    ("echo 'rm -rf /' | bash /dev/fd/0", "rm-rf-root"),
    ("echo 'rm -rf /' | source /dev/stdin", "rm-rf-root"),
    ("echo 'rm -rf /' | . /dev/stdin", "rm-rf-root"),
    ("source /dev/stdin <<< 'git push --force'", "force-push"),
    ("bash <(echo 'rm -rf /')", "rm-rf-root"),
    ("source <(echo 'git push --force')", "force-push"),
    (". <(printf 'git filter-repo')", "filter-repo"),
    ("sh < <(echo 'rm -rf /')", "rm-rf-root"),
    ("echo 'rm -rf /' |& bash", "rm-rf-root"),
    ("cat <<< 'rm -rf /' | sh", "rm-rf-root"),
    ("yes 'rm -rf /' | head -1 | sh", "rm-rf-root"),
    ("echo 'rm -rf /' | tee /dev/null | sh", "rm-rf-root"),
    ("echo 'rm -rf /' | cat | sort | uniq | sh", "rm-rf-root"),
    ("echo 'rm -rf /' | xargs -0 sh -c", "rm-rf-root"),
    ("echo 'rm -rf /' | xargs -I{} sh -c '{}'", "rm-rf-root"),
])
def test_the_text_that_reaches_a_shell_is_read(src, want):
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits]


@pytest.mark.parametrize("src", ["cat x | sh", "base64 -d f | sh", "bash <(curl -s x)", "curl x | tr a b | bash"])
def test_text_the_judge_cannot_know_stays_unread(src):
    """Tier C (encoded) or residual 1 (unknown): unread, never called whole."""
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


def test_a_plain_source_of_a_file_stays_tier_c():
    """source venv/bin/activate && git push keeps its yellow token."""
    hits, whole = judge_read("source venv/bin/activate && git push", home=HOME, proj=PROJ, sole=SOLE)
    assert [k for _, k, _ in hits] == ["git-push"] and whole is True


@pytest.mark.parametrize("src,want", [
    ("{ echo 'rm -rf /'; } | sh", "rm-rf-root"),
    ("(echo 'rm -rf /') | sh", "rm-rf-root"),
    ("bash <( { echo 'rm -rf /'; } )", "rm-rf-root"),
    ("if true; then echo 'rm -rf /'; fi | sh", "rm-rf-root"),
    ("echo 'rm -rf /' | xargs -L1 sh -c", "rm-rf-root"),
])
def test_a_group_or_compound_does_not_hide_the_feeder(src, want):
    """The commit security review on 7d9f824: a group drops the pipe in the parse."""
    hits, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits] and whole is False


@pytest.mark.parametrize("src", ["yes 'ls' | head -c 1 | sh", "echo ls | sort | sh", "echo ls | cat -v | sh"])
def test_a_filter_that_changes_text_is_never_whole(src):
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


@pytest.mark.parametrize("src,want", [
    ("strace -f -o /tmp/t rm -rf /", "rm-rf-root"), ("ltrace -e malloc rm -rf /", "rm-rf-root"),
    ("unshare -m -p --fork rm -rf /", "rm-rf-root"), ("pkexec --user root git push --force", "force-push"),
    ("systemd-run --user --scope -p MemoryMax=1G rm -rf /", "rm-rf-root"),
    ("nsenter -t 1 -m -u rm -rf /", "rm-rf-root"), ("setpriv --reuid 0 rm -rf /", "rm-rf-root"),
    ("runuser -u root -- rm -rf /", "rm-rf-root"), ("chrt -f 10 rm -rf /", "rm-rf-root"),
    ("taskset 0x1 rm -rf /", "rm-rf-root"), ("taskset -c 0-1 rm -rf /", "rm-rf-root"),
    ("chroot / rm -rf /", "rm-rf-root"), ("chroot --userspec 0:0 /srv/x git push -f", "force-push"),
    ("flock -w 5 /tmp/l rm -rf /", "rm-rf-root"),
])
def test_the_new_wrappers_run_their_command(src, want):
    assert key(src) == want


@pytest.mark.parametrize("src", ["taskset -p 0x1 1234", "chrt -p 10 1234", "flock /tmp/l git status"])
def test_the_new_wrappers_pass_what_runs_nothing_red(src):
    assert key(src) is None


def test_ssh_carries_its_remote_command():
    """The bypass list: ssh HOST WORDS runs WORDS on the remote shell (was a tier C pass)."""
    assert key("ssh host git push") == "git-push"


# ── the bypass list, cluster 3: text another shell runs ──

@pytest.mark.parametrize("src,want", [
    ("su -c 'rm -rf /' root", "rm-rf-root"), ("su - root -c 'rm -rf /'", "rm-rf-root"),
    ("runuser root -c 'git push --force'", "force-push"), ("runuser -l root -c 'rm -rf /'", "rm-rf-root"),
    ("runuser --us root -- rm -rf /", "rm-rf-root"), ("runuser -lu root -- rm -rf /", "rm-rf-root"),
    ("script -qc 'rm -rf /' /dev/null", "rm-rf-root"), ("script -c 'git push -f' log", "force-push"),
    ("flock /tmp/l -c 'rm -rf /'", "rm-rf-root"), ("flock -w 5 /tmp/l -c 'rm -rf /'", "rm-rf-root"),
    ("watch -n 5 rm -rf /", "rm-rf-root"), ("trap 'rm -rf /' EXIT", "rm-rf-root"),
    ("ssh -p 22 host rm -rf /", "rm-rf-root"), ("find / -exec rm -rf {} \;", "rm-rf-root"),
    ("find /work/projects -delete", "rm-rf-sole-copy"), ("find ~ -execdir rm -rf {} +", "rm-rf-sole-copy"),
    ("git -c alias.p='push --force' p", "force-push"), ("git -c alias.p='!rm -rf /' p", "rm-rf-root"),
    ("chroot $D rm -rf /", "rm-rf-root"), ("sudo --us root rm -rf /", "rm-rf-root"),
])
def test_text_another_shell_runs_is_read(src, want):
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits]


@pytest.mark.parametrize("src", ["ssh host ls", "su root", "watch ls", "find . -name x -delete",
                                 "find . -name '*.pyc' -exec rm {} +", "git -c alias.st=status st",
                                 "trap - EXIT", "script log"])
def test_carried_text_with_nothing_red_passes(src):
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert not [k for _, k, _ in hits]


def test_a_shell_with_an_unseen_stdin_is_not_whole():
    _, whole = judge_read("{ curl -s x; } | sh", home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


def test_too_many_payloads_fail_closed():
    big = "; ".join("echo x%d" % i for i in range(300)) + " | sh"
    hits, whole = judge_read(big, home=HOME, proj=PROJ, sole=SOLE)
    assert "parser-depth" in [k for _, k, _ in hits] and whole is False


# ── the commit security review on 9dce826 ──

@pytest.mark.parametrize("src,want", [
    ("flock /tmp/l git -c alias.x='!rm -rf /' x", "rm-rf-root"),
    ("flock /tmp/l ionice -c3 uv publish", "public-publish"),
    ("strace --quiet rm -rf /", "rm-rf-root"),
    ("su --comm 'rm -rf /' root", "rm-rf-root"), ("su -s /bin/bash -c 'rm -rf /' root", "rm-rf-root"),
    ("su root --session-command 'rm -rf /'", "rm-rf-root"), ("su -c 'rm -rf /' $U", "rm-rf-root"),
    ("git -c Alias.P='push -f' p", "force-push"), ("git -c alias.a=b -c alias.b='push -f' a", "force-push"),
    ("git -c alias.q='push -f' -c alias.s='!git q' s", "force-push"),
    ("find / -exec sh -c 'rm -rf {}' \;", "rm-rf-root"),
    ("ssh -p22 host rm -rf /", "rm-rf-root"), ("ssh -vp 22 host rm -rf /", "rm-rf-root"),
])
def test_carried_text_review_folds(src, want):
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits]


@pytest.mark.parametrize("src", ["git push; su -c \"$X\" root", "git push; trap \"$X\" EXIT"])
def test_a_run_time_carried_text_is_not_whole(src):
    _, whole = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


def test_a_repeated_unterminated_heredoc_reads_fast():
    """The judge fuzzer on 9dce826: re-reading bodies through every shell grew this to 9 s;
    the hook cuts the judge at 2 s and a cut passes. Memo and budget keep it linear."""
    import time
    unit = "x=$( <<cat <<< '  \"git\" push '\\''&&-f'\\'' origin main  ' | sh )\ntrue"
    t = time.perf_counter()
    judge_read(unit * 40, home=HOME, proj=PROJ, sole=SOLE)
    assert time.perf_counter() - t < 0.5


def test_past_the_read_budget_is_parser_depth(monkeypatch):
    from maude_shell import judge as J
    monkeypatch.setattr(J, "READ_BUDGET", 10)
    hits, whole = judge_read("echo this text is longer than ten", home=HOME, proj=PROJ, sole=SOLE)
    assert [k for _, k, _ in hits] == ["parser-depth"] and whole is False


# ── the commit security reviews on ef8d92e ──

@pytest.mark.parametrize("src,want", [
    ("su --c 'rm -rf /' root", "rm-rf-root"), ("su --co='rm -rf /' root", "rm-rf-root"),
    ("su --s /bin/sh -c 'rm -rf /' root", "rm-rf-root"), ("su root -- -c 'rm -rf /'", "rm-rf-root"),
    ("flock --time 5 /tmp/l -c 'rm -rf /'", "rm-rf-root"), ("flock -w5 /tmp/l -c 'rm -rf /'", "rm-rf-root"),
    ("flock -n /tmp/l -c 'rm -rf /'", "rm-rf-root"), ("script --comm 'rm -rf /' x", "rm-rf-root"),
    ("systemd-run --expand-environment no rm -rf /", "rm-rf-root"),
    ("sudo --us root rm -rf /tmp/x", "sudo-rm-rf"),
])
def test_ef8d92e_review_folds(src, want):
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits]


def test_both_readings_never_recurse_forever():
    """A form whose two readings start at the same word looped (flock --time …)."""
    hits, _ = judge_read("flock --time 5 /tmp/l true", home=HOME, proj=PROJ, sole=SOLE)
    assert hits == []


# ── the lens on ef8d92e, the commit security review on 91730fa, and the variant hunt ──

@pytest.mark.parametrize("src,want", [
    ("find / -delete", "rm-rf-root"), ("find / -maxdepth 0 -delete", "rm-rf-root"),
    ("sudo find /var/log -delete", "sudo-rm-rf"),
    ("su root -- -ec 'rm -rf /'", "rm-rf-root"), ("su root -- -c -e 'rm -rf /'", "rm-rf-root"),
    ("flock --w 5 /tmp/l -c 'rm -rf /'", "rm-rf-root"), ("flock --wait 5 /tmp/l -c 'rm -rf /'", "rm-rf-root"),
    ("bash -c \"$SHELL -c 'rm -rf /'\"", "rm-rf-root"), ("bash -c \"$x; rm -rf /\"", "rm-rf-root"),
    ("eval \"$x; rm -rf /\"", "rm-rf-root"),
    ("su -c \"bash <(echo 'rm -rf /')\" root", "rm-rf-root"), ("ssh h 'echo \"rm -rf /\" | sh'", "rm-rf-root"),
    ("find / -maxdepth 0 -exec su -c 'rm -rf /' root \\;", "rm-rf-root"),
    ("git -C /tmp -c alias.p='push -f' p", "force-push"), ("watch -x rm -rf /", "rm-rf-root"),
    ("trap -- 'rm -rf /' INT", "rm-rf-root"), ("$SHELL -lc 'rm -rf /'", "rm-rf-root"),
    ("echo 'rm -rf /' |& tee x | sh", "rm-rf-root"), ("echo 'rm -rf /' | sort -r | sh", "rm-rf-root"),
    ("echo 'rm -rf /' | sudo -u root bash -s", "rm-rf-root"),
])
def test_bypass_variants_read_red(src, want):
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits]


@pytest.mark.parametrize("src", ["find / -name '*'", "find / -name x -o -true", "find / ! -name core",
                                 "find / -type f", "find / -mtime +0", "find / -name '*.*'",
                                 "find / -name '[a-z][a-z]*'", "find / -name \"$P\"", "find / -fprint -name",
                                 "find / -foo -name core"])
def test_a_find_test_that_may_take_everything_stays_rm_rf(src):
    """The commit security review on 2e26962: only a literal -name narrows; fail closed."""
    assert key(src + " -delete") == "rm-rf-root"


@pytest.mark.parametrize("src,want", [
    ("su -- root -c 'rm -rf /'", "rm-rf-root"), ("su -- root -ec 'rm -rf /'", "rm-rf-root"),
    ("su - -- -c 'rm -rf /'", "rm-rf-root"), ("su - root -c 'rm -rf /'", "rm-rf-root"),
    ("find / -delete -name core", "rm-rf-root"), ("find / -exec rm -rf {} \\; -name core", "rm-rf-root"),
    ("find / -name 'co[r]e' -delete", "rm-rf-root"),
])
def test_su_double_dash_before_the_user(src, want):
    """The commit security review on 4e66f8a: before any operand, -- is followed by the user."""
    assert key(src) == want


def test_su_double_dash_run_time_text_is_not_whole():
    _, whole = judge_read('git push; su root -- -c "$X"', home=HOME, proj=PROJ, sole=SOLE)
    assert whole is False


@pytest.mark.parametrize("src", ["find / -xdev -name core -delete", "find / -name core -exec rm -rf {} \\;",
                                 "find / -xdev -name core -mtime +3 -delete",
                                 "sudo find /var/log -name '*.gz' -delete", "find ~ -name '*.tmp' -delete"])
def test_a_find_with_a_test_deletes_matches_not_the_tree(src):
    """The lens on ef8d92e: a -name/-type/-mtime test picks files; not rm -rf of the start."""
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert not [k for _, k, _ in hits]


@pytest.mark.parametrize("src,want", [
    ("git -c alias.push=status push --force", "force-push"),
    ("git -c alias.reset=status reset --hard", "reset-hard"),
    ("find -D tree / -delete", "rm-rf-root"), ("find -O3 / -delete", "rm-rf-root"),
    ("find -- / -delete", "rm-rf-root"), ("find -L -- / -delete", "rm-rf-root"),
])
def test_acce506_push_review_folds(src, want):
    """git ignores an alias that shadows a builtin; find's -D/-O lead the start paths."""
    hits, _ = judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert want in [k for _, k, _ in hits]
