#!/usr/bin/env bash
set -euo pipefail

PORTS=(8080 9696 7878 8989 8096)

# Load config
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run generate-env.sh first."
  exit 1
fi
source .env

# Directories

echo "==> Creating directory structure..."
dirs=(
  "$CONFIG_PATH/gluetun"
  "$CONFIG_PATH/qbittorrent"
  "$CONFIG_PATH/prowlarr"
  "$CONFIG_PATH/radarr"
  "$CONFIG_PATH/sonarr"
  "$CONFIG_PATH/jellyfin"
  "$DATA_PATH/downloads/complete/movies"
  "$DATA_PATH/downloads/complete/tv"
  "$DATA_PATH/downloads/incomplete"
  "$DATA_PATH/media/movies"
  "$DATA_PATH/media/tv"
)
for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

echo "==> Setting ownership to ${PUID}:${PGID}..."
chown -R "${PUID}:${PGID}" "$CONFIG_PATH" "$DATA_PATH"

# /dev/net/tun

echo "==> Checking /dev/net/tun..."
if [[ ! -c /dev/net/tun ]]; then
  echo "WARNING: /dev/net/tun not found. Run: sudo modprobe tun"
fi

# Firewall

echo "==> Configuring firewall..."

# Scope the LAN subnet to the interface used by the default route.
# This excludes Docker bridge networks (172.17.x.x, etc.) which also appear
# as 'proto kernel' routes and would otherwise be picked up incorrectly.
_wan_iface=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
_lan_subnet=""
if [[ -n "$_wan_iface" ]]; then
  _lan_subnet=$(ip route show dev "$_wan_iface" 2>/dev/null | awk '/proto kernel/{print $1; exit}')
fi

if [[ -z "$_lan_subnet" ]]; then
  echo "WARNING: Could not detect LAN subnet. Add firewall rules manually."
  echo "         Ports to restrict to LAN only: ${PORTS[*]}"
else
  echo "  Detected LAN subnet: $_lan_subnet (via $_wan_iface)"

  # ufw
  if command -v ufw &>/dev/null; then
    for port in "${PORTS[@]}"; do
      # Delete old gatonet rules for this port to avoid duplicates on re-run.
      # ufw status numbered format: "[ N] PORT/tcp ... # comment"
      # awk splits on [ and ] to isolate the rule number, then converts to int
      # to strip the leading space that ufw pads short numbers with.
      ufw status numbered 2>/dev/null \
        | awk -F'[][]' "/$port\/tcp/ && /gatonet/{print \$2+0}" \
        | sort -rn \
        | xargs -r -I{} ufw --force delete {} 2>/dev/null

      ufw allow from "$_lan_subnet" to any port "$port" proto tcp comment "gatonet" >/dev/null
      ufw deny to any port "$port" proto tcp comment "gatonet" >/dev/null
    done

    if ! ufw status | grep -q "Status: active"; then
      echo "  Enabling ufw..."
      ufw --force enable
    fi

    echo "  ufw rules applied."
  else
    echo "  INFO: ufw not installed. Skipping ufw configuration."
  fi

  # DOCKER-USER iptables chain
  # ufw rules are bypassed by Docker's own iptables rules for published ports.
  # DOCKER-USER is evaluated before Docker's ACCEPT rules and is the correct
  # place to restrict access to container ports.
  if iptables -L DOCKER-USER &>/dev/null 2>&1; then
    echo "  Adding DOCKER-USER iptables rules..."
    for port in "${PORTS[@]}"; do
      # Remove any existing rules for this port (idempotent re-runs).
      iptables -D DOCKER-USER -p tcp --dport "$port" -s "$_lan_subnet" -j RETURN 2>/dev/null || true
      iptables -D DOCKER-USER -p tcp --dport "$port" -j DROP 2>/dev/null || true
      # Insert in reverse order: RETURN is evaluated first, DROP second.
      iptables -I DOCKER-USER -p tcp --dport "$port" -j DROP
      iptables -I DOCKER-USER -p tcp --dport "$port" -s "$_lan_subnet" -j RETURN
    done

    # Persist across reboots if tooling is available
    if command -v netfilter-persistent &>/dev/null; then
      netfilter-persistent save >/dev/null
    elif [[ -d /etc/iptables ]]; then
      iptables-save > /etc/iptables/rules.v4
    else
      echo "  NOTE: Install iptables-persistent to keep these rules across reboots."
      echo "        sudo apt install iptables-persistent"
    fi

    echo "  DOCKER-USER rules applied. Ports ${PORTS[*]} are LAN-only."
  else
    echo "  NOTE: DOCKER-USER chain not found - start Docker first, then re-run this script."
  fi
fi

# Done

_current_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<your-server-ip>")

echo ""
echo "==> Done. Start the stack with:"
echo "    docker compose up -d"
echo ""
echo "Web UIs (accessible from your home network):"
echo "  Jellyfin    : http://${_current_ip}:8096"
echo "  Radarr      : http://${_current_ip}:7878"
echo "  Sonarr      : http://${_current_ip}:8989"
echo "  Prowlarr    : http://${_current_ip}:9696"
echo "  qBittorrent : http://${_current_ip}:8080"
echo ""
echo "IP changed? Find the new address with: hostname -I"
echo "Subnet changed? Re-run this script to update firewall rules."
