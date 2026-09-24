#!/usr/bin/env python3
# Fake Google Antigravity ACP agent (agy_acp_server) for tests.
#
# Signed in when GEMINI_HOME/antigravity-acp/acp_token.json exists (or an API key
# method has its key). `authenticate` for a Google method opens the sign-in page
# through Python's webbrowser (so BROWSER is honoured) and, with
# FAKE_AGY_STDOUT_URL=1, also prints it on stdout as agy 1.1.1 does; a GET to the
# loopback redirect with the state and a code signs in. Every request is appended
# to FAKE_AGY_LOG as a JSON line. Prompts: "question", "approve", "files", "wait",
# anything else runs one command.
import json, os, sys, threading, uuid, webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

HOME = os.environ.get("GEMINI_HOME", ".")
TOKEN = os.path.join(HOME, "antigravity-acp", "acp_token.json")
LOG = os.environ.get("FAKE_AGY_LOG")
VERSION = os.environ.get("FAKE_AGY_VERSION", "agy_acp_server_1.1.1")
lock = threading.Lock()


def send(msg):
    msg["jsonrpc"] = "2.0"
    with lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


def log(entry):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")


def update(sid, u):
    send({"method": "session/update", "params": {"sessionId": sid, "update": u}})


method_id = None


def signed_in():
    if method_id == "gemini-api-key":
        return bool(os.environ.get("GEMINI_API_KEY"))
    return os.path.exists(TOKEN)


