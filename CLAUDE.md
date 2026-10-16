# gandalf

A local code-review UI for an agent's uncommitted working-tree changes: a
Swift package (`GandalfServer/`: the `GandalfCore` library and a thin
`gandalf` CLI on SwiftNIO) + plain HTML/CSS/JS (`public/`). The README is
the short human intro.

**Read `docs/DESIGN.md` before changing anything** — it documents the full
feature behavior, the state layout, and the hard invariants (Apple-only
dependencies, strict CSP, read-only `.git` support, no auto-refresh,
predictable comment anchoring, single-level threads, deterministic JSON).
Ask before relaxing any invariant.

## Checks

```sh
(cd GandalfServer && swift build -c release && swift test)
node --check public/app.js
node tests/test_buildrows.js
node tests/test_highlight.js
node tests/test_filetree.js
```

`public/` changes only need a browser reload; `GandalfServer/` changes need
`swift build -c release` (the `gandalf` symlink points at the release
binary) and a server restart. For end-to-end checks, script a throwaway
fixture repo and run the real server on a spare port with `--no-open`.
