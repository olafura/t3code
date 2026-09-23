# Fake `codex app-server` for tests: answers the handshake and plays a scripted turn.
# A turn whose text contains "wait" stays running until turn/interrupt.
import json, sys

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

thread_id = "native-thread-1"
turns = 0
for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    if mid is None:
        continue
    if method == "initialize":
        send({"id": mid, "result": {"userAgent": "fake", "platformOs": "test"}})
    elif method in ("thread/start", "thread/resume"):
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    elif method == "turn/start":
        turns += 1
        turn_id = f"native-turn-{turns}"
        text = params["input"][0]["text"]
        send({"id": mid, "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        ctx = {"threadId": thread_id, "turnId": turn_id}
        send({"method": "turn/started", "params": {**ctx, "turn": {"id": turn_id, "status": "inProgress"}}})
        if "wait" in text:
            continue
        send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "ls", "status": "inProgress"}}})
        send({"method": "item/commandExecution/outputDelta", "params": {**ctx, "itemId": "cmd-1", "delta": "a.txt\n"}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "ls", "status": "completed", "aggregatedOutput": "a.txt\n", "exitCode": 0}}})
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-1", "text": ""}}})
        for delta in ["Hel", "lo ", "from ", "codex"]:
            send({"method": "item/agentMessage/delta", "params": {**ctx, "itemId": "msg-1", "delta": delta}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-1", "text": "Hello from codex"}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
    elif method == "turn/interrupt":
        send({"id": mid, "result": {}})
        send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": params["turnId"], "status": "interrupted"}}})
    else:
        send({"id": mid, "error": {"code": -32601, "message": method}})
