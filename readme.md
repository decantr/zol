# Zol - Zig OSRS Launcher

A minimal, portable session manager and launcher for Jagex accounts (Old School
 RuneScape).
It manages config, login sessions, and cached characters from the command line,
 and can launch the client with a chosen character.

## Requirements

- Zig 0.16.0 or newer

Using [mise](https://mise.jdx.dev), install dependencies:

```sh
mise install
```

## Build

```sh
mise run build-release
```

This builds an optimized release binary to `zig-out/bin/zol`.

## Run

```sh
zig build run
```

Or run the built binary directly:

```sh
zig-out/bin/zol help
```
