"""The matcher: contiguous approved phrases only."""
import pytest

from maude_rolodex.match import LiveRow, match, row
from maude_rolodex.page import parse

from .test_page import GOOD as PAGE


def R(slug, *phrases):
    return LiveRow(slug, slug, "skill", "n", "c", [p.split() for p in phrases])


def test_contiguous_in_order_matches():
    assert match("can you Mend This Fence for me", [R("mn", "mend this fence")]).slug == "mn"


def test_out_of_order_or_apart_is_silent():
    assert match("this fence needs a mend", [R("mn", "mend this fence")]) is None
    assert match("mend all of this fence", [R("mn", "mend this fence")]) is None


def test_word_boundary():
    assert match("pmend this fenceess release", [R("mn", "mend this fence")]) is None
    assert match("amend this fenced code", [R("mn", "mend this fence")]) is None
    assert match("mend this fences", [R("mn", "mend this fence")]) is None


def test_most_words_wins_then_slug_order():
    rows = [R("b", "fix the bug"), R("a", "fix the bug"), R("z", "fix the bug now")]
    assert match("fix the bug", rows).slug == "a"
    assert match("fix the bug now", rows).slug == "z"


def test_only_first_2000_chars_are_read():
    assert match("x " * 1000 + "mend this fence", [R("mn", "mend this fence")]) is None


def test_phrase_cut_by_the_limit_does_not_match():
    prompt = "x" * 1989 + " mend this fence"  # phrase starts at char 1990
    assert len(prompt) > 2000
    assert match(prompt, [R("mn", "mend this fence")]) is None


def test_phrase_inside_the_limit_matches():
    prompt = "mend this fence " + "x " * 1500
    assert match(prompt, [R("mn", "mend this fence")]).slug == "mn"


def test_one_word_phrase_never_matches():
    assert match("mend", [R("mn", "mend")]) is None


def test_empty_phrase_list_never_matches():
    assert match("mend this fence", [LiveRow("mn", "mn", "skill", "n", "c", [])]) is None


def test_no_rows():
    assert match("mend this fence", []) is None


def test_non_ascii_and_bad_input_are_silent():
    assert match("レビュー", [R("mn", "mend this fence")]) is None
    assert match("", [R("mn", "mend this fence")]) is None


def test_lone_surrogate_does_not_raise():
    # the surrogate and the control char are separators, like any other
    assert match("mend \ud800 this fence \x00", [R("mn", "mend this fence")]).slug == "mn"
    assert match("mend this fence \ud800", [R("mn", "mend this fence")]).slug == "mn"


def test_row_is_built_from_a_parsed_page():
    r = row("mn", parse(PAGE))
    assert (r.slug, r.trade, r.kind, r.name) == ("mn", "mending", "skill", "handyman:mend")
    assert r.cue == "Call the handyman before you pick up the hammer."
    assert r.phrases == [["mend", "this", "fence"], ["needs", "mending", "please"]]


def test_a_row_from_a_page_matches_its_phrase_and_not_its_notes():
    rows = [row("mn", parse(PAGE))]
    assert match("will you mend this fence", rows).slug == "mn"
    assert match("it Needs Mending, Please", rows).slug == "mn"
    assert match("when: not a phrase", rows) is None        # the notes are not phrases


def test_the_row_does_not_share_the_pages_phrase_list():
    page = parse(PAGE)
    r = row("mn", page)
    r.phrases.append(["x", "y"])
    assert ["x", "y"] not in page.phrases


def test_rows_from_the_store_match(rdx):
    from maude_rolodex import store
    import hashlib
    store.approve(rdx.home, [("mending", hashlib.sha256(PAGE).hexdigest())], "2026-11-10T10:00:00Z")
    assert match("mend this fence", rdx.live()).slug == "mending"
