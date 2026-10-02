#!/usr/bin/env python3
"""
Gandalf — a local, zero-dependency review UI for an agent's working-tree
changes and commits.

Run:  gandalf [--repo /path/to/repo] [--base HEAD] [--port 4633] [--state-dir DIR]
Then open http://127.0.0.1:4633

- Serves the static UI from ./public (plain HTML/CSS/JS, no external requests).
- Reads the diff of the working tree vs. a base ref (default HEAD), or of
  single commits, using read-only git commands (works with a read-only .git
  mount; review snapshots go to a private object store under the state dir).
- The reviewed repo defaults to the git repo containing the current directory.
- State (drafts, submitted reviews, the agent handoff file) lives in
  <repo root>/.gandalf/, regardless of the subdirectory you launched from —
  overridable with --state-dir.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
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


class ViewError(Exception):
    """The requested view can't be shown (e.g. its snapshot is gone)."""


# Query parameters that pick a view (see collect_view).
VIEW_PARAMS = ("since", "commit", "all")


def run_git(repo, args, input_bytes=None, env=None):
    proc = subprocess.run(
        ["git", "--no-optional-locks", "-C", str(repo)] + list(args),
        capture_output=True,
        input=input_bytes,
        env={**os.environ, **env} if env else None,
    )
    if proc.returncode != 0:
        raise GitError(proc.stderr.decode("utf-8", "replace").strip() or f"git {args[0]} failed")
    return proc.stdout


def run_git_text(repo, args, env=None):
    return run_git(repo, args, env=env).decode("utf-8", "replace")


SHA_RE = re.compile(r"[0-9a-f]{4,64}")


def is_sha(s):
    """Guards anything client-supplied before it reaches git's argv."""
    return isinstance(s, str) and SHA_RE.fullmatch(s) is not None


def rev_parse(repo, ref):
    """Full object name of a commit, or None."""
    try:
        return run_git_text(repo, ["rev-parse", "--verify", "-q", f"{ref}^{{commit}}"]).strip()
    except GitError:
        return None


def is_ancestor(repo, sha, of="HEAD"):
    try:
        run_git(repo, ["merge-base", "--is-ancestor", sha, of])
        return True
    except GitError:
        return False


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


def file_bytes(repo, rel, rev=None):
    """A file's contents in the working tree (rev=None) or at a commit; None
    when it doesn't exist there or is over MAX_FILE_BYTES."""
    if rev is None:
        p = safe_repo_path(repo, rel)
        if not p.is_file() or p.stat().st_size > MAX_FILE_BYTES:
            return None
        return p.read_bytes()
    spec = f"{rev}:{rel}"
    try:
        if int(run_git_text(repo, ["cat-file", "-s", spec])) > MAX_FILE_BYTES:
            return None
        return run_git(repo, ["cat-file", "blob", spec])
    except (GitError, ValueError):
        return None


def split_lines(data):
    text = data.decode("utf-8", "replace")
    file_lines = text.split("\n")
    if text.endswith("\n"):
        file_lines = file_lines[:-1]
    return file_lines


def finalize_files(repo, files, rev=None):
    """`rev` names the commit a commit view's new side comes from; None means
    the working tree."""
    # Per-file content signature, used to persist "viewed" checkmarks: a file
    # stays viewed only while its diff is byte-identical to when it was marked.
    # Binary diffs carry no hunk content, so fall back to size + mtime there
    # (a commit never changes, so its sha is enough).
    for f in files:
        h = hashlib.sha1()
        for part in (f["status"], f["path"] or "", f["oldPath"] or ""):
            h.update(part.encode("utf-8", "replace"))
            h.update(b"\x00")
        for hk in f["hunks"]:
            h.update(hunk_sig(hk).encode("ascii"))
        if f["binary"] and rev:
            h.update(rev.encode("ascii"))
        elif f["binary"]:
            try:
                st = (Path(repo) / f["path"]).stat()
                h.update(f"{st.st_size}:{st.st_mtime_ns}".encode("ascii"))
            except OSError:
                pass
        f["sig"] = h.hexdigest()[:16]

    # Total line count of the new-side file, needed for "expand down" past
    # the last hunk. Deleted/binary files have nothing to expand into.
    for f in files:
        if f["status"] == "deleted" or f["binary"] or f.get("newTotal") is not None:
            continue
        try:
            data = file_bytes(repo, f["path"], rev)
        except (ValueError, OSError):
            data = None
        if data is not None:
            f["newTotal"] = count_lines(data)
    files.sort(key=lambda f: f["path"] or "")


