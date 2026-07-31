#!/usr/bin/env python3
"""
Gandalf — a local, zero-dependency review UI for an agent's working-tree changes.

Run:  gandalf [--repo /path/to/repo] [--base HEAD] [--port 4633] [--state-dir DIR]
Then open http://127.0.0.1:4633

- Serves the static UI from ./public (plain HTML/CSS/JS, no external requests).
- Reads the diff of the working tree vs. a base ref (default HEAD) using
  read-only git commands (works with a read-only .git mount).
- The reviewed repo defaults to the git repo containing the current directory.
- State (drafts, submitted reviews, the agent handoff file) lives in
  <repo root>/.gandalf/, regardless of the subdirectory you launched from —
  overridable with --state-dir.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

TOOL_DIR = Path(__file__).resolve().parent
PUBLIC_DIR = TOOL_DIR / "public"
STATE_DIR_NAME = ".gandalf"
MAX_FILE_BYTES = 5 * 1024 * 1024  # beyond this, skip content/expansion support
STATE_LOCK = threading.Lock()
# Hostnames that count as "this machine". The server only ever binds loopback,
# so a request whose Host names anything else reached us via DNS rebinding.
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}


class GitError(Exception):
    pass


def run_git(repo, args, input_bytes=None):
    proc = subprocess.run(
        ["git", "--no-optional-locks", "-C", str(repo)] + list(args),
        capture_output=True,
        input=input_bytes,
    )
    if proc.returncode != 0:
        raise GitError(proc.stderr.decode("utf-8", "replace").strip() or f"git {args[0]} failed")
    return proc.stdout


def run_git_text(repo, args):
    return run_git(repo, args).decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# Diff collection & parsing
# ---------------------------------------------------------------------------

def unquote_git_path(p):
    """Undo git's C-style quoting of unusual paths."""
    if not (p.startswith('"') and p.endswith('"')):
        return p
    body = p[1:-1]
    out, i = [], 0
    escapes = {'n': '\n', 't': '\t', '"': '"', '\\': '\\', 'r': '\r'}
    while i < len(body):
        c = body[i]
        if c == '\\' and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in escapes:
                out.append(escapes[nxt])
                i += 2
                continue
            if nxt.isdigit() and i + 3 < len(body):  # octal escape
                out.append(chr(int(body[i + 1:i + 4], 8)))
                i += 4
                continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_prefix(p):
    p = unquote_git_path(p.strip())
    if p == "/dev/null":
        return None
    if p.startswith("a/") or p.startswith("b/"):
        return p[2:]
    return p


HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$")


def parse_unified_diff(raw):
    files = []
    lines = raw.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        if not lines[i].startswith("diff --git "):
            i += 1
            continue
        header = lines[i]
        i += 1
        f = {
            "path": None, "oldPath": None, "status": "modified", "binary": False,
            "additions": 0, "deletions": 0, "hunks": [], "newTotal": None,
        }
        is_new = is_deleted = False
        rename_from = rename_to = None
        old_p = new_p = "__unset__"
        while i < n and not lines[i].startswith("diff --git ") and not lines[i].startswith("@@"):
            l = lines[i]
            if l.startswith("new file mode"):
                is_new = True
            elif l.startswith("deleted file mode"):
                is_deleted = True
            elif l.startswith("rename from "):
                rename_from = unquote_git_path(l[len("rename from "):])
            elif l.startswith("rename to "):
                rename_to = unquote_git_path(l[len("rename to "):])
            elif l.startswith("Binary files ") or l.startswith("GIT binary patch"):
                f["binary"] = True
            elif l.startswith("--- "):
                old_p = strip_prefix(l[4:])
            elif l.startswith("+++ "):
                new_p = strip_prefix(l[4:])
            i += 1

        if rename_to is not None:
            f["path"], f["oldPath"], f["status"] = rename_to, rename_from, "renamed"
        else:
            # Prefer ---/+++ headers; fall back to the "diff --git a/X b/Y" line.
            if new_p == "__unset__" and old_p == "__unset__":
                m = re.match(r'^diff --git "?a/(.*?)"? "?b/(.*)"?$', header)
                f["path"] = unquote_git_path(m.group(2)) if m else header
            else:
                f["path"] = new_p if new_p not in (None, "__unset__") else old_p
            if is_new:
                f["status"] = "added"
            elif is_deleted:
                f["status"] = "deleted"

        while i < n and lines[i].startswith("@@"):
            m = HUNK_RE.match(lines[i])
            if not m:
                break
            i += 1
            old_start = int(m.group(1))
            old_count = int(m.group(2)) if m.group(2) is not None else 1
            new_start = int(m.group(3))
            new_count = int(m.group(4)) if m.group(4) is not None else 1
            hunk = {
                "oldStart": old_start, "oldCount": old_count,
                "newStart": new_start, "newCount": new_count,
                "section": m.group(5) or "", "lines": [],
            }
            old_num, new_num = old_start, new_start
            old_rem, new_rem = old_count, new_count
            while i < n and (old_rem > 0 or new_rem > 0):
                l = lines[i]
                if l.startswith("\\"):  # "\ No newline at end of file"
                    if hunk["lines"]:
                        hunk["lines"][-1]["nne"] = True
                    i += 1
                    continue
                c = l[0] if l else " "
                text = l[1:] if l else ""
                if c == "+":
                    hunk["lines"].append({"t": "add", "old": None, "new": new_num, "text": text})
                    new_num += 1
                    new_rem -= 1
                    f["additions"] += 1
                elif c == "-":
                    hunk["lines"].append({"t": "del", "old": old_num, "new": None, "text": text})
                    old_num += 1
                    old_rem -= 1
                    f["deletions"] += 1
                else:
                    hunk["lines"].append({"t": "ctx", "old": old_num, "new": new_num, "text": text})
                    old_num += 1
                    new_num += 1
                    old_rem -= 1
                    new_rem -= 1
                i += 1
            f["hunks"].append(hunk)
        files.append(f)
    return files


