"""Recall pages what the question is ABOUT, not whatever shares a word (2026-09-25).

One OR of every token with no floor filled the top five on every prompt: "fix the recall
noise" paged a sqlite letter, a CRLF note and the memory index, matched on "fix" (in 72%
of the live vault's notes). Once a vault has 100 pageable notes (smaller ones rank exactly
as before):
  - letters, daily logs and archives are not paged (they are read at arrival);
  - instruction words ("again", "try", "tell") are not evidence of a subject;
  - a word in more than 30% of the pageable notes is COMMON: evidence only in a note's name;
  - a RARE word is evidence anywhere; a hit needs evidence in its name or description and at
    least half the rare words (never fewer than two pieces); a lone rare word must be in the
    name (or the head, if very rare); common words alone need a note named for all of them;
  - every judgement goes through the FTS index (its stemming, its tokenizer): the first
    version's regex lost "dogfooding mandates" and read "liveness" as "live".
What was measured on the live vault, and what could not be re-measured, is in the
CHANGELOG entry; the labelled probe sets of 2026-09-25 were not kept.
"""
import os
import pathlib

from maude_vault import ingest, page


def _note(mem, fname, name, description, body, ntype="feedback"):
    (mem / fname).write_text(f"---\nname: {name}\ndescription: {description}\n"
                             f"metadata:\n  type: {ntype}\n---\n{body}\n")


def _vault(tmp_path, extra=()):
    """120 notes; "fix" and "session" in all of them (common words, like the live vault)."""
    mem = tmp_path / "mem"
    mem.mkdir()
    for i in range(120):
        _note(mem, f"feedback_filler-{i}.md", f"feedback_filler-{i}",
              f"filler note {i} about topic{i}",
              f"fix the session thing number {i}. topic{i} detail.")
    for args in extra:
        _note(mem, *args)
    dbp = tmp_path / "v.db"
    ingest.build(mem, dbp)
    return dbp


_UNCOMMON = "quokka wombat dingo emu numbat bilby"


def _bulk(n=10):
    """Notes whose BODIES carry the test words, so each is uncommon (~7%) but not very rare
    (<= 5% makes a word in a name the subject by itself). None has them in its head."""
    return [(f"project_bulk{i}.md", f"project_bulk{i}", f"bulk {i}", _UNCOMMON, "project")
            for i in range(n)]


def _names(dbp, q, k=5):
    # A test that asserts a note is NOT paged must look past the default five: the bulk
    # fixture outranks a single-term target, which sat at rank 11 on the unfloored code and
    # made four such tests pass there by the cutoff alone (lens round 3). They pass k=25.
    return [h["name"] for h in page.page(dbp, q, k=k)]


def test_a_prompt_made_of_common_words_pages_nothing(tmp_path):
    dbp = _vault(tmp_path)
    assert _names(dbp, "fix the session") == []


def test_a_note_about_the_question_is_paged(tmp_path):
    dbp = _vault(tmp_path, [("feedback_wake-tape-head.md", "feedback_wake-tape-head",
                             "the wake tape plays the head of an append only file",
                             "read the tail, not the head.")])
    assert _names(dbp, "fix the wake tape head")[0] == "feedback_wake-tape-head"


def test_a_long_note_that_merely_mentions_the_words_is_not_paged(tmp_path):
    body = "wake tape head append " + "unrelated prose " * 300
    dbp = _vault(tmp_path, [("project_long.md", "project_long", "a long log of other work", body,
                             "project")])
    assert "project_long" not in _names(dbp, "wake tape head append")


def test_letters_and_dailies_are_not_paged(tmp_path):
    dbp = _vault(tmp_path, [
        ("letter-from-claude-x.md", "letter-from-claude-x", "zebra crossing zebra rules",
         "zebra crossing", "project"),
        ("today-x.md", "today-x", "zebra crossing day", "zebra crossing", "project"),
        ("feedback_zebra.md", "feedback_zebra-crossing", "zebra crossing rule", "zebra crossing")])
    assert _names(dbp, "zebra crossing") == ["feedback_zebra-crossing"]


def test_the_skip_prefixes_are_a_knob(tmp_path, monkeypatch):
    dbp = _vault(tmp_path, [("letter-from-claude-x.md", "letter-from-claude-x",
                             "zebra crossing zebra rules", "zebra crossing", "project")])
    monkeypatch.setenv("MAUDE_PAGE_SKIP_PREFIXES", "nothing-")
    assert _names(dbp, "zebra crossing") == ["letter-from-claude-x"]


def test_a_lone_uncommon_word_must_be_in_the_name(tmp_path):
    # "widget" in 10% of notes: uncommon, not very rare. In a description only: not paged.
    extra = [(f"feedback_w{i}.md", f"feedback_w{i}", f"has a widget {i}", "x") for i in range(12)]
    extra.append(("reference_widget-rules.md", "reference_widget-rules", "how it works", "x",
                  "reference"))
    dbp = _vault(tmp_path, extra)
    assert _names(dbp, "fix the widget") == ["reference_widget-rules"]


def test_a_very_rare_word_in_the_description_is_enough(tmp_path):
    dbp = _vault(tmp_path, [("user_mind.md", "user_mind", "his metaphors are the content",
                             "render them", "user")])
    assert _names(dbp, "how should I handle the metaphors") == ["user_mind"]


def test_a_small_vault_ranks_as_it_always_did(tmp_path):
    # Letters included: the skip list is a big-vault rule too (lens: the claim was false).
    mem = tmp_path / "mem"
    mem.mkdir()
    _note(mem, "a.md", "a-note", "zebra habits", "zebra zebra")
    _note(mem, "letter-from-claude-x.md", "letter-from-claude-x", "zebra letter", "zebra")
    dbp = tmp_path / "v.db"
    ingest.build(mem, dbp)
    assert sorted(_names(dbp, "zebra")) == ["a-note", "letter-from-claude-x"]