# ---------------------------------------------------------------------------
# Review snapshots & the other views
#
# Finishing a review snapshots the whole working tree as a git tree object.
# The objects go to a private store (<state>/objects) that borrows the
# repo's own objects as an alternate: only uncommitted content is stored, and
# .git is never written to. "Since review rN" is then a plain tree-to-tree
# `git diff`, unaffected by commits, rebases or a moving base.
# ---------------------------------------------------------------------------

def snapshot_env(repo, state_root):
    objects = Path(state_root) / "objects"
    objects.mkdir(parents=True, exist_ok=True)
    repo_objects = run_git_text(repo, ["rev-parse", "--git-path", "objects"]).strip()
    return {
        "GIT_OBJECT_DIRECTORY": str(objects),
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": str((Path(repo) / repo_objects).resolve()),
    }


def snapshot_tree(repo, state_root, state_paths):
    """Tree object for the working tree as it is now (tracked + untracked,
    minus ignored files and gandalf's own state at `state_paths`)."""
    env = snapshot_env(repo, state_root)
    with tempfile.TemporaryDirectory(prefix="gandalf-index-") as td:
        env["GIT_INDEX_FILE"] = str(Path(td) / "index")
        # Starting from a copy of the repo's index lets `add` trust its stat
        # cache and hash only what changed.
        real = Path(repo) / run_git_text(repo, ["rev-parse", "--git-path", "index"]).strip()
        if real.is_file():
            shutil.copyfile(real, env["GIT_INDEX_FILE"])
        else:
            run_git(repo, ["read-tree", "HEAD"], env=env)
        # Not an exclude pathspec: `add` rejects one naming an ignored path,
        # and the state dir is usually gitignored.
        run_git(repo, ["add", "-A"], env=env)
        run_git(repo, ["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", *state_paths],
                env=env)
        return run_git_text(repo, ["write-tree"], env=env).strip()


def diff_revs(repo, a, b, ignore_ws=False, env=None):
    ws = ["-w"] if ignore_ws else []
    raw = run_git_text(
        repo, ["diff", "--no-color", "--find-renames", "-U3", *ws, a, b, "--"], env=env
    )
    return parse_unified_diff(raw)


def collect_review_since(repo, state_root, state_paths, tree, ignore_ws=False):
    """What changed between review snapshot `tree` and the working tree."""
    now = snapshot_tree(repo, state_root, state_paths)
    files = diff_revs(repo, tree, now, ignore_ws, env=snapshot_env(repo, state_root))
    finalize_files(repo, files)
    return files


def commit_parent(repo, sha):
    """First parent, or the empty tree for a root commit."""
    parent = rev_parse(repo, f"{sha}^")
    if parent:
        return parent
    return run_git_text(repo, ["hash-object", "-t", "tree", "--stdin"]).strip()


def collect_commit(repo, sha, ignore_ws=False):
    files = diff_revs(repo, commit_parent(repo, sha), sha, ignore_ws)
    finalize_files(repo, files, rev=sha)
    return files


def commit_info(repo, sha):
    """{sha, short, subject, time} for a commit object, or None."""
    try:
        out = run_git_text(repo, ["log", "-1", "--format=%H%x00%s%x00%ct", sha, "--"])
    except GitError:
        return None
    full, subject, ts = out.rstrip("\n").split("\x00", 2)
    return {"sha": full, "short": full[:7], "subject": subject, "time": int(ts or 0)}


def branch_point(repo):
    """(sha, name): HEAD's merge-base with the default branch (HEAD itself
    when on it) and that branch's short name; None when there is no default
    branch to compare with."""
    for ref in ("refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master"):
        tip = rev_parse(repo, ref)
        if not tip:
            continue
        try:
            sha = run_git_text(repo, ["merge-base", tip, "HEAD"]).strip()
            name = run_git_text(repo, ["rev-parse", "--abbrev-ref", ref]).strip()
        except GitError:
            return None
        return sha, name
    return None


