# Fake `codex app-server` for tests: answers the handshake and plays a scripted turn.
# A turn whose text contains "wait" stays running until turn/interrupt; "approve" asks
# to run a command, "ask" asks a question (item/tool/requestUserInput), and "write NAME"
# creates the file NAME. "where are we" says which native thread the turn ran on and whether
# handed-off history or merged work came with the message.
import json, os, sys

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

thread_id = "native-thread-1"
# Current Codex keeps paginated history, which only rewinds with thread/revert.
paginated = os.environ.get("FAKE_CODEX_LEGACY") != "1"
turns = 0
for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    if mid is None:
        continue
    # A reply to our question: say what was answered.
    if "result" in msg and mid == "input-1":
        ctx = pending_ctx
        text = "answered " + json.dumps(msg["result"]["answers"], sort_keys=True)
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-ask", "text": ""}}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-ask", "text": text}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
        continue
    # A reply to our approval request: finish the command according to the decision.
    if "result" in msg and mid == "approval-1":
        decision = msg["result"]["decision"]
        ctx = pending_ctx
        status = "completed" if decision in ("accept", "acceptForSession") else "declined"
        if status == "completed":
            open("x", "w").write("approved\n")
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": status, "aggregatedOutput": "", "exitCode": 0}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
        continue
    if method == "initialize":
        send({"id": mid, "result": {"userAgent": "fake", "platformOs": "test"}})
    elif method == "feedback/upload":
        send({"id": mid, "result": {"threadId": f"feedback-for-{params['threadId']}"}})
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
            waiting_ctx = ctx
            continue
        if "where are we" in text:
            where = f"on {thread_id} history {'<conversation_history>' in text} merged {'<merged_work>' in text}"
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-where", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-where", "text": where}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if text.startswith("repeat"):
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-repeat", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-repeat", "text": text}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if text.startswith("write "):
            open(text.split()[1], "w").write(text + "\n")
        if "look" in text:
            kinds = [item["type"] for item in params["input"]]
            saved = "is saved at" in text
            send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-look", "text": ""}}})
            send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-look", "text": f"input {','.join(kinds)} saved {saved}"}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if "plan" in text:
            mode = (params.get("collaborationMode") or {}).get("mode")
            if mode == "plan":
                send({"method": "turn/plan/updated", "params": {**ctx, "explanation": "Two steps", "plan": [
                    {"step": "Read the code", "status": "completed"}, {"step": "Write the plan", "status": "inProgress"}]}})
                send({"method": "item/started", "params": {**ctx, "item": {"type": "plan", "id": "plan-1", "text": ""}}})
                for delta in ["# Plan\n", "- do it"]:
                    send({"method": "item/plan/delta", "params": {**ctx, "itemId": "plan-1", "delta": delta}})
                send({"method": "item/completed", "params": {**ctx, "item": {"type": "plan", "id": "plan-1", "text": "# Plan\n- do it"}}})
            else:
                send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-mode", "text": ""}}})
                send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-mode", "text": f"mode {mode}"}}})
            send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
            continue
        if "ask" in text:
            pending_ctx = ctx
            send({"id": "input-1", "method": "item/tool/requestUserInput", "params": {**ctx, "itemId": "ask-1", "questions": [
                {"id": "color", "header": "Color", "question": "Which color?", "options": [{"label": "Red", "description": "Warm"}]}]}})
            continue
        if "approve" in text:
            pending_ctx = ctx
            send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "touch x", "status": "inProgress"}}})
            send({"id": "approval-1", "method": "item/commandExecution/requestApproval", "params": {**ctx, "itemId": "cmd-1", "command": "touch x"}})
            continue
        send({"method": "item/started", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "ls", "status": "inProgress"}}})
        send({"method": "item/commandExecution/outputDelta", "params": {**ctx, "itemId": "cmd-1", "delta": "a.txt\n"}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "commandExecution", "id": "cmd-1", "command": "ls", "status": "completed", "aggregatedOutput": "a.txt\n", "exitCode": 0}}})
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-1", "text": ""}}})
        for delta in ["Hel", "lo ", "from ", "codex"]:
            send({"method": "item/agentMessage/delta", "params": {**ctx, "itemId": "msg-1", "delta": delta}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-1", "text": "Hello from codex"}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": turn_id, "status": "completed"}}})
    elif method == "turn/steer":
        ctx = waiting_ctx
        if params["expectedTurnId"] != ctx["turnId"]:
            send({"id": mid, "error": {"code": -32600, "message": "turn moved on"}})
            continue
        send({"id": mid, "result": {"turnId": ctx["turnId"]}})
        text = "steered: " + params["input"][0]["text"]
        send({"method": "item/started", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-steer", "text": ""}}})
        send({"method": "item/completed", "params": {**ctx, "item": {"type": "agentMessage", "id": "msg-steer", "text": text}}})
        send({"method": "turn/completed", "params": {**ctx, "turn": {"id": ctx["turnId"], "status": "completed"}}})
    elif method == "thread/fork":
        thread_id = f"forked-{params['threadId']}-at-{params.get('lastTurnId')}"
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    elif method == "thread/revert" and paginated:
        thread_id = f"native-thread-1-before-{params['beforeTurnId']}"
        send({"id": mid, "result": {"thread": {"id": thread_id, "turns": []}}})
    elif method == "thread/rollback" and paginated:
        send({"id": mid, "error": {"code": -32600, "message": "paginated threads do not support thread/rollback"}})
    elif method == "thread/rollback":
        # The returned id says how many turns were dropped.
        thread_id = f"native-thread-1-dropped-{params['numTurns']}"
        send({"id": mid, "result": {"thread": {"id": thread_id}}})
    # Account and quota: FAKE_CODEX_ACCOUNT picks the account type ("none" signs out).
    # A reset credit redemption logs its idempotency key to FAKE_CODEX_CONSUME_LOG and
    # fails once while the FAKE_CODEX_CONSUME_FAIL file exists.
    elif method == "account/read":
        kind = os.environ.get("FAKE_CODEX_ACCOUNT", "chatgpt")
        account = None if kind == "none" else {"type": kind, "email": "me@example.com", "planType": "pro"}
        send({"id": mid, "result": {"account": account, "requiresOpenaiAuth": True}})
    elif method == "account/rateLimits/read":
        main = {"limitId": "codex", "planType": "pro",
                "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1790000000},
                "secondary": {"usedPercent": 10.5, "resetsAt": 1790500000}}
        send({"id": mid, "result": {
            "rateLimits": {"limitId": "codex_spark", "primary": {"usedPercent": 99}},
            "rateLimitsByLimitId": {"codex": main, "codex_spark": {"limitId": "codex_spark", "primary": {"usedPercent": 99}}},
            "rateLimitResetCredits": {"availableCount": 2, "credits": [
                {"status": "available", "expiresAt": 1800000000},
                {"status": "available", "expiresAt": 1795000000},
                {"status": "redeemed", "expiresAt": 1700000000}]}}})
    elif method == "account/rateLimitResetCredit/consume":
        with open(os.environ["FAKE_CODEX_CONSUME_LOG"], "a") as log:
            log.write(params["idempotencyKey"] + "\n")
        flag = os.environ.get("FAKE_CODEX_CONSUME_FAIL", "")
        if flag and os.path.exists(flag):
            os.remove(flag)
            send({"id": mid, "error": {"code": -32000, "message": "upstream unavailable"}})
        else:
            send({"id": mid, "result": {"outcome": "reset"}})
    elif method == "turn/interrupt":
        send({"id": mid, "result": {}})
        send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": params["turnId"], "status": "interrupted"}}})
    else:
        send({"id": mid, "error": {"code": -32601, "message": method}})
