# gandalf 📖

> "this code shall eventually pass"

A local-only, zero-dependency "code review" tool designed for working alongside an AI agent.

Review and comment on uncommitted changes (made by an agent) — or the commits on your branch — in a browser-based UI powered by a local Python server. Submitting a review provides you with a self-describing markdown summary of your comments, ready to be handed back to the agent.

`gandalf` makes no network requests, has no third-party dependencies besides Python and a browser, and only needs read-only access to `.git`. It stores state relevant to its reviews (not expected to be committed) in `<repo>/.gandalf`.

## Quickstart

Navigate to the directory with changes to review, and run `gandalf`. That's it!

```sh
cd /path/to/repo-under-review
gandalf
```

Options:

- `--repo PATH`: repository to review (default: the git repo containing the cwd)
- `--base REF`: what to diff the working tree against by default (its
  merge-base with `HEAD`, so a branch name shows what this branch changed).
  Default: `HEAD`.
- `--state-dir DIR`: where review state lives. Default: `<repo>/.gandalf`.
- `--port N`: default `4633`, or the next free port after it — so parallel
  sessions just work. An explicit `--port` fails rather than moving the URL.
- `--no-open`: don't open the browser on startup.

## Reviewing

Review should be familiar if you've used browser-based code-review tools before.
Diffs show **inline** or **split** (side-by-side) — toggle in the topbar; the
choice sticks on this machine. The left sidebar is a **file tree** of the diff:
fold folders, filter by path (`/` focuses the box), and click a file to jump to
it. Submitting a review provides you with copyable feedback, addressed and self-explanatory, for you to paste to your agent.

The **view picker** in the topbar chooses what you're reviewing: uncommitted
changes, all changes since your branch left main, everything since a past
review, or a single commit on its own. Comments left on a single commit stay pinned to
that commit, and the feedback tells the agent which commit they're about.

Submitting a review "checkpoints" changes, such that your next review will show the diff *since the last review*, regardless of git commits or rebases.

If git surgery makes those checkpoints unhelpful, **Wipe review history** in
the gear menu deletes past reviews and their snapshots — in-progress drafts
are kept.

## Resources

Detailed behavior, design decisions, and invariants live in [docs/](docs/).
