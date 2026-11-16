import pytest

from maude_rolodex.page import PageError, parse, render_cue, validate, words

GOOD = b"""trade: mending
what: putting right a thing that broke
when: mend this fence
when: Needs Mending, please
provider: skill | handyman:mend | handyman@mk@1.0.0 | read in full 2026-11-10 by Claude
pick: skill | handyman:mend | does it weekly
cue: Call the handyman before you pick up the hammer.
---
free notes: when: not a phrase
"""


def test_words_ascii_lower_and_separators():
    assert words("Code-Review, PLEASE! café x2") == ["code", "review", "please", "caf", "x2"]


def test_parse_good_page():
    p = parse(GOOD)
    assert p.trade == "mending"
    assert p.phrases == [["mend", "this", "fence"], ["needs", "mending", "please"]]
    assert (p.pick_kind, p.pick_name) == ("skill", "handyman:mend")
    assert p.providers == [("skill", "handyman:mend",
                            "handyman@mk@1.0.0", "read in full 2026-11-10 by Claude")]
    assert validate(p) == []


def test_notes_after_rule_are_not_parsed():
    assert len(parse(GOOD).phrases) == 2


def test_crlf_and_bom_parse_the_same():
    assert parse(b"\xef\xbb\xbf" + GOOD.replace(b"\n", b"\r\n")) == parse(GOOD)


def test_blank_lines_before_rule_are_ignored():
    assert parse(GOOD.replace(b"what:", b"\nwhat:")) == parse(GOOD)


def test_avoid_and_pipe_splitting():
    p = parse(GOOD.replace(b"---\n", b"avoid: bad-one | slow | seen | twice\n---\n"))
    assert p.avoid == [("bad-one", "slow", "seen | twice")]


def test_render_cue_exact():
    assert render_cue(parse(GOOD)) == ("**Maude:** I know who handles that: mending -> "
        "handyman:mend (skill). Call the handyman before you pick up the hammer.")


@pytest.mark.parametrize("old,new,needle", [
    (b"when: mend this fence\n", b"when: mend\n", "2 to 6 words"),
    (b"when: mend this fence\n", b"when: a b c d e f g\n", "2 to 6 words"),
    (b"cue: Call", b"cue: " + b"x" * 201 + b" Call", "200 bytes"),
    (b"trade: mending", b"trade: " + b"t" * 260, "300 bytes"),
    (b"cue: Call", b"cue: \x1b[31mCall", "control"),
    (b"cue: Call", b"cue: a\tb Call", "control"),
])
def test_validate_refuses(old, new, needle):
    errs = validate(parse(GOOD.replace(old, new)))
    assert any(needle in e for e in errs)


def test_no_when_line_is_refused():
    errs = validate(parse(GOOD.replace(b"when: mend this fence\n", b"").replace(b"when: Needs Mending, please\n", b"")))
    assert any("at least one" in e for e in errs)


@pytest.mark.parametrize("bad", [
    GOOD.replace(b"cue: ", b"cue2: "), GOOD.replace(b"pick: skill", b"pick: wizard"),
    GOOD.replace(b"---\n", b"cue: twice\n---\n"), GOOD.replace(b"trade: mending\n", b""),
    GOOD.replace(b"trade:", b"stray line\ntrade:"),
])
def test_parse_errors(bad):
    with pytest.raises(PageError):
        parse(bad)


def test_own_trade_needs_no_provider():
    p = parse(NO_PROVIDER.replace(b"pick: skill | handyman:mend |", b"pick: own | - |"))
    assert p.pick_kind == "own" and validate(p) == []



NO_PROVIDER = GOOD.replace(
    b"provider: skill | handyman:mend | handyman@mk@1.0.0 | read in full 2026-11-10 by Claude\n", b"")
RECIPE = NO_PROVIDER.replace(
    b"pick: skill | handyman:mend |", b"pick: recipe | ~/.claude/maude/recipes/a/SKILL.md |",
).replace(b"cue:", b"pin: " + b"a" * 64 + b"\ncue:")
PIN = b"pin: " + b"a" * 64


def test_recipe_page_parses_and_validates():
    p = parse(RECIPE)
    assert p.pick_kind == "recipe" and p.pin == "a" * 64
    assert validate(p) == []


