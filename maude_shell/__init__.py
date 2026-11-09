"""Read a shell command the way bash tokenizes it, and hand back plain data.

The gate judges words; this module only reads them. Scope and tiers live in
docs/gate-threat-model.md, the design in docs/specs/2026-10-23-shell-parser-design.md.

Expansions done here are the ones the text alone fixes: quote removal, escapes,
ANSI-C $'...', brace expansion, and ~ / $HOME / ${HOME}. Anything only known at run
time ($x, $(...), backticks, $((...))) keeps its source spelling and marks the word
dynamic. Commands inside substitutions and unquoted heredoc bodies are listed too,
because bash runs them. Text that is not complete bash comes back {"ok": False}.

Python 3.8 floor, stdlib only.
"""
import os
import pwd
import re

__all__ = ["parse", "ParseError"]

BRACE_CAP = 4096
BRACE_WORK_CAP = 2000000  # braces in a word times its length: bash's own scan is quadratic too
BRACE_ITEMS_CAP = 1000000  # characters across all the words one brace expansion makes
INT_MAX = 2 ** 63 - 1
DECL = {"declare", "typeset", "local", "readonly", "export"}
DEPTH_CAP = 64
STOP = " \t\n;&|<>()"
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSIGN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")
KEYWORD_RE = re.compile(r"(?:[a-z]+|\[\[|\]\]|[{}!])(?=[ \t\n;&|()<>]|$)")
REDIR_RE = re.compile(r"([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})?(<<<|<<-|<<|<>|<&|>&|>>|>\||&>>|&>|<|>)")
OPS = (";;&", ";;", ";&", "&&", "||", "|&", ";", "|", "&", ")")
SEQ_INT = re.compile(r"(-?[0-9]+)\.\.(-?[0-9]+)(?:\.\.(-?[0-9]+))?$")
SEQ_CHR = re.compile(r"([A-Za-z])\.\.([A-Za-z])(?:\.\.(-?[0-9]+))?$")
TIME_P = re.compile(r"-p(?=[ \t\n;&|]|$)")
TIME_DASHES = re.compile(r"--(?=[ \t\n;&|]|$)")
OCT2 = re.compile(r"[0-7]{0,2}")
HEX2 = re.compile(r"[0-9A-Fa-f]{1,2}")
HEX4 = re.compile(r"[0-9A-Fa-f]{1,4}")
HEX8 = re.compile(r"[0-9A-Fa-f]{1,8}")
HOME_READ = re.compile(r"\$HOME(?!\w)|\$\{HOME\}")
HOME_NAMED = re.compile(r"(?<!\w)HOME(?!\w)")
HOME_TEXT = re.compile(r"(?<!\$\{)(?<!\$)HOME")
QUOTING = re.compile(r"[\\'\"]")  # H\OME, 'HO'ME, $'HOME': the name a builtin is handed
COMPOUND = {"{", "if", "while", "until", "for", "select", "case", "[["}
CLOSERS = {"then", "else", "elif", "fi", "do", "done", "esac", "}", "in", "]]"}

# A word is a list of items: ("c", ch) an unquoted literal character, the only kind
# brace and tilde expansion act on; ("q", text) quoted literal text; ("b", ch) a
# backslash-escaped character; ("d", src) a run-time expansion, kept as written;
# ("v", "$name") an unquoted variable, named only after brace expansion; ("e", value)
# an unquoted $HOME or ${HOME}, already expanded.


BARE = object()  # parse_command's answer for a `time` or `!` with no command after it
# kept in a word's empty reading: `$x$SHELL -c …` runs a shell when x is empty, and the
# judge reads these as bash (its SHELL_VARS); every other run-time expansion is dropped
SHELL_KEEP = {"$SHELL", "${SHELL}", "$BASH", "${BASH}"}


class ParseError(Exception):
    pass


def parse(text, home=None):
    """Return {"ok": True, "commands": [...]} or {"ok": False, "error": str}."""
    if home is None:
        home = os.environ.get("HOME", "")
    # A HOME the command itself may set makes every ~ and $HOME in it unknown: the value on
    # this box is not bash's. Two nets: the raw text (HOME=, export H\\OME, ${HOME:=..}),
    # and the names the reader resolved, which are bash-exact ($'\\x48OME', HO\\<newline>ME).
    known = not HOME_NAMED.search(QUOTING.sub("", HOME_READ.sub("", text)))
    out, names = _run(text, home, known)
    if known and out["ok"] and _sets_home(out["commands"], names):
        out, _ = _run(text, home, False)
    return out


