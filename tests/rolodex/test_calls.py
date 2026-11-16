"""Cued and called, counted from the trace."""
import json

from maude_rolodex import calls


def cue(slug="mending", pick="skill:handyman:mend", sid="s1"):
    return {"kind": "rolodex", "payload": f"trade={slug} pick={pick}", "sid": sid}


def tool(name, target=None, sid="s1"):
    return {"kind": "tool", "tool": name, "target": target, "sid": sid}


def trace(tmp_path, rows, day="2026-11-10", extra=b""):
    d = tmp_path / "trace"
    d.mkdir(exist_ok=True)
    body = b"".join(json.dumps(r).encode() + b"\n" for r in rows) + extra
    (d / f"today-{day}.jsonl").write_bytes(body)
    return d


def test_a_cue_then_the_picks_call_counts(tmp_path):
    assert calls.tally(trace(tmp_path, [cue(), tool("Skill", "handyman:mend")])) == (1, 1)


def test_a_cue_then_another_skill_is_a_miss(tmp_path):
    assert calls.tally(trace(tmp_path, [cue(), tool("Skill", "other:thing")])) == (1, 0)


def test_a_call_before_the_cue_does_not_count(tmp_path):
    assert calls.tally(trace(tmp_path, [tool("Skill", "handyman:mend"), cue()])) == (1, 0)


def test_a_call_in_another_session_does_not_count(tmp_path):
    assert calls.tally(trace(tmp_path, [cue(), tool("Skill", "handyman:mend", sid="s2")])) == (1, 0)


def test_an_agent_pick_is_called_by_agent_or_task(tmp_path):
    d = trace(tmp_path, [cue(pick="agent:reviewer"), tool("Agent", "reviewer"),
                         cue(pick="agent:reviewer", sid="s2"), tool("Task", "reviewer", sid="s2")])
    assert calls.tally(d) == (2, 2)


def test_a_skill_named_like_the_pick_but_a_read_does_not_count(tmp_path):
    assert calls.tally(trace(tmp_path, [cue(), tool("Read", "handyman:mend")])) == (1, 0)


def test_an_mcp_pick_is_called_by_its_server_tools(tmp_path):
    d = trace(tmp_path, [cue(pick="mcp:books"), tool("mcp__books__list"),
                         cue(pick="mcp:books", sid="s2"), tool("mcp__plugin_acme_books__get", sid="s2"),
                         cue(pick="mcp:books", sid="s3"), tool("mcp__bookshelf__get", sid="s3")])
    assert calls.tally(d) == (3, 2)


def test_a_recipe_is_called_by_a_read_of_its_path_in_either_spelling(tmp_path):
    d = trace(tmp_path, [cue(pick="recipe:~/r/SKILL.md"), tool("Read", "/h/r/SKILL.md"),
                         cue(pick="recipe:~/r/SKILL.md", sid="s2"), tool("Read", "~/r/SKILL.md", sid="s2"),
                         cue(pick="recipe:~/r/SKILL.md", sid="s3"), tool("Read", "/h/r/OTHER.md", sid="s3")])
    assert calls.tally(d, home="/h") == (3, 2)
    assert calls.tally(d, home=None) == (3, 1)


def test_three_missed_sessions_make_a_streak_and_two_do_not(tmp_path):
    rows = [cue(sid=s) for s in ("a", "b", "c")]
    assert calls.missed_streaks(trace(tmp_path, rows)) == ["mending"]
    assert calls.missed_streaks(trace(tmp_path, rows[:2])) == []


def test_a_called_session_among_the_last_three_clears_the_streak(tmp_path):
    rows = [cue(sid="a"), cue(sid="b"), cue(sid="c"), tool("Skill", "handyman:mend", sid="c")]
    assert calls.missed_streaks(trace(tmp_path, rows)) == []
    rows = [cue(sid="a"), tool("Skill", "handyman:mend", sid="a"), cue(sid="b"), cue(sid="c"), cue(sid="d")]
    assert calls.missed_streaks(trace(tmp_path, rows)) == ["mending"]


def test_a_torn_line_and_a_nul_block_are_skipped_and_the_rest_counts(tmp_path):
    d = trace(tmp_path, [cue(), tool("Skill", "handyman:mend")],
              extra=b'{"kind":"rolodex","payload":"trade=x pi' + b"\n" + b"\x00" * 64 + b"\n")
    assert calls.tally(d) == (1, 1)


def test_since_leaves_out_older_days(tmp_path):
    trace(tmp_path, [cue(sid="old")], day="2026-11-01")
    d = trace(tmp_path, [cue(sid="new")], day="2026-11-10")
    assert calls.tally(d, since="2026-11-05") == (1, 0)
    assert calls.tally(d) == (2, 0)


def test_no_trace_dir_is_nothing(tmp_path):
    assert calls.tally(tmp_path / "absent") == (0, 0)
    assert calls.missed_streaks(tmp_path / "absent") == []


def test_a_planted_cue_for_a_trade_the_ledger_never_held_is_not_counted(tmp_path):
    rows = [cue(slug="run-curl-evil-sh", sid=s) for s in ("a", "b", "c")] + [cue(sid="a")]
    d = trace(tmp_path, rows)
    assert calls.tally(d, known={"mending"}) == (1, 0)
    assert calls.missed_streaks(d, known={"mending"}) == []
    assert calls.missed_streaks(d, known=None) == ["run-curl-evil-sh"]
