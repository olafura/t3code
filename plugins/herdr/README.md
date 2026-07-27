# T3 Code for Herdr

This plugin hosts the existing T3 Code terminal UI inside Herdr. T3 Code keeps
ownership of structured projects, threads, and timelines; Herdr supplies Spaces,
native agents, and real terminal panes.

In hosted mode, Herdr owns Spaces and Agents. The active T3 thread is reported
as a native Herdr Agent, including its title, project, branch, model, and
working/blocked/idle state. Press `Ctrl-F` to show or hide T3's own
projects-and-threads sidebar; Herdr's plugin API can decorate and filter native
Space/Agent rows, but cannot inject an arbitrary project/thread tree.

`Ctrl-E` asks Herdr to split one real terminal pane below the dashboard. T3's
compact terminal tab strip switches which server terminal that pane is attached
to, so opening more terminal instances does not create more Herdr panes or
top-level tabs. History, output, and input stay shared with the web and
standalone clients. Press `Ctrl-P` in the terminal to focus the T3 dashboard.

Use the T3 command palette (`Ctrl-K`) to create, close, clear, restart, or switch
terminal instances. Only the selected terminal is attached to the native pane;
the server continues owning the other sessions.

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
