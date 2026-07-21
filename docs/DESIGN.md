# gandalf — design & behavior reference

This is the maintainer/agent-facing companion to the README (which is the
short human intro). It records what the tool does in detail, the invariants
that must not regress, and why the design is the way it is. If you are an
agent resuming work on this repo: read this before changing `server.py` or
`public/`.

## What it is

A local, zero-dependency "PR review" UI for an agent's **uncommitted
working-tree changes**. The reviewer comments in a browser; finishing a
review renders the comments as **self-describing markdown** to paste to an
agent (also written to `.gandalf/pending-review.md`), snapshots the review
locally as an audit trail, and checkpoints the working tree so the next
review can show only what changed since.

## Hard invariants (do not regress; ask before relaxing)

- **Zero dependencies.** One stdlib-only Python 3.11 file (`server.py`) plus
  plain HTML/CSS/JS in `public/`. No pip, npm, CDN, or web fonts.
- **No network.** The server binds `127.0.0.1` only. The page carries a strict
  CSP (`default-src 'none'; …` in `public/index.html`) that forbids any
  non-local request — keep it intact. Requests are guarded against DNS
  rebinding (Host header check) and cross-site requests (Origin check).
- **Read-only `.git` must work.** Every git call goes through `run_git()`
  with `--no-optional-locks`. Staging is the *only* write path and must fail
  gracefully (error toast, everything else keeps working).
- **Never auto-refresh.** On working-tree drift, show the sticky "diff is out
  of date" banner with a Refresh button. Never yank the view.
- **Predictable draft anchoring** (rule below). No fuzzy matching without
  asking the user.
- **State lives at `<repo root>/.gandalf/`** regardless of launch directory
  (`--state-dir` overrides). Local-only, never committed; `.gandalf` is
  excluded from the review diff.
- Comments are **flat** — no reply threads. Overlapping/duplicate ranges are
  allowed.
- The user runs the tool on macOS and reviews in **Firefox**; keep changes
  Firefox-compatible (e.g. the `ClipboardItem`-promise copy pattern).

## Architecture

- `gandalf` — launcher script (runpy, symlink-safe). `python3 server.py`
  works too.
- `server.py` — stdlib `ThreadingHTTPServer`. Diff collection/parsing,
  staging, staleness fingerprinting, draft re-anchoring, review snapshots,
  markdown rendering, static file serving (whitelist, `no-store`).
- `public/app.js` — all UI logic. `buildRows` (hunks + expanded context →
  display rows) is the unit-tested core.
- `public/highlight.js` — spec-driven, dependency-free syntax tokenizer.
- `tests/test_buildrows.js`, `tests/test_highlight.js` — run with
  `node tests/<file>.js`; they stub the DOM and evaluate `app.js` in a vm.

### HTTP API

| Route | Method | Purpose |
| --- | --- | --- |
| `/api/review[?since=N][&ws=1]` | GET | Review payload; `since` = delta view vs review N's snapshot; `ws=1` = ignore whitespace |
| `/api/status[?ws=1]` | GET | `{fingerprint, head}` for staleness polling (every 4 s, page-visible only); pass the same `ws` the review used |
| `/api/file?path=` | GET | Working-tree file lines (context expansion) |
| `/api/revision?n=` / `/api/revision-md?n=` | GET | Audit-trail snapshot / its markdown |
| `/api/drafts` | POST | Replace the draft set (autosave, debounced 400 ms) |
| `/api/viewed` | POST | `{path, sig, viewed}` — persist a Viewed mark |
| `/api/submit` | POST | Finish review: snapshot, markdown, clear drafts |
| `/api/stage` | POST | Stage/unstage file or hunk (needs writable `.git`) |

## Diff scope & rendering

- Diff is `working tree vs --base` (default `HEAD`), staged and unstaged
  alike, plus untracked files (synthesized as all-added). `.gandalf/` is
  excluded.
- Files > 5 MB (`MAX_FILE_BYTES`) and binary files are listed but not
  rendered.