def count_lines(data):
    if not data:
        return 0
    text = data.decode("utf-8", "replace")
    return len(text.split("\n")) - (1 if text.endswith("\n") else 0)


def synthesize_untracked(repo, rel):
    p = Path(repo) / rel
    try:
        size = p.stat().st_size
    except OSError:
        return None
    f = {
        "path": rel, "oldPath": None, "status": "added", "binary": False,
        "additions": 0, "deletions": 0, "hunks": [], "newTotal": None, "untracked": True,
    }
    if size > MAX_FILE_BYTES:
        f["binary"] = True  # treat as opaque; too big to render
        f["tooLarge"] = True
        return f
    data = p.read_bytes()
    if b"\x00" in data:
        f["binary"] = True
        return f
    text = data.decode("utf-8", "replace")
    file_lines = text.split("\n")
    if text.endswith("\n"):
        file_lines = file_lines[:-1]
    if file_lines:
        hunk = {
            "oldStart": 0, "oldCount": 0, "newStart": 1, "newCount": len(file_lines),
            "section": "", "lines": [],
        }
        for idx, t in enumerate(file_lines):
            hunk["lines"].append({"t": "add", "old": None, "new": idx + 1, "text": t})
        f["hunks"].append(hunk)
        f["additions"] = len(file_lines)
    f["newTotal"] = len(file_lines)
    return f


def hunk_sig(hunk):
    """Content signature of a hunk, independent of line numbers, used to spot
    hunks that are already present in the index (i.e. staged)."""
    h = hashlib.sha1()
    for l in hunk["lines"]:
        h.update((l["t"] + l["text"]).encode("utf-8", "replace"))
        h.update(b"\n")
    return h.hexdigest()


def skip_untracked(rel, skip_prefixes):
    if STATE_DIR_NAME in rel.split("/"):
        return True
    return any(rel == p or rel.startswith(p + "/") for p in skip_prefixes)


def gather_raws(repo, base, excludes, skip_prefixes, ignore_ws=False):
    """Run the (read-only) git commands once and derive a change fingerprint.
    The fingerprint is view-scoped: with ignore_ws, whitespace-only edits
    neither show nor count as staleness — the rendered view is unchanged."""
    ws = ["-w"] if ignore_ws else []
    raw = run_git_text(repo, [
        "diff", "--no-color", "--find-renames", "-U3", *ws, base, "--", ".", *excludes,
    ])
    cached_raw = run_git_text(repo, [
        "diff", "--cached", "--no-color", "--find-renames", *ws, base, "--", ".", *excludes,
    ])
    unstaged_names = set(
        n for n in run_git(repo, ["diff", "--name-only", "-z"])
        .decode("utf-8", "replace").split("\x00") if n
    )
    untracked = [
        rel for rel in run_git(repo, ["ls-files", "--others", "--exclude-standard", "-z"])
        .decode("utf-8", "replace").split("\x00")
        if rel and not skip_untracked(rel, skip_prefixes)
    ]
    head = run_git_text(repo, ["rev-parse", "--short", "HEAD"]).strip()
    fp = hashlib.sha256()
    for part in (raw, "\x00".join(untracked), cached_raw, head):
        fp.update(part.encode("utf-8", "replace"))
        fp.update(b"\x00")
    return {
        "raw": raw,
        "cached_raw": cached_raw,
        "unstaged_names": unstaged_names,
        "untracked": untracked,
        "head": head,
        "fingerprint": fp.hexdigest()[:16],
    }


def collect_review(repo, base, excludes, skip_prefixes, raws=None, ignore_ws=False):
    raws = raws or gather_raws(repo, base, excludes, skip_prefixes, ignore_ws=ignore_ws)
    files = parse_unified_diff(raws["raw"])
    for rel in raws["untracked"]:
        f = synthesize_untracked(repo, rel)
        if f:
            files.append(f)

    # Staged state: which files/hunks are already in the index.
    cached_files = parse_unified_diff(raws["cached_raw"])
    cached_names = set()
    cached_sigs = {}
    for cf in cached_files:
        for name in (cf["path"], cf["oldPath"]):
            if name:
                cached_names.add(name)
        cached_sigs.setdefault(cf["path"], set())
        for h in cf["hunks"]:
            cached_sigs[cf["path"]].add(hunk_sig(h))
    for f in files:
        if f.get("untracked"):
            f["stagedState"] = "none"
            continue
        names = {n for n in (f["path"], f["oldPath"]) if n}
        in_cached = bool(names & cached_names)
        in_unstaged = bool(names & raws["unstaged_names"])
        f["stagedState"] = "full" if in_cached and not in_unstaged \
            else ("partial" if in_cached else "none")
        sigs = set()
        for n in names:
            sigs |= cached_sigs.get(n, set())
        for h in f["hunks"]:
            h["staged"] = hunk_sig(h) in sigs

    finalize_files(repo, files)
    return files, raws


