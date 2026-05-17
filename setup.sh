#!/usr/bin/env bash
set -euo pipefail

# Load config
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill it in first."
  exit 1
fi
source .env

echo "==> Creating directory structure..."
dirs=(
  "$CONFIG_PATH/gluetun"
  "$CONFIG_PATH/qbittorrent"
  "$CONFIG_PATH/prowlarr"
  "$CONFIG_PATH/radarr"
  "$CONFIG_PATH/sonarr"
  "$CONFIG_PATH/jellyfin"
  "$DOWNLOADS_PATH/complete/movies"
  "$DOWNLOADS_PATH/complete/tv"
  "$DOWNLOADS_PATH/incomplete"
  "$MEDIA_PATH/movies"
  "$MEDIA_PATH/tv"
)
for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

echo "==> Setting ownership to ${PUID}:${PGID}..."
chown -R "${PUID}:${PGID}" "$CONFIG_PATH" "$DOWNLOADS_PATH" "$MEDIA_PATH"

echo "==> Checking that /dev/net/tun exists..."
if [[ ! -c /dev/net/tun ]]; then
  echo "WARNING: /dev/net/tun not found. Run: sudo modprobe tun"
fi

echo "==> Done. Start the stack with:"
echo "    docker compose up -d"
echo ""
echo "Web UIs (accessible from your home network):"
echo "  qBittorrent : http://${LAN_IP}:8080"
echo "  Prowlarr    : http://${LAN_IP}:9696"
echo "  Radarr      : http://${LAN_IP}:7878"
echo "  Sonarr      : http://${LAN_IP}:8989"
echo "  Jellyfin    : http://${LAN_IP}:8096"
