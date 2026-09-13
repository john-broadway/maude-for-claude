# tests/rules/test_schema.py
import subprocess
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from maude_rules.schema import lint, format_line, extract_tables  # noqa: E402


def findings(text):
    return sorted((f.rule, f.column) for f in lint(text) if f.level == "finding")


# Every check: one planted schema that MUST fire, one clean schema that MUST stay silent.

def test_no_key_fires_and_a_key_silences():
    assert ("codd-2", "") in findings("CREATE TABLE t (name TEXT, age INT);")
    assert ("codd-2", "") not in findings("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);")
    assert ("codd-2", "") not in findings("CREATE TABLE t (a INT, b INT, PRIMARY KEY (a, b));")
    assert ("codd-2", "") not in findings("CREATE TABLE t (email TEXT UNIQUE NOT NULL, name TEXT);")


def test_table_level_unique_not_null_stands_in_for_a_key():
    assert ("codd-2", "") not in findings("CREATE TABLE t (email TEXT NOT NULL, name TEXT, UNIQUE(email));")
    assert ("codd-2", "") in findings("CREATE TABLE t (email TEXT, name TEXT, UNIQUE(email));")


def test_named_table_constraints_route_like_unnamed_ones():
    planted = """
    CREATE TABLE customers (id INT PRIMARY KEY);
    CREATE TABLE orders (
        id INT,
        customer_id INT,
        email TEXT,
        CONSTRAINT pk_orders PRIMARY KEY (id),
        CONSTRAINT fk_cust FOREIGN KEY (customer_id) REFERENCES customers(id),
        CONSTRAINT uq_email UNIQUE (email)
    );
    """
    assert findings(planted) == []
    no_fk = """
    CREATE TABLE customers (id INT PRIMARY KEY);
    CREATE TABLE orders (
        id INT,
        customer_id INT,
        email TEXT,
        CONSTRAINT pk_orders PRIMARY KEY (id),
        CONSTRAINT uq_email UNIQUE (email)
    );
    """
    assert ("codd-10", "customer_id") in findings(no_fk)
    no_pk = """
    CREATE TABLE customers (id INT PRIMARY KEY);
    CREATE TABLE orders (
        id INT,
        customer_id INT,
        email TEXT,
        CONSTRAINT fk_cust FOREIGN KEY (customer_id) REFERENCES customers(id),
        CONSTRAINT uq_email UNIQUE (email)
    );
    """
    assert ("codd-2", "") in findings(no_pk)
    # named UNIQUE alone (no PK, no FK involved) already routed correctly before
    # this round; kept here as a regression guard on that specific path.
    assert ("codd-2", "") not in findings(
        "CREATE TABLE t (email TEXT NOT NULL, CONSTRAINT uq_email UNIQUE (email));"
    )


def test_constraint_strip_requires_a_following_constraint_keyword():
    text = "CREATE TABLE t (constraint TEXT NOT NULL, id INT PRIMARY KEY);"
    cols = {c.name: c for t in extract_tables(text) for c in t.columns}
    assert set(cols) == {"constraint", "id"}
    assert cols["constraint"].ctype == "TEXT" and cols["constraint"].notnull is True
    assert findings(text) == []
    assert findings("CREATE TABLE t (a INT, b INT, CONSTRAINT pk PRIMARY KEY (a, b));") == []


def test_repeating_group_fires_on_consecutive_suffixes_only():
    assert ("1nf", "phone1") in findings("CREATE TABLE p (id INT PRIMARY KEY, phone1 TEXT, phone2 TEXT);")
    assert ("1nf", "sales_2024") in findings("CREATE TABLE s (id INT PRIMARY KEY, sales_2024 INT, sales_2025 INT);")
    assert findings("CREATE TABLE n (id INT PRIMARY KEY, ipv4 TEXT, ipv6 TEXT);") == []
    assert findings("CREATE TABLE h (id INT PRIMARY KEY, sha256 TEXT, md5 TEXT);") == []


def test_repeating_group_exempts_line_stems():
    assert findings("CREATE TABLE a (id INT PRIMARY KEY, address_line1 TEXT, address_line2 TEXT);") == []
    assert findings("CREATE TABLE l (id INT PRIMARY KEY, line1 TEXT, line2 TEXT);") == []
    assert ("1nf", "phone1") in findings("CREATE TABLE p (id INT PRIMARY KEY, phone1 TEXT, phone2 TEXT);")