- **Ignore whitespace** (checkbox in the Settings gear panel; per-machine
  localStorage):
  the server diffs with `-w` in both views, so whitespace-only files
  disappear entirely (git emits nothing for them) and whitespace-only lines
  render as context. While on: hunk staging is disabled (a hunk parsed from
  a `-w` diff is not a valid patch for `git apply --cached`; file-level
  staging keeps working), the topbar shows "ignoring whitespace", and the
  staleness fingerprint is view-scoped — a whitespace-only edit doesn't trip
  the banner because the rendered view wouldn't change. Submitting freezes
  the audit diff as the reviewer saw it, but the content snapshot always
  covers the plain changed-file set so later deltas don't resurface
  pre-review whitespace edits.
- Hidden unchanged regions render as gap bars with **↓ 20 / ↑ 20 / Show all**
  expansion controls; expansion fetches working-tree content lazily via
  `/api/file`.
- Syntax highlighting: `EXT_LANG`/`LANG_SPECS` in `highlight.js` (currently
  Swift). A new language = keyword set + syntax flags + extension mapping.
  Line-by-line tokenizing with carry state; old and new diff sides carry
  separately; carries reset at unexpanded gaps. Known limit: a hunk that
  *starts* inside a block comment or multiline string renders plain until the
  construct closes — cheap and predictable beats fetching whole files.
- Tab title is `gandalf: <branch>:<repo>`. The **gear (Settings) menu** in
  the topbar sets a per-machine monospace font (localStorage, prepended to
  the `--mono` stack so missing fonts fall through — never hardcode a
  personal font in the repo) and holds the ignore-whitespace toggle. The
  gear is an inline SVG (stroke `currentColor`), keeping the no-external-
  assets rule.

## Fold vs. Viewed (GitHub-style, deliberate split)

- The **caret** purely folds a file card; expanded context and any open form
  survive and return on unfold. Collapse/Expand-all do the same.
- The **Viewed** checkbox is review progress: it collapses the file and
  *resets* its expanded context. Viewed persists per branch, keyed to a
  per-file content signature (status + paths + hunk contents; binary files
  fall back to size+mtime), so it clears itself the moment that file's diff
  changes. Only Viewed resets expansion — folding never does.

## Comments

- Hover **+** on a line, or drag across lines, to comment on a line/block.
  `⌘⏎` saves, `esc` cancels. Drafts autosave (debounced POST) and survive
  reloads.
- Overlapping and duplicate ranges are allowed. When several comments end on
  the same line, the widest range renders first, then oldest.
- **File-level comments**: the **Comment** button in a file header. Rendered
  in a strip above the diff; works for binary files. `fileLevel: true`,
  no line anchoring ever.
- **Review-level (overall) comment**: written in the **Finish review dialog**
  (GitHub-summary style). Stored as a draft (`reviewLevel: true, file: null`)
  and upserted on every way out of the dialog (confirm/cancel/esc), so the
  text survives reloads and failed submits. Leads the markdown as an
  `## Overall` section. A review may consist of only an overall comment —
  the Finish button is never disabled.

### Draft anchoring (the predictable rule)