def finalize_files(repo, files):
    # Per-file content signature, used to persist "viewed" checkmarks: a file
    # stays viewed only while its diff is byte-identical to when it was marked.
    # Binary diffs carry no hunk content, so fall back to size + mtime there.
    for f in files:
        h = hashlib.sha1()
        for part in (f["status"], f["path"] or "", f["oldPath"] or ""):
            h.update(part.encode("utf-8", "replace"))
            h.update(b"\x00")
        for hk in f["hunks"]:
            h.update(hunk_sig(hk).encode("ascii"))
        if f["binary"]:
            try:
                st = (Path(repo) / f["path"]).stat()
                h.update(f"{st.st_size}:{st.st_mtime_ns}".encode("ascii"))
            except OSError:
                pass
        f["sig"] = h.hexdigest()[:16]

    # Total line count of the working-tree file, needed for "expand down" past
    # the last hunk. Deleted/binary files have nothing to expand into.
    for f in files:
        if f["status"] == "deleted" or f["binary"] or f.get("newTotal") is not None:
            continue
        p = Path(repo) / f["path"]
        try:
            if p.stat().st_size <= MAX_FILE_BYTES:
                f["newTotal"] = count_lines(p.read_bytes())
        except OSError:
            pass
    files.sort(key=lambda f: f["path"] or "")


# ---------------------------------------------------------------------------
# Review-to-review deltas
#
# Nothing is staged or committed between review loops, so git alone cannot
# answer "what changed since my last review". Instead, finishing a review
# snapshots the working-tree contents of every reviewed file
# (revisions/<n>.files.json, zlib-compressed), and the delta view diffs those
# snapshots against the working tree via `git diff --no-index` on temp files —
# no repo involved, so it works with a read-only .git mount.
# ---------------------------------------------------------------------------

def split_lines(data):
    text = data.decode("utf-8", "replace")
    file_lines = text.split("\n")
    if text.endswith("\n"):
        file_lines = file_lines[:-1]
    return file_lines


def describe_file_entry(p):
    """Snapshot-entry shape for a path as it is right now: {"z": ...} for
    diffable text, or an {"absent"/"binary"/"tooLarge"} marker. Two entries
    compare equal iff there is no change worth showing."""
    try:
        if not p.is_file():
            return {"absent": True}
        st = p.stat()
        if st.st_size > MAX_FILE_BYTES:
            return {"tooLarge": True, "stat": f"{st.st_size}:{st.st_mtime_ns}"}
        data = p.read_bytes()
    except OSError:
        return {"absent": True}
    if b"\x00" in data:
        return {"binary": True, "sha": hashlib.sha1(data).hexdigest()}
    return {"z": base64.b64encode(zlib.compress(data)).decode("ascii")}


def entry_bytes(entry):
    """The text content of a snapshot entry, or None if it has none."""
    if entry and "z" in entry:
        return zlib.decompress(base64.b64decode(entry["z"]))
    return None


def snapshot_worktree(repo, files):
    entries = {}
    for f in files:
        rel = f["path"]
        if not rel:
            continue
        try:
            p = safe_repo_path(repo, rel)
        except ValueError:
            continue
        entries[rel] = describe_file_entry(p)
    return entries


def snapshot_path(state_root, branch, n):
    return branch_dir(state_root, branch) / "revisions" / f"{n}.files.json"


def load_snapshot_files(state_root, branch, n):
    p = snapshot_path(state_root, branch, n)
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("files", {})
    except (OSError, json.JSONDecodeError):
        return None


def base_ref_entry(repo, base, rel):
    """Snapshot-shaped entry for the file as of the base ref. This is the
    delta baseline for files the review snapshot doesn't cover: a file that
    wasn't in the review was identical to the base at review time (else it
    would have been in the diff), and a file the base doesn't know is truly
    new since the review."""
    try:
        data = run_git(repo, ["show", f"{base}:{rel}"])
    except GitError:
        return {"absent": True}
    if len(data) > MAX_FILE_BYTES:
        return {"tooLarge": True, "stat": f"{len(data)}:base"}
    if b"\x00" in data:
        return {"binary": True, "sha": hashlib.sha1(data).hexdigest()}
    return {"z": base64.b64encode(zlib.compress(data)).decode("ascii")}


def diff_no_index(old_bytes, new_bytes, ignore_ws=False):
    """Parsed unified diff of two byte strings. `git diff --no-index` needs no
    repository (and exits 1 when the files differ, which is not an error)."""
    ws = ["-w"] if ignore_ws else []
    with tempfile.TemporaryDirectory(prefix="gandalf-delta-") as td:
        a, b = Path(td) / "a", Path(td) / "b"
        a.write_bytes(old_bytes)
        b.write_bytes(new_bytes)
        proc = subprocess.run(
            ["git", "diff", "--no-color", "-U3", *ws, "--no-index", "--", str(a), str(b)],
            capture_output=True,
        )
    if proc.returncode not in (0, 1):
        raise GitError(
            proc.stderr.decode("utf-8", "replace").strip() or "git diff --no-index failed"
        )
    parsed = parse_unified_diff(proc.stdout.decode("utf-8", "replace"))
    return parsed[0] if parsed else None