def list_commits(repo, point, reviewed_head=None, limit=100):
    """The commits on HEAD's branch: first-parent history back to, but not
    including, branch point `point`, newest first. Without a branch point,
    just the most recent commits. `new` marks commits made since
    `reviewed_head`."""
    try:
        out = run_git_text(repo, [
            "log", "--first-parent", f"-n{limit}", "--format=%H%x00%s",
            f"{point}..HEAD" if point else "HEAD", "--",
        ])
    except GitError:
        return []  # unborn branch
    new = set()
    if reviewed_head:
        try:
            new = set(run_git_text(repo, ["rev-list", "HEAD", f"^{reviewed_head}", "--"]).split())
        except GitError:
            pass  # reviewed head no longer exists
    commits = []
    for line in out.splitlines():
        sha, subject = line.split("\x00", 1)
        commits.append({"sha": sha, "short": sha[:7], "subject": subject, "new": sha in new})
    return commits


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
# they only detach if the deletion itself is gone from the diff. Drafts made
# in a commit view are pinned to that commit, which never changes, so they
# are never re-anchored at all.
# ---------------------------------------------------------------------------

def safe_repo_path(repo, rel):
    root = Path(repo).resolve()
    p = (root / rel).resolve()
    if p != root and root not in p.parents:
        raise ValueError("path outside repository")
    return p


def read_worktree_lines(repo, rel):
    data = file_bytes(repo, rel)
    return None if data is None else split_lines(data)


def find_occurrences(haystack, needle):
    n = len(needle)
    return [i for i in range(len(haystack) - n + 1) if haystack[i:i + n] == needle]


def old_side_key(c):
    """Which old side a draft's deleted-line numbers point into."""
    if c.get("commit"):
        return ("commit", c["commit"])
    if c.get("baseline"):
        return ("since", c["baseline"])
    return ("base", c.get("base"))


def view_old_key(view):
    kind = view["kind"]
    return (kind, view["since"] if kind == "since" else view[kind])


def reanchor_drafts(repo, files, drafts, view):
    """`view` is the view being collected. Old-side drafts belong to the view
    they were made in — their line numbers mean nothing against a different
    old side — so they are only re-checked when the views match. New-side
    drafts anchor to the working tree, which is the new side of every view
    but a commit view."""
    by_path = {f["path"]: f for f in files}
    file_cache = {}
    changed = False
    for c in drafts:
        if c.get("fileLevel") or c.get("reviewLevel") or c.get("parentId"):
            continue  # no lines of their own; replies follow their thread root
        if c.get("commit"):
            continue  # pinned to an immutable commit
        before = (c.get("detached"), c.get("startLine"), c.get("endLine"))
        if c.get("side") == "old":
            if old_side_key(c) != view_old_key(view):
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
            if view["kind"] == "commit":
                continue
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


