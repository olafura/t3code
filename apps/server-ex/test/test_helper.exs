# Tests tagged :codex or :claude drive the real provider CLIs; run them with
# `mix test --include codex` / `--include claude`. Tests tagged :parity compare
# against Node output from real data; see T3.Projection.ShellParityTest.
ExUnit.start(exclude: [:codex, :claude, :parity])