def test_pin_defaults_to_empty():
    assert parse(GOOD).pin == ""


@pytest.mark.parametrize("old,new,needle", [
    (PIN + b"\n", b"", "pin"),
    (PIN, b"pin: " + b"a" * 63, "pin"),
    (PIN, b"pin: " + b"A" * 64, "pin"),
    (b"~/.claude/", b"recipes/", "path"),
])
def test_recipe_validate_refuses(old, new, needle):
    assert any(needle in e for e in validate(parse(RECIPE.replace(old, new))))


def test_pin_on_skill_page_is_refused():
    errs = validate(parse(GOOD.replace(b"cue:", PIN + b"\ncue:")))
    assert any("pin" in e for e in errs)


def test_two_pin_lines_raise():
    with pytest.raises(PageError):
        parse(RECIPE.replace(b"cue:", b"pin: " + b"b" * 64 + b"\ncue:"))


def test_recipe_render_cue():
    cue = render_cue(parse(RECIPE))
    assert cue.endswith("(recipe). Call the handyman before you pick up the hammer.")
    assert "~/.claude/maude/recipes/a/SKILL.md" in cue


def _cue(text: str) -> bytes:
    return GOOD.replace(b"cue: Call", b"cue: " + text.encode("utf-8") + b" Call")


@pytest.mark.parametrize("ch", ["\x0c", "\x1c", "\u2028", "\u0085", "\u202e", "\u200b", "\x00", "\x7f"])
def test_cue_with_hidden_character_is_refused(ch):
    assert any("control" in e for e in validate(parse(_cue("a" + ch + "b"))))


def test_formfeed_does_not_end_the_header():
    data = GOOD.replace(b"cue: Call", b"cue: hi\x0c---\nwhen: and so on now\ncue2: Call")
    with pytest.raises(PageError):
        parse(data)
    data = GOOD.replace(b"cue: Call the handyman", b"cue: hi\x0c---\nwhen: and so on now\nx: Call")
    with pytest.raises(PageError):
        parse(data)


def test_formfeed_line_is_not_dropped_silently():
    p = parse(GOOD.replace(b"cue: Call", b"cue: hi\x0c---"))
    assert "\x0c" in p.cue and any("control" in e for e in validate(p))


@pytest.mark.parametrize("old,new", [
    (b"what: putting", b"what: pu\x07tting"),
    (b"handyman@mk@1.0.0", b"handyman@mk@1.\x1b0.0"),
    (b"does it weekly", b"does it\x0bweekly"),
    (b"when: mend this fence", b"when: mend\x0ethis fence"),
])
def test_hidden_character_in_any_field_is_refused(old, new):
    assert any("control" in e for e in validate(parse(GOOD.replace(old, new))))


def test_avoid_part_with_hidden_character_is_refused():
    p = parse(GOOD.replace(b"---\n", "avoid: bad | sl\u200bow | seen\n---\n".encode(), 1))
    assert any("control" in e for e in validate(p))


def test_non_ascii_letters_are_refused():
    for old, new in ((b"trade: mending", "trade: caf\u00e9".encode()),
                     (b"cue: Call", "cue: \u4fee\u7406 Call".encode())):
        assert any("ASCII" in e for e in validate(parse(GOOD.replace(old, new))))


def test_invalid_utf8_raises():
    with pytest.raises(PageError):
        parse(GOOD.replace(b"cue: Call", b"cue: \xff\xfe Call"))


def test_second_bom_is_not_stripped():
    with pytest.raises(PageError):
        parse(b"\xef\xbb\xbf\xef\xbb\xbf" + GOOD)


def test_bom_with_crlf_equals_good():
    assert parse(b"\xef\xbb\xbf" + GOOD.replace(b"\n", b"\r\n")) == parse(GOOD)


@pytest.mark.parametrize("old,new", [
    (b"trade: mending", b"trade:"), (b"cue: Call the handyman before you pick up the hammer.", b"cue:"),
    (b"pick: skill | handyman:mend |", b"pick: own |  |"),
])
def test_empty_required_values_are_refused(old, new):
    assert any("empty" in e for e in validate(parse(GOOD.replace(old, new))))


def test_dash_name_only_for_own():
    p = parse(GOOD.replace(b"pick: skill | handyman:mend |", b"pick: skill | - |"))
    assert any("empty" in e for e in validate(p))


