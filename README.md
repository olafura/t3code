# T3 Code

T3 Code is a minimal web GUI for coding agents (currently Codex, Claude, Cursor, and OpenCode, more coming soon).

## Installation

> [!WARNING]
> T3 Code currently supports Codex, Claude, Cursor, and OpenCode.
> Install and authenticate at least one provider before use:
>
> - Codex: install [Codex CLI](https://developers.openai.com/codex/cli) and run `codex login`
> - Claude: install [Claude Code](https://claude.com/product/claude-code) and run `claude auth login`
> - Cursor: install [Cursor CLI](https://cursor.com/cli) and run `cursor-agent login`
> - OpenCode: install [OpenCode](https://opencode.ai) and run `opencode auth login`

### Run without installing

```bash
npx t3@latest
```

Tip: Use `npx t3@latest --help` for the full CLI reference.

### Desktop app

Install the latest version of the desktop app from [GitHub Releases](https://github.com/pingdotgg/t3code/releases), or from your favorite package registry:

#### Windows (`winget`)

```bash
winget install T3Tools.T3Code
```

#### macOS (Homebrew)

```bash
brew install --cask t3-code
```

#### Arch Linux (AUR)

```bash
yay -S t3code-bin
```

### Terminal UI (over SSH, no port forwarding)

If you run a T3 Code server on a remote machine, you can monitor and drive its
threads from a terminal UI that talks to the already-running local server — no
port forwarding required. The TUI renders with [OpenTUI](https://opentui.com)
and runs on [Bun](https://bun.sh), so install Bun on the box first:

```bash
ssh my-remote-box
curl -fsSL https://bun.sh/install | bash   # if Bun isn't already installed
t3 tui                                      # or: npx t3@latest tui
```

`t3 tui` (Node) bootstraps auth and launches the UI in a Bun subprocess; if Bun
isn't on `PATH` it prints an install hint and exits.

The prompt is always ready: pick a thread with `↑`/`↓` and just start typing,
then press `Enter` to send. Conversations render as Markdown and follow the
latest reply; scroll with `PgUp`/`PgDn`. The TUI also lets you approve/deny tool
prompts (`^A`/`^R`), interrupt a running turn (`^G`), start new threads (`^N`),
and attach to a thread's terminal (`^E`; `Ctrl-Q` detaches). Start a server
first with `t3 serve` if one isn't already running.

## Some notes

We are very very early in this project. Expect bugs.

We are not accepting contributions yet.

There's no public docs site yet, checkout the miscellaneous markdown files in [docs](./docs).

## Documentation

- [Getting started](./docs/getting-started/quick-start.md)
- [Architecture overview](./docs/architecture/overview.md)
- [Provider guides](./docs/providers/codex.md)
- [Operations](./docs/operations/ci.md)
- [Reference](./docs/reference/encyclopedia.md)

## If you REALLY want to contribute still.... read this first

### Install `vp`

T3 Code uses Vite+ so you'll need to install the global `vp` command-line tool.

#### macOS / Linux

```bash
curl -fsSL https://vite.plus | bash
```

#### Windows

```bash
irm https://vite.plus/ps1 | iex
```

Checkout their getting started guide for more information: https://viteplus.dev/guide/

### Install dependencies

```bash
vp i
```

Read [CONTRIBUTING.md](./CONTRIBUTING.md) before opening an issue or PR.

Need support? Join the [Discord](https://discord.gg/jn4EGJjrvv).
