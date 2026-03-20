# SURVIVE — Offline Library Appliance

**Install, Operations & Troubleshooting Guide**
**Last Updated:** March 2026

---

## Hardware

| Component | Spec |
|---|---|
| Board | Raspberry Pi 5 8GB |
| Boot | 64GB microSD |
| Data | 2TB external SSD, ext4, label `survive-data`, mounted at `/srv/offline` |
| OS | EndeavourOS ARM (aarch64) |
| Hostname | `survive` |
| Travel IP | 192.168.8.2 (static DHCP on Beryl) |
| DNS name | `survive.travel` (Pi-hole static entry) |
| Content user | `library` (system user, owns `/srv/offline`) |

---

## Architecture

All content services run internally and are reverse-proxied by Caddy on port 80.
No raw service ports are exposed to clients.

| Service | Internal Port | Public Path | Description |
|---|---|---|---|
| Caddy | 80 | — | Reverse proxy + static portal |
| Kiwix | 8080 | `/wiki/` | Wikipedia + ZIM files |
| Calibre | 8081 | `/books/` | Ebook library |
| mbtileserver | 8082 | `/maps/tiles/` | Map tile server |
| — | — | `/pdfs/` | PDF guides (static files) |
| — | — | `/video/` | Video files (static files) |
| — | — | `/maps/download/` | .mbtiles downloads for OsmAnd/Locus |

---

## Content Layout

```
/srv/offline/
├── portal/             web portal static files (served by Caddy)
│   ├── index.html
│   ├── docs/
│   └── maps/           MapLibre GL JS viewer
├── kiwix/
│   ├── library.xml     rebuilt by update-kiwix-library.sh after each sync
│   └── zim/            *.zim files (Wikipedia ~100GB, Wiktionary, Simple Wikipedia)
├── pdfs/
│   ├── 00-start-here/
│   ├── 01-medical/
│   ├── 02-water/
│   ├── 03-food/
│   ├── 04-agriculture/
│   ├── 05-shelter/
│   ├── 06-power/
│   ├── 07-repair/
│   ├── 08-comms/
│   ├── 09-navigation/
│   ├── 10-security/
│   ├── 11-reference/
│   └── 12-technology/
├── books/
│   ├── calibre-library/    Calibre database (metadata.db + book files)
│   └── epub/
├── maps/
│   ├── tiles/          *.mbtiles files (US Northeast: CT ME MA NH RI VT NY)
│   ├── pbf/            Geofabrik OSM PBF source files
│   └── topo/
├── video/
│   ├── first-aid/
│   ├── repair/
│   ├── power/
│   ├── food/
│   └── morale/
├── scripts/            sync scripts and configs (copied from this repo)
└── logs/
```

---

## Fresh Install

### Prerequisites

- Pi 5 booted with EndeavourOS ARM on microSD
- 2TB SSD connected via USB
- Pi reachable on the network (ethernet)

### Steps

```bash
# On the Pi
git clone git@github.com:jbattist/survive-sync.git ~/survive-sync
cd ~/survive-sync
sudo bash install.sh
```

If packages fail to install (stale package DB):
```bash
yay -Syu
sudo bash install.sh
```

`install.sh` is idempotent — safe to re-run after updates or to fix partial failures.

### What install.sh Does

1. Installs packages: `tilemaker` (built from source on aarch64), `mbtileserver` (via `go install`), `kiwix-tools`, `calibre`, `yt-dlp`, `caddy`
2. Formats/mounts USB SSD at `/srv/offline` (ext4, label `survive-data`)
3. Creates full directory structure under `/srv/offline`
4. Initializes empty Calibre library (`metadata.db`)
5. Copies scripts, configs, and portal assets
6. Downloads MapLibre GL JS and OpenMapTiles fonts (offline map viewer)
7. Installs and restarts systemd units
8. Writes `/etc/caddy/Caddyfile` (always overwrites) and restarts Caddy
9. Opens firewall ports (firewalld: adds ports to public + internal zones)
10. Sets ownership: `chown -R library:library /srv/offline`
11. Configures `sudo` for `library` user service restarts
12. Installs `/etc/profile.d/survive-welcome.sh` (login banner)

---

## Sync

### Run a Full Sync

```bash
sudo systemctl start survive-sync.service
journalctl -u survive-sync -f          # Ctrl+C to detach, sync keeps running
```

### Run Specific Modules Only

```bash
SYNC_MODULES='pdfs books' sudo systemctl start survive-sync.service
# modules: zim pdfs books maps video
```

### Timer

Runs automatically every Sunday at 02:00. `Persistent=true` — if the Pi was off, it
catches up on next boot.

```bash
systemctl list-timers survive-sync.timer
```

### Check Sync Status

```bash
journalctl -u survive-sync -n 100 --no-pager
systemctl status survive-sync
```

---

## Service Management

### Status at a Glance

```bash
systemctl status caddy kiwix calibre-server mbtileserver --no-pager
```

### Restart All Services

```bash
sudo systemctl restart caddy kiwix calibre-server mbtileserver
```

### Restart Individual Service

```bash
sudo systemctl restart caddy
sudo systemctl restart kiwix
sudo systemctl restart calibre-server
sudo systemctl restart mbtileserver
```

### View Logs

```bash
journalctl -u caddy -f
journalctl -u kiwix -f
journalctl -u calibre-server -f
journalctl -u mbtileserver -f
```

---

## Troubleshooting

### Caddy serving its default page instead of the portal

Caddy has the old config loaded in memory. Restart it:
```bash
sudo systemctl restart caddy
```

