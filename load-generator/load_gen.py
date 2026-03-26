#!/usr/bin/env python3
"""
load_gen.py — Fake traffic generator for the kvstore service.

Simulates a realistic mix of SET / GET / DELETE requests to drive CPU load
on the kvstore pods so the HPA can observe and scale the deployment.

Usage (local):
    python load_gen.py --url http://localhost:5000 --rps 50 --duration 120

Usage (env-based, for Kubernetes Job):
    TARGET_URL=http://kvstore:5000 RPS=50 DURATION=120 python load_gen.py
"""

import argparse
import os
import random
import string
import sys
import time
import urllib.error
import urllib.request
import json
from concurrent.futures import ThreadPoolExecutor, as_completed


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _rand_key(length: int = 8) -> str:
    return "".join(random.choices(string.ascii_lowercase, k=length))


def _rand_value(length: int = 16) -> str:
    return "".join(random.choices(string.ascii_letters + string.digits, k=length))


def _http(method: str, url: str, body: dict | None = None) -> tuple[int, str]:
    data = json.dumps(body).encode() if body else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, str(e.reason)
    except Exception as e:
        return 0, str(e)


def do_request(base_url: str, known_keys: list[str]) -> str:
    """Pick a random operation and execute it. Returns a short log string."""
    roll = random.random()

    if roll < 0.50 or not known_keys:
        # 50% — SET a new key
        key = _rand_key()
        val = _rand_value()
        status, _ = _http("POST", f"{base_url}/set", {"key": key, "value": val})
        if status in (200, 201) and key not in known_keys:
            known_keys.append(key)
        return f"SET {key}={val[:8]}…  [{status}]"

    elif roll < 0.85:
        # 35% — GET a random existing key
        key = random.choice(known_keys)
        status, _ = _http("GET", f"{base_url}/get/{key}")
        return f"GET {key}  [{status}]"

    else:
        # 15% — DELETE a random existing key
        key = random.choice(known_keys)
        status, _ = _http("DELETE", f"{base_url}/delete/{key}")
        if status == 200 and key in known_keys:
            known_keys.remove(key)
        return f"DEL {key}  [{status}]"


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run(base_url: str, rps: int, duration: int) -> None:
    print(f"[load-gen] Target: {base_url}  RPS: {rps}  Duration: {duration}s")
    print(f"[load-gen] Waiting for service to be ready...")

    # Wait for service to be healthy (up to 60s)
    for attempt in range(60):
        status, _ = _http("GET", f"{base_url}/health")
        if status == 200:
            print(f"[load-gen] Service is ready after {attempt}s")
            break
        time.sleep(1)
    else:
        print("[load-gen] ERROR: Service did not become healthy in 60s. Exiting.")
        sys.exit(1)

    known_keys: list[str] = []
    interval = 1.0 / rps
    deadline = time.monotonic() + duration
    total_requests = 0
    errors = 0

    print(f"[load-gen] Starting load...")
    with ThreadPoolExecutor(max_workers=min(rps, 50)) as pool:
        futures = []
        while time.monotonic() < deadline:
            start = time.monotonic()

            # Submit one batch per second to achieve target RPS
            batch = [pool.submit(do_request, base_url, known_keys) for _ in range(rps)]
            futures.extend(batch)

            # Drain completed futures to avoid memory growth
            still_pending = []
            for f in futures:
                if f.done():
                    result = f.result()
                    total_requests += 1
                    if "[0]" in result:
                        errors += 1
                else:
                    still_pending.append(f)
            futures = still_pending

            elapsed = time.monotonic() - start
            remaining = 1.0 - elapsed
            if remaining > 0:
                time.sleep(remaining)

            elapsed_total = duration - (deadline - time.monotonic())
            if int(elapsed_total) % 10 == 0:
                print(
                    f"[load-gen] {int(elapsed_total)}/{duration}s — "
                    f"{total_requests} reqs, {errors} errors, "
                    f"{len(known_keys)} keys in store"
                )

    print(f"[load-gen] Done. Total requests: {total_requests}, Errors: {errors}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="kvstore load generator")
    parser.add_argument(
        "--url",
        default=os.environ.get("TARGET_URL", "http://localhost:5000"),
        help="Base URL of the kvstore service",
    )
    parser.add_argument(
        "--rps",
        type=int,
        default=int(os.environ.get("RPS", "30")),
        help="Requests per second",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=int(os.environ.get("DURATION", "120")),
        help="Duration of the load test in seconds",
    )
    args = parser.parse_args()
    run(args.url, args.rps, args.duration)


if __name__ == "__main__":
    main()
