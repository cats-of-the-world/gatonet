#!/usr/bin/env bash
set -euo pipefail

# Wires up all services via their APIs. Safe to re-run - skips anything
# already configured.

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run from the gatonet directory."
  exit 1
fi
source .env

# Helpers

section() { echo ""; echo "$*:"; }

wait_for() {
  local url="$1" name="$2"
  printf "  Waiting for %s" "$name"
  local i=0
  until curl -s --max-time 2 "$url" -o /dev/null 2>/dev/null; do
    sleep 2; (( i += 2 ))
    if (( i > 120 )); then
      echo " TIMEOUT"
      echo "  ERROR: $name did not become ready. Check: docker compose logs $name"
      exit 1
    fi
    printf "."
  done
  echo " ready"
}

get_api_key() {
  grep -oP '(?<=<ApiKey>)[^<]+' "$1" 2>/dev/null || true
}

# POST JSON to an *arr API endpoint
arr_post() {
  local key="$1" url="$2" body="$3"
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $key" \
    -d "$body" \
    "$url"
}

# Returns 0 if a given string exists in an API response (used to skip duplicates)
arr_has() {
  local key="$1" url="$2" needle="$3"
  curl -sf -H "X-Api-Key: $key" "$url" 2>/dev/null | grep -q "$needle"
}

# Escape a string for embedding in a JSON value
json_escape() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

# Wait for all services

section "Waiting for services"
wait_for "http://127.0.0.1:9696/api/v1/health" "Prowlarr"
wait_for "http://127.0.0.1:7878/api/v3/health" "Radarr"
wait_for "http://127.0.0.1:8989/api/v3/health" "Sonarr"
wait_for "http://127.0.0.1:8686/api/v1/health" "Lidarr"
wait_for "http://127.0.0.1:8080"               "qBittorrent"

# Read API keys from config files

section "Reading API keys"

PROWLARR_KEY=$(get_api_key "$CONFIG_PATH/prowlarr/config.xml")
RADARR_KEY=$(get_api_key "$CONFIG_PATH/radarr/config.xml")
SONARR_KEY=$(get_api_key "$CONFIG_PATH/sonarr/config.xml")
LIDARR_KEY=$(get_api_key "$CONFIG_PATH/lidarr/config.xml")

[[ -z "$PROWLARR_KEY" ]] && { echo "  ERROR: Prowlarr key not found in $CONFIG_PATH/prowlarr/config.xml"; exit 1; }
[[ -z "$RADARR_KEY" ]]   && { echo "  ERROR: Radarr key not found"; exit 1; }
[[ -z "$SONARR_KEY" ]]   && { echo "  ERROR: Sonarr key not found"; exit 1; }
[[ -z "$LIDARR_KEY" ]]   && { echo "  ERROR: Lidarr key not found"; exit 1; }

echo "  Prowlarr : ${PROWLARR_KEY:0:8}..."
echo "  Radarr   : ${RADARR_KEY:0:8}..."
echo "  Sonarr   : ${SONARR_KEY:0:8}..."
echo "  Lidarr   : ${LIDARR_KEY:0:8}..."

# qBittorrent

section "qBittorrent"

echo "  Fresh installs print a one-time password to the container logs:"
echo "    docker logs qbittorrent 2>&1 | grep -i password"
read -rp  "  Username [admin]: " QB_USER; QB_USER="${QB_USER:-admin}"
read -rsp "  Password: " QB_PASS; echo ""
while [[ -z "$QB_PASS" ]]; do
  echo "  Required - cannot be empty."
  read -rsp "  Password: " QB_PASS; echo ""
done

QB_JAR=$(mktemp)
QB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -c "$QB_JAR" \
  -X POST "http://127.0.0.1:8080/api/v2/auth/login" \
  -H "Referer: http://127.0.0.1:8080" \
  -d "username=$QB_USER&password=$QB_PASS" 2>/dev/null || true)

if [[ "$QB_STATUS" != "200" && "$QB_STATUS" != "204" ]]; then
  echo "  ERROR: login failed (HTTP $QB_STATUS) - check the password."
  rm -f "$QB_JAR"; exit 1
fi

# Gluetun names its VPN interface tun0 for both WireGuard and OpenVPN
# (VPN_INTERFACE default). Binding qBittorrent to it is defense-in-depth on
# top of gluetun's own kill-switch.
QB_IFACE="tun0"

# web_ui_username/web_ui_password persist the credentials used above.
# Without this, the auto-generated temporary password changes on every
# container restart and breaks the download client set up in Radarr/Sonarr.
QB_PREFS="{\"save_path\":\"/data/downloads/complete\",\"temp_path\":\"/data/downloads/incomplete\",\"temp_path_enabled\":true,\"current_interface_name\":\"$QB_IFACE\",\"current_interface_address\":\"0.0.0.0\",\"web_ui_username\":\"$(json_escape "$QB_USER")\",\"web_ui_password\":\"$(json_escape "$QB_PASS")\"}"

