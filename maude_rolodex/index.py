"""The index: what is callable in this house, as a flat inventory. Stdlib only.

Walks the plugins the install record names, the synced and personal skills,
and the project's own skills, agents and MCP servers. Rows are 5-tuples of str:
kind, name, source, commit, description. The live file is TSV, no header.
Every doubt (missing, empty, corrupt, oddly shaped) yields fewer rows, never
an exception. `home` and `project` are arguments; `$HOME` and the cwd are
never read.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from pathlib import Path

Row = tuple[str, str, str, str, str]

_MAX_BYTES = 256 * 1024
_DESC_MAX = 500
_NAME_MAX = 120  # versions and commits only; provider names use _NAME_RE
_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
_MAX_FILES = 2000
_MAX_DEPTH = 6
_GROUP_SUFFIX = re.compile(r"~g\d+$")
_VERSION_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}")
_COMMIT_RE = re.compile(r"[0-9a-f]{7,64}")


# --- small readers ----------------------------------------------------

def _plain(text: str, limit: int) -> str:
    """Printable ASCII only, whitespace runs folded to one space, cut to limit."""
    out = "".join(c if 0x20 <= ord(c) <= 0x7E else " " for c in text)
    return " ".join(out.split())[:limit]


def _read_json(path: Path):
    try:
        if path.stat().st_size > _MAX_BYTES:
            return None
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return None


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


_BLOCK_MARKERS = (">", "|", ">-", "|-", ">+", "|+")


def _scalar(value: str) -> str:
    value = _unquote(value)
    return "" if value in _BLOCK_MARKERS else value


def _frontmatter(path: Path) -> tuple[str, str]:
    """(name, description) from the first closed `---` block; ("", "") on any doubt."""
    try:
        if path.stat().st_size > _MAX_BYTES:
            return "", ""
        lines = [l.rstrip("\r") for l in path.read_bytes().decode("utf-8").split("\n")]
    except (OSError, UnicodeError):
        return "", ""
    if not lines or lines[0] != "---":
        return "", ""
    try:
        end = lines.index("---", 1)
    except ValueError:
        return "", ""
    name = desc = ""
    for line in lines[1:end]:
        key, sep, value = line.partition(":")
        if not sep or key != key.lstrip():
            continue
        if key == "name":
            name = _scalar(value)
        elif key == "description":
            desc = _scalar(value)
    return name, desc


def _walk(root: Path):
    """Yield (dir, [file names]) under root: no symlinked dirs, no dot dirs, capped."""
    seen = 0
    base = len(root.parts)
    try:
        walker = os.walk(root, followlinks=False)
        for dirpath, dirnames, filenames in walker:
            dirnames[:] = sorted(d for d in dirnames
                                 if d != "node_modules" and not d.startswith("."))
            if len(Path(dirpath).parts) - base >= _MAX_DEPTH:
                dirnames[:] = []
            room = _MAX_FILES - seen
            if room <= 0:
                return
            names = sorted(filenames)[:room]
            seen += len(names)
            yield Path(dirpath), names
            if seen >= _MAX_FILES:
                return
    except OSError:
        return


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root)
        return True
    except (OSError, ValueError, RuntimeError):
        return False


def _contained_file(path: Path, root: Path) -> bool:
    """A regular file whose resolved path is inside the resolved root."""
    try:
        return _inside(path, root) and os.path.isfile(path.resolve())
    except (OSError, ValueError, RuntimeError):
        return False


def _good(name: str) -> bool:
    """The one allowlist every provider name, prefix and server key must pass."""
    return _NAME_RE.fullmatch(name) is not None and ".." not in name


# --- providers --------------------------------------------------------

def _row(kind: str, file: Path, root: Path, fallback: str, prefix: str,
         source: str, commit: str) -> Row | None:
    if not _contained_file(file, root):
        return None
    if prefix and not _good(prefix):
        return None
    name, desc = _frontmatter(file)
    if not _good(name):
        name = fallback
    if not _good(name):
        return None
    full = f"{prefix}:{name}" if prefix else name
    desc = "" if source == "project" else _plain(desc, _DESC_MAX)
    return (kind, full, source, commit, desc)


def _mcp_rows(file: Path, root: Path, source: str, commit: str, allow=None) -> list[Row]:
    if not _contained_file(file, root):
        return []
    data = _read_json(file)
    if not isinstance(data, dict):
        return []
    servers = data["mcpServers"] if "mcpServers" in data else data
    if not isinstance(servers, dict):
        return []
    rows = []
    for key in servers:
        name = str(key)
        if _good(name) and (allow is None or allow(name)):
            rows.append(("mcp", name, source, commit, ""))
    return rows


def _tree_rows(root: Path, prefix: str, source: str, commit: str,
               agents: bool = True) -> list[Row]:
    """Skills (`**/SKILL.md`) and, if asked, agents (`**/agents/*.md`) under one root."""
    rows: list[Row] = []
    resolved = root.resolve()
    for dirpath, files in _walk(root):
        for f in files:
            row = None
            if f == "SKILL.md":
                row = _row("skill", dirpath / f, resolved, dirpath.name, prefix, source, commit)
            elif agents and f.endswith(".md") and dirpath.name == "agents":
                row = _row("agent", dirpath / f, resolved, (dirpath / f).stem, prefix, source, commit)
            if row:
                rows.append(row)
    return rows


def _project_agent_rows(root: Path) -> list[Row]:
    rows: list[Row] = []
    resolved = root.resolve()
    for dirpath, files in _walk(root):
        if dirpath != root:
            continue
        for f in files:
            if f.endswith(".md"):
                row = _row("agent", dirpath / f, resolved, (dirpath / f).stem, "", "project", "")
                if row:
                    rows.append(row)
    return rows


def _synced_rows(root: Path) -> list[Row]:
    rows: list[Row] = []
    resolved = root.resolve()
    for dirpath, files in _walk(root):
        if "SKILL.md" not in files:
            continue
        parts = dirpath.relative_to(root).parts  # <account>/<group>/.../<skill>
        group = _GROUP_SUFFIX.sub("", parts[1]) if len(parts) >= 3 else ""
        if len(parts) >= 3 and not _good(group):
            continue
        row = _row("skill", dirpath / "SKILL.md", resolved, dirpath.name,
                   group, "synced", "")
        if row:
            rows.append(row)
    return rows


def _settings(path: Path) -> dict:
    data = _read_json(path)
    return data if isinstance(data, dict) else {}


def _enabled_map(home: Path, project: Path | None) -> dict:
    files = [home / ".claude" / "settings.json"]
    if project is not None:
        files += [project / ".claude" / "settings.json", project / ".claude" / "settings.local.json"]
    merged: dict = {}
    for p in files:
        enabled = _settings(p).get("enabledPlugins")
        if isinstance(enabled, dict):
            merged.update(enabled)
    return merged


def _same_path(a: str, b: Path) -> bool:
    try:
        return Path(a).is_absolute() and Path(a).resolve() == b.resolve()
    except (OSError, ValueError, RuntimeError):
        return False


def _pick_entry(entries, project: Path | None):
    """The first entry callable from this project, or None."""
    if not isinstance(entries, list):
        return None
    for e in entries:
        if not isinstance(e, dict):
            continue
        if e.get("scope") in ("project", "local"):
            pp = e.get("projectPath")
            if project is None or not isinstance(pp, str) or not _same_path(pp, project):
                continue
        return e
    return None


def _plugin_installs(home: Path, project: Path | None) -> list[tuple[str, str, str, Path, str]]:
    """(plugin, version, commit, installPath, marketplace) for each callable, enabled plugin."""
    data = _read_json(home / ".claude" / "plugins" / "installed_plugins.json")
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        return []
    enabled = _enabled_map(home, project)
    allowed = (home / ".claude" / "plugins").resolve()
    out = []
    for key in sorted(plugins):
        if not isinstance(key, str) or enabled.get(key) is False:
            continue
        entry = _pick_entry(plugins[key], project)
        if entry is None or not isinstance(entry.get("installPath"), str):
            continue
        path = Path(entry["installPath"])
        if not path.is_absolute() or not path.is_dir():
            continue
        try:
            depth = len(path.resolve().relative_to(allowed).parts)
        except (OSError, ValueError, RuntimeError):
            continue
        if depth < 2:
            continue
        plugin, _, market = key.partition("@")
        version = str(entry.get("version", ""))
        commit = str(entry.get("gitCommitSha") or "")
        if _COMMIT_RE.fullmatch(commit) is None:
            commit = ""
        if _good(plugin) and _good(market) and _VERSION_RE.fullmatch(version):
            out.append((plugin, version, commit, path, market))
    return out


def _str_list(value) -> set[str] | None:
    if isinstance(value, list) and all(isinstance(v, str) for v in value):
        return set(value)
    return None


def _mcp_allow(home: Path, project: Path):
    """Approval of project .mcp.json servers, from the user's OWN settings only."""
    own = [_settings(home / ".claude" / "settings.json"),
           _settings(project / ".claude" / "settings.local.json")]
    committed = _settings(project / ".claude" / "settings.json")
    all_ok = any(d.get("enableAllProjectMcpServers") is True for d in own)
    named: set[str] = set()
    for d in own:
        named |= _str_list(d.get("enabledMcpjsonServers")) or set()
    off: set[str] = set()
    for d in own + [committed]:
        if "disabledMcpjsonServers" not in d:
            continue
        listed = _str_list(d["disabledMcpjsonServers"])
        if listed is None:
            return lambda server: False  # a deny list we cannot read: approve nothing
        off |= listed
    return lambda server: server not in off and (all_ok or server in named)


