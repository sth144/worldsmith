"""Work the queue of asset requests that people make inside scenes.

An agent, or a person, uses this to see what has been asked for, claim a
request while building it, place the finished asset, or give a request up
with a reason. It talks to a running scene server.

    python3 scripts/request_queue.py list
    python3 scripts/request_queue.py claim <scene-id> <request-id> --note "Building in Blender"
    python3 scripts/request_queue.py fulfil <scene-id> <request-id> <library-asset-id> --name "Display name"
    python3 scripts/request_queue.py fail <scene-id> <request-id> --note "Why it could not be made"
    python3 scripts/request_queue.py release <scene-id> <request-id>
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

DEFAULT_SERVER = "http://127.0.0.1:8765"


def call(server: str, path: str, payload: dict | None = None) -> object:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(server.rstrip("/") + path, data=data,
                                     headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"Server refused ({error.code}): {detail}") from error
    except urllib.error.URLError as error:
        raise SystemExit(f"Could not reach the scene server at {server}: {error.reason}") from error


def request_path(arguments: argparse.Namespace, action: str) -> str:
    return f"/api/scenes/{arguments.scene_id}/asset-requests/{arguments.request_id}/{action}"


def run(arguments: argparse.Namespace) -> object:
    if arguments.command == "list":
        queue = call(arguments.server, "/api/requests")
        return queue if arguments.all else [job for job in queue if job["status"] == "needs_asset"]
    if arguments.command == "fulfil":
        payload = {"asset_id": arguments.asset_id}
        if arguments.name:
            payload["name"] = arguments.name
        return call(arguments.server, request_path(arguments, "fulfill"), payload)["job"]
    status = {"claim": "in_progress", "fail": "failed", "release": "needs_asset"}[arguments.command]
    return call(arguments.server, request_path(arguments, "status"), {"status": status, "note": arguments.note})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", default=DEFAULT_SERVER)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="Requests waiting to be built")
    listing.add_argument("--all", action="store_true", help="Also show requests being built or failed")
    for name, note_required in (("claim", False), ("fail", True), ("release", False)):
        command = commands.add_parser(name)
        command.add_argument("scene_id")
        command.add_argument("request_id")
        command.add_argument("--note", required=note_required)
    fulfil = commands.add_parser("fulfil", help="Place a promoted, reviewed library mesh for a request")
    fulfil.add_argument("scene_id")
    fulfil.add_argument("request_id")
    fulfil.add_argument("asset_id")
    fulfil.add_argument("--name")
    json.dump(run(parser.parse_args()), sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