def _run(text, home, home_known):
    p = _Parser(text, home, [], 0)
    p.home_known = home_known
    try:
        p.parse_list("top", 0)
        p.flush_heredocs()
    except ParseError as e:
        return {"ok": False, "error": str(e)}, p.names
    except RecursionError:
        return {"ok": False, "error": "nested too deep"}, p.names
    return {"ok": True, "commands": p.commands}, p.names


def _sets_home(commands, names):
    """Any resolved word, assignment or loop name holding the text HOME, anywhere: a name
    can ride glued to an option (printf -vHOME), so the check is the bare text. A false
    hit costs only a word marked unknown. A read ($HOMEx, ${HOME...}) is not a set."""
    return any(HOME_TEXT.search(t) for t in names + [w for c in commands for w in c["words"] + c["assigns"]])


class _Parser:
    def __init__(self, s, home, commands, depth):
        self.s, self.i, self.home = s, 0, home
        self.commands = commands
        self.depth = depth
        self.pending = []
        self.home_known = True
        self.names = []  # for/select loop names, which no command lists

    # ── characters ─────────────────────────────────────────────────────────
    def eof(self):
        return self.i >= len(self.s)

    def at(self, lit):
        return self.s.startswith(lit, self.i)

    def skip_blanks(self):
        s = self.s
        while self.i < len(s):
            if s[self.i] in " \t":
                self.i += 1
            elif s.startswith("\\\n", self.i):
                self.i += 2
            else:
                break

    def skip_comment(self):
        if not self.eof() and self.s[self.i] == "#":
            j = self.s.find("\n", self.i)
            self.i = len(self.s) if j < 0 else j

    def skip_space(self, newlines=True):
        while True:
            self.skip_blanks()
            self.skip_comment()
            if newlines and self.at("\n"):
                self.newline()
            else:
                return

    def newline(self):
        self.i += 1
        if self.pending:
            self.read_heredocs()

    def peek_keyword(self):
        m = KEYWORD_RE.match(self.s, self.i)
        return m.group(0) if m else None

    def take_keyword(self, kw):
        self.i += len(kw)

    def peek_op(self):
        if self.at("&>"):
            return None
        for op in OPS:
            if self.at(op):
                return op
        return None

    def sub(self, text):
        p = _Parser(text, self.home, self.commands, self.depth)
        p.home_known = self.home_known
        p.names = self.names
        return p

    # ── lists and commands ─────────────────────────────────────────────────
    def parse_list(self, ctx, depth, end_words=(), end_ops=(), need=False):
        """Read commands until a closing keyword or operator; return which one.
        need: the list must hold a command (a then-body, a group); bash refuses one empty."""
        if depth >= DEPTH_CAP:
            raise ParseError("nested too deep")
        outer, self.depth = self.depth, depth
        try:
            return self._list(ctx, depth, end_words, end_ops, need)
        finally:
            self.depth = outer

    def _list(self, ctx, depth, end_words, end_ops, need):
        last = None
        have = False      # a command since the last separator
        owed = False      # after && || | |&, a command must follow
        piped = False     # the next command sits right after | or |&
        seen = False      # any command in this list
        while True:
            self.skip_blanks()
            self.skip_comment()
            end = None
            if self.eof():
                if end_words or end_ops:
                    raise ParseError("missing %s" % " or ".join(sorted(end_words) + sorted(end_ops)))
            elif self.at("\n"):
                self.newline()
                if last is not None and last["sep"] is None:
                    last["sep"] = "\n"
                last = None
                if not owed:
                    have = False
                continue
            else:
                op = self.peek_op()
                if op is not None:
                    self.i += len(op)
                    if op in end_ops:
                        end = op
                    elif op in (")", ";;", ";;&", ";&"):
                        raise ParseError("unexpected %r" % op)
                    else:
                        if not have or have is BARE and op != ";":
                            raise ParseError("%r with no command before it" % op)
                        if last is not None:
                            last["sep"] = op
                        last = None
                        have = False
                        owed = op not in (";", "&")
                        piped = op in ("|", "|&")
                        continue
                else:
                    kw = self.peek_keyword()
                    if kw is not None and kw in end_words:
                        self.take_keyword(kw)
                        end = kw
                    else:
                        last = self.parse_command(ctx, depth, piped)
                        have = BARE if last is BARE else True
                        last = None if last is BARE else last
                        seen = True
                        owed = False
                        continue
            if owed:
                raise ParseError("a command must follow the operator")
            if need and not seen:
                raise ParseError("empty command list")
            return end

    def parse_command(self, ctx, depth, piped=False):
        """piped: right after | or |&, where bash takes ! as an error and time as a name."""
        kw = self.peek_keyword()
        if piped and kw == "!":
            raise ParseError("'!' after a pipe")
        if kw == "coproc":
            self.take_keyword(kw)
            self.skip_blanks()
            if self.eof() or self.s[self.i] in "\n;&|)":
                raise ParseError("coproc needs a command")
            # a NAME is only a name before a compound command: coproc N zap runs N
            m = NAME_RE.match(self.s, self.i)
            if m:
                j = m.end()
                while j < len(self.s) and self.s[j] in " \t":
                    j += 1
                nxt = KEYWORD_RE.match(self.s, j)
                if self.s.startswith("(", j) or nxt and nxt.group(0) in COMPOUND:
                    self.i = j
            return self.parse_command(ctx, depth)
        if kw == "!" or kw == "time" and not piped:
            self.take_keyword(kw)
            self.skip_blanks()
            if kw == "time" and TIME_P.match(self.s, self.i):
                self.i += 2
                self.skip_blanks()
            if kw == "time" and TIME_DASHES.match(self.s, self.i):
                self.i += 2
                self.skip_blanks()
            if self.eof() or self.s[self.i] in "\n;&|)":
                return BARE  # `time` or `!` with nothing: bash allows it before ; but not &&
            return self.parse_command(ctx, depth)
        if kw == "if":
            self.take_keyword(kw)
            self.parse_list(ctx, depth, {"then"}, need=True)
            while True:
                t = self.parse_list(ctx, depth, {"elif", "else", "fi"}, need=True)
                if t == "elif":
                    self.parse_list(ctx, depth, {"then"}, need=True)
                elif t == "else":
                    self.parse_list(ctx, depth, {"fi"}, need=True)
                    break
                else:
                    break
        elif kw in ("while", "until"):
            self.take_keyword(kw)
            self.parse_list(ctx, depth, {"do"}, need=True)
            self.parse_list(ctx, depth, {"done"}, need=True)
        elif kw in ("for", "select"):
            self.take_keyword(kw)
            self.parse_for(ctx, depth)
        elif kw == "case":
            self.take_keyword(kw)
            self.parse_case(ctx, depth)
        elif kw == "{":
            self.take_keyword(kw)
            self.parse_list("group" if ctx == "top" else ctx, depth + 1, {"}"}, need=True)
        elif kw == "[[":
            self.take_keyword(kw)
            self.parse_test()
        elif kw == "function":
            self.take_keyword(kw)
            self.skip_blanks()
            if not NAME_RE.match(self.s, self.i) and self.peek_keyword() is None:
                raise ParseError("function needs a name")
            self.word()
            self.skip_blanks()
            if re.match(r"\([ \t]*\)", self.s[self.i:self.i + 64]):
                self.empty_parens()
            self.parse_body(depth)
            return None
        elif self.at("(("):
            self.i += 2
            self.arith()
        elif self.at("("):
            self.i += 1
            self.parse_list("subshell" if ctx == "top" else ctx, depth + 1, (), {")"}, need=True)
        elif kw in CLOSERS:
            raise ParseError("unexpected %r" % kw)
        else:
            return self.simple(ctx, depth)
        self.after_compound()
        return None

    def parse_body(self, depth):
        """A function body: bash takes only a compound command here."""
        self.skip_space()
        kw = self.peek_keyword()
        if kw == "{":
            self.take_keyword("{")
            self.parse_list("function", depth + 1, {"}"}, need=True)
        elif self.at("(") and not self.at("(("):
            self.i += 1
            self.parse_list("function", depth + 1, (), {")"}, need=True)
        elif kw in ("if", "while", "until", "for", "select", "case", "[[") or self.at("(("):
            self.parse_command("function", depth + 1)
            return
        else:
            raise ParseError("a function body must be a compound command")
        self.after_compound()

    def empty_parens(self):
        self.i += 1
        self.skip_blanks()
        if not self.at(")"):
            raise ParseError("expected ()")
        self.i += 1

    def parse_for(self, ctx, depth):
        self.skip_blanks()
        if self.at("(("):
            self.i += 2
            self.arith()
        else:
            if not NAME_RE.match(self.s, self.i):
                raise ParseError("for needs a name")
            self.names.append("".join(t for _, t in self.word()))
            self.skip_space()
            if self.peek_keyword() == "in":
                self.take_keyword("in")
                while True:
                    self.skip_blanks()
                    self.skip_comment()
                    if self.eof() or self.s[self.i] in ";\n":
                        break
                    if self.s[self.i] in STOP:
                        raise ParseError("unexpected %r in for" % self.s[self.i])
                    self.word()
        self.skip_blanks()
        if self.at(";"):
            self.i += 1
        self.skip_space()
        kw = self.peek_keyword()
        if kw == "do":
            self.take_keyword(kw)
            self.parse_list(ctx, depth, {"done"}, need=True)
        elif kw == "{":
            self.take_keyword(kw)
            self.parse_list(ctx, depth, {"}"}, need=True)
        else:
            raise ParseError("for without do")

    def parse_case(self, ctx, depth):
        self.skip_blanks()
        if self.eof() or self.s[self.i] in STOP:
            raise ParseError("case needs a word")
        self.word()
        self.skip_space()
        if self.peek_keyword() != "in":
            raise ParseError("case without in")
        self.take_keyword("in")
        while True:
            self.skip_space()
            if self.eof():
                raise ParseError("missing esac")
            if self.peek_keyword() == "esac":
                self.take_keyword("esac")
                return
            if self.at("("):
                self.i += 1
            while True:
                self.skip_blanks()
                if self.eof() or self.s[self.i] in STOP:
                    raise ParseError("bad case pattern")
                self.word()
                self.skip_blanks()
                if self.at("|"):
                    self.i += 1
                elif self.at(")"):
                    self.i += 1
                    break
                else:
                    raise ParseError("bad case pattern")
            if self.parse_list(ctx, depth, {"esac"}, {";;&", ";;", ";&"}) == "esac":
                return

    def parse_test(self):
        while True:
            self.skip_space()
            if self.eof():
                raise ParseError("missing ]]")
            if self.peek_keyword() == "]]":
                self.take_keyword("]]")
                return
            if self.s[self.i] in "&|<>()!;":
                self.i += 1
            else:
                self.word()

    def after_compound(self):
        """Only redirects may follow a compound command, then a separator or a closer."""
        self.trailing_redirects()
        self.skip_comment()
        if self.eof() or self.s[self.i] in "\n;&|)" or self.peek_keyword() in CLOSERS:
            return
        raise ParseError("a word after a compound command")

    def trailing_redirects(self):
        while True:
            self.skip_blanks()
            r = self.redirect()
            if r is None:
                return

    def redirect(self, rec=None):
        m = REDIR_RE.match(self.s, self.i)
        if not m:
            return None
        fd, op = m.group(1), m.group(2)
        if op in ("<", ">") and self.s.startswith("(", m.end()):
            return None  # a process substitution, read as a word
        self.i = m.end()
        self.skip_blanks()
        if self.eof() or self.s[self.i] in STOP and not self.s.startswith(("<(", ">("), self.i):
            raise ParseError("redirect %s needs a target" % op)
        if op in ("<<", "<<-"):
            items = self.word()
            h = {"delim": "".join(t for _, t in items),
                 "quoted": any(k in "qb" for k, _ in items),
                 "strip_tabs": op == "<<-", "body": "", "terminated": False}
            self.pending.append(h)
            if rec is not None:
                rec["heredocs"].append(h)
            return h
        target = self.finish(self.word(), brace=False)
        text, dyn, glob = target[0][:3] if target else ("", False, False)
        r = {"op": op, "fd": fd, "target": text, "dynamic": dyn, "glob": glob}
        if rec is not None:
            rec["redirects"].append(r)
        return r

    def simple(self, ctx, depth):
        rec = {"words": [], "dynamic": [], "glob": [], "empty": [], "assigns": [], "redirects": [],
               "heredocs": [], "context": ctx, "depth": depth, "sep": None}
        while True:
            self.skip_blanks()
            if self.eof():
                break
            c = self.s[self.i]
            if c == "#":
                self.skip_comment()
                continue
            if self.redirect(rec) is not None:
                continue
            if c in "\n;&|)":
                break
            if c == "(":
                if len(rec["words"]) == 1 and not rec["assigns"] and not rec["redirects"]:
                    self.empty_parens()
                    self.parse_body(depth)
                    return None
                raise ParseError("unexpected '('")
            items = self.word()
            if not rec["words"] and self.is_assign(items):
                if self.at("("):
                    items = items + [("q", self.array())]
                rec["assigns"].append(self.tilde_assign(items)[0])
                continue
            if rec["words"] and rec["words"][0] in DECL and self.at("(") and self.is_assign(items):
                items = items + [("q", self.array())]  # declare -a a=(1 2): bash allows it here
            for text, dyn, glob, empty in self.finish(items):
                rec["words"].append(text)
                rec["dynamic"].append(dyn)
                rec["glob"].append(glob)
                rec["empty"].append(empty)
        if rec["words"] or rec["assigns"] or rec["redirects"] or rec["heredocs"]:
            self.commands.append(rec)
            return rec
        return None

    def array(self):
        self.i += 1
        vals = []
        while True:
            self.skip_space()
            if self.eof():
                raise ParseError("missing ) in array")
            if self.at(")"):
                self.i += 1
                return "(" + " ".join(vals) + ")"
            if self.s[self.i] in STOP:
                raise ParseError("unexpected %r in array" % self.s[self.i])
            vals.extend(w[0] for w in self.finish(self.word()))

    # ── heredocs ───────────────────────────────────────────────────────────
    def read_heredocs(self):
        s = self.s
        for h in self.pending:
            body = []
            while self.i < len(s):
                line, j = self.physical_line()
                if h["strip_tabs"]:
                    line = line.lstrip("\t")
                # unquoted: a line ending in an odd run of \ joins the next, and the delimiter
                # is compared on the joined line (bash's read_secondary_line)
                while not h["quoted"] and j >= 0 and self.i < len(s) and \
                        (len(line) - len(line.rstrip("\\"))) % 2 == 1:
                    nxt, j = self.physical_line()
                    line = line[:-1] + nxt
                if line == h["delim"]:
                    h["terminated"] = True
                    break
                body.append(line + ("\n" if j >= 0 else ""))
            h["body"] = "".join(body)
            if not h["quoted"]:
                self.sub(h["body"]).expand_body()
        self.pending = []

    def physical_line(self):
        """The next line and the index of its newline (-1 at the end of the text)."""
        s = self.s
        j = s.find("\n", self.i)
        end = len(s) if j < 0 else j
        line = s[self.i:end]
        self.i = end + 1 if j >= 0 else end
        return line, j

    def flush_heredocs(self):
        for h in self.pending:
            h["terminated"] = False
        self.pending = []

    def expand_body(self):
        """An unquoted heredoc body: run its substitutions the way bash does."""
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c == "\\":
                self.i += 2
            elif c == "$":
                self.dollar(dq=True)
            elif c == "`":
                self.backtick(dq=True)
            else:
                self.i += 1

    # ── words ──────────────────────────────────────────────────────────────
    def word(self):
        s, start = self.s, self.i
        items = []
        if s.startswith(("<(", ">("), self.i):
            self.i += 2
            self.subst()
            return [("d", s[start:self.i])]
        while self.i < len(s):
            c = s[self.i]
            if c in STOP:
                break
            if c == "\\":
                if self.i + 1 >= len(s):
                    items.append(("q", "\\"))
                    self.i += 1
                elif s[self.i + 1] == "\n":
                    self.i += 2
                else:
                    items.append(("b", s[self.i + 1]))
                    self.i += 2
            elif c == "'":
                j = s.find("'", self.i + 1)
                if j < 0:
                    raise ParseError("open single quote")
                items.append(("q", s[self.i + 1:j]))
                self.i = j + 1
            elif c == '"':
                self.i += 1
                items.extend(self.dquote())
            elif c == "$":
                items.append(self.dollar(dq=False))
            elif c == "`":
                items.append(self.backtick(dq=False))
            else:
                items.append(("c", c))
                self.i += 1
        if self.i == start:
            # every caller loops on word(); one that reads nothing would spin forever
            raise ParseError("cannot read %r" % s[self.i:self.i + 1])
        return items

    def dquote(self):
        s = self.s
        items = [("q", "")]
        while True:
            if self.i >= len(s):
                raise ParseError("open double quote")
            c = s[self.i]
            if c == '"':
                self.i += 1
                return items
            if c == "\\" and self.i + 1 < len(s) and s[self.i + 1] in '$`"\\\n':
                if s[self.i + 1] != "\n":
                    items.append(("q", s[self.i + 1]))
                self.i += 2
            elif c == "$":
                it = self.dollar(dq=True)
                items.append(it if it[0] == "d" else ("q", it[1]))
            elif c == "`":
                items.append(self.backtick(dq=True))
            else:
                items.append(("q", c))
                self.i += 1

    def dollar(self, dq):
        s, start = self.s, self.i
        nxt = s[self.i + 1] if self.i + 1 < len(s) else ""
        if s.startswith("$((", self.i):
            self.i += 3
            self.arith()
            return ("d", s[start:self.i])
        if nxt == "(":
            self.i += 2
            self.subst()
            return ("d", s[start:self.i])
        if nxt == "[":
            self.i += 2
            self.old_arith()
            return ("d", s[start:self.i])
        if nxt == "{":
            self.i += 2
            self.braced(dq)
            inner = s[start + 2:self.i - 1]
            if inner == "HOME" and self.home_known:
                return ("q" if dq else "e", self.home)
            return ("d", s[start:self.i])
        if nxt == "'" and not dq:
            self.i += 2
            return ("q", self.ansi_c())
        if nxt == '"' and not dq:
            self.i += 2
            items = self.dquote()
            if any(k == "d" for k, _ in items):
                return ("d", s[start:self.i])
            return ("q", "".join(t for _, t in items))
        m = NAME_RE.match(s, self.i + 1)
        if m:
            self.i = m.end()
            if not dq:
                return ("v", s[start:self.i])  # named after brace expansion (see resolve)
            if m.group(0) == "HOME" and self.home_known:
                return ("q", self.home)
            return ("d", s[start:self.i])
        if nxt and nxt in "0123456789@*#?$!-":
            self.i += 2
            return ("d", s[start:self.i])
        self.i += 1
        return ("c", "$")

    def subst(self):
        """The rest of $( or <( up to its ). A heredoc opened on this line before it is read
        after the line, not at a newline inside the substitution (bash's order)."""
        outer, self.pending = self.pending, []
        try:
            self.parse_list("subst", self.depth + 1, (), {")"})
        finally:
            self.pending = outer + self.pending

    def old_arith(self):
        """The rest of $[ ... ], bash's old arithmetic: substitutions inside still run."""
        s, level = self.s, 0
        while True:
            if self.i >= len(s):
                raise ParseError("open $[")
            c = s[self.i]
            if c == "[":
                level += 1
            elif c == "]":
                if level == 0:
                    self.i += 1
                    return
                level -= 1
            elif c == "$":
                self.dollar(dq=True)
                continue
            elif c == "`":
                self.backtick(dq=True)
                continue
            elif c == "\\":
                self.i += 1
            self.i += 1

    def braced(self, dq):
        """Read the rest of ${...}; nested ${ and $( count, quotes delimit."""
        s, level = self.s, 1
        while True:
            if self.i >= len(s):
                raise ParseError("open ${")
            c = s[self.i]
            if c == "\\":
                self.i += 2
            elif c == "'":
                # a ' delimits here either way; inside double quotes what it spans still
                # expands (bash: "${x:-'$(y)'}" runs y, and the } it holds does not close)
                j = s.find("'", self.i + 1)
                if j < 0:
                    raise ParseError("open single quote")
                if dq:
                    self.sub(s[self.i + 1:j]).expand_body()
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.dquote()
            elif s.startswith("${", self.i):
                self.i += 2
                level += 1
            elif c == "$":
                self.dollar(dq=True)
            elif c == "`":
                self.backtick(dq=True)
            elif c == "}":
                self.i += 1
                level -= 1
                if level == 0:
                    return
            else:
                self.i += 1

    def arith(self):
        """Read the rest of $(( or (( up to its )). Substitutions inside still run, quoted
        or not."""
        s, level = self.s, 0
        while True:
            if self.i >= len(s):
                raise ParseError("open ((")
            c = s[self.i]
            if c == "(":
                level += 1
                self.i += 1
            elif c == ")":
                if level == 0:
                    if s.startswith("))", self.i):
                        self.i += 2
                        return
                    raise ParseError("unbalanced ) in ((")
                level -= 1
                self.i += 1
            elif c == "$":
                self.dollar(dq=True)
            elif c == "`":
                self.backtick(dq=True)
            elif c == "\\":
                self.i += 2
            else:
                self.i += 1  # quotes do not quote here: "$(x)" and '$(x)' both run

    def backtick(self, dq):
        s, start = self.s, self.i
        self.i += 1
        out = []
        while True:
            if self.i >= len(s):
                raise ParseError("open backtick")
            c = s[self.i]
            if c == "`":
                self.i += 1
                break
            if c == "\\" and self.i + 1 < len(s) and (s[self.i + 1] in "$`\\" or (dq and s[self.i + 1] == '"')):
                out.append(s[self.i + 1])
                self.i += 2
            else:
                out.append(c)
                self.i += 1
        p = self.sub("".join(out))
        p.parse_list("subst", self.depth + 1)
        p.flush_heredocs()
        return ("d", s[start:self.i])

    def ansi_c(self):
        s, out = self.s, []
        simple = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
                  "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
        while True:
            if self.i >= len(s):
                raise ParseError("open $'")
            c = s[self.i]
            if c == "'":
                self.i += 1
                text = "".join(out)
                return text.split("\x00", 1)[0]  # bash strings are C strings: a NUL ends it
            if c != "\\" or self.i + 1 >= len(s):
                out.append(c)
                self.i += 1
                continue
            e = s[self.i + 1]
            self.i += 2
            if e in simple:
                out.append(simple[e])
            elif e in "01234567":
                m = OCT2.match(s, self.i)
                out.append(chr(int(e + m.group(0), 8) & 0xFF))
                self.i = m.end()
            elif e == "x":
                m = HEX2.match(s, self.i)
                if m:
                    out.append(chr(int(m.group(0), 16)))
                    self.i = m.end()
                else:
                    out.append("\\x")
            elif e in "uU":
                m = (HEX4 if e == "u" else HEX8).match(s, self.i)
                if m:
                    out.append(chr(min(int(m.group(0), 16), 0x10FFFF)))
                    self.i = m.end()
                else:
                    out.append("\\" + e)
            elif e == "c" and self.i < len(s):
                out.append(chr(ord(s[self.i]) & 0x1F))
                self.i += 1
            else:
                out.append("\\" + e)

    # ── expansion ──────────────────────────────────────────────────────────
    @staticmethod
    def is_assign(items):
        lead = []
        for k, t in items:
            if k != "c":
                break
            lead.append(t)
        return bool(ASSIGN_RE.match("".join(lead)))

    def finish(self, items, brace=True):
        """Brace, then tilde: the words bash would pass. Returns [(text, dynamic, glob, empty)]:
        `empty` is the word's EMPTY READING, its text with every run-time expansion dropped,
        what bash runs when each comes out empty (`${x}git` is `git`; `$x` is nothing). A
        word with no expansion is its own empty reading."""
        out = []
        words = expand_braces(items) if brace else [items]
        # bash drops the x=~ rule for a word brace expansion changed (x=~/{a,b} keeps ~)
        braced = not (len(words) == 1 and words[0] == items)
        for w in words:
            w = self.tilde(self.resolve(w), assign=not braced)
            if not w or all(k == "c" for k, _ in w) and not "".join(t for _, t in w):
                continue
            out.append(("".join(t for _, t in w), any(k == "d" for k, _ in w), _is_glob(w),
                        "".join(t for k, t in w if k != "d" or t in SHELL_KEEP)))
        return out

    def resolve(self, items):
        """Name each unquoted $var now: brace expansion may have glued letters onto it."""
        out, n = [], 0
        while n < len(items):
            k, t = items[n]
            n += 1
            if k != "v":
                out.append((k, t))
                continue
            while n < len(items) and items[n][0] == "c" and (items[n][1].isalnum() or items[n][1] == "_") \
                    and items[n][1].isascii():
                t += items[n][1]
                n += 1
            out.append(("e", self.home) if t == "$HOME" and self.home_known else ("d", t))
        return out

    def tilde_span(self, items, j, assign=False):
        """A tilde prefix at items[j]: (replacement, end) for items[j:end], or None.

        bash reads up to the next / (or : in an assignment value) and expands nothing if
        a quote or escape sits there. The user name ends at the first : or =~
        (~root:x is the root home, then :x). Where bash gets odd, an unquoted $ in that stretch, a second
        =~ it would chain inside an assignment, or ~+ ~- ~N (the directory stack), the ~ is
        marked dynamic: the gate is told it cannot know, not handed a guess.
        """
        if j >= len(items) or items[j] != ("c", "~"):
            return None
        ends = "/:" if assign else "/"
        k = j + 1
        name = []
        while k < len(items) and items[k][0] == "c" and items[k][1] not in ends:
            name.append(items[k][1])
            k += 1
        unknown = ([("d", "~")], j + 1)
        if k < len(items) and items[k][0] in "qb":
            return None
        if k < len(items) and items[k][0] in "dve":
            return unknown
        text = "".join(name)
        m = re.search(r":|=~", text)
        user = text[:m.start()] if m else text
        if assign and "=~" in text[len(user):]:
            return unknown
        if re.fullmatch(r"[+-]?[0-9]*", user) and user:
            return unknown
        if user == "":
            if not self.home_known:
                return unknown
            val = self.home
        elif re.fullmatch(r"[A-Za-z0-9._-]+", user):
            try:
                val = pwd.getpwnam(user).pw_dir
            except KeyError:
                return None
        else:
            return None
        return [("q", val)], j + 1 + len(user)

    def tilde(self, items, assign=True):
        if assign and self.is_assign(items):
            return self.tilde_assign(items)[1]
        r = self.tilde_span(items, 0)
        return items if r is None else r[0] + items[r[1]:]

    def tilde_assign(self, items):
        """Assignment value: tilde after the first = and after each unquoted :. One pass."""
        eq = next(n for n, it in enumerate(items) if it == ("c", "="))
        out, n, start = items[:eq + 1], eq + 1, True
        while n < len(items):
            r = self.tilde_span(items, n, assign=True) if start else None
            if r is not None:
                out.extend(r[0])
                n = r[1]
                start = False
                continue
            out.append(items[n])
            start = items[n] == ("c", ":")
            n += 1
        return "".join(t for _, t in out), out


