# gandalf — design notes

For maintainers and agents. The README is the user-facing intro; this covers
the layout, the invariants, and the decisions that aren't obvious from the
code.

## Layout

- `GandalfServer/` — Swift package. `GandalfCore` is the library;
  `gandalf` is the CLI (argument parsing, then `App.run`). Version lives in
  `Sources/gandalf/Version.swift`.
  - `Server.swift` (SwiftNIO, loopback only, requests on a thread pool since
    git blocks), `Router.swift` (routes + API), `Review.swift` (diffs,
    snapshots, commit list), `Diff.swift` (unified-diff parser),
    `Drafts.swift` (re-anchoring, hunk patches), `State.swift`,
    `Markdown.swift` (agent handoff), `JSON.swift`, and git/path/text helpers.
- `public/` — the UI: plain HTML/CSS/JS, compiled into the binary via
  `.embedInCode` (through the `Sources/GandalfCore/public` symlink). A new
  file needs an entry in `uiFiles` in `Router.swift`; a test enforces it.
  UI changes need a rebuild.
- `tests/` — node tests for the pure parts of `app.js` (row building, split
  pairing, selection anchoring, file tree) and `highlight.js`.
- `GandalfRelease/` — `gandalf-release`, which tests, builds, signs,
  notarizes, tags `v<version>`, and drafts a GitHub release. macOS only.
- `gandalf` — symlink to the release build, for running from a checkout.

## Checks

```sh
(cd GandalfServer && swift build -c release && swift test)
node --check public/app.js
node tests/test_buildrows.js
node tests/test_highlight.js
node tests/test_filetree.js
```

For end-to-end checks, script a throwaway fixture repo and run the real server
on a spare port with `--no-open`. Visual changes can be checked with headless
Firefox via `geckodriver`.

## Invariants

Ask before relaxing any of these.

- **Apple-only dependencies** for the server (SwiftNIO, Argument Parser,
  Crypto); no npm, CDN, or web fonts. Builds on macOS and Linux.
- **No network.** Binds `127.0.0.1`; strict CSP in `index.html` (so no
  inline styles); Host and Origin checks against DNS rebinding and
  cross-site requests.
- **Read-only `.git` works.** Git calls use `--no-optional-locks`. Staging is
  the only write into `.git` and fails gracefully. Snapshots go to gandalf's
  own object store.
- **Never auto-refresh.** Drift shows a "diff is out of date" banner; the
  view never moves on its own.
- **Predictable comment anchoring** (below); no fuzzy matching.
- **Single-level threads.** Replies attach to a root, never to a reply.
- **Deterministic JSON.** Everything goes through `JSON`, which sorts keys.
- **State at `<repo root>/.gandalf/`** (`--state-dir` overrides), excluded
  from the diff.
- **Firefox on macOS** is the target browser.

## Views

| View | Old side → new side | Query |
| --- | --- | --- |
| Uncommitted changes (default) | `--base` → working tree | — |
| Since review rN | rN's snapshot → working tree | `since=N` |
| One commit | first parent → commit | `commit=SHA` |
| All changes since main | branch point → working tree | `all=1` |

- `--base` resolves to its merge-base with HEAD, so `--base main` shows what
  the branch changed.
- The commit list is HEAD's first-parent history back to the branch point
  (merge-base with `origin/HEAD`, `main`, or `master`), capped at 100.
- Staging is offered only when the old side is HEAD, and hunk staging not
  while ignoring whitespace (a `-w` hunk isn't a valid patch).

## Snapshots

Nothing need be committed between reviews, so finishing a review snapshots
the working tree as a git tree (temporary index, `GIT_OBJECT_DIRECTORY` set to
`.gandalf/objects` with `.git` as an alternate). "Since rN" is then a plain
tree diff, unaffected by commits or rebases. A `git gc` can prune blobs an old
snapshot relied on; that surfaces as the stale-view fallback.

**Wipe review history** deletes revisions and snapshots but keeps drafts and
Viewed marks. It's the only destructive action, so it sits behind the gear
menu and a confirmation.

## Comments

- **Anchoring:** a new-side draft follows the exact lines it quotes. On load,
  it's re-located by verbatim search of the working tree, nearest the old
  position winning; if the lines are gone, it detaches and shows its excerpt.
  Old-side drafts (on deleted lines) never move, and only anchor in views
  with the same old side.
- In split view, a selection with any new-side line anchors on the new side;
  only an all-deletions selection anchors on the old side, since mixed
  old-side anchors would detach on reload.
- **Surfaces:** comments made in a commit view are pinned to that commit and
  never re-anchored. Other views show a note linking to them. Comments on
  commits no longer in history collect in their own bucket.
- Half-written comments are never dropped implicitly: replacing an open form
  stashes it as an unfinished draft. Only Cancel or Esc discards.
- A review with no comments is an approval, and still checkpoints.

## Fold vs. Viewed

Folding is just display. Viewed collapses the file, resets expanded context,
and is keyed to a signature of the file's diff, so it clears when the diff
changes.

## Handoff

Finishing writes `revisions/<n>.json` (comments + the diff as seen), the
snapshot, and `.gandalf/pending-review.md`. The markdown is self-describing,
so an agent needs no knowledge of gandalf: "Line N" means the working tree
now, and commit-pinned comments get their own sections.

## State

```
.gandalf/
  pending-review.md      # latest review only
  objects/               # snapshot trees, shared across branches
  branches/<branch>/
    state.json           # drafts, viewed marks, revision index
    revisions/<n>.json
```

Detached HEAD uses `detached-<sha>`. Writes are atomic, under a process-wide
lock.

## Known limits

- The staleness fingerprint doesn't hash untracked files' contents.
- Highlighting is line-by-line, so a hunk starting inside a block comment or
  multiline string renders plain until it closes.
- Identical duplicate hunks can confuse the per-hunk staged badge.