def whole_file_hunk(file_lines, kind):
    add = kind == "add"
    return {
        "oldStart": 0 if add else 1, "oldCount": 0 if add else len(file_lines),
        "newStart": 1 if add else 0, "newCount": len(file_lines) if add else 0,
        "section": "",
        "lines": [
            {"t": kind, "old": None if add else i + 1,
             "new": i + 1 if add else None, "text": t}
            for i, t in enumerate(file_lines)
        ],
    }


def delta_file(repo, rel, snap_entry, ignore_ws=False):
    """One file's diff between a review snapshot and the working tree now;
    None when it hasn't changed since that review."""
    try:
        p = safe_repo_path(repo, rel)
    except ValueError:
        return None
    old = snap_entry or {"absent": True}
    cur = describe_file_entry(p)
    if old == cur:
        return None
    old_b, cur_b = entry_bytes(old), entry_bytes(cur)

    f = {
        "path": rel, "oldPath": None, "status": "modified", "binary": False,
        "additions": 0, "deletions": 0, "hunks": [], "newTotal": None, "delta": True,
    }
    if old_b is not None and cur_b is not None:
        if old_b == cur_b:
            return None  # markers differ but bytes don't (e.g. clock-only stat drift)
        d = diff_no_index(old_b, cur_b, ignore_ws=ignore_ws)
        if d is None:
            return None
        f["hunks"], f["additions"], f["deletions"] = d["hunks"], d["additions"], d["deletions"]
        return f
    if old.get("absent") and cur_b is not None:
        f["status"] = "added"
        lines = split_lines(cur_b)
        if lines:
            f["hunks"] = [whole_file_hunk(lines, "add")]
            f["additions"] = len(lines)
        f["newTotal"] = len(lines)
        return f
    if cur.get("absent") and old_b is not None:
        f["status"] = "deleted"
        lines = split_lines(old_b)
        if lines:
            f["hunks"] = [whole_file_hunk(lines, "del")]
            f["deletions"] = len(lines)
        return f
    # Binary or too-large on at least one side: listed but not rendered.
    f["binary"] = True
    if old.get("absent"):
        f["status"] = "added"
    elif cur.get("absent"):
        f["status"] = "deleted"
    return f


def collect_review_since(repo, base, excludes, skip_prefixes, snapshot_files,
                         raws=None, ignore_ws=False):
    """The delta view: candidates are every file changed vs the base now plus
    every file the snapshot covered; each is diffed snapshot -> working tree.
    Files untouched since the review drop out entirely."""
    raws = raws or gather_raws(repo, base, excludes, skip_prefixes, ignore_ws=ignore_ws)
    current = set(raws["untracked"])
    for f in parse_unified_diff(raws["raw"]):
        for name in (f["path"], f["oldPath"]):
            if name:
                current.add(name)
    files = []
    for rel in sorted(current | set(snapshot_files.keys())):
        entry = snapshot_files.get(rel) or base_ref_entry(repo, base, rel)
        f = delta_file(repo, rel, entry, ignore_ws=ignore_ws)
        if f:
            files.append(f)
    finalize_files(repo, files)
    return files, raws


# ---------------------------------------------------------------------------
# Draft re-anchoring
#
# The rule (kept deliberately simple so it's predictable): a draft follows the
# exact lines it quotes. On every load, "new"-side drafts are re-located by
# searching the working-tree file for their quoted lines verbatim; if found,
# the anchor moves with them (occurrence closest to the previous anchor wins).
# If the quoted lines no longer exist verbatim, the draft is marked detached
# and displays its saved excerpt instead of pointing at the wrong code.
# "old"-side drafts (on deleted lines) never move — their old side is fixed —
# they only detach if the deletion itself is gone from the diff.
# ---------------------------------------------------------------------------

def safe_repo_path(repo, rel):
    root = Path(repo).resolve()
    p = (root / rel).resolve()
    if p != root and root not in p.parents:
        raise ValueError("path outside repository")
    return p


def read_worktree_lines(repo, rel):
    p = safe_repo_path(repo, rel)
    if not p.is_file() or p.stat().st_size > MAX_FILE_BYTES:
        return None
    text = p.read_bytes().decode("utf-8", "replace")
    file_lines = text.split("\n")
    if text.endswith("\n"):
        file_lines = file_lines[:-1]
    return file_lines


def find_occurrences(haystack, needle):
    n = len(needle)
    return [i for i in range(len(haystack) - n + 1) if haystack[i:i + n] == needle]


