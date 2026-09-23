#!/usr/bin/env python3
# Fake `claude -p` and `codex exec` for text generation tests. Appends each call
# (argv, cwd, prompt) to $FAKE_TEXT_LOG and answers every key its JSON schema asks
# for with "<cli> <key>" (false for booleans).
import json, os, sys

args = sys.argv[1:]
prompt = sys.stdin.read()
codex = args[:1] == ["exec"]

log = os.environ.get("FAKE_TEXT_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({"argv": args, "cwd": os.getcwd(), "prompt": prompt}) + "\n")

if codex:
    schema = json.load(open(args[args.index("--output-schema") + 1]))
else:
    schema = json.loads(args[args.index("--json-schema") + 1])

name = "codex" if codex else "claude"
out = {key: (False if spec["type"] == "boolean" else "%s %s" % (name, key))
       for key, spec in schema["properties"].items()}

if codex:
    with open(args[args.index("--output-last-message") + 1], "w") as f:
        f.write(json.dumps(out))
else:
    print(json.dumps([{"type": "system"}, {"type": "result", "structured_output": out}]))
