# gandalf

A local, zero-dependency code-review UI for an agent's uncommitted
working-tree changes: stdlib-only Python server (`server.py`) + plain
HTML/CSS/JS (`public/`). The README is the short human intro.

**Read `docs/DESIGN.md` before changing anything** — it documents the full
feature behavior, the state layout, and the hard invariants (zero
dependencies, strict CSP, read-only `.git` support, no auto-refresh,
predictable comment anchoring, flat comments). Ask before relaxing any
invariant.

## Checks

```sh
python3 -m py_compile server.py
node --check public/app.js
node tests/test_buildrows.js
node tests/test_highlight.js
```

`public/` changes only need a browser reload; `server.py` changes need a
server restart. For end-to-end checks, script a throwaway fixture repo and
run the real server on a spare port with `--no-open`.
