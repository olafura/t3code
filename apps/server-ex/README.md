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
mix t3.pair                                      # one-time pairing URL for Settings → Connections
```

State lives in the repo's `.t3/elixir` during development; set `T3_HOME` elsewhere.

## Release

```sh
MIX_ENV=prod mix release        # _build/prod/rel/t3, about 31 MB with ERTS
_build/prod/rel/t3/bin/t3 start # foreground; state in $T3_HOME (default ~/.t3/elixir)
```

A machine that has joined a cluster boots clustered: joining writes
`$T3_HOME/cluster/vm.args`, which the release reads at start.

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