def _guard(fn, *args) -> list[Row]:
    """One source failing must not drop the others."""
    try:
        return fn(*args)
    except (OSError, ValueError, RuntimeError, TypeError, AttributeError, KeyError):
        return []


def _plugin_rows(home: Path, project: Path | None) -> list[Row]:
    rows: list[Row] = []
    for plugin, version, commit, path, market in _plugin_installs(home, project):
        source = f"{plugin}@{market}@{version}"
        rows += _guard(_tree_rows, path, plugin, source, commit)
        rows += _guard(_mcp_rows, path / ".mcp.json", path.resolve(), source, commit)
    return rows


def _dir_rows(fn, path: Path, *args) -> list[Row]:
    return fn(path, *args) if path.is_dir() else []


def build(home: Path, project: Path) -> list[Row]:
    """The inventory: sorted, de-duplicated on (kind, name, source)."""
    home, project = Path(home), Path(project)
    if not home.is_absolute():
        return []
    proj = project if project.is_absolute() else None
    claude = home / ".claude"
    rows = _guard(_plugin_rows, home, proj)
    rows += _guard(_dir_rows, _synced_rows, claude / "plugins" / "synced")
    rows += _guard(_dir_rows, _tree_rows, claude / "skills", "", "personal", "", False)
    if proj is not None:
        rows += _guard(_dir_rows, _tree_rows, proj / ".claude" / "skills", "", "project", "", False)
        rows += _guard(_dir_rows, _project_agent_rows, proj / ".claude" / "agents")
        rows += _guard(lambda: _mcp_rows(proj / ".mcp.json", proj.resolve(), "project", "",
                                         _mcp_allow(home, proj)))
    unique: dict[tuple[str, str, str], Row] = {}
    for r in sorted(rows):
        unique.setdefault(r[:3], r)
    return sorted(unique.values())