curl -s -b "$QB_JAR" \
  -X POST "http://127.0.0.1:8080/api/v2/app/setPreferences" \
  -H "Referer: http://127.0.0.1:8080" \
  --data-urlencode "json=$QB_PREFS" \
  >/dev/null

# Categories with save paths so movies, tv and music land in separate folders
# (matches the directory layout created by setup.sh)
for _cat in movies tv music; do
  _status=$(curl -s -o /dev/null -w "%{http_code}" -b "$QB_JAR" \
    -X POST "http://127.0.0.1:8080/api/v2/torrents/createCategory" \
    -H "Referer: http://127.0.0.1:8080" \
    --data-urlencode "category=$_cat" \
    --data-urlencode "savePath=/data/downloads/complete/$_cat")
  if [[ "$_status" != "200" ]]; then
    # 409 = category exists; update its save path instead
    curl -s -b "$QB_JAR" \
      -X POST "http://127.0.0.1:8080/api/v2/torrents/editCategory" \
      -H "Referer: http://127.0.0.1:8080" \
      --data-urlencode "category=$_cat" \
      --data-urlencode "savePath=/data/downloads/complete/$_cat" \
      >/dev/null
  fi
done

rm -f "$QB_JAR"
echo "  Save paths and categories configured."
echo "  WebUI credentials saved (the temporary log password is now permanent)."
echo "  Network interface bound to $QB_IFACE (VPN tunnel only)."

# Prowlarr -> Radarr

section "Prowlarr -> Radarr"

if arr_has "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/applications" "\"Radarr\""; then
  echo "  Already connected, skipping."
else
  arr_post "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/applications" \
    "{\"syncLevel\":\"fullSync\",\"name\":\"Radarr\",\"implementationName\":\"Radarr\",\"implementation\":\"Radarr\",\"configContract\":\"RadarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://radarr:7878\"},{\"name\":\"apiKey\",\"value\":\"$RADARR_KEY\"},{\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]}]}" \
    >/dev/null
  echo "  Connected."
fi

# Prowlarr -> Sonarr

section "Prowlarr -> Sonarr"

if arr_has "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/applications" "\"Sonarr\""; then
  echo "  Already connected, skipping."
else
  arr_post "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/applications" \
    "{\"syncLevel\":\"fullSync\",\"name\":\"Sonarr\",\"implementationName\":\"Sonarr\",\"implementation\":\"Sonarr\",\"configContract\":\"SonarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://sonarr:8989\"},{\"name\":\"apiKey\",\"value\":\"$SONARR_KEY\"},{\"name\":\"syncCategories\",\"value\":[5000,5010,5020,5030,5040,5045,5050]}]}" \
    >/dev/null
  echo "  Connected."
fi

# Prowlarr -> Lidarr
# syncCategories 3000-3040 are the Audio categories (MP3, lossless/FLAC, etc.)

section "Prowlarr -> Lidarr"

if arr_has "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/applications" "\"Lidarr\""; then
  echo "  Already connected, skipping."
else
  arr_post "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/applications" \
    "{\"syncLevel\":\"fullSync\",\"name\":\"Lidarr\",\"implementationName\":\"Lidarr\",\"implementation\":\"Lidarr\",\"configContract\":\"LidarrSettings\",\"tags\":[],\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://lidarr:8686\"},{\"name\":\"apiKey\",\"value\":\"$LIDARR_KEY\"},{\"name\":\"syncCategories\",\"value\":[3000,3010,3020,3030,3040]}]}" \
    >/dev/null
  echo "  Connected."
fi

# Prowlarr -> FlareSolverr
# Registered as an indexer proxy gated behind a "flaresolverr" tag, so it only
# applies to indexers you tag with it (proxying everything through a headless
# browser would slow down all searches).

section "Prowlarr -> FlareSolverr"

if arr_has "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/indexerProxy" "\"FlareSolverr\""; then
  echo "  Already configured, skipping."
else
  _tags=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/tag" 2>/dev/null || echo "[]")
  FS_TAG_ID=$(echo "$_tags" | grep -oP '\{[^{}]*"label":"flaresolverr"[^{}]*\}' | grep -oP '(?<="id":)\d+' | head -1)
  if [[ -z "$FS_TAG_ID" ]]; then
    FS_TAG_ID=$(arr_post "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/tag" '{"label":"flaresolverr"}' \
      | grep -oP '(?<="id":)\d+' | head -1)
  fi

  if [[ -z "$FS_TAG_ID" ]]; then
    echo "  WARNING: could not create the flaresolverr tag, skipping."
  elif arr_post "$PROWLARR_KEY" "http://127.0.0.1:9696/api/v1/indexerProxy" \
    "{\"name\":\"FlareSolverr\",\"implementationName\":\"FlareSolverr\",\"implementation\":\"FlareSolverr\",\"configContract\":\"FlareSolverrSettings\",\"tags\":[$FS_TAG_ID],\"fields\":[{\"name\":\"host\",\"value\":\"http://flaresolverr:8191/\"},{\"name\":\"requestTimeout\",\"value\":60}]}" \
    >/dev/null; then
    echo "  Connected. Add the 'flaresolverr' tag to Cloudflare-protected indexers to use it."
  else
    echo "  WARNING: could not add FlareSolverr proxy. Is the container running?"
    echo "           Check: docker compose logs flaresolverr"
  fi
