# T3 Code for Herdr

This plugin hosts the existing T3 Code terminal UI inside Herdr. T3 Code keeps
ownership of structured projects, threads, and timelines; Herdr supplies Spaces,
native agents, and real terminal panes.

Requirements:

- Herdr 0.7.5 or newer on Linux or macOS
- the `t3` and `bun` executables available on `PATH`
- a running T3 Code server

For local development, link the plugin and open its dashboard pane:

```sh
herdr plugin link ./plugins/herdr
herdr plugin pane open --plugin dev.t3code --entrypoint dashboard
```

If T3 Code is not already running, open the `server` entrypoint in a separate
Herdr tab:

```sh
herdr plugin pane open --plugin dev.t3code --entrypoint server
```

The standalone `t3 tui` command remains unchanged. The plugin launcher alone
adds `--tui-host herdr`.
