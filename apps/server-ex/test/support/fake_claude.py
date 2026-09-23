# Fake `claude -p --input-format stream-json --output-format stream-json` for tests.
# Plays one turn per user message: thinking, a Bash tool call, and a streamed answer.
# A message containing "wait" stays open until an interrupt control request; "approve"
# asks permission for a command, "ask" asks a question (AskUserQuestion), and "where are we"
# says which message the session resumed at (--resume-session-at).
import json, os, sys

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

session = "fake-session-1"
turn = 0
resume_at = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--resume-session-at=")), None)
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("type") == "control_response":
        reply = msg["response"]["response"]
        allowed = reply["behavior"] == "allow"
        answers = reply.get("updatedInput", {}).get("answers")
        text = ("answered " + json.dumps(answers, sort_keys=True)) if answers is not None else ("allowed" if allowed else "denied")
        send({"type": "assistant", "session_id": session, "message": {"id": "m-perm", "role": "assistant", "content": [{"type": "text", "text": text}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if msg.get("type") == "control_request":
        sub = msg["request"]["subtype"]
        # Plan usage; FAKE_CLAUDE_USAGE=unsupported is an account without plan limits.
        if sub == "get_usage":
            usage = {"rate_limits_available": False, "rate_limits": None} if os.environ.get("FAKE_CLAUDE_USAGE") == "unsupported" else {
                "rate_limits_available": True,
                "rate_limits": {
                    "five_hour": {"utilization": 30, "resets_at": "2026-09-24T15:00:00.123456+00:00"},
                    "seven_day": {"utilization": 55.5, "resets_at": None},
                    "model_scoped": [{"display_name": "Fable 1", "utilization": 12, "resets_at": "2026-09-30T00:00:00Z"}]}}
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": usage}})
            continue
        # The account a signed-in Claude Code reports when it starts.
        reply = {"account": {"email": "me@example.com", "subscriptionType": "max", "tokenSource": "claude.ai"}} if sub == "initialize" else {}
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": reply}})
        if sub == "interrupt":
            send({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": session})
        continue
    if msg.get("type") != "user":
        continue
    # A steer cuts the running turn short and answers the new message in the same turn.
    if msg.get("priority") == "now":
        steer_text = msg["message"]["content"] if isinstance(msg["message"]["content"], str) else ""
        send({"type": "result", "subtype": "error_during_execution", "is_error": True, "terminal_reason": "aborted_streaming", "session_id": session})
        send({"type": "assistant", "session_id": session, "message": {"id": "m-steer", "role": "assistant", "content": [{"type": "text", "text": "steered: " + steer_text}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    turn += 1
    text = msg["message"]["content"] if isinstance(msg["message"]["content"], str) else ""
    send({"type": "system", "subtype": "init", "session_id": session, "model": "claude-haiku"})
    if "wait" in text:
        continue
    if "where are we" in text:
        send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}w", "role": "assistant", "content": [{"type": "text", "text": f"resumed at {resume_at} fork {'--fork-session' in sys.argv} history {'<conversation_history>' in text}"}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "approve" in text:
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "touch x"}}})
        continue
    if "plan" in text:
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": {"plan": "# Plan\n- do it"}}})
        continue
    if "todo" in text:
        send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}t", "role": "assistant", "content": [{"type": "tool_use", "id": f"todo-{turn}", "name": "TodoWrite", "input": {"todos": [
            {"content": "Read the code", "status": "completed", "activeForm": "Reading"}, {"content": "Fix it", "status": "in_progress", "activeForm": "Fixing"}]}}]}})
        send({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": session})
        continue
    if "ask" in text:
        send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [
            {"question": "Which color?", "header": "Color", "multiSelect": False,
             "options": [{"label": "Red", "description": "Warm"}, {"label": "Blue", "description": ""}]}]}}})
        continue
    ev = lambda e: send({"type": "stream_event", "session_id": session, "event": e})
    send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}a", "role": "assistant", "content": [{"type": "thinking", "thinking": "Let me look."}]}})
    send({"type": "assistant", "session_id": session, "message": {"id": f"m{turn}b", "role": "assistant", "content": [{"type": "tool_use", "id": f"tool-{turn}", "name": "Bash", "input": {"command": "ls"}}]}})
    send({"type": "user", "session_id": session, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": f"tool-{turn}", "content": "a.txt\n", "is_error": False}]}})
    ev({"type": "message_start", "message": {"id": f"m{turn}c"}})
    ev({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    for d in ["Hel", "lo from ", "claude"]:
        ev({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": d}})
    ev({"type": "content_block_stop", "index": 0})
    send({"type": "assistant", "session_id": session, "uuid": f"uuid-{turn}", "message": {"id": f"m{turn}c", "role": "assistant", "content": [{"type": "text", "text": "Hello from claude"}]}})
    send({"type": "result", "subtype": "success", "is_error": False, "result": "Hello from claude", "session_id": session})
