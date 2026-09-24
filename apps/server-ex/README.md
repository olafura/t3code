# T3 node (Elixir)

The Elixir/OTP backend. Each machine runs one node with its own SQLite event log;
nodes on your machines join a cluster over mutually authenticated TLS and share one
sidebar, so a client connected to any node sees threads on all of them.

Clients speak orchestration protocol 3 (`T3.Web.Protocol`): shape subscriptions over
one WebSocket, resumed from an offset. `packages/client-runtime/src/v3` adapts it to
the existing client state, so a node pairs and appears like any other environment.

## Run

```sh
mix deps.get
mix t3.import ~/path/to/snapshot/state.sqlite   # optional: a VACUUM INTO copy of a Node server's state
mix t3.server                                    # prints ws://127.0.0.1:3780/ws?token=...
mix t3.pair                                      # one-time pairing URL
```

A node serves the web app as `npx t3` does, from `apps/web/dist` in development
(`vp run build` in `apps/web`), `T3_STATIC_DIR`, or the copy a release carries. Open
the pairing URL in a browser to sign in there, or paste it into Settings →
Connections in another client.

State lives in the repo's `.t3/elixir` during development; set `T3_HOME` elsewhere.

## Release

```sh
MIX_ENV=prod mix release        # _build/prod/rel/t3, about 80 MB with ERTS
_build/prod/rel/t3/bin/t3 start # foreground; state in $T3_HOME (default ~/.t3/elixir)
```

The release carries the web app when `apps/web/dist` holds a build, and the Cursor sidecar (`packages/cursor-acp`, bundled with its
dependencies for the build machine's platform), so building one needs `pnpm`, and
running Cursor needs Node 22+ on the machine. The desktop app runs it on its own
Electron binary instead (`T3_NODE_COMMAND`).

A machine that has joined a cluster boots clustered: joining writes
`$T3_HOME/cluster/vm.args`, which the release reads at start.

Run it as a service with `bin/t3-service` (under launchd, systemd, or a terminal): it
is `bin/t3 start`, started again when the node restarts to finish an update.
`bin/t3ctl service install` sets that up as a launchd agent or systemd user unit.

`bin/t3ctl` is the node's command line (`T3.CLI`), after the Node server's `t3`:
`pair [--admin]` prints a pairing URL, and `auth`, `project` and `connect` manage
sessions, projects and the T3 Connect link on the running node.

## T3 Connect

A node links to a T3 Connect account like the Node server (`T3.Cloud`): from the app
it serves, with an administrative session (`mix t3.pair --admin`), Settings → Connections
links it, installs the relay client (`cloudflared`) when needed, and runs the tunnel
the relay provisions. Clients reaching it through the relay authenticate with DPoP
(`T3.Dpop`), and agent activity is published for notifications when turned on.

## Upgrades

A node carries the T3 version (`apps/server/package.json`, or `T3_VERSION` for a
build of its own), and clients offer to update it like any server. It moves to the
new version in place when it can: the running code is replaced module by module and
nothing reconnects. A new Erlang runtime, native library, configuration or
supervision tree needs a restart instead, which `bin/t3-service` provides
(`T3.Upgrade` has the rules).

Nodes get a version's bundle from a cluster peer that has it, or else from the
`node-v<version>` GitHub release (`.github/workflows/release-node.yml`; set
`T3_UPGRADE_URL` to publish elsewhere). From a checkout:

```sh
T3_VERSION=0.0.43-mine mix t3.upgrade t3@host     # build a release, send it, update
mix t3.upgrade --dev t3a@my-mac t3b@my-mac        # nodes run with `mix run`: reload changes
MIX_ENV=prod mix t3.bundle                        # just pack _build/prod/rel/t3
```

A process that holds state across an upgrade migrates it: OTP processes in
`code_change/3`, and `T3.Web.Socket` (whose processes belong to Bandit) at its next
callback.

## Cluster your machines

```sh
mix t3.cluster init 100.x.y.z                    # first machine: its Tailscale IP
mix t3.cluster invite 100.a.b.c bundle           # on a member, for the new machine
mix t3.cluster join bundle                       # on the new machine; then delete the bundle
elixir --erl "$(mix t3.cluster vm-args)" -S mix t3.server
```

Nodes find each other on the tailnet (`T3.Cluster.Tailscale`) or through
`T3_PEERS=t3@host,...`, and only connect when both certificates come from the
cluster's CA.

## Test

`mix test` runs the suite. `--include codex` / `--include claude` drive the real
CLIs; `--include parity` compares sidebar rows with the Node server's
(see `test/t3/projection/shell_parity_test.exs`).
