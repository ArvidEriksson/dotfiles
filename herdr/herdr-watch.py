#!/usr/bin/env python3
"""Watch several dispatched coders at once and report the first to need attention.

    herdr-watch [AGENT ...] [--all] [--until STATUS]... [--timeout-ms MS]
                [--notify] [--once] [--quiet]

herdr-collect blocks on one agent at a time, so a coder that goes blocked behind
a slower sibling can sit unnoticed for the whole wait. This subscribes to
pane.agent_status_changed for every watched pane over a single socket and prints
one NDJSON line per transition, as it happens.

  --all           watch every live Claude agent whose cwd is a Herdr worktree
  --until STATUS  statuses that count as "done waiting" (repeatable;
                  default: blocked, idle, done)
  --once          exit after the first matching transition instead of waiting
                  for every agent to settle
  --notify        raise a Herdr toast per match (request sound for blocked)
  --timeout-ms    give up after MS (default 1800000; 0 waits forever)

Exit status: 0 every watched agent settled, 2 timed out with some still working,
1 setup failure. Emits a final {"event":"summary"} line either way.

The subscription opens before the initial state sweep, so an agent that was
already blocked is reported and a transition mid-sweep is not lost.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
HERDR_BIN = os.environ.get("HERDR_BIN", str(HOME / ".local/bin/herdr"))
HERDR_WORKTREES = HOME / ".herdr" / "worktrees"
TERMINAL_DEFAULT = ["blocked", "idle", "done"]


def socket_path():
    if p := os.environ.get("HERDR_SOCKET_PATH"):
        return p
    if s := os.environ.get("HERDR_SESSION"):
        return str(HOME / ".config/herdr/sessions" / s / "herdr.sock")
    return str(HOME / ".config/herdr/herdr.sock")


def herdr_json(*args):
    try:
        out = subprocess.run(
            [HERDR_BIN, *args], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def list_agents():
    data = herdr_json("agent", "list")
    if not data:
        return []
    return data.get("result", {}).get("agents", []) or []


def notify(title, body, blocked):
    subprocess.run(
        [
            HERDR_BIN, "notification", "show", title,
            "--body", body[:240],
            "--sound", "request" if blocked else "done",
        ],
        capture_output=True, timeout=10, check=False,
    )


def emit(obj):
    print(json.dumps(obj), flush=True)


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("agents", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--until", action="append", dest="until")
    ap.add_argument("--timeout-ms", type=int, default=1800000)
    ap.add_argument("--notify", action="store_true")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        return 0

    terminal = set(args.until or TERMINAL_DEFAULT)

    live = list_agents()
    if live is None:
        print("could not reach herdr; is the server running?", file=sys.stderr)
        return 1

    if args.all:
        wanted = [
            a for a in live
            if a.get("agent") == "claude"
            and a.get("name")
            and str(a.get("cwd") or "").startswith(str(HERDR_WORKTREES))
        ]
    else:
        if not args.agents:
            print("name at least one agent, or pass --all", file=sys.stderr)
            return 1
        by_name = {a.get("name"): a for a in live if a.get("name")}
        wanted, missing = [], []
        for n in args.agents:
            if n in by_name:
                wanted.append(by_name[n])
            else:
                missing.append(n)
        if missing:
            print("no such live agent: " + ", ".join(missing), file=sys.stderr)
            return 1

    if not wanted:
        print("no matching live agents", file=sys.stderr)
        return 1

    panes = {}
    for a in wanted:
        if pid := a.get("pane_id"):
            panes[pid] = a.get("name")

    if not panes:
        print("watched agents have no resolvable panes", file=sys.stderr)
        return 1

    sp = socket_path()
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(sp)
    except OSError as e:
        print(f"cannot connect to {sp}: {e}", file=sys.stderr)
        return 1

    f = sock.makefile("rwb")
    req = {
        "id": "watch",
        "method": "events.subscribe",
        "params": {
            "subscriptions": [
                {"type": "pane.agent_status_changed", "pane_id": p} for p in panes
            ]
        },
    }
    f.write((json.dumps(req) + "\n").encode())
    f.flush()

    ack = f.readline().decode().strip()
    try:
        parsed = json.loads(ack)
    except json.JSONDecodeError:
        print(f"unexpected subscribe reply: {ack[:200]}", file=sys.stderr)
        return 1
    if "error" in parsed:
        print(f"subscribe rejected: {json.dumps(parsed['error'])}", file=sys.stderr)
        return 1

    if not args.quiet:
        emit({
            "event": "watching",
            "agents": sorted(v for v in panes.values() if v),
            "until": sorted(terminal),
        })

    settled = {}

    def record(name, status, source):
        if name in settled:
            return
        settled[name] = status
        emit({
            "event": "settled", "agent": name, "agent_status": status,
            "source": source, "at": round(time.time(), 3),
        })
        if args.notify:
            notify(
                f"{name} is {status}",
                "Needs a human." if status == "blocked" else "Ready to collect.",
                status == "blocked",
            )

    # Sweep current state only after the subscription is live, so nothing that
    # transitions during the sweep is missed.
    for a in list_agents():
        n = a.get("name")
        if n in panes.values() and (st := a.get("agent_status")) in terminal:
            record(n, st, "initial")

    deadline = None if args.timeout_ms <= 0 else time.time() + args.timeout_ms / 1000.0
    rc = 0

    if not (settled and args.once) and len(settled) < len(panes):
        while True:
            if deadline is not None:
                remaining = deadline - time.time()
                if remaining <= 0:
                    rc = 2
                    break
                sock.settimeout(min(remaining, 30))
            else:
                sock.settimeout(30)

            try:
                line = f.readline()
            except socket.timeout:
                continue
            except OSError:
                break
            if not line:
                break

            try:
                ev = json.loads(line.decode().strip())
            except json.JSONDecodeError:
                continue

            # Envelope is {"event": "<name>", "data": {...}}; the subscription is
            # named pane.agent_status_changed but the event arrives underscored.
            kind = ev.get("event")
            body = ev.get("data")
            if not isinstance(body, dict):
                continue
            if kind and "agent_status_changed" not in str(kind):
                continue
            pid = body.get("pane_id")
            status = body.get("agent_status")
            if pid not in panes or not status:
                continue

            name = panes[pid]
            if not args.quiet:
                emit({
                    "event": "transition", "agent": name, "pane_id": pid,
                    "agent_status": status, "at": round(time.time(), 3),
                })
            if status in terminal:
                record(name, status, "event")
                if args.once:
                    break
            elif name in settled:
                # It went back to work; stop treating it as finished.
                del settled[name]

            if len(settled) >= len(panes):
                break

    still = sorted(n for n in panes.values() if n and n not in settled)
    if still and rc == 0:
        rc = 2
    emit({
        "event": "summary",
        "settled": {k: v for k, v in sorted(settled.items()) if k},
        "still_working": still,
        "timed_out": rc == 2,
    })

    try:
        sock.close()
    except OSError:
        pass
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
