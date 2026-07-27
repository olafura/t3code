# T3 Code for Herdr

This plugin hosts the existing T3 Code terminal UI inside Herdr. T3 Code keeps
ownership of structured projects, threads, and timelines; Herdr supplies Spaces,
native agents, and real terminal panes.

In hosted mode, Herdr owns navigation: the T3 pane does not render the
standalone projects sidebar. The current Herdr Space selects the project
checkout, and the active T3 thread reports semantic working, blocked, or idle
state into Herdr's native Agents sidebar. `Ctrl-E` opens a real Herdr shell pane
for that thread, falling back to the project root if an old worktree has already
been removed.

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
