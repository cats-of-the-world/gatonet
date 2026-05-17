Disclaimer: LLMs were used to generate the configuration files.

# GatoNet

> *In Brazil, "fazer um gato" (to make a cat) is slang for tapping into a cable line to get free TV. GatoNet brings that spirit home — self-hosted, private, yours.*

A containerized media stack for automated movie and TV show downloading and streaming. Runs entirely on your home network. Torrent traffic is tunneled through a commercial VPN with a kill-switch so your ISP never sees what you download.

## Stack

| Container    | Role                                          |
|--------------|-----------------------------------------------|
| Gluetun      | VPN tunnel + kill-switch for torrent traffic  |
| qBittorrent  | Torrent client (runs inside Gluetun's network)|
| Prowlarr     | Indexer aggregator                            |
| Radarr       | Movie automation                              |
| Sonarr       | TV show automation                            |
| Jellyfin     | Media server — stream from any browser or app |

## Architecture

```
Browser ──► Radarr / Sonarr ──► qBittorrent ──► [ VPN ] ──► Internet
                  │                   │
              Prowlarr            Downloads
              (indexers)              │
                               Jellyfin (stream)
```

Ports bind to all interfaces but are restricted to LAN-only by firewall rules
that `setup.sh` writes to both ufw and the `DOCKER-USER` iptables chain.

## Requirements

- Docker + Docker Compose
- A commercial VPN subscription with WireGuard support (Mullvad, NordVPN, ProtonVPN, etc.)
- Linux host (amd64 or arm64)

## Getting Started

**1. Clone and generate config**

```bash
git clone https://github.com/youruser/gatonet.git
cd gatonet
bash generate-env.sh
```

The script auto-detects your user IDs and timezone, walks you through VPN
credentials, and writes a `chmod 600` `.env` file.

**2. Get WireGuard credentials**

- **Mullvad** — Account → WireGuard keys → Generate key
- **NordVPN** — [NordVPN WireGuard setup](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md)
- **ProtonVPN** — Account → Downloads → WireGuard configuration
- **Other providers** — [Gluetun provider list](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)

**3. Run setup and start**

```bash
sudo bash setup.sh
docker compose up -d
docker compose logs -f gluetun   # confirm VPN is connected
```

**4. Verify VPN is working**

```bash
docker exec -it qbittorrent curl -s https://ipinfo.io/ip
# Must return a VPN IP, not your home IP
```

## Web Interfaces

Find your current IP with `hostname -I`. The stack keeps working even if DHCP
assigns a new address — only the URL you type changes.

| Service     | URL                        | Purpose                      |
|-------------|----------------------------|------------------------------|
| Jellyfin    | `http://<your-ip>:8096`    | Stream movies and TV shows   |
| Radarr      | `http://<your-ip>:7878`    | Add and manage movies        |
| Sonarr      | `http://<your-ip>:8989`    | Add and manage TV shows      |
| Prowlarr    | `http://<your-ip>:9696`    | Manage torrent indexers      |
| qBittorrent | `http://<your-ip>:8080`    | Torrent client UI            |

## Post-start Wiring (one time)

### qBittorrent — set save paths
Tools → Options → Downloads:
- Default save path: `/data/downloads/complete`
- Temp path: `/data/downloads/incomplete`

### Prowlarr → Radarr and Sonarr
1. Prowlarr → Settings → Apps → Add → Radarr
   - Radarr URL: `http://radarr:7878`
   - API key: Radarr → Settings → General
2. Repeat for Sonarr (`http://sonarr:8989`)

### Radarr and Sonarr → qBittorrent
All containers share the same `/data` mount, so paths are consistent and no
Remote Path Mapping is needed.

1. Radarr → Settings → Download Clients → Add → qBittorrent
   - Host: `gluetun`, Port: `8080`, Category: `movies`
2. Repeat for Sonarr (Category: `tv`)

### Radarr → set paths
Settings → Media Management:
- Root folder: `/data/media/movies`

### Sonarr → set paths
Settings → Media Management:
- Root folder: `/data/media/tv`

### Prowlarr → Add indexers
Prowlarr → Indexers → Add → search for your preferred public or private indexers.

### Jellyfin → Add libraries
Dashboard → Libraries → Add Media Library:
- Movies → `/data/movies`
- TV Shows → `/data/tv`

## Usage

Open Radarr or Sonarr in a browser, search for a title, select a quality profile and click **Add**. The stack handles the rest — search, download, rename, and import into Jellyfin automatically.

## Maintenance

```bash
# Update all images
docker compose pull && docker compose up -d

# View logs
docker compose logs -f

# Stop everything
docker compose down
```

## License

MIT
