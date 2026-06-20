#!/bin/bash
export MSYS_NO_PATHCONV=1   # stop Git Bash from rewriting /workspace
# cc.sh — shortcut to start Claude Code inside the running container.
#
# Usage:
#   ./cc.sh             → opens Claude Code interactively in /workspace
#   ./cc.sh --help      → passes --help to claude
#   ./cc.sh setup-token → generates a long-lived auth token (one-time)
#
# Place this in your repo root (or ~/bin/cc) and chmod +x it.

CONTAINER="claude-vpn"

# Is the container running?
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Container '${CONTAINER}' is not running."
    echo "Start it with:  docker compose up -d"
    exit 1
fi

# Is the VPN tunnel up? The image has a HEALTHCHECK that turns the container
# 'unhealthy' if tun0 disappears. Without the tunnel, Claude Code has no
# internet (the kill switch blocks everything else), so warn but don't block.
HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null)
if [ "$HEALTH" = "unhealthy" ]; then
    echo "Warning: container is 'unhealthy' — the VPN tunnel (tun0) looks down."
    echo "Claude Code may fail to reach the API. Check: docker logs $CONTAINER"
elif [ "$HEALTH" = "starting" ]; then
    echo "Note: VPN is still connecting. If Claude can't reach the API, wait a moment and retry."
fi

exec docker exec -it -u dev -w /workspace "$CONTAINER" claude "$@"
