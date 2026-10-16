# gandalf 📖

> "this code shall eventually pass"

A local-only "code review" tool designed for working alongside an AI agent.

Review and comment on uncommitted changes in a browser-based UI powered by a local Swift server.

`gandalf` makes no network requests, and depends only on `git`, a browser, and Swift packages shipped by Apple. It persists review state in `.gandalf`.

## Installing

`gandalf` is a Swift CLI that runs a local HTTP server serving embedded HTML/CSS/JS.

To install, download `gandalf-<version>-macos-arm64.zip` from [Releases](https://github.com/sashaweiss/gandalf/releases), unzip it, and add `gandalf` to your `PATH`.

### Building from source

Alternatively, build `gandalf` from source. From the repo root:

```sh
swift build -c release --package-path GandalfServer
./gandalf # symlink to the built product
```

### Releases

For releasing, see `GandalfRelease/`.

## Quickstart

Navigate to the directory with changes to review, and run `gandalf`. That's it!

```sh
cd /path/to/repo-under-review
gandalf
```

See `gandalf --help` for full usage.

### Reviewing

Review should be familiar if you've used browser-based code-review tools before. Submitting a review provides you with self-describing, copy-paste ready feedback in Markdown.

Submitting a review "checkpoints" changes, such that you can subsequently re-review only the diff since your last submitted review.

## Resources

See also: [docs/](docs/).