def test_repeating_group_exemption_is_exact_not_a_suffix_match():
    assert ("1nf", "pipeline1") in findings("CREATE TABLE p (id INT PRIMARY KEY, pipeline1 TEXT, pipeline2 TEXT);")
    assert ("1nf", "deadline1") in findings("CREATE TABLE d (id INT PRIMARY KEY, deadline1 TEXT, deadline2 TEXT);")


def test_multivalued_column_is_an_ask():
    hits = lint("CREATE TABLE u (id INT PRIMARY KEY, tags TEXT, prefs JSON, emails_list TEXT);")
    asks = sorted((f.rule, f.column) for f in hits if f.level == "ask")
    assert ("1nf", "tags") in asks and ("1nf", "prefs") in asks and ("1nf", "emails_list") in asks
    assert all(f.level == "ask" for f in hits if f.rule == "1nf")
    assert lint("CREATE TABLE u (id INT PRIMARY KEY, email TEXT);") == []


def test_composite_key_with_non_key_columns_is_a_2nf_ask():
    hits = lint("CREATE TABLE oi (order_id INT, item_id INT, qty INT, PRIMARY KEY (order_id, item_id));")
    assert [(f.rule, f.level) for f in hits if f.rule == "2nf"] == [("2nf", "ask")]
    assert [f for f in lint("CREATE TABLE oi (order_id INT, item_id INT, PRIMARY KEY (order_id, item_id));") if f.rule == "2nf"] == []


def test_transitive_column_fires_across_tables():
    text = """
    CREATE TABLE customers (id INT PRIMARY KEY, name TEXT);
    CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT REFERENCES customers(id), customer_name TEXT);
    """
    assert ("3nf", "customer_name") in findings(text)
    clean = """
    CREATE TABLE customers (id INT PRIMARY KEY, name TEXT);
    CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT REFERENCES customers(id), total INT);
    """
    assert ("3nf", "customer_name") not in findings(clean) and findings(clean) == []


def test_id_without_references_fires_only_when_the_table_exists():
    text = "CREATE TABLE users (id INT PRIMARY KEY); CREATE TABLE posts (id INT PRIMARY KEY, user_id INT);"
    assert ("codd-10", "user_id") in findings(text)
    inline = "CREATE TABLE users (id INT PRIMARY KEY); CREATE TABLE posts (id INT PRIMARY KEY, user_id INT REFERENCES users(id));"
    assert findings(inline) == []
    table_level = ("CREATE TABLE users (id INT PRIMARY KEY); CREATE TABLE posts (id INT PRIMARY KEY, user_id INT, "
                   "FOREIGN KEY (user_id) REFERENCES users(id));")
    assert findings(table_level) == []
    no_such_table = "CREATE TABLE posts (id INT PRIMARY KEY, external_id INT);"
    assert findings(no_such_table) == []


def test_sentinel_default_is_an_ask():
    hits = lint("CREATE TABLE t (id INT PRIMARY KEY, note TEXT DEFAULT 'N/A', n INT DEFAULT -1, z INT DEFAULT 0);")
    asks = sorted((f.rule, f.column) for f in hits if f.level == "ask")
    assert ("codd-3", "note") in asks and ("codd-3", "n") in asks
    assert ("codd-3", "z") not in asks


def test_extraction_from_string_literals_in_other_languages():
    py = 'cur.execute("""CREATE TABLE laps (driver TEXT, ms INT)""")'
    lua = 'db:exec([[CREATE TABLE laps (driver TEXT, ms INT)]])'
    js = 'await db.run(`CREATE TABLE IF NOT EXISTS laps (driver TEXT, ms INT)`);'
    for src in (py, lua, js):
        assert ("codd-2", "") in findings(src), src


def test_comments_quoted_identifiers_and_if_not_exists():
    text = """
    -- a comment with CREATE TABLE ghost (x INT) inside it
    CREATE TABLE IF NOT EXISTS "orders" (`id` INTEGER PRIMARY KEY, /* note */ [total] INT);
    """
    assert findings(text) == []
    assert [f.table for f in lint("CREATE TABLE ghost (x INT)")] == ["ghost"]


