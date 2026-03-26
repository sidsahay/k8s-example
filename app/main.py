"""
kvstore — a simple in-memory key-value store served over HTTP.
Intentionally does a small CPU spin on each write so that HPA
CPU metrics become visible under load.
"""

import hashlib
import os
import threading
import time

from flask import Flask, jsonify, request

app = Flask(__name__)

# Shared in-memory store + a lock for thread safety
_store: dict[str, str] = {}
_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _cpu_burn(iterations: int = 5_000) -> None:
    """Simulate CPU work so HPA has something to react to."""
    h = hashlib.sha256()
    for i in range(iterations):
        h.update(str(i).encode())


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "keys": len(_store)}), 200


@app.route("/set", methods=["POST"])
def set_key():
    body = request.get_json(silent=True)
    if not body or "key" not in body or "value" not in body:
        return jsonify({"error": "Body must contain 'key' and 'value'"}), 400

    key = str(body["key"])
    value = str(body["value"])

    _cpu_burn()  # artificial CPU pressure

    with _lock:
        _store[key] = value

    return jsonify({"key": key, "value": value, "action": "set"}), 201


@app.route("/get/<key>", methods=["GET"])
def get_key(key: str):
    _cpu_burn(iterations=2_000)

    with _lock:
        if key not in _store:
            return jsonify({"error": f"Key '{key}' not found"}), 404
        value = _store[key]

    return jsonify({"key": key, "value": value}), 200


@app.route("/delete/<key>", methods=["DELETE"])
def delete_key(key: str):
    with _lock:
        if key not in _store:
            return jsonify({"error": f"Key '{key}' not found"}), 404
        del _store[key]

    return jsonify({"key": key, "action": "deleted"}), 200


@app.route("/keys", methods=["GET"])
def list_keys():
    with _lock:
        keys = list(_store.keys())
    return jsonify({"keys": keys, "count": len(keys)}), 200


# ---------------------------------------------------------------------------
# Entry point (dev only — production uses gunicorn)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    debug = os.environ.get("DEBUG", "false").lower() == "true"
    app.run(host="0.0.0.0", port=port, debug=debug)