def _is_glob(items):
    """An unquoted * or ?, or an unquoted [ with an unquoted ] after it: bash may expand it."""
    seen_open = False
    for k, t in items:
        if k != "c":
            continue
        if t in "*?" or t == "]" and seen_open:
            return True
        seen_open = seen_open or t == "["
    return False


def expand_braces(items):
    """Bash brace expansion over a word's items; only ("c", ...) braces count."""
    opens = sum(1 for it in items if it == ("c", "{"))
    if opens and opens * len(items) > BRACE_WORK_CAP:
        raise ParseError("a word with %d braces is past what can be read in time" % opens)
    out = _braces(items)
    if len(out) > BRACE_CAP:
        raise ParseError("brace expansion past %d words" % BRACE_CAP)
    return out


def _braces(items):
    """bash 5.2 braces.c brace_expand, over items: ("c", ...) is the unquoted raw text;
    quoted, escaped and $-items are inert, as bash's gobbler skips them."""
    j = 0
    while True:
        j = _opener(items, j)
        if j is None:
            return [items]
        k = _close(items, j + 1)
        if k is not None:
            break
        j += 1
    pre, amble, post = items[:j], items[j + 1:k], items[k + 1:]
    # bash checks the amble for a comma skipping only backslashes, so a quoted one counts
    if not any((t == "," if kind == "c" else "," in t) for kind, t in amble if kind != "b"):
        alts = _sequence(amble)
        if alts is None:
            if not post:
                return [items]
            alts = [items[j:k + 1]]  # not a sequence: kept whole, the rest still expands
    else:
        alts = [a for piece in _split(amble) for a in _braces(piece)]
    tails = _braces(post) if post else [[]]
    res, size = [], 0
    for a in alts:
        for t in tails:
            size += len(pre) + len(a) + len(t)
            if len(res) >= BRACE_CAP:
                raise ParseError("brace expansion past %d words" % BRACE_CAP)
            if size > BRACE_ITEMS_CAP:
                raise ParseError("brace expansion past %d characters" % BRACE_ITEMS_CAP)
            res.append(pre + a + t)
    return res


