"""Sample real Service responses and fail if a response is unexpected."""

import argparse
from datetime import datetime, timezone
import json
import time
from urllib.request import ProxyHandler, Request, build_opener


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args()
    if args.count < 1 or args.interval < 0:
        parser.error("count must be positive and interval must be nonnegative")

    # Cluster Service traffic must not be sent through an inherited HTTP proxy.
    client = build_opener(ProxyHandler({}))
    failures = 0
    for index in range(args.count):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "sample": index + 1,
            "url": args.url,
            "expected_version": args.expected_version,
        }
        started = time.monotonic()
        try:
            request = Request(args.url, headers={"Connection": "close"})
            with client.open(request, timeout=3) as response:
                entry["status"] = response.status
                entry["body"] = response.read().decode("utf-8")
            payload = json.loads(entry["body"])
            entry["ok"] = (
                entry["status"] == 200
                and payload.get("version") == args.expected_version
                and bool(payload.get("pod"))
            )
        except Exception as exc:
            entry["ok"] = False
            entry["error"] = f"{type(exc).__name__}: {exc}"

        entry["elapsed_ms"] = round((time.monotonic() - started) * 1000, 3)
        failures += int(not entry["ok"])
        print(json.dumps(entry), flush=True)
        if index + 1 < args.count:
            time.sleep(args.interval)

    print(json.dumps({
        "result": "HTTP_CHECK_PASS" if failures == 0 else "HTTP_CHECK_FAIL",
        "samples": args.count,
        "failures": failures,
        "expected_version": args.expected_version,
    }), flush=True)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
