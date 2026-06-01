# statusline

A fast [Claude Code](https://claude.com/claude-code) statusline written in Zig. It shows the
working directory, git branch and diff stats, a context-window meter, and a compact subagent
panel.

```
~/projs/statusline • [main] • 3f 90(+) 2(-) • ▓▓▓▓░░░░░░ 42%
```

## Install

Grab the latest binary for your platform. The `releases/latest/download/` path always resolves
to the newest release.

```sh
mkdir -p ~/.local/bin

# Linux x86_64
curl -fL https://github.com/carlosarraes/statusline/releases/latest/download/statusline-linux-x86_64 -o ~/.local/bin/statusline && chmod +x ~/.local/bin/statusline

# Linux arm64
curl -fL https://github.com/carlosarraes/statusline/releases/latest/download/statusline-linux-arm64 -o ~/.local/bin/statusline && chmod +x ~/.local/bin/statusline

# macOS (Apple Silicon)
curl -fL https://github.com/carlosarraes/statusline/releases/latest/download/statusline-macos-arm64 -o ~/.local/bin/statusline && chmod +x ~/.local/bin/statusline

# macOS (Intel)
curl -fL https://github.com/carlosarraes/statusline/releases/latest/download/statusline-macos-x86_64 -o ~/.local/bin/statusline && chmod +x ~/.local/bin/statusline
```

`~/.local/bin` just needs to be a directory Claude Code can reach — use any path and point your
config at it. On macOS, if Gatekeeper blocks the binary, clear the quarantine flag:
`xattr -d com.apple.quarantine ~/.local/bin/statusline`.

## Usage

Add it to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.local/bin/statusline"
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.local/bin/statusline --subagent"
  }
}
```

The statusline reads Claude Code's JSON from stdin and prints a single line:

```
~/projs/statusline • [main] • 3f 90(+) 2(-) • ▓▓▓▓░░░░░░ 42%
```

| Segment | Meaning |
| --- | --- |
| `~/projs/statusline` | Current directory, with `$HOME` shown as `~` |
| `⑂` | Shown when the directory is a git worktree |
| `[main]` | Current git branch |
| `3f 90(+) 2(-)` | Files changed, insertions, deletions (`git diff --stat`) |
| `▓▓▓▓░░░░░░ 42%` | Context-window usage (green → yellow → red as it fills) |

With `--subagent`, it reads a list of tasks instead and emits one JSON line per row, rendering
`name · status · tokens · dir` for the subagent panel.

## Build from source

Requires [Zig](https://ziglang.org) 0.16.

```sh
zig build-exe statusline.zig -O ReleaseFast   # produces ./statusline
zig test statusline.zig                       # run the test suite
```

## Releasing

Releases are cut by CI on any `MAJOR.MINOR.PATCH` tag. Pushing a tag cross-compiles all four
binaries and publishes a GitHub release:

```sh
git tag 0.0.1
git push origin 0.0.1
```