def wipe_history(state_root, branch, all_branches):
    """Delete submitted reviews and their content snapshots — for when git
    surgery (rebase, reset, re-created branch) makes the "since review rN"
    baselines meaningless. Drafts and Viewed marks are deliberately kept:
    they are the review in progress, not history. Returns what was removed."""
    root = Path(state_root) / "branches"
    if all_branches:
        dirs = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
    else:
        d = branch_dir(state_root, branch)
        dirs = [d] if d.is_dir() else []
    reviews = 0
    branches = 0
    for d in dirs:
        sp = d / "state.json"
        state = None
        if sp.exists():
            try:
                state = json.loads(sp.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                state = None  # unreadable state: still drop the revisions
        n = len((state or {}).get("revisions") or [])
        revdir = d / "revisions"
        had_dir = revdir.is_dir()
        if not had_dir and not n:
            continue
        if had_dir:
            shutil.rmtree(revdir)
        if state is not None:
            state["revisions"] = []
            write_json_atomic(sp, state)
        reviews += n
        branches += 1
    # Snapshot trees are shared across branches, so only a full wipe can
    # drop the store; a branch wipe just leaves its trees unreferenced.
    if all_branches:
        shutil.rmtree(Path(state_root) / "objects", ignore_errors=True)
    # The handoff file describes the latest submitted review; once that review
    # is gone, an agent must not still be able to act on it.
    (Path(state_root) / "pending-review.md").unlink(missing_ok=True)
    (Path(state_root) / "pending-review.json").unlink(missing_ok=True)
    return {"reviews": reviews, "branches": branches}


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
    comments = snapshot.get("comments") or []
    commits = snapshot.get("commits") or {}
    intro = (
        f"Review r{snapshot['revision']} of the changes in this repository "
        f"(branch `{snapshot['branch']}`, HEAD {snapshot['head']}, "
        f"submitted {snapshot['submittedAt']})"
    )
    if not comments:
        # A commentless review is an approval: the reviewer checkpointed the
        # changes as good. Say so plainly — an agent reading the handoff
        # file should know there is nothing to act on.
        return (
            "# Code review — approved, nothing to address\n"
            "\n"
            f"{intro} was finished with no comments: the reviewer approved "
            "these changes as-is. No action is needed.\n"
        )
    on_commits = any(c.get("commit") for c in comments)
    lines = [
        "# Code review — please address each comment",
        "",
        f"{intro}.",
        "",
        "How to read the comments:",
        "",
        "- \"Line N\" refers to the file as it exists in the working tree right now"
        + (", except under a \"Commit\" heading." if on_commits else "."),
        f"- Comments marked \"on deleted code\" are about removed lines; those line "
        f"numbers refer to the file as of {base_desc}, unless noted otherwise.",
        "- Each comment quotes the lines it targets (`+`/`-`/space = added/removed/"
        "unchanged). If line numbers have drifted since submission, locate the "
        "quoted code instead.",
        "- Comments marked \"detached\" quote code that has since changed; apply "
        "their intent to the closest current code.",
        "- A \"File comment\" applies to its whole file; an \"Overall\" section "
        "applies to the entire change.",
    ]
    if on_commits:
        lines += [
            "- Comments under a \"Commit\" heading were left on that single commit. "
            "Their line numbers refer to the file as of that commit (or its parent, "
            "for deleted lines). The code may have changed since: address them in "
            "the current code, and don't rewrite history unless asked.",
            "- A commit marked \"no longer in history\" was rewritten (e.g. by a "
            "rebase); locate the quoted code instead.",
        ]
    lines.append("")
    overall = [c for c in comments if c.get("reviewLevel")]
    if overall:
        lines.append("## Overall")
        lines.append("")
        for c in overall:
            lines.append((c.get("text") or "").rstrip())
            lines.append("")
    # Replies render as additional paragraphs of their thread root's entry.
    replies = {}
    for c in comments:
        if c.get("parentId"):
            replies.setdefault(c["parentId"], []).append(c)
    for arr in replies.values():
        arr.sort(key=lambda c: str(c.get("createdAt") or ""))

    def entry_text(c):
        texts = [(c.get("text") or "").rstrip()]
        texts += [(r.get("text") or "").rstrip() for r in replies.get(c.get("id"), [])]
        return "\n\n".join(t for t in texts if t)

    def file_sections(by_file, heading):
        for path in sorted(by_file):
            lines.append(f"{heading} {path}")
            lines.append("")
            # File-level comments first (startLine None sorts as 0), then by line.
            for c in sorted(by_file[path], key=lambda c: (c.get("startLine") or 0)):
                if c.get("fileLevel"):
                    lines.append("**File comment**")
                    lines.append("")
                    lines.append(entry_text(c))
                    lines.append("")
                    continue
                start, end = c.get("startLine"), c.get("endLine")
                rng = f"Line {start}" if start == end else f"Lines {start}–{end}"
                notes = []
                if c.get("side") == "old":
                    # A baseline marks a comment made in the "changes since
                    # review rN" view: its deleted lines came from that
                    # review's snapshot, not from the base ref.
                    if c.get("baseline"):
                        notes.append(f"on code removed since review r{c['baseline']}")
                    elif c.get("base") and c["base"] != snapshot.get("baseSha") \
                            and not c.get("commit"):
                        notes.append(f"on deleted code, as of commit {c['base'][:7]}")
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
                lines.append(entry_text(c))
                lines.append("")

    worktree, by_commit = {}, {}
    for c in comments:
        if c.get("reviewLevel") or c.get("parentId"):
            continue
        group = by_commit.setdefault(c["commit"], {}) if c.get("commit") else worktree
        group.setdefault(c.get("file") or "(unknown file)", []).append(c)
    file_sections(worktree, "##")
    # Commits in history order; rewritten ones last.
    order = sorted(by_commit, key=lambda sha: (
        bool(commits.get(sha, {}).get("gone")), commits.get(sha, {}).get("time", 0)))
    for sha in order:
        meta = commits.get(sha, {})
        title = f"## Commit `{meta.get('short') or sha[:7]}`"
        if meta.get("subject"):
            title += f" — {meta['subject']}"
        if meta.get("gone"):
            title += " (no longer in history)"
        lines.append(title)
        lines.append("")
        file_sections(by_commit[sha], "###")
    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def make_handler(repo, base, state_root, excludes, skip_prefixes):
    # gandalf's own state, as repo-relative paths kept out of snapshots.
    state_paths = [STATE_DIR_NAME, *skip_prefixes]

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
                if route in ("/style.css", "/app.js", "/highlight.js", "/index.html",
                             "/favicon.svg"):
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
                if route == "/api/reset-history":
                    return self.api_reset_history()
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

        def default_base(self):
            """--base as a commit: its merge-base with HEAD, so a branch name
            reviews what this branch changed (GitHub's `base...HEAD`)."""
            try:
                return run_git_text(repo, ["merge-base", base, "HEAD"]).strip()
            except GitError:
                sha = rev_parse(repo, base)
                if not sha:
                    raise GitError(f"unknown base ref {base!r}")
                return sha

        def collect_view(self, params, revisions, default, ignore_ws, raws=None):
            """-> (files, view). `params` picks the view: since=N (review rN's
            snapshot -> working tree), commit=SHA (one commit vs its parent),
            or all=1 (the branch point -> working tree). Without any, --base
            -> working tree."""
            since, commit, all_ = (params.get(k) for k in VIEW_PARAMS)
            if since:
                rev = next((r for r in revisions
                            if str(r.get("revision")) == str(since) and r.get("tree")), None)
                if rev is None:
                    raise ViewError(f"no snapshot for review r{since}")
                try:
                    files = collect_review_since(
                        repo, state_root, state_paths, rev["tree"], ignore_ws
                    )
                except GitError as e:
                    raise ViewError(f"snapshot for review r{since} is unreadable ({e})")
                return files, {"kind": "since", "since": rev["revision"]}
            if commit:
                info = commit_info(repo, commit) if is_sha(commit) else None
                if not info:
                    raise ViewError(f"no such commit {commit}")
                return collect_commit(repo, info["sha"], ignore_ws), {
                    "kind": "commit", "commit": info["sha"],
                    "short": info["short"], "subject": info["subject"],
                }
            view_base, since_branch = default, None
            if all_:
                point = branch_point(repo)
                if not point:
                    raise ViewError("no default branch to diff against")
                # On the default branch, that is just the default view.
                if point[0] != default:
                    view_base, since_branch = point
            files, _ = collect_review(
                repo, view_base, excludes, skip_prefixes,
                raws=raws if view_base == default else None, ignore_ws=ignore_ws,
            )
            # Staging works on the index, so its badges and hunk patches only
            # make sense when the diff is relative to HEAD.
            if view_base != rev_parse(repo, "HEAD"):
                for f in files:
                    f["stagedState"] = None
                    for h in f["hunks"]:
                        h["staged"] = False
            return files, {"kind": "base", "base": view_base, "all": since_branch}

        def api_review(self, q):
            branch = current_branch(repo)
            ignore_ws = (q.get("ws") or [""])[0] == "1"
            params = {k: (q.get(k) or [""])[0] for k in VIEW_PARAMS}
            with STATE_LOCK:
                revisions = read_state(state_root, branch).get("revisions", [])
            default = self.default_base()
            raws = gather_raws(repo, default, excludes, skip_prefixes, ignore_ws=ignore_ws)
            try:
                files, view = self.collect_view(params, revisions, default, ignore_ws, raws)
            except ViewError as e:
                return self.send_error_json(str(e), 404)
            with STATE_LOCK:
                state = read_state(state_root, branch)
                drafts = state.get("drafts", [])
                if reanchor_drafts(repo, files, drafts, view):
                    write_state(state_root, branch, state)
            # Viewed marks are per path in the working-tree views, and per
            # commit + path in a commit view.
            viewed_map = state.get("viewed", {})
            for f in files:
                key = f"{view['commit']}:{f['path']}" if view["kind"] == "commit" else f["path"]
                f["viewedKey"] = key
                f["viewed"] = viewed_map.get(key) == f["sig"]
            reviewed_head = next(
                (r["headSha"] for r in reversed(revisions) if r.get("headSha")), None
            )
            pinned = {c["commit"] for c in drafts if is_sha(c.get("commit"))}
            point = branch_point(repo)
            # "All changes" only means something off the default branch, and
            # when it isn't what the default view already shows.
            all_changes = point[1] if point and point[0] not in (
                rev_parse(repo, "HEAD"), default) else None
            self.send_json({
                "repo": Path(repo).name,
                "branch": branch,
                "base": base,
                "view": view,
                "ignoreWhitespace": ignore_ws,
                "head": raws["head"],
                # A commit never changes, so there is nothing to go stale.
                "fingerprint": None if view["kind"] == "commit" else raws["fingerprint"],
                "files": files,
                "drafts": drafts,
                "revisions": state.get("revisions", []),
                "commits": list_commits(repo, point and point[0], reviewed_head),
                "allChanges": all_changes,
                "lostCommits": sorted(s for s in pinned if not is_ancestor(repo, s)),
            })

        def api_status(self, q):
            # Same ?ws= the review was fetched with, so fingerprints compare.
            ignore_ws = (q.get("ws") or [""])[0] == "1"
            raws = gather_raws(
                repo, self.default_base(), excludes, skip_prefixes, ignore_ws=ignore_ws
            )
            self.send_json({"fingerprint": raws["fingerprint"], "head": raws["head"]})

        def api_file(self, q):
            """A file's lines in the working tree, or at ?rev= (a commit view)."""
            rel = (q.get("path") or [""])[0]
            if not rel:
                return self.send_error_json("missing ?path=", 400)
            rev = (q.get("rev") or [""])[0] or None
            if rev is not None and not is_sha(rev):
                return self.send_error_json("bad ?rev=", 400)
            data = file_bytes(repo, rel, rev)
            if data is None:
                return self.send_error_json("file missing or too large for context expansion", 404)
            self.send_json({"path": rel, "lines": split_lines(data)})

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

        def api_reset_history(self):
            payload = self.read_body_json()
            scope = payload.get("scope")
            if scope not in ("branch", "all"):
                return self.send_error_json('expected {scope: "branch"|"all"}', 400)
            branch = current_branch(repo)
            with STATE_LOCK:
                stats = wipe_history(state_root, branch, scope == "all")
            self.send_json({"ok": True, **stats})

        def api_submit(self):
            payload = self.read_body_json()
            comments = payload.get("comments")
            # An empty list is a valid review: it approves the changes.
            if not isinstance(comments, list):
                return self.send_error_json("expected {comments: [...]}", 400)
            branch = current_branch(repo)
            ignore_ws = bool(payload.get("ignoreWs"))
            view_params = {k: str(v) for k, v in (payload.get("view") or {}).items()
                           if k in VIEW_PARAMS and v}
            default = self.default_base()
            with STATE_LOCK:
                revisions = read_state(state_root, branch).get("revisions", [])
            # Freeze the diff the way the reviewer saw it, for the audit trail
            # (comments carry their own excerpts either way).
            try:
                files, view = self.collect_view(view_params, revisions, default, ignore_ws)
            except ViewError:
                files, view = self.collect_view({}, revisions, default, ignore_ws)
            # The checkpoint the next "since" view diffs against.
            tree = snapshot_tree(repo, state_root, state_paths)
            head_sha = rev_parse(repo, "HEAD")
            head = run_git_text(repo, ["rev-parse", "--short", "HEAD"]).strip()
            commits = {}
            for sha in {c.get("commit") for c in comments if is_sha(c.get("commit"))}:
                info = commit_info(repo, sha) or {"short": sha[:7], "subject": "", "time": 0}
                commits[sha] = {**info, "gone": not is_ancestor(repo, sha)}
            submitted_at = now_iso()
            with STATE_LOCK:
                state = read_state(state_root, branch)
                revision = (state["revisions"][-1]["revision"] + 1) if state["revisions"] else 1
                snapshot = {
                    "revision": revision,
                    "branch": branch,
                    "base": base,
                    "baseSha": default,
                    "head": head,
                    "headSha": head_sha,
                    "submittedAt": submitted_at,
                    "view": view,
                    "commits": commits,
                    "comments": comments,
                    "files": files,
                }
                write_json_atomic(
                    branch_dir(state_root, branch) / "revisions" / f"{revision}.json", snapshot
                )
                state["revisions"].append({
                    "revision": revision,
                    "submittedAt": submitted_at,
                    "head": head,
                    "headSha": head_sha,
                    "tree": tree,
                    "commentCount": len(comments),
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
