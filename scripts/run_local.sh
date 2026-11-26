#!/usr/bin/env bash
# Open the local workspace, optionally preselecting a scene.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scene_id="${1:-}"
if [[ -n "$scene_id" && ! "$scene_id" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    echo "Usage: scripts/run_local.sh [scene_id]" >&2
    exit 2
fi

port="${WORLDSMITH_PORT:-8765}"
if [[ ! "$port" =~ ^[0-9]{2,5}$ ]]; then
    echo "WORLDSMITH_PORT must be a TCP port" >&2
    exit 2
fi
server_url="http://127.0.0.1:$port"
started_pid=""
if ! curl --silent --fail --max-time 2 "$server_url/openapi.json" >/dev/null; then
    "${repo_root}/server/.venv/bin/uvicorn" app.main:app \
        --app-dir "${repo_root}/server" --host 127.0.0.1 --port "$port" \
        >"${repo_root}/data/local-server.log" 2>&1 &
    started_pid="$!"
    trap 'kill "$started_pid" 2>/dev/null || true' EXIT
    for attempt in {1..50}; do
        if curl --silent --fail --max-time 1 "$server_url/openapi.json" >/dev/null; then
            break
        fi
        sleep 0.1
    done
fi

if ! curl --silent --fail --max-time 2 "$server_url/openapi.json" >/dev/null; then
    echo "Worldsmith server did not start; see data/local-server.log" >&2
    exit 1
fi
if ! curl --silent --fail --max-time 2 "$server_url/api/scenes" >/dev/null; then
    echo "An older Worldsmith server is still running on port $port. Close its Godot window or stop that server, then retry." >&2
    exit 1
fi

echo "Opening Worldsmith workspace"
if [[ -n "$scene_id" ]]; then
    "${repo_root}/scripts/godot.sh" --xr-mode off --path "${repo_root}/client" -- \
        --server-url="ws://127.0.0.1:$port" --scene-id="$scene_id"
else
    "${repo_root}/scripts/godot.sh" --xr-mode off --path "${repo_root}/client" -- \
        --server-url="ws://127.0.0.1:$port"
fi