If the Caddyfile itself looks wrong:
```bash
cat /etc/caddy/Caddyfile     # should contain 'survive-sync' marker
sudo bash ~/survive-sync/install.sh   # step 8 always rewrites it
```

### Books — 502 Bad Gateway

Calibre isn't running. Check why:
```bash
systemctl status calibre-server
journalctl -u calibre-server -n 30 --no-pager
```

**"There is no calibre library"** — library was never initialized:
```bash
sudo chown library:library /srv/offline/books/calibre-library
_tmp=$(mktemp /tmp/XXXXXX.txt)
sudo -u library calibredb add --with-library /srv/offline/books/calibre-library "$_tmp"
sudo -u library calibredb remove --with-library /srv/offline/books/calibre-library 1
rm "$_tmp"
sudo systemctl restart calibre-server
```

### Wikipedia — 502 Bad Gateway

```bash
systemctl status kiwix
journalctl -u kiwix -n 30 --no-pager
```

No ZIM files yet — sync hasn't finished. Check progress:
```bash
ls -lh /srv/offline/kiwix/zim/
journalctl -u survive-sync -n 50 --no-pager
```

### Maps not loading

```bash
systemctl status mbtileserver
ls /srv/offline/maps/tiles/*.mbtiles    # files must exist
```

If no `.mbtiles` files: maps sync hasn't run or failed. Check sync logs.

### /srv/offline not mounted

The SSD isn't mounted. All services depend on it:
```bash
lsblk
systemctl status srv-offline.mount
sudo systemctl start srv-offline.mount
```

Check that the SSD label is `survive-data`:
```bash
lsblk -o NAME,LABEL,MOUNTPOINT
```

If label is missing (drive was reformatted):
```bash
sudo e2label /dev/sda survive-data
sudo systemctl start srv-offline.mount
```

### Packages fail to install

Package DB is stale — sync it first:
```bash
yay -Syu
sudo bash install.sh
```

### tilemaker or mbtileserver missing after install

On aarch64, these aren't in the standard repos. `install.sh` handles them:
- `tilemaker`: built from source via cmake (~10 min)
- `mbtileserver`: installed via `go install`

If they're still missing after a failed install run:
```bash
# tilemaker
sudo pacman -S --noconfirm --needed base-devel cmake git boost boost-libs protobuf shapelib rapidjson luajit sqlite zlib
git clone --depth=1 https://github.com/systemed/tilemaker.git /tmp/tilemaker-src
cmake -S /tmp/tilemaker-src -B /tmp/tilemaker-src/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build /tmp/tilemaker-src/build --parallel $(nproc)
sudo cmake --install /tmp/tilemaker-src/build

# mbtileserver
sudo pacman -S --noconfirm --needed go
sudo GOPATH=/usr/local go install github.com/consbio/mbtileserver@latest
sudo ln -sf /usr/local/bin/mbtileserver /usr/bin/mbtileserver
```

### OpenMapTiles fonts missing (map labels blank)

```bash
ls /srv/offline/portal/maps/fonts/    # should have font directories
sudo bash install.sh                  # step 6 retries font download
```

### Firewall blocking services

Check open ports:
```bash
sudo firewall-cmd --list-all
sudo firewall-cmd --zone=internal --list-all
```

Manually open if needed:
```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=8081/tcp
sudo firewall-cmd --permanent --add-port=8082/tcp
sudo firewall-cmd --reload
```

---

## Rebuild From Scratch

If the SD card dies or the OS needs to be reflashed:

1. Flash EndeavourOS ARM to a new 64GB microSD
2. Boot Pi — the 2TB SSD data survives (it's a separate drive)
3. `git clone git@github.com:jbattist/survive-sync.git ~/survive-sync`
4. `sudo bash ~/survive-sync/install.sh`

All content on `/srv/offline` is preserved. Only the OS and services need to be reinstalled.

---

## Systemd Units

| Unit | Purpose |
|---|---|
| `srv-offline.mount` | Mounts USB SSD at `/srv/offline` by label |
| `kiwix.service` | Kiwix ZIM server, port 8080, depends on mount |
| `calibre-server.service` | Calibre ebook server, port 8081, depends on mount |
| `mbtileserver.service` | Map tile server, port 8082, depends on mount |
| `caddy.service` | Reverse proxy and portal, port 80 |
| `survive-sync.service` | Oneshot sync job (runs `sync-all.sh`) |
| `survive-sync.timer` | Weekly timer, Sunday 02:00, Persistent=true |

All unit files live in `/etc/systemd/system/` and are sourced from this repo at `systemd/`.

---

## Repo Layout

```
survive-sync/
├── install.sh                  deploy script — run with: sudo bash install.sh
├── SURVIVE.md                  this file
├── NETWORK.md                  network/VPN setup guide
├── portal/                     web portal (copied to /srv/offline/portal/)
│   ├── index.html
│   ├── docs/
│   └── maps/index.html
├── config/                     sync source lists
│   ├── zim-list.conf
│   ├── pdf-sources.conf
│   ├── book-list.conf
│   ├── video-list.conf
│   └── map-regions.conf
├── sync/                       sync scripts (run by survive-sync.service)
│   ├── sync-all.sh
│   ├── sync-zim.sh
│   ├── sync-pdfs.sh
│   ├── sync-books.sh
│   ├── sync-maps.sh
│   └── sync-video.sh
├── postprocess/
│   ├── update-kiwix-library.sh
│   ├── update-catalog.sh
│   └── rebuild-indexes.sh
├── scripts/
│   └── survive-welcome.sh      login banner → /etc/profile.d/
└── systemd/                    unit files → /etc/systemd/system/
```