def reanchor_drafts(repo, files, drafts, baseline=None):
    """`baseline` names the view being collected (a review number for the
    delta view, None for the full diff). Old-side drafts belong to the view
    they were made in — their line numbers mean nothing against a different
    old side — so they are only re-checked when the views match. New-side
    drafts anchor to the working tree, which is the same in every view."""
    by_path = {f["path"]: f for f in files}
    file_cache = {}
    changed = False
    for c in drafts:
        if c.get("fileLevel") or c.get("reviewLevel"):
            continue  # no lines to follow; these never move or detach
        before = (c.get("detached"), c.get("startLine"), c.get("endLine"))
        if c.get("side") == "old":
            if (c.get("baseline") or None) != baseline:
                continue
            f = by_path.get(c.get("file"))
            if f is None or f.get("binary"):
                c["detached"] = True
            else:
                deleted = set()
                for h in f["hunks"]:
                    for l in h["lines"]:
                        if l["t"] == "del":
                            deleted.add(l["old"])
                c["detached"] = not all(
                    n in deleted for n in range(c["startLine"], c["endLine"] + 1)
                )
        else:
            texts = [e[1:] for e in c.get("excerpt", []) if e[:1] in ("+", " ")]
            if c["file"] not in file_cache:
                try:
                    file_cache[c["file"]] = read_worktree_lines(repo, c["file"])
                except (ValueError, OSError):
                    file_cache[c["file"]] = None
            content = file_cache[c["file"]]
            occ = find_occurrences(content, texts) if (texts and content is not None) else []
            if not occ:
                c["detached"] = True
            else:
                c["detached"] = False
                best = min(occ, key=lambda i: abs((i + 1) - c["startLine"]))
                c["startLine"] = best + 1
                c["endLine"] = best + len(texts)
        if (c.get("detached"), c.get("startLine"), c.get("endLine")) != before:
            changed = True
    return changed


def hunk_patch(path, hunk):
    """Reconstruct a minimal unified-diff patch for one hunk (for git apply)."""
    out = [
        f"--- a/{path}",
        f"+++ b/{path}",
        "@@ -{},{} +{},{} @@".format(
            hunk["oldStart"], hunk["oldCount"], hunk["newStart"], hunk["newCount"]
        ),
    ]
    prefixes = {"add": "+", "del": "-", "ctx": " "}
    for l in hunk["lines"]:
        out.append(prefixes[l["t"]] + l["text"])
        if l.get("nne"):
            out.append("\\ No newline at end of file")
    return ("\n".join(out) + "\n").encode("utf-8")


# ---------------------------------------------------------------------------
# Branch-scoped state under <repo>/.gandalf/
# ---------------------------------------------------------------------------

def current_branch(repo):
    name = run_git_text(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).strip()
    if name == "HEAD":  # detached
        sha = run_git_text(repo, ["rev-parse", "--short", "HEAD"]).strip()
        return f"detached-{sha}"
    return name


def branch_slug(branch):
    return re.sub(r"[^A-Za-z0-9._-]+", "__", branch)


def branch_dir(state_root, branch):
    return Path(state_root) / "branches" / branch_slug(branch)