A draft follows the **exact lines it quotes**. On every load, "new"-side
drafts are re-located by searching the working-tree file for their quoted
lines verbatim; the occurrence closest to the previous anchor wins ("followed
code from line N"). If the quoted lines no longer exist verbatim, the draft
**detaches**: flagged, shows its saved excerpt, sits at the bottom of its
file card. "Old"-side drafts (on deleted lines) never move and detach only if
the deletion leaves the diff. New-side anchoring searches the working tree
regardless of whether the file is in the current view, so switching views
can't falsely detach a draft.

## Review loops (the delta view)

Nothing is committed or staged between review rounds, so git alone can't
answer "what changed since my last review". Instead:

- **Finish review snapshots** the working-tree contents of every file in the
  review to `revisions/<n>.files.json` (zlib+base64; binary/too-large files
  store markers with sha/stat).
- The topbar **baseline picker** (visible once a snapshot exists) offers
  "All changes" and "Since review rN" for every snapshotted revision.
  `GET /api/review?since=N` diffs snapshot → working tree per file with
  `git diff --no-index` on temp files — no repo state involved, read-only
  safe, same unified format, one parsing/rendering pipeline for both views.
- Files untouched since the review drop out. New files show as added;
  reverts show as reverts.
- **Snapshot-missing files fall back to the base-ref blob** as their
  baseline (`base_ref_entry`): a file that wasn't in review N was identical
  to the base at that time (else it would have been in the diff), so a file
  first touched *after* a review shows only its new edits, not the whole
  file. Files unknown to the base ref are truly new and show in full.
  Caveat: this assumes the base ref doesn't move mid-loop.
- **Staging is disabled in the delta view** (`file.delta`) — its hunks are
  not HEAD-relative and `git apply --cached` would corrupt the index.
- **Old-side comments are per-view**: a comment on deleted lines carries the
  `baseline` it was made against and only anchors in that view; elsewhere it
  renders in the "not attached to visible lines" bucket rather than on a
  coincidentally same-numbered line. New-side comments anchor identically in
  every view. In markdown these read "on code removed since review rN".
- Finishing a review **auto-advances the baseline** to the new revision, so
  the page reads "No changes since review rN" until the agent resumes. The
  choice persists per tab (sessionStorage); a stale baseline falls back to
  the full view with a toast.
- Viewed marks share one per-path signature map across views; any change to
  a file invalidates its mark in both.

## Finishing & the agent handoff

- **Finish review (N)** opens a dialog (comment tally + optional overall
  comment). Confirming POSTs `/api/submit`, which writes
  `revisions/<n>.json` (comments + full diff at submit time), the content
  snapshot, and `.gandalf/pending-review.md`, then clears drafts.
- The handoff is **self-describing markdown**: a preamble explains line-number
  semantics ("Line N" = working tree now; "on deleted code" = base version;
  detached = follow the quoted code), then per-file sections, each comment
  with its range, `+`/`-`/space-prefixed excerpt, and text. An agent needs
  zero knowledge of gandalf; the whole prompt can be *"Read
  `.gandalf/pending-review.md` and do what it says."*
- A second dialog shows the rendered markdown with a **Copy feedback**
  button (explicit, repeatable — clipboard writes happen on their own click;
  `ClipboardItem` fed a promise for Safari/Firefox gesture rules).
- The **audit trail** lists past revisions chronologically (newest last,
  nearest the fresh changes), each expandable to its frozen diff+comments and
  re-copyable via **Copy for agent** (`/api/revision-md`).
- Submit flushes the debounced draft save first so it can't land mid-submit
  and resurrect consumed drafts.

## Staging

- File-level Stage/Unstage buttons per file header (with staged/partially-
  staged badge); hunk-level Stage/Unstage on hunk headers of `modified`
  files. Added/deleted/renamed/binary files stage at file level only.
  Hunk staging is unavailable in the delta view and while ignoring
  whitespace (those hunks aren't valid HEAD-relative patches).
- Per-hunk staged detection is content-based (identical hunk exists in the
  index), so identical duplicate hunks in one file could confuse the badge —
  the underlying git state is always right.
- Requires a writable `.git`; on read-only mounts the buttons error cleanly.

## Staleness

The page polls `/api/status` every 4 s (only while visible). The fingerprint
hashes the base diff, cached diff, untracked *names*, and HEAD — note it does
not hash untracked file *contents* (known limitation). On drift, the sticky
banner offers Refresh; nothing reloads by itself.

## State layout (`<repo root>/.gandalf/`)

```
.gandalf/
  pending-review.md              # agent-facing handoff: latest review only
  branches/<branch-slug>/
    state.json                   # drafts, viewed map, revision index
    revisions/<n>.json           # per submission: comments + full diff then
    revisions/<n>.files.json     # per submission: reviewed files' contents
                                 # (zlib) — the "since review rN" baseline
```

Branch-scoped; detached HEAD uses `detached-<sha>`. All writes are atomic
(tmp + rename) under a process-wide lock.

## Testing & verification

- `python3 -m py_compile server.py` and `node --check public/app.js` after
  every change; `node tests/test_buildrows.js` and
  `node tests/test_highlight.js` (assert-style, exit code is the result).
- Server behavior is exercised end-to-end with curl against throwaway fixture
  repos (`git init` + scripted edits + the real server on a spare port) —
  see git history for examples; there is no committed server test suite yet.
- UI changes only need a browser reload (static files are `no-store`);
  `server.py` changes need a server restart.
