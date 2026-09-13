import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
RULES = ROOT / "rules"
FAMILIES = {
    "cue", "overload", "chunk", "order", "reuse", "consolidate", "distinct",
    "provenance", "one-place", "grouping", "reach", "pace", "expectation",
    "simplicity", "closure", "perception", "system",
}
FILES = {
    "laws-of-ux.json": ("ui", 30),
    "codd-and-normal-forms.json": ("schema", 19),
    "laws-of-memory.json": ("memory", 22),
}


def _load(name):
    return json.loads((RULES / name).read_text(encoding="utf-8"))


def test_every_rulebook_parses_and_has_its_count():
    for name, (cls, count) in FILES.items():
        book = _load(name)
        assert book["class"] == cls, name
        assert len(book["laws"]) == count, (name, len(book["laws"]))
        assert book["read_on"] == "2026-09-03", name
        assert book["heading"], name


def test_every_law_has_the_fields_and_a_question():
    seen = set()
    for name in FILES:
        for law in _load(name)["laws"]:
            for key in ("id", "name", "aliases", "family", "url", "ask"):
                assert law.get(key), (name, law.get("id"), key)
            assert law["id"] not in seen, ("duplicate id", law["id"])
            seen.add(law["id"])
            assert law["family"] in FAMILIES, (name, law["id"], law["family"])
            assert law["ask"].endswith("?"), (name, law["id"])
            assert "—" not in law["ask"], (name, law["id"], "em dash")
            assert re.match(r"^[a-z0-9-]+$", law["id"]), law["id"]
            assert law["name"].lower() in [a.lower() for a in law["aliases"]], (law["id"], "own name must be an alias")


def test_ux_is_the_live_thirty_including_pragnanz():
    ids = {law["id"] for law in _load("laws-of-ux.json")["laws"]}
    assert "law-of-pragnanz" in ids
    assert "fittss-law" in ids and "zeigarnik-effect" in ids
    for law in _load("laws-of-ux.json")["laws"]:
        assert law["url"].startswith("https://lawsofux.com/"), law["id"]


def test_codd_floor_and_schema_touching_flags():
    book = _load("codd-and-normal-forms.json")
    assert book["floor"] == 3
    by_id = {law["id"]: law for law in book["laws"]}
    assert {f"codd-{n}" for n in range(13)} <= set(by_id)
    assert {"1nf", "2nf", "3nf", "bcnf", "4nf", "5nf"} <= set(by_id)
    assert {by_id[i]["schema_touching"] for i in ("codd-1", "codd-2", "codd-3", "codd-10")} == {True}
    assert by_id["codd-0"]["schema_touching"] is False
    assert all(by_id[nf]["floor"] is True for nf in ("1nf", "2nf", "3nf"))
    assert all(by_id[nf]["floor"] is False for nf in ("bcnf", "4nf", "5nf"))


def test_memory_is_a_draft_with_sources():
    book = _load("laws-of-memory.json")
    assert book["status"] == "draft"
    assert all(law.get("source") for law in book["laws"])


def test_families_cross_the_seats():
    # The point of the family key: at least one family holds a law from every seat.
    by_family = {}
    for name in FILES:
        for law in _load(name)["laws"]:
            by_family.setdefault(law["family"], set()).add(_load(name)["class"])
    assert any(seats == {"ui", "schema", "memory"} for seats in by_family.values()), by_family