@pytest.mark.parametrize("kind", ["skill", "agent", "mcp"])
def test_pick_without_matching_provider_is_refused(kind):
    data = NO_PROVIDER.replace(b"pick: skill", b"pick: " + kind.encode())
    assert any("provider" in e for e in validate(parse(data)))


def test_provider_must_match_kind_and_name():
    data = GOOD.replace(b"provider: skill | handyman:mend", b"provider: skill | handyman:other")
    assert any("provider" in e for e in validate(parse(data)))


def test_own_and_recipe_need_no_provider():
    assert validate(parse(NO_PROVIDER.replace(b"pick: skill | handyman:mend |", b"pick: own | - |"))) == []
    assert validate(parse(RECIPE)) == []


def test_colon_in_value_keeps_the_rest():
    p = parse(GOOD.replace(b"what: putting", b"what: a: b putting"))
    assert p.what == "a: b putting right a thing that broke"


SNEAKY = ["\ufe0f", "\u034f", "\u3164", "\u115f", "\u2800", "\u0301", "\u00a0", "\u00e9"]


def _asc(errs):
    return any("ASCII" in e and "control" in e for e in errs)


@pytest.mark.parametrize("ch", SNEAKY)
def test_cue_with_non_ascii_is_refused(ch):
    assert _asc(validate(parse(_cue("a" + ch + "b"))))


@pytest.mark.parametrize("ch", SNEAKY)
@pytest.mark.parametrize("old,new", [
    (b"what: putting", "what: pu{}tting"),
    (b"handyman@mk@1.0.0", "handyman@mk@1.{}0.0"),
    (b"does it weekly", "does it{}weekly"),
    (b"when: mend this fence", "when: mend{}this fence"),
])
def test_non_ascii_in_any_field_is_refused(ch, old, new):
    data = GOOD.replace(old, new.format(ch).encode("utf-8"))
    assert _asc(validate(parse(data)))


@pytest.mark.parametrize("ch", SNEAKY)
def test_non_ascii_in_avoid_part_is_refused(ch):
    data = GOOD.replace(b"---\n", f"avoid: bad | sl{ch}ow | seen\n---\n".encode("utf-8"), 1)
    assert _asc(validate(parse(data)))


def test_all_ascii_pages_validate():
    assert validate(parse(GOOD)) == [] and validate(parse(RECIPE)) == []


def test_ascii_punctuation_in_cue_validates():
    assert validate(parse(_cue("~ !?()[]{}@#$%^&*'\" ok"))) == []


# --- `also:` companion files (Task 4 ruling 17) -----------------------

ALSO1 = b"also: ~/.claude/maude/recipes/a/notes.md | " + b"b" * 64 + b"\n"
ALSO2 = b"also: /opt/house/recipes/a/more.md | " + b"c" * 64 + b"\n"


def _with_also(base, *lines):
    return base.replace(b"cue:", b"".join(lines) + b"cue:")


def test_parse_reads_two_also_lines():
    p = parse(_with_also(RECIPE, ALSO1, ALSO2))
    assert p.also == [("~/.claude/maude/recipes/a/notes.md", "b" * 64),
                      ("/opt/house/recipes/a/more.md", "c" * 64)]
    assert validate(p) == []


def test_also_defaults_to_empty_and_is_not_shared():
    assert parse(GOOD).also == [] and parse(GOOD).also is not parse(GOOD).also


def test_also_on_a_skill_page_is_refused():
    assert any("also" in e for e in validate(parse(_with_also(GOOD, ALSO1))))


@pytest.mark.parametrize("line,needle", [
    (b"also: relative/x.md | " + b"b" * 64 + b"\n", "path"),
    (b"also: ~/x.md | " + b"b" * 63 + b"\n", "pin"),
    (b"also: ~/x.md | " + b"B" * 64 + b"\n", "pin"),
    (b"also: ~/x\xc3\xa9.md | " + b"b" * 64 + b"\n", "ASCII"),
])
def test_also_validate_refuses(line, needle):
    assert any(needle in e for e in validate(parse(_with_also(RECIPE, line))))


def test_also_with_one_field_raises():
    with pytest.raises(PageError):
        parse(_with_also(RECIPE, b"also: ~/x.md\n"))
