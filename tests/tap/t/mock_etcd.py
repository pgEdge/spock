#!/usr/bin/env python3
"""
A stand-in for the etcd v3 HTTP/JSON gateway, for the TAP suite.

Implements just enough of /v3/kv/{put,range,txn,deleterange} and
/v3/lease/{grant,keepalive,revoke} for Spock's etcd quorum provider, in
the request and reply shapes the real gateway uses (base64 keys and values,
int64 fields as strings, the keepalive reply wrapped in "result").  Leases
never expire on their own; a test revokes them.

Usage: mock_etcd.py <port>
"""
import base64
import itertools
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

KV = {}                     # key -> (value, lease id)
LEASES = {}                 # lease id -> ttl
IDS = itertools.count(1000)
REV = [1]

# Fault injection, set through POST /mock/mode {"mode": ..., "delay": secs}:
#   ok        normal service
#   http500   every etcd call fails with HTTP 500
#   garbage   every etcd call returns a body that is not JSON
#   slow      every etcd call waits "delay" seconds before answering
MODE = {"mode": "ok", "delay": 0}


def b64e(s):
    return base64.b64encode(s.encode()).decode()


def b64d(s):
    return base64.b64decode(s).decode()


def kv_entry(key):
    value, lease = KV[key]
    return {"key": b64e(key), "create_revision": "1", "mod_revision": "1",
            "version": "1", "value": b64e(value), "lease": str(lease)}


def do_range(req):
    key = b64d(req["key"])
    end = b64d(req["range_end"]) if req.get("range_end") else None
    if end is None:
        keys = [key] if key in KV else []
    else:
        keys = sorted(k for k in KV if key <= k < end)
    limit = int(req.get("limit") or 0)
    if limit:
        keys = keys[:limit]
    return {"header": {"revision": str(REV[0])},
            "kvs": [kv_entry(k) for k in keys], "count": str(len(keys))}


def do_put(req):
    KV[b64d(req["key"])] = (b64d(req["value"]), int(req.get("lease") or 0))
    REV[0] += 1
    return {"header": {"revision": str(REV[0])}}


def do_delete(req):
    key = b64d(req["key"])
    deleted = 1 if KV.pop(key, None) is not None else 0
    return {"header": {"revision": str(REV[0])}, "deleted": str(deleted)}


def compare(c):
    key = b64d(c["key"])
    exists = 1 if key in KV else 0
    if c.get("target") == "CREATE":
        expected = int(c.get("create_revision") or 0)
    else:
        expected = int(c.get("version") or 0)
    result = c.get("result")
    if result == "EQUAL":
        return exists == expected
    if result == "GREATER":
        return exists > expected
    if result == "LESS":
        return exists < expected
    return exists != expected


def do_txn(req):
    ok = all(compare(c) for c in req.get("compare", []))
    responses = []
    for op in req.get("success" if ok else "failure", []):
        rng = op.get("request_range") or op.get("requestRange")
        put = op.get("request_put") or op.get("requestPut")
        if rng is not None:
            responses.append({"response_range": do_range(rng)})
        elif put is not None:
            responses.append({"response_put": do_put(put)})
    return {"header": {"revision": str(REV[0])}, "succeeded": ok,
            "responses": responses}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(200, {"ok": True})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        p = self.path
        if p == "/mock/mode":
            MODE["mode"] = req.get("mode", "ok")
            MODE["delay"] = float(req.get("delay") or 0)
            self.reply(200, MODE)
            return
        if MODE["mode"] == "slow":
            time.sleep(MODE["delay"])
        elif MODE["mode"] == "http500":
            self.reply(500, {"error": "injected failure", "code": 14})
            return
        elif MODE["mode"] == "garbage":
            body = b"<html>not json</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if p == "/v3/lease/grant":
            i = next(IDS)
            LEASES[i] = int(req.get("TTL") or 0)
            resp = {"ID": str(i), "TTL": str(LEASES[i])}
        elif p == "/v3/lease/keepalive":
            i = int(req["ID"])
            resp = {"result": {"ID": str(i), "TTL": str(LEASES.get(i, 0))}}
        elif p == "/v3/lease/revoke":
            i = int(req["ID"])
            LEASES.pop(i, None)
            for k in [k for k, (v, l) in KV.items() if l == i]:
                del KV[k]
            resp = {"header": {}}
        elif p == "/v3/kv/put":
            resp = do_put(req)
        elif p == "/v3/kv/range":
            resp = do_range(req)
        elif p == "/v3/kv/txn":
            resp = do_txn(req)
        elif p == "/v3/kv/deleterange":
            resp = do_delete(req)
        else:
            self.reply(404, {"error": "unknown path"})
            return
        self.reply(200, resp)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