def project_slug(project: Path) -> str:
    """The one slug rule: the resolved project path, every non-[A-Za-z0-9] as `-`.

    Never raises: a relative path is not resolved, and a path that cannot be
    resolved (loop, NUL byte) is used as written.
    """
    project = Path(project)
    full = project
    if project.is_absolute():
        try:
            full = project.resolve()
        except (OSError, RuntimeError, ValueError):
            pass
    return re.sub(r"[^A-Za-z0-9]", "-", str(full))


def inventory_path(home: Path, project: Path) -> Path:
    """Where this project's inventory lives: one file per project."""
    return (Path(home) / ".claude" / "maude" / "rolodex" / "inventory"
            / f"{project_slug(project)}.tsv")


def write(rows, path: Path) -> None:
    """Write the TSV atomically: temp file beside the target, then replace."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write("\t".join(r) + "\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read(path: Path) -> list[Row] | None:
    """The inventory as written, or None when it is missing or not five fields a row."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    rows = []
    for line in text.split("\n"):
        if not line:
            continue
        f = line.split("\t")
        if len(f) != 5:
            return None
        rows.append(tuple(f))
    return rows


def _stat(path: Path) -> str:
    try:
        st = path.stat()
        return f"{path}:{st.st_mtime_ns}:{st.st_size}"
    except OSError:
        return f"{path}:-"


def signature(home: Path, project: Path) -> str:
    """Hash of mtimes and sizes of the record, settings and every scanned dir."""
    home, project = Path(home), Path(project)
    proj = project if project.is_absolute() else None
    claude = home / ".claude"
    parts = [_stat(claude / "plugins" / "installed_plugins.json"), _stat(claude / "settings.json")]
    roots = [claude / "plugins" / "synced", claude / "skills"]
    if proj is not None:
        parts += [_stat(proj / ".claude" / "settings.json"),
                  _stat(proj / ".claude" / "settings.local.json"),
                  _stat(proj / ".mcp.json")]
        roots += [proj / ".claude" / "skills", proj / ".claude" / "agents"]
    try:
        roots += [p[3] for p in _plugin_installs(home, proj)]
    except (OSError, ValueError, RuntimeError):
        pass
    for root in roots:
        for dirpath, files in _walk(root):
            parts.append(_stat(dirpath))
            parts += [_stat(dirpath / f) for f in files if f.endswith(".md") or f == ".mcp.json"]
    return hashlib.sha256("\n".join(parts).encode("utf-8", "replace")).hexdigest()