def write_text_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def write_json_atomic(path, obj):
    write_text_atomic(path, json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


def read_state(state_root, branch):
    p = branch_dir(state_root, branch) / "state.json"
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return {"branch": branch, "drafts": [], "revisions": []}


def write_state(state_root, branch, state):
    write_json_atomic(branch_dir(state_root, branch) / "state.json", state)


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def render_review_markdown(snapshot):
    """The agent-facing form of a submitted review: plain markdown whose
    preamble carries everything needed to act on it, so the reviewer never
    has to explain this tool to an agent. Works both pasted into a chat and
    read from .gandalf/pending-review.md."""
    base_ref = snapshot.get("base") or "HEAD"
    base_desc = "the last commit (HEAD)" if base_ref == "HEAD" \
        else f"the base ref `{base_ref}`"
    lines = [
        "# Code review — please address each comment",
        "",
        f"Review r{snapshot['revision']} of the uncommitted working-tree changes "
        f"in this repository (branch `{snapshot['branch']}`, "
        f"HEAD {snapshot['head']}, submitted {snapshot['submittedAt']}).",
        "",
        "How to read the comments:",
        "",
        "- \"Line N\" refers to the file as it exists in the working tree right now.",
        f"- Comments marked \"on deleted code\" are about removed lines; those line "
        f"numbers refer to the file as of {base_desc}.",
        "- Each comment quotes the lines it targets (`+`/`-`/space = added/removed/"
        "unchanged). If line numbers have drifted since submission, locate the "
        "quoted code instead.",
        "- Comments marked \"detached\" quote code that has since changed; apply "
        "their intent to the closest current code.",
        "- A \"File comment\" applies to its whole file; an \"Overall\" section "
        "applies to the entire change.",
        "",
    ]
    overall = [c for c in snapshot.get("comments", []) if c.get("reviewLevel")]
    if overall:
        lines.append("## Overall")
        lines.append("")
        for c in overall:
            lines.append((c.get("text") or "").rstrip())
            lines.append("")
    by_file = {}
    for c in snapshot.get("comments", []):
        if c.get("reviewLevel"):
            continue
        by_file.setdefault(c.get("file") or "(unknown file)", []).append(c)
    for path in sorted(by_file):
        lines.append(f"## {path}")
        lines.append("")
        # File-level comments first (startLine None sorts as 0), then by line.
        for c in sorted(by_file[path], key=lambda c: (c.get("startLine") or 0)):
            if c.get("fileLevel"):
                lines.append("**File comment**")
                lines.append("")
                lines.append((c.get("text") or "").rstrip())
                lines.append("")
                continue
            start, end = c.get("startLine"), c.get("endLine")
            rng = f"Line {start}" if start == end else f"Lines {start}–{end}"
            notes = []
            if c.get("side") == "old":
                # A baseline marks a comment made in the "changes since review
                # rN" view: its deleted lines came from that review's snapshot
                # of the file, not from the base ref.
                if c.get("baseline"):
                    notes.append(f"on code removed since review r{c['baseline']}")
                else:
                    notes.append("on deleted code")
            if c.get("detached"):
                notes.append("detached")
            suffix = f" ({', '.join(notes)})" if notes else ""
            lines.append(f"**{rng}{suffix}**")
            lines.append("")
            for ex in c.get("excerpt") or []:
                lines.append(f"> {ex}")
            if c.get("excerpt"):
                lines.append("")
            lines.append((c.get("text") or "").rstrip())
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def make_handler(repo, base, state_root, excludes, skip_prefixes):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # keep the terminal quiet
            pass

        # -- helpers -------------------------------------------------------
        def send_json(self, obj, status=200):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def send_error_json(self, message, status=500):
            self.send_json({"error": message}, status=status)

        # -- request-origin guard -----------------------------------------
        # The server is unauthenticated and loopback-only; these two checks
        # keep *other* things on the machine from driving it. The Host check
        # defeats DNS rebinding (a rebound page still sends the attacker's
        # hostname); the Origin check defeats cross-site requests (a browser
        # always attaches Origin to cross-origin fetches, and can't forge a
        # loopback one). Absent Origin => not a browser CSRF vector (e.g. curl,
        # or a same-origin top-level navigation), so it's allowed through.
        def host_is_loopback(self):
            host = self.headers.get("Host", "")
            if host.startswith("["):  # bracketed IPv6, e.g. [::1]:4633
                hostname = host[1:host.index("]")] if "]" in host else host
            else:
                hostname = host.rsplit(":", 1)[0] if ":" in host else host
            return hostname in LOOPBACK_HOSTS

        def origin_is_loopback(self):
            origin = self.headers.get("Origin")
            if origin is None:
                return True
            try:
                return urlparse(origin).hostname in LOOPBACK_HOSTS
            except ValueError:
                return False

        def guard_local(self):
            if not self.host_is_loopback():
                self.send_error_json("forbidden: non-local Host header", 403)
                return False
            if not self.origin_is_loopback():
                self.send_error_json("forbidden: cross-origin request", 403)
                return False
            return True

        def read_body_json(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > 20 * 1024 * 1024:
                raise ValueError("request too large")
            return json.loads(self.rfile.read(length).decode("utf-8"))

        def repo_file(self, rel):
            return safe_repo_path(repo, rel)

        # -- routes --------------------------------------------------------
        def do_GET(self):
            if not self.guard_local():
                return
            try:
                url = urlparse(self.path)
                q = parse_qs(url.query)
                route = url.path
                if route == "/":
                    return self.serve_static("index.html")
                if route in ("/style.css", "/app.js", "/highlight.js", "/index.html"):
                    return self.serve_static(route.lstrip("/"))
                if route == "/api/review":
                    return self.api_review(q)
                if route == "/api/status":
                    return self.api_status(q)
                if route == "/api/file":
                    return self.api_file(q)
                if route == "/api/revision":
                    return self.api_revision(q)
                if route == "/api/revision-md":
                    return self.api_revision_md(q)
                self.send_error_json("not found", 404)
            except GitError as e:
                self.send_error_json(f"git: {e}", 500)
            except Exception as e:  # noqa: BLE001 — surface anything to the UI
                self.send_error_json(str(e), 500)

        def do_POST(self):
            if not self.guard_local():
                return
            try:
                route = urlparse(self.path).path
                if route == "/api/drafts":
                    return self.api_drafts()
                if route == "/api/submit":
                    return self.api_submit()
                if route == "/api/stage":
                    return self.api_stage()
                if route == "/api/viewed":
                    return self.api_viewed()
                self.send_error_json("not found", 404)
            except GitError as e:
                self.send_error_json(f"git: {e}", 500)
            except Exception as e:  # noqa: BLE001
                self.send_error_json(str(e), 500)

        def serve_static(self, name):
            p = (PUBLIC_DIR / name).resolve()
            if PUBLIC_DIR not in p.parents or not p.is_file():
                return self.send_error_json("not found", 404)
            body = p.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPES.get(p.suffix, "application/octet-stream"))
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def api_review(self, q):
            branch = current_branch(repo)
            since_q = (q.get("since") or [""])[0]
            since = int(since_q) if since_q.isdigit() else None
            ignore_ws = (q.get("ws") or [""])[0] == "1"
            raws = gather_raws(repo, base, excludes, skip_prefixes, ignore_ws=ignore_ws)
            if since is not None:
                snap_files = load_snapshot_files(state_root, branch, since)
                if snap_files is None:
                    return self.send_error_json(f"no snapshot for review r{since}", 404)
                files, raws = collect_review_since(
                    repo, base, excludes, skip_prefixes, snap_files,
                    raws=raws, ignore_ws=ignore_ws,
                )
            else:
                files, raws = collect_review(
                    repo, base, excludes, skip_prefixes, raws=raws, ignore_ws=ignore_ws
                )
            with STATE_LOCK:
                state = read_state(state_root, branch)
                drafts = state.get("drafts", [])
                if reanchor_drafts(repo, files, drafts, baseline=since):
                    write_state(state_root, branch, state)
            viewed_map = state.get("viewed", {})
            for f in files:
                f["viewed"] = viewed_map.get(f["path"]) == f["sig"]
            self.send_json({
                "repo": Path(repo).name,
                "branch": branch,
                "base": base,
                "since": since,
                "ignoreWhitespace": ignore_ws,
                "head": raws["head"],
                "fingerprint": raws["fingerprint"],
                "files": files,
                "drafts": drafts,
                "revisions": state.get("revisions", []),
            })

        def api_status(self, q):
            # Same ?ws= the review was fetched with, so fingerprints compare.
            ignore_ws = (q.get("ws") or [""])[0] == "1"
            raws = gather_raws(repo, base, excludes, skip_prefixes, ignore_ws=ignore_ws)
            self.send_json({"fingerprint": raws["fingerprint"], "head": raws["head"]})

        def api_file(self, q):
            rel = (q.get("path") or [""])[0]
            if not rel:
                return self.send_error_json("missing ?path=", 400)
            p = self.repo_file(rel)
            if not p.is_file():
                return self.send_error_json("no such file in working tree", 404)
            if p.stat().st_size > MAX_FILE_BYTES:
                return self.send_error_json("file too large for context expansion", 413)
            text = p.read_bytes().decode("utf-8", "replace")
            file_lines = text.split("\n")
            if text.endswith("\n"):
                file_lines = file_lines[:-1]
            self.send_json({"path": rel, "lines": file_lines})

        def api_revision(self, q):
            n = (q.get("n") or [""])[0]
            if not n.isdigit():
                return self.send_error_json("missing ?n=", 400)
            branch = current_branch(repo)
            p = branch_dir(state_root, branch) / "revisions" / f"{int(n)}.json"
            if not p.is_file():
                return self.send_error_json("no such revision", 404)
            self.send_json(json.loads(p.read_text(encoding="utf-8")))

        def api_revision_md(self, q):
            n = (q.get("n") or [""])[0]
            if not n.isdigit():
                return self.send_error_json("missing ?n=", 400)
            branch = current_branch(repo)
            p = branch_dir(state_root, branch) / "revisions" / f"{int(n)}.json"
            if not p.is_file():
                return self.send_error_json("no such revision", 404)
            snap = json.loads(p.read_text(encoding="utf-8"))
            self.send_json({"markdown": render_review_markdown(snap)})

        def api_drafts(self):
            payload = self.read_body_json()
            drafts = payload.get("drafts")
            if not isinstance(drafts, list):
                return self.send_error_json("expected {drafts: [...]}", 400)
            branch = current_branch(repo)
            with STATE_LOCK:
                state = read_state(state_root, branch)
                state["drafts"] = drafts
                write_state(state_root, branch, state)
            self.send_json({"ok": True, "count": len(drafts)})

        def api_viewed(self):
            payload = self.read_body_json()
            path_ = payload.get("path")
            sig = payload.get("sig")
            viewed = payload.get("viewed")
            if not isinstance(path_, str) or not isinstance(sig, str) \
                    or not isinstance(viewed, bool):
                return self.send_error_json("expected {path, sig, viewed}", 400)
            branch = current_branch(repo)
            with STATE_LOCK:
                state = read_state(state_root, branch)
                viewed_map = state.setdefault("viewed", {})
                if viewed:
                    viewed_map[path_] = sig
                else:
                    viewed_map.pop(path_, None)
                write_state(state_root, branch, state)
            self.send_json({"ok": True})

        def api_submit(self):
            payload = self.read_body_json()
            comments = payload.get("comments")
            if not isinstance(comments, list) or not comments:
                return self.send_error_json("no comments to submit", 400)
            branch = current_branch(repo)
            # Freeze the diff the way the reviewer saw it (ignore-whitespace
            # is cosmetic; comments carry their own excerpts either way).
            ignore_ws = bool(payload.get("ignoreWs"))
            files, raws = collect_review(
                repo, base, excludes, skip_prefixes, ignore_ws=ignore_ws
            )
            # The content snapshot is a checkpoint in time, not a view: cover
            # the plain changed-file set even when the reviewer hid
            # whitespace, so later deltas don't resurface pre-review
            # whitespace edits as "changed since".
            snap_files = files
            if ignore_ws:
                snap_files, _ = collect_review(repo, base, excludes, skip_prefixes)
            head = raws["head"]
            submitted_at = now_iso()
            with STATE_LOCK:
                state = read_state(state_root, branch)
                revision = (state["revisions"][-1]["revision"] + 1) if state["revisions"] else 1
                snapshot = {
                    "revision": revision,
                    "branch": branch,
                    "base": base,
                    "head": head,
                    "submittedAt": submitted_at,
                    "comments": comments,
                    "files": files,
                }
                write_json_atomic(
                    branch_dir(state_root, branch) / "revisions" / f"{revision}.json", snapshot
                )
                # Working-tree contents of the reviewed files, so a later
                # session can show only what changed since this review.
                write_json_atomic(
                    snapshot_path(state_root, branch, revision),
                    {"revision": revision, "files": snapshot_worktree(repo, snap_files)},
                )
                state["revisions"].append({
                    "revision": revision,
                    "submittedAt": submitted_at,
                    "head": head,
                    "commentCount": len(comments),
                    "hasSnapshot": True,
                })
                state["drafts"] = []
                write_state(state_root, branch, state)
                # The agent-facing handoff file: latest submitted review only,
                # self-describing markdown (see render_review_markdown).
                markdown = render_review_markdown(snapshot)
                write_text_atomic(Path(state_root) / "pending-review.md", markdown)
                # Predecessor format; remove so no agent reads a stale review.
                (Path(state_root) / "pending-review.json").unlink(missing_ok=True)
            self.send_json({
                "ok": True,
                "revision": revision,
                "revisions": state["revisions"],
                "markdown": markdown,
            })

        def api_stage(self):
            """Stage/unstage a whole file or a single hunk. Requires a writable
            .git; failures (e.g. read-only mounts) surface as error toasts."""
            payload = self.read_body_json()
            action = payload.get("action")
            rel = payload.get("path")
            if not rel:
                return self.send_error_json("missing path", 400)
            safe_repo_path(repo, rel)  # traversal guard; git does the real work
            old_rel = payload.get("oldPath")
            if old_rel:
                safe_repo_path(repo, old_rel)
            if action == "stage-file":
                paths = [rel] + ([old_rel] if old_rel else [])
                run_git(repo, ["add", "--"] + paths)
            elif action == "unstage-file":
                paths = [rel] + ([old_rel] if old_rel else [])
                run_git(repo, ["reset", "-q", "HEAD", "--"] + paths)
            elif action in ("stage-hunk", "unstage-hunk"):
                hunk = payload.get("hunk")
                if not isinstance(hunk, dict):
                    return self.send_error_json("missing hunk", 400)
                args = ["apply", "--cached", "--whitespace=nowarn"]
                if action == "unstage-hunk":
                    args.append("--reverse")
                args.append("-")
                run_git(repo, args, input_bytes=hunk_patch(rel, hunk))
            else:
                return self.send_error_json("unknown action", 400)
            self.send_json({"ok": True})

    return Handler


def main():
    import sys

    ap = argparse.ArgumentParser(prog="gandalf", description="Gandalf — local review UI")
    ap.add_argument("--repo", default=None,
                    help="repository to review (default: the git repo containing the cwd)")
    ap.add_argument("--base", default="HEAD",
                    help="ref to diff the working tree against (default: HEAD)")
    ap.add_argument("--state-dir", default=None,
                    help="where review state lives (default: <repo root>/.gandalf)")
    ap.add_argument("--port", type=int, default=None,
                    help="port to bind (default: 4633, or the next free port "
                         "after it so parallel sessions just work)")
    ap.add_argument("--no-open", action="store_true",
                    help="don't open the review UI in a browser on startup")
    args = ap.parse_args()

    cwd = Path.cwd()
    if args.repo:
        repo = Path(args.repo).resolve()
        if not (repo / ".git").exists():
            print(f"error: {repo} does not look like a git repository", file=sys.stderr)
            raise SystemExit(1)
    else:
        try:
            repo = Path(run_git_text(cwd, ["rev-parse", "--show-toplevel"]).strip()).resolve()
        except GitError as e:
            print(f"error: not inside a git repository ({e})", file=sys.stderr)
            raise SystemExit(1)

    state_root = Path(args.state_dir).resolve() if args.state_dir else repo / STATE_DIR_NAME

    # Keep the state directory itself out of the review: exclude it from the
    # diff / untracked scan when it lives inside the reviewed repo.
    excludes = [f":(exclude){STATE_DIR_NAME}"]
    skip_prefixes = []
    try:
        rel = state_root.relative_to(repo).as_posix()
        if rel not in (".", STATE_DIR_NAME):
            excludes.append(f":(exclude){rel}")
            skip_prefixes.append(rel)
    except ValueError:
        pass  # state dir is outside the repo; nothing to exclude

    handler = make_handler(repo, args.base, state_root, excludes, skip_prefixes)
    if args.port is not None:
        # An explicit port is a promise: fail loudly rather than move the URL.
        try:
            server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
        except OSError as e:
            print(f"error: cannot bind port {args.port}: {e}", file=sys.stderr)
            raise SystemExit(1)
    else:
        server = None
        port = 4633
        for candidate in range(port, port + 50):
            try:
                server = ThreadingHTTPServer(("127.0.0.1", candidate), handler)
                break
            except OSError:
                continue  # in use (likely another gandalf); try the next one
        if server is None:
            print(f"error: no free port in {port}–{port + 49}; use --port",
                  file=sys.stderr)
            raise SystemExit(1)
    url = f"http://127.0.0.1:{server.server_address[1]}"
    print(f"gandalf: reviewing {repo} (base: {args.base})")
    print(f"gandalf: state in   {state_root}")
    print(f"gandalf: {url}")
    if not args.no_open:
        # The socket is bound, so the page can't beat the server. A daemon
        # thread keeps a blocking platform default (e.g. a terminal browser
        # in a headless container) from wedging startup; failures are silent
        # and the printed URL is the fallback.
        import webbrowser
        threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