def test_format_line_and_cli(tmp_path):
    f = tmp_path / "s.sql"
    f.write_text("CREATE TABLE t (name TEXT);", encoding="utf-8")
    r = subprocess.run([sys.executable, "-m", "maude_rules", "schema", str(f)],
                       cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 1
    assert "t: no PRIMARY KEY" in r.stdout and "(codd-2)" in r.stdout
    b = subprocess.run([sys.executable, "-m", "maude_rules", "schema", "--brief", str(f)],
                       cwd=ROOT, capture_output=True, text=True)
    assert b.stdout.strip().startswith(f"{f}: 1 finding(s): ")
    c = tmp_path / "c.sql"
    c.write_text("CREATE TABLE t (id INT PRIMARY KEY);", encoding="utf-8")
    ok = subprocess.run([sys.executable, "-m", "maude_rules", "schema", "--brief", str(c)],
                        cwd=ROOT, capture_output=True, text=True)
    assert ok.returncode == 0 and ok.stdout.strip() == f"{c}: clean"


def test_unknown_flag_refuses(tmp_path):
    f = tmp_path / "s.sql"
    f.write_text("CREATE TABLE t (id INT PRIMARY KEY);", encoding="utf-8")
    r = subprocess.run([sys.executable, "-m", "maude_rules", "schema", "--nope", str(f)],
                       cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 2
    assert r.stdout == ""
    assert "usage: python3 -m maude_rules schema" in r.stderr


def test_single_dash_flag_refuses(tmp_path):
    f = tmp_path / "s.sql"
    f.write_text("CREATE TABLE t (id INT PRIMARY KEY);", encoding="utf-8")
    r = subprocess.run([sys.executable, "-m", "maude_rules", "schema", "-x", str(f)],
                       cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 2
    assert r.stdout == ""
    assert "usage: python3 -m maude_rules schema" in r.stderr


def test_library_never_raises_on_garbage():
    assert lint("CREATE TABLE (") == []
    assert lint("") == []
    assert lint("CREATE TABLE t (a INT, PRIMARY KEY") == []


# ── the table-clause dispatch is a shape, not a prefix ───────────────────────
# `upper.startswith(("UNIQUE", "CHECK", "INDEX", "KEY"))` swallowed every ordinary
# column whose name merely began with one of those words, so a declared PRIMARY KEY
# vanished and a false codd-2 was minted. A table-level clause is a keyword, then an
# optional name, then a paren.

def test_columns_named_like_constraint_keywords_are_columns():
    text = "CREATE TABLE t (keyword TEXT PRIMARY KEY, checksum TEXT, indexed_at TEXT, uniquely TEXT);"
    tables = extract_tables(text)
    assert len(tables) == 1
    cols = [c.name for c in tables[0].columns]
    assert cols == ["keyword", "checksum", "indexed_at", "uniquely"]
    assert tables[0].pk_cols == ["keyword"]
    assert findings(text) == []


def test_more_columns_named_like_keywords():
    text = "CREATE TABLE t (id INT PRIMARY KEY, key_id INT, check_in DATE, index_name TEXT, unique_ref TEXT);"
    cols = [c.name for t in extract_tables(text) for c in t.columns]
    assert cols == ["id", "key_id", "check_in", "index_name", "unique_ref"]
    assert ("codd-2", "") not in findings(text)


def test_mysql_unique_key_and_unique_index_are_unique_groups():
    uk = ("CREATE TABLE sessions (token TEXT NOT NULL, created_at TEXT, "
          "UNIQUE KEY token_uniq (token));")
    assert ("codd-2", "") not in findings(uk)
    ui = ("CREATE TABLE sessions (token TEXT NOT NULL, created_at TEXT, "
          "UNIQUE INDEX token_uniq (token));")
    assert ("codd-2", "") not in findings(ui)
    # The control: the same shape without NOT NULL cannot stand in for a key.
    nullable = ("CREATE TABLE sessions (token TEXT, created_at TEXT, "
                "UNIQUE KEY token_uniq (token));")
    assert ("codd-2", "") in findings(nullable)


def test_plain_key_and_index_clauses_are_ignored_and_columns_survive():
    text = ("CREATE TABLE t (id INT PRIMARY KEY, a INT, b INT, "
            "KEY idx_a (a), INDEX idx_b (b));")
    tables = extract_tables(text)
    assert [c.name for c in tables[0].columns] == ["id", "a", "b"]
    assert tables[0].unique_groups == []
    assert findings(text) == []


def test_a_quoted_constraint_name_with_spaces_routes_as_a_constraint():
    text = 'CREATE TABLE t (id INT, note TEXT, CONSTRAINT "my pk name" PRIMARY KEY (id));'
    tables = extract_tables(text)
    assert [c.name for c in tables[0].columns] == ["id", "note"]
    assert tables[0].pk_cols == ["id"]
    assert findings(text) == []
    back = "CREATE TABLE t (id INT, note TEXT, CONSTRAINT `my pk name` PRIMARY KEY (id));"
    assert [c.name for c in extract_tables(back)[0].columns] == ["id", "note"]
    assert extract_tables(back)[0].pk_cols == ["id"]


def test_a_parenthesised_type_is_not_a_table_clause():
    text = "CREATE TABLE t (key VARCHAR(20) PRIMARY KEY, check_val DECIMAL(10,2));"
    tables = extract_tables(text)
    assert [c.name for c in tables[0].columns] == ["key", "check_val"]
    assert tables[0].pk_cols == ["key"]


# ── zero tables is not "clean" ───────────────────────────────────────────────

def test_brief_says_no_create_table_found(tmp_path):
    f = tmp_path / "alter.sql"
    f.write_text("ALTER TABLE orders ADD COLUMN total INT;\n", encoding="utf-8")
    r = subprocess.run([sys.executable, "-m", "maude_rules", "schema", "--brief", str(f)],
                       cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0
    assert r.stdout.strip() == f"{f}: no CREATE TABLE found"


def test_count_reports_the_tables_the_linter_actually_read(tmp_path):
    f = tmp_path / "two.sql"
    f.write_text("CREATE TABLE a (id INT PRIMARY KEY); CREATE TABLE b (id INT PRIMARY KEY);",
                 encoding="utf-8")
    e = tmp_path / "alter.sql"
    e.write_text("ALTER TABLE a ADD COLUMN x INT;", encoding="utf-8")
    r = subprocess.run([sys.executable, "-m", "maude_rules", "schema", "--count", str(f), str(e)],
                       cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0
    assert r.stdout == f"{f}: 2 table(s)\n{e}: 0 table(s)\n"


# The rail's first dogfood (2026-09-03) read zero over Maude's own six tables, and the two
# reasons were the linter's, not the tables': a document column named `json` sat outside
# the name lists, and a self-reference that does not end in `_id` was invisible to the
# Codd 10 check. Both were filed that hour and fixed here; her own schemas are the control.

def test_a_document_column_named_whole_is_the_multivalued_ask():
    hits = lint("CREATE TABLE p (id INT PRIMARY KEY, json TEXT NOT NULL, embedding TEXT, links TEXT, note TEXT);")
    asks = sorted((f.rule, f.column) for f in hits if f.level == "ask")
    assert ("1nf", "json") in asks and ("1nf", "embedding") in asks and ("1nf", "links") in asks
    assert ("1nf", "note") not in asks
    assert all(f.level == "ask" for f in hits if f.rule == "1nf")


def test_a_reference_named_by_without_references_is_a_codd10_ask():
    hits = lint("CREATE TABLE canon (id INTEGER PRIMARY KEY, text TEXT, superseded_by INTEGER);")
    assert [(f.rule, f.column, f.level) for f in hits] == [("codd-10", "superseded_by", "ask")]
    declared = lint("CREATE TABLE canon (id INTEGER PRIMARY KEY, text TEXT, superseded_by INTEGER REFERENCES canon(id));")
    assert declared == []
    # A text column ending in _by names a method, not a row.
    assert lint("CREATE TABLE p (id INT PRIMARY KEY, sorted_by TEXT);") == []


def test_maudes_own_schemas_raise_their_asks():
    tape = lint((ROOT / "maude_tape" / "tape.py").read_text())
    vault = lint((ROOT / "maude_vault" / "db.py").read_text())
    tape_asks = sorted((f.rule, f.table, f.column) for f in tape if f.level == "ask")
    vault_asks = sorted((f.rule, f.table, f.column) for f in vault if f.level == "ask")
    assert ("1nf", "voice_profile", "json") in tape_asks
    assert ("codd-10", "canon", "superseded_by") in tape_asks
    assert ("1nf", "notes", "links") in vault_asks
    # Questions the design answers (spec 8a), never findings: her tables stay keyed and normal.
    assert [f for f in tape + vault if f.level == "finding"] == []
