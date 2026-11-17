"""A stand-in for Linear's GraphQL API, for tests/e2e.sh.

    python3 tests/fake-linear.py PORT STATE.json

It answers rex-develop's queries from STATE.json, read again on every
request, so a test changes the world by rewriting the file:

    {"viewer": {"id": "...", "name": "..."},
     "issues": [{"id", "identifier", "title", "url", "branchName", "priority",
                 "state": {"name", "type"}, "assignee": {"id"},
                 "labels": ["agent"], "cycle": {"id", "number", "isActive"} or null,
                 "team": "ENG", "description": "...", "comments": [{"body", "user"}]}]}

The key must be "test-key". Standard library only.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
STATE = sys.argv[2]


def node(i):
    return {
        "id": i["id"],
        "identifier": i["identifier"],
        "title": i["title"],
        "url": i["url"],
        "branchName": i["branchName"],
        "priority": i.get("priority", 0),
        "updatedAt": "2026-11-17T10:00:00.000Z",
        "state": i["state"],
        "assignee": i.get("assignee"),
        "labels": {"nodes": [{"name": n} for n in i.get("labels", [])]},
        "cycle": i.get("cycle"),
        "team": {"key": i["team"]},
        "project": None,
        "comments": {"nodes": [{"id": str(k)} for k, _ in enumerate(i.get("comments", []))]},
    }


def detail(i):
    d = node(i)
    d.update(
        {
            "description": i.get("description", ""),
            "priorityLabel": "High",
            "team": {"key": i["team"], "name": i["team"]},
            "cycle": i.get("cycle"),
            "creator": {"name": "Ana"},
            "assignee": {"name": "Sam"},
            "comments": {
                "nodes": [
                    {"body": c["body"], "createdAt": "2026-11-17T09:00:00Z", "user": {"name": c.get("user", "Ana")}}
                    for c in i.get("comments", [])
                ]
            },
            "parent": None,
            "children": {"nodes": []},
            "relations": {"nodes": []},
            "attachments": {"nodes": []},
        }
    )
    return d


def eligible(i, me):
    labeled = any(n.lower() == "agent" for n in i.get("labels", []))
    cycle = bool(i.get("cycle") and i["cycle"].get("isActive"))
    return (i.get("assignee") or {}).get("id") == me and i["state"]["type"] == "unstarted" and (labeled or cycle)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        out = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.headers.get("Authorization") != "test-key":
            return self.reply({"errors": [{"message": "Authentication required"}]})
        with open(STATE) as f:
            st = json.load(f)
        q, v = req["query"], req.get("variables") or {}
        me = st["viewer"]["id"]
        if "RexDevelopScan" in q:
            data = {"viewer": st["viewer"], "matching": {"nodes": [node(i) for i in st["issues"] if eligible(i, me)]}}
            if "tracked:" in q:
                data["tracked"] = {"nodes": [node(i) for i in st["issues"] if i["id"] in v.get("ids", [])]}
        elif "children(first" in q:
            found = [i for i in st["issues"] if i["identifier"] == v.get("id")]
            data = {"issue": detail(found[0]) if found else None}
        elif "issue(id" in q:
            found = [i for i in st["issues"] if i["identifier"] == v.get("id")]
            data = {"viewer": st["viewer"], "issue": node(found[0]) if found else None}
        else:
            data = {"viewer": st["viewer"]}
        self.reply({"data": data})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