def start_sign_in(rid):
    state = "state-123"

    class Callback(BaseHTTPRequestHandler):
        def do_GET(self):
            query = parse_qs(urlparse(self.path).query)
            ok = query.get("state") == [state] and "code" in query
            self.send_response(200 if ok else 400)
            self.end_headers()
            self.wfile.write(b"done")
            if ok:
                os.makedirs(os.path.dirname(TOKEN), exist_ok=True)
                open(TOKEN, "w").write("{}")
                send({"id": rid, "result": {}})
                threading.Thread(target=server.shutdown).start()

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Callback)
    port = server.server_address[1]
    url = ("https://accounts.google.com/o/oauth2/v2/auth?client_id=x&response_type=code"
           "&redirect_uri=http%%3A%%2F%%2F127.0.0.1%%3A%d%%2F&state=%s" % (port, state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if os.environ.get("FAKE_AGY_STDOUT_URL") == "1":
        with lock:
            sys.stdout.write("Open the following link to authenticate the ACP server: " + url + "\n")
            sys.stdout.flush()
    webbrowser.open(url)


models = {"id": "model", "type": "select", "category": "model", "currentValue": "gemini-2.5-pro",
          "options": [{"value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"},
                      {"value": "gemini-3.8-flash-high", "name": "Gemini 3.8 Flash (High)"},
                      {"value": "gemini-3.8-flash-low", "name": "Gemini 3.8 Flash (Low)"}]}
mode = "default"
pending = {}  # our request id -> (prompt id, session id, kind)
waiting = None
next_id = [0]


def ask(method, params, pid, sid, kind):
    next_id[0] += 1
    rid = "agy-%d" % next_id[0]
    pending[rid] = (pid, sid, kind)
    send({"id": rid, "method": method, "params": params})


def session_result(sid=None):
    result = {"configOptions": [dict(models)],
              "modes": {"currentModeId": mode, "availableModes": [
                  {"id": m, "name": m} for m in ("default", "auto_edit", "yolo")]}}
    if sid:
        result["sessionId"] = sid
    return result


def reply(pid, sid, text):
    update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
    send({"id": pid, "result": {"stopReason": "end_turn"}})


for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    if method is None:
        pid, sid, kind = pending.pop(mid)
        log({"response": kind, "message": msg})
        if kind == "question":
            outcome = msg["result"]["outcome"]
            reply(pid, sid, "You chose " + outcome.get("optionId", "nothing"))
        elif kind == "approve":
            outcome = msg["result"]["outcome"]
            reply(pid, sid, "allowed" if outcome.get("optionId") == "once" else "denied")
        elif kind == "write":
            cwd = pending_cwd
            ask("fs/read_text_file", {"sessionId": sid, "path": os.path.join(cwd, "out.txt"), "line": 2, "limit": 1}, pid, sid, "read")
        elif kind == "read":
            content = msg.get("result", {}).get("content", "")
            ask("fs/write_text_file", {"sessionId": sid, "path": "/etc/t3-outside.txt", "content": "x"}, pid, sid, "outside")
            read_back = content
        elif kind == "outside":
            refused = "error" in msg
            reply(pid, sid, "read %s; outside %s" % (read_back, "refused" if refused else "written"))
        continue
    log({"method": method, "params": params})
    if method == "initialize":
        send({"id": mid, "result": {
            "protocolVersion": 2,
            "agentCapabilities": {"loadSession": True,
                                  "promptCapabilities": {"image": True, "audio": True, "embeddedContext": True},
                                  "sessionCapabilities": {"list": {}, "resume": {}},
                                  "auth": {"logout": {}}},
            "authMethods": [{"id": "oauth-personal", "name": "Log in with Google"},
                            {"id": "gemini-api-key", "name": "Gemini API key"}],
            "agentInfo": {"name": "antigravity-acp", "title": "Google Antigravity", "version": VERSION}}})
    elif method == "authenticate":
        method_id = params.get("methodId")
        if signed_in():
            send({"id": mid, "result": {}})
        elif method_id == "oauth-personal":
            start_sign_in(mid)
        else:
            send({"id": mid, "error": {"code": -32602, "message": "Invalid credentials"}})
    elif method == "logout":
        if os.path.exists(TOKEN):
            os.remove(TOKEN)
        send({"id": mid, "result": {}})
    elif method in ("session/new", "session/resume", "session/load"):
        if not signed_in():
            send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
            continue
        sid = params.get("sessionId") or str(uuid.uuid4())
        send({"id": mid, "result": session_result(sid if method == "session/new" else None)})
        update(sid, {"sessionUpdate": "available_commands_update",
                     "availableCommands": [{"name": "compact", "description": "Compact the chat"}]})
    elif method == "session/set_config_option":
        if params.get("configId") == "model":
            models["currentValue"] = params["value"]
        elif params.get("configId") == "mode":
            mode = params["value"]
        send({"id": mid, "result": {"configOptions": [dict(models)]}})
    elif method == "session/cancel":
        if waiting:
            send({"id": waiting, "result": {"stopReason": "cancelled"}})
            waiting = None
    elif method == "session/prompt":
        sid = params["sessionId"]
        text = " ".join(b.get("text", "") for b in params["prompt"] if b.get("type") == "text")
        if "Return only the requested JSON object" in text and "sneaky" not in text:
            reply(mid, sid, '```json\n{"title": "Fix the login", "branch": "fix-login"}\n```')
        elif "question" in text:
            ask("session/request_permission", {"sessionId": sid,
                "toolCall": {"toolCallId": "interaction_1", "title": "Pick a colour"},
                "options": [{"optionId": "red", "name": "Red", "kind": "allow_once"},
                            {"optionId": "blue", "name": "Blue", "kind": "allow_once"}]}, mid, sid, "question")
        elif "approve" in text:
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "call-2", "kind": "execute",
                         "title": "Run rm", "status": "pending", "rawInput": {"CommandLine": "rm -rf build"}})
            ask("session/request_permission", {"sessionId": sid,
                "toolCall": {"toolCallId": "call-2", "kind": "execute", "title": "Run rm",
                             "rawInput": {"CommandLine": "rm -rf build"}},
                "options": [{"optionId": "once", "name": "Allow", "kind": "allow_once"},
                            {"optionId": "always", "name": "Always", "kind": "allow_always",
                             "_meta": {"agy.security.warning": {"message": "Could be prompt injection"}}},
                            {"optionId": "no", "name": "Deny", "kind": "reject_once"}]}, mid, sid, "approve")
        elif "files" in text:
            pending_cwd = os.getcwd()
            ask("fs/write_text_file", {"sessionId": sid, "path": os.path.join(pending_cwd, "out.txt"),
                                        "content": "one\ntwo\nthree"}, mid, sid, "write")
        elif "wait" in text:
            waiting = mid
        else:
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "Running command",
                         "status": "in_progress", "rawInput": {"CommandLine": "ls -la", "Cwd": "/w"}})
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
                         "rawOutput": {"combinedOutput": "a.txt\n", "exitCode": 0}})
            reply(mid, sid, "Done")
    else:
        if mid is not None:
            send({"id": mid, "error": {"code": -32601, "message": method}})