fi

# Radarr: download client + root folder

section "Radarr"

if arr_has "$RADARR_KEY" "http://127.0.0.1:7878/api/v3/downloadclient" "\"qBittorrent\""; then
  echo "  Download client already configured, skipping."
else
  arr_post "$RADARR_KEY" "http://127.0.0.1:7878/api/v3/downloadclient" \
    "{\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"name\":\"qBittorrent\",\"implementationName\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"gluetun\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"username\",\"value\":\"$QB_USER\"},{\"name\":\"password\",\"value\":\"$QB_PASS\"},{\"name\":\"movieCategory\",\"value\":\"movies\"},{\"name\":\"recentMoviePriority\",\"value\":0},{\"name\":\"olderMoviePriority\",\"value\":0},{\"name\":\"initialState\",\"value\":0},{\"name\":\"sequentialOrder\",\"value\":false},{\"name\":\"firstAndLast\",\"value\":false}]}" \
    >/dev/null
  echo "  qBittorrent connected."
fi

if arr_has "$RADARR_KEY" "http://127.0.0.1:7878/api/v3/rootfolder" "/data/media/movies"; then
  echo "  Root folder already configured, skipping."
else
  arr_post "$RADARR_KEY" "http://127.0.0.1:7878/api/v3/rootfolder" \
    "{\"path\":\"/data/media/movies\"}" >/dev/null
  echo "  Root folder /data/media/movies added."
fi

# Sonarr: download client + root folder

section "Sonarr"

if arr_has "$SONARR_KEY" "http://127.0.0.1:8989/api/v3/downloadclient" "\"qBittorrent\""; then
  echo "  Download client already configured, skipping."
else
  arr_post "$SONARR_KEY" "http://127.0.0.1:8989/api/v3/downloadclient" \
    "{\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"name\":\"qBittorrent\",\"implementationName\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"gluetun\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"username\",\"value\":\"$QB_USER\"},{\"name\":\"password\",\"value\":\"$QB_PASS\"},{\"name\":\"tvCategory\",\"value\":\"tv\"},{\"name\":\"recentTvPriority\",\"value\":0},{\"name\":\"olderTvPriority\",\"value\":0},{\"name\":\"initialState\",\"value\":0},{\"name\":\"sequentialOrder\",\"value\":false},{\"name\":\"firstAndLast\",\"value\":false}]}" \
    >/dev/null
  echo "  qBittorrent connected."
fi

if arr_has "$SONARR_KEY" "http://127.0.0.1:8989/api/v3/rootfolder" "/data/media/tv"; then
  echo "  Root folder already configured, skipping."
else
  arr_post "$SONARR_KEY" "http://127.0.0.1:8989/api/v3/rootfolder" \
    "{\"path\":\"/data/media/tv\"}" >/dev/null
  echo "  Root folder /data/media/tv added."
fi

# Lidarr: download client + root folder

section "Lidarr"

if arr_has "$LIDARR_KEY" "http://127.0.0.1:8686/api/v1/downloadclient" "\"qBittorrent\""; then
  echo "  Download client already configured, skipping."
else
  arr_post "$LIDARR_KEY" "http://127.0.0.1:8686/api/v1/downloadclient" \
    "{\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"name\":\"qBittorrent\",\"implementationName\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"gluetun\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"username\",\"value\":\"$QB_USER\"},{\"name\":\"password\",\"value\":\"$QB_PASS\"},{\"name\":\"musicCategory\",\"value\":\"music\"},{\"name\":\"initialState\",\"value\":0},{\"name\":\"sequentialOrder\",\"value\":false},{\"name\":\"firstAndLast\",\"value\":false}]}" \
    >/dev/null
  echo "  qBittorrent connected."
fi

if arr_has "$LIDARR_KEY" "http://127.0.0.1:8686/api/v1/rootfolder" "/data/media/music"; then
  echo "  Root folder already configured, skipping."
else
  arr_post "$LIDARR_KEY" "http://127.0.0.1:8686/api/v1/rootfolder" \
    "{\"name\":\"Music\",\"path\":\"/data/media/music\",\"defaultMetadataProfileId\":1,\"defaultQualityProfileId\":1,\"defaultMonitorOption\":\"all\"}" >/dev/null
  echo "  Root folder /data/media/music added."
fi

# Done

echo ""
echo "==> All done. Open Radarr, Sonarr or Lidarr and search for something to download."