def _opener(items, j):
    for n in range(j, len(items)):
        if items[n] != ("c", "{"):
            continue
        # bash ignores a { with a blank (or nothing) before it and } right after it; the
        # raw char before an escaped blank is the blank, the raw char after { is never one
        before = n == 0 or items[n - 1][0] == "b" and items[n - 1][1] in " \t\n"
        if before and n + 1 < len(items) and items[n + 1] == ("c", "}"):
            continue
        return n
    return None


def _close(items, j):
    """The } that closes a brace opened before j: at level 0, after a top-level , or .."""
    level = commas = 0
    for k in range(j, len(items)):
        t = items[k]
        if t == ("c", "}") and level == 0 and commas:
            return k
        if t == ("c", "{"):
            level += 1
        elif t == ("c", "}"):
            if level:
                level -= 1
        elif level == 0 and (t == ("c", ",") or t == ("c", ".") and k + 1 < len(items)
                             and items[k + 1] == ("c", ".")
                             and not (k + 2 < len(items) and items[k + 2] == ("c", "}"))):
            commas += 1
    return None


def _split(amble):
    pieces, cur, level = [], [], 0
    for t in amble:
        if t == ("c", "{"):
            level += 1
        elif t == ("c", "}") and level:
            level -= 1
        elif t == ("c", ",") and level == 0:
            pieces.append(cur)
            cur = []
            continue
        cur.append(t)
    pieces.append(cur)
    return pieces