def test_the_index_stems_so_an_inflected_question_still_finds_its_note(tmp_path):
    dbp = _vault(tmp_path, [("feedback_dogfood-mandate.md", "feedback_dogfood-mandate",
                             "the dogfood mandate", "always go through the tool")])
    assert _names(dbp, "dogfooding mandates") == ["feedback_dogfood-mandate"]


def test_a_common_word_counts_where_a_note_is_named_for_it(tmp_path):
    # "session" and "fix" are in every filler note; a note NAMED for them answers.
    dbp = _vault(tmp_path, [("feedback_session-fix-rule.md", "feedback_session-fix-rule",
                             "how to fix a session", "x")])
    assert _names(dbp, "session fix") == ["feedback_session-fix-rule"]


def test_instruction_words_are_not_a_subject(tmp_path):
    dbp = _vault(tmp_path, [("feedback_runs-again.md", "feedback_runs-again",
                             "a migration runs again", "x")])
    assert _names(dbp, "try it again") == []


def test_two_rare_words_are_the_floor_even_when_half_is_one(tmp_path):
    dbp = _vault(tmp_path, [("feedback_quokka.md", "feedback_quokka", "quokka habits", "x"),
                            *_bulk()])
    assert "feedback_quokka" not in _names(dbp, "quokka wombat", k=25)


def test_half_the_rare_words_is_enough(tmp_path):
    # Every word exists somewhere (a word in no note is dropped and shrinks the question);
    # "wombat" is in this note's BODY: a rare word is evidence anywhere.
    dbp = _vault(tmp_path, [("feedback_quokka-rules.md", "feedback_quokka-rules",
                             "quokka habits", "a wombat too"),
                            ("project_zoo.md", "project_zoo", "elsewhere", "dingo emu")])
    assert "feedback_quokka-rules" in _names(dbp, "quokka wombat dingo emu")


def test_a_common_word_in_the_body_is_not_evidence(tmp_path):
    # "session" is in every note's body. Only "quokka" is real evidence here: one of two
    # rare words, so no page.
    dbp = _vault(tmp_path, [("feedback_quokka.md", "feedback_quokka", "quokka habits",
                             "a session note"), *_bulk()])
    assert "feedback_quokka" not in _names(dbp, "quokka wombat session", k=25)


# ── the recall lens, round 2 ──────────────────────────────────────────────

def test_a_very_rare_word_in_the_name_is_the_subject_whatever_else_is_asked(tmp_path):
    dbp = _vault(tmp_path, [("feedback_gaslighting.md", "feedback_gaslighting",
                             "a rule", "x"), *_bulk()])
    assert "feedback_gaslighting" in _names(dbp, "gaslighting after a wombat")


def test_a_lone_common_word_pages_nothing(tmp_path):
    # "fix it" paged five notes named for "fix" (63% of the live vault).
    dbp = _vault(tmp_path, [("feedback_fix-rule.md", "feedback_fix-rule", "a rule", "x")])
    assert _names(dbp, "fix it") == []


def test_common_words_in_a_name_do_not_stand_in_for_the_rare_ones(tmp_path):
    dbp = _vault(tmp_path, [("feedback_session-fix-rule.md", "feedback_session-fix-rule",
                             "a rule", "x"), *_bulk()])
    assert "feedback_session-fix-rule" not in _names(dbp, "session fix wombat", k=25)


def test_half_is_rounded_up(tmp_path):
    # Five rare words need three pieces of evidence; two is not half of five.
    dbp = _vault(tmp_path, [("feedback_quokka-note.md", "feedback_quokka-note",
                             "quokka rule", "a wombat"), *_bulk()])
    assert "feedback_quokka-note" not in _names(dbp, "quokka wombat dingo emu numbat", k=25)


def test_common_words_alone_need_a_note_named_for_all_of_them(tmp_path):
    dbp = _vault(tmp_path, [("feedback_session-rule.md", "feedback_session-rule",
                             "a rule", "x")])
    assert _names(dbp, "session fix") == []


# ── lens round 3 (2026-09-28): a name word is the subject alone only if it is the rarest ──
# Note names here are sentences ("john-doesnt-do-git"), so a filler word in a name was a
# "very rare subject": "the coffee maker doesnt turn on" paged the git note, because
# "coffee" (rarer, and not in that note) is what the question was about.

def _sentence_vault(tmp_path):
    extra = [("feedback_john-doesnt-do-git.md", "feedback_john-doesnt-do-git",
              "john is not comfortable with git", "claude does all git.")]
    # "doesnt" in 4 filler bodies (very rare, not the rarest), "coffee" in 1 other note
    for i in range(4):
        extra.append((f"project_d{i}.md", f"project_d{i}", f"d note {i}", "it doesnt matter here",
                      "project"))
    extra.append(("project_brew.md", "project_brew", "a brew log", "coffee grind notes", "project"))
    return _vault(tmp_path, extra)


def test_a_filler_name_word_does_not_page_when_the_question_has_a_rarer_word(tmp_path):
    dbp = _sentence_vault(tmp_path)
    assert "feedback_john-doesnt-do-git" not in _names(dbp, "the coffee maker doesnt turn on")


def test_the_name_word_still_pages_when_it_is_the_questions_rarest(tmp_path):
    dbp = _sentence_vault(tmp_path)
    assert "feedback_john-doesnt-do-git" in _names(dbp, "doesnt he do that")
