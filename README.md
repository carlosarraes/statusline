# statusline

A simple terminal statusline that shows the current directory, git branch, and diff stats.

## Build

```sh
zig build-exe statusline.zig -O ReleaseFast
```

## Usage

Configure as a Claude Code statusline hook. It reads JSON from stdin and outputs a formatted statusline:

```
~/projs/statusline • [main] • 1f 24(+) 70(-)
```