def _sequence(inner):
    if any(k != "c" for k, _ in inner):
        return None
    text = "".join(t for _, t in inner)
    m = SEQ_INT.match(text)
    if m:
        # bash reads these as intmax_t; one that overflows makes the brace literal
        if any(g and len(g.lstrip("-")) > 19 for g in m.groups()):
            return None
        a, b = int(m.group(1)), int(m.group(2))
        step = abs(int(m.group(3) or 1)) or 1
        if max(abs(a), abs(b), step) > INT_MAX:
            return None
        if abs(b - a) // step + 1 > BRACE_CAP:
            raise ParseError("brace expansion past %d words" % BRACE_CAP)
        width = max(len(m.group(1)), len(m.group(2))) \
            if re.match(r"-?0[0-9]", m.group(1)) or re.match(r"-?0[0-9]", m.group(2)) else 0
        rng = range(a, b + 1, step) if a <= b else range(a, b - 1, -step)
        return [[("c", c) for c in ("%0*d" % (width, n) if width else str(n))] for n in rng]
    m = SEQ_CHR.match(text)
    if m:
        a, b = ord(m.group(1)), ord(m.group(2))
        step = abs(int(m.group(3) or 1)) or 1
        rng = range(a, b + 1, step) if a <= b else range(a, b - 1, -step)
        return [[("c", chr(n))] for n in rng]
    return None
