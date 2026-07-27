# T3 Code for Herdr

This plugin hosts the existing T3 Code terminal UI inside Herdr. T3 Code keeps
ownership of structured projects, threads, and timelines; Herdr supplies Spaces,
native agents, and real terminal panes.

In hosted mode, Herdr owns navigation by default. Press `Ctrl-F` to show or hide
T3's full projects-and-threads sidebar when you need functionality Herdr's
native sidebar cannot expose. The current Herdr Space selects the project
checkout, and the active T3 thread reports semantic working, blocked, or idle
state into Herdr's native Agents sidebar. `Ctrl-E` opens the selected T3
terminal below the prompt, using the same drawer and terminal tab strip as the
standalone TUI. It attaches to the same server terminal session used by the web
and standalone TUI, so history, output, and input stay shared across clients.

Use the T3 command palette (`Ctrl-K`) to create, close, clear, restart, or focus
the next/previous terminal. Only the selected terminal is visible; background
terminal tabs remain attached and continue buffering output.

Requirements:

- Herdr 0.7.5 or newer on Linux or macOS
- the `bun` executable available on `PATH`
- either a linked T3 Code source checkout or the `t3` executable on `PATH`
- a running T3 Code server

For local development, link the plugin and open its dashboard pane:

```sh
herdr plugin link ./plugins/herdr
herdr plugin pane open --plugin dev.t3code --entrypoint dashboard
```

A locally linked plugin launches `apps/server/src/bin.ts` from that checkout, so
it uses the same build and `http://localhost:5733` development server as
`pnpm run tui:dev`. Run `pnpm run tui:build` after TUI source changes. Set
`T3_CODE_DEV_URL` to use another development server, or `T3_CODE_BIN` to
override the executable explicitly.

If T3 Code is not already running, open the `server` entrypoint in a separate
Herdr tab:

```sh
herdr plugin pane open --plugin dev.t3code --entrypoint server
```

The standalone `t3 tui` command remains unchanged. The plugin launcher alone
adds `--tui-host herdr`.
