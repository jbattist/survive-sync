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
| NAS book share | `truenas.home:/mnt/hdd/books` → `/mnt/truenas-books` (ro, NFS automount) |

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
│   ├── 12-technology/
│   ├── 13-cbrn/
│   ├── 14-transport/
│   ├── 15-leadership/
│   ├── 16-maritime/
│   ├── 17-weather/
│   ├── 18-firearms/
│   ├── 19-logistics/
│   ├── 20-classics/
│   ├── 21-engineering/
│   ├── 22-usmc/
│   └── ...
├── books/
│   ├── calibre-library/    Calibre database (metadata.db + book files)
│   ├── epub/               local copies of all ingested EPUBs
│   └── .calibre-ingested.txt   dedup archive (one slug per line)
├── maps/
│   ├── tiles/          *.mbtiles files (US Northeast: CT ME MA NH RI VT NY)
│   ├── pbf/            Geofabrik OSM PBF source files
│   └── topo/           USGS topo PDFs
├── video/
│   ├── first-aid/
│   ├── repair/
│   ├── power/
│   ├── food/
│   ├── morale/
│   ├── agriculture/
│   └── shelter/
├── metadata/           hash records used by sync-pdfs.sh (sha256sums-pdfs.txt)
├── scripts/            sync scripts and configs (copied from this repo)
└── logs/               sync-YYYY-MM-DD.log (one per day)
```

---

## Fresh Install

### Prerequisites

- Pi 5 booted with EndeavourOS ARM on microSD
- 2TB SSD connected via USB
- Pi reachable on the network (ethernet)
- TrueNAS reachable at `truenas.home` (for NAS book ingest — optional)

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

1. Installs packages: `tilemaker` (built from source on aarch64), `mbtileserver` (via `go install`), `kiwix-tools`, `calibre`, `yt-dlp`, `caddy`, `nfs-utils`
2. Formats/mounts USB SSD at `/srv/offline` (ext4, label `survive-data`)
2b. Configures NFS mount: adds `truenas.home:/mnt/hdd/books` → `/mnt/truenas-books` to `/etc/fstab` as a read-only automount; tests connectivity
3. Creates full directory structure under `/srv/offline`
4. Initializes empty Calibre library (`metadata.db`)
5. Copies scripts, configs, and portal assets
6. Downloads MapLibre GL JS and OpenMapTiles fonts (offline map viewer)
7. Installs and restarts systemd units (including `survive-books.timer`)
8. Writes `/etc/caddy/Caddyfile` (always overwrites) and restarts Caddy
9. Opens firewall ports (firewalld or nftables)
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

### Run Books Only (NAS ingest + Gutenberg)

```bash
sudo systemctl start survive-books.service
journalctl -u survive-books -f
```

### Run Specific Modules Only

```bash
SYNC_MODULES='pdfs books' sudo systemctl start survive-sync.service
# modules: zim pdfs books maps video
```

### Timers

| Timer | Schedule | Purpose |
|---|---|---|
| `survive-sync.timer` | Weekly, Sunday 02:00 | Full sync (ZIM, PDFs, books, maps, video) |
| `survive-books.timer` | Hourly | Books only — picks up new EPUBs from NAS within an hour |

Both timers use `Persistent=true` — if the Pi was off at trigger time, they run on next boot.

```bash
systemctl list-timers survive-sync.timer survive-books.timer
```

### Check Sync Status

```bash
journalctl -u survive-sync -n 100 --no-pager
journalctl -u survive-books -n 100 --no-pager
systemctl status survive-sync survive-books
```

### Reading Sync Logs

Each sync run writes a detailed log at `/srv/offline/logs/sync-YYYY-MM-DD.log`.
`journalctl` shows the same output but this file is easier to grep.

```bash
# View today's log
cat /srv/offline/logs/sync-$(date +%Y-%m-%d).log

# Show only failures
grep FAIL /srv/offline/logs/sync-$(date +%Y-%m-%d).log

# List all log files
ls -lh /srv/offline/logs/
```

Each module prefixes its lines: `[ZIM]`, `[PDF]`, `[VIDEO]`, `[MAPS]`, `[BOOK]`.
A run ends with a summary line per module: `added=N skipped=N failed=N`.

---

## NAS Book Ingest

EPUBs on the TrueNAS share (`truenas.home:/mnt/hdd/books`) are automatically copied
to `/srv/offline/books/epub/` and added to the Calibre library by `sync-books.sh`.

### How it works

- The NFS share is mounted read-only at `/mnt/truenas-books` (automount via fstab)
- `sync-books.sh` scans the mount after the Gutenberg/Standard Ebooks phase
- Any `.epub` found is validated (>5KB, valid ZIP header), copied locally, and ingested via `calibredb add`
- Deduplication uses `/srv/offline/books/.calibre-ingested.txt` (slug = filename stem) — books already in the library are skipped instantly
- `survive-books.timer` runs the process hourly so new books appear in Calibre within an hour

### Adding books to the NAS

Drop any `.epub` file into `truenas.home:/mnt/hdd/books` (or any subdirectory).
It will appear in the Calibre library within one hour. To ingest immediately:

```bash
sudo systemctl start survive-books.service
journalctl -u survive-books -f
```

### Verify the NFS mount

```bash
mountpoint /mnt/truenas-books && ls /mnt/truenas-books
# If not mounted:
sudo mount /mnt/truenas-books
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

### Sync FAIL entries

First, check whether the failure is transient or permanent.

**Transient** — a re-run fixes it:
- Archive.org outage (returns 503 — can affect dozens of PDFs at once)
- USGS/government sites timing out or rate-limiting
- Network blip during download

```bash
# Rerun just the affected module to confirm
SYNC_MODULES='pdfs' sudo systemctl start survive-sync.service
journalctl -u survive-sync -f
```

**Permanent** — re-runs won't help, config needs fixing:
- URL redirects to a login/gated page → file downloads but fails the sanity check
- URL has moved or the file was renamed upstream

The PDF sanity check rejects anything under 10 KB or that doesn't start with `%PDF`.
A gated page that returns HTML will always fail this, even if wget exits 0.

To test a specific URL manually:
```bash
wget -O /tmp/test.pdf "https://example.com/file.pdf"
file /tmp/test.pdf            # should say "PDF document"
wc -c /tmp/test.pdf           # should be much larger than 10240 bytes
```

If it returns HTML, the URL is broken. Comment it out in `config/pdf-sources.conf`
with a note, then commit and redeploy.

---

### Video sync always shows `added=N skipped=0`

This is a known cosmetic issue. `yt-dlp` exits 0 whether it downloaded something new
or found all content already in its archive file. The script counts any exit-0 as
`added`, so the counter is inflated. No actual re-downloading occurs — the archive
file at `/srv/offline/video/.yt-dlp-archive.txt` prevents it. Safe to ignore.

---

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

### Books sync exits with failure but books are being added

If the only `FAIL` line is a single book (e.g. `princess-of-mars--burroughs`), the
sync is working correctly — one failed download causes exit 1 even when everything
else succeeded. Check `AGENTS.md` for known permanent failures to comment out.

### NAS books not appearing in Calibre

1. Check the NFS mount is up:
```bash
mountpoint /mnt/truenas-books
ls /mnt/truenas-books
```

2. Force a books sync and watch the NFS scan section:
```bash
sudo systemctl start survive-books.service
journalctl -u survive-books -f
```

3. Check the ingest archive to see if a book was already recorded:
```bash
grep "filename-stem" /srv/offline/books/.calibre-ingested.txt
```

If a book is in the archive but not in Calibre (e.g. archive was manually edited or
`calibredb add` failed silently), remove its line from the archive and re-run the sync.

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
The NFS fstab entry and book ingest archive are also restored by `install.sh`.

---

## Systemd Units

| Unit | Purpose |
|---|---|
| `srv-offline.mount` | Mounts USB SSD at `/srv/offline` by label |
| `kiwix.service` | Kiwix ZIM server, port 8080, depends on mount |
| `calibre-server.service` | Calibre ebook server, port 8081, depends on mount |
| `mbtileserver.service` | Map tile server, port 8082, depends on mount |
| `caddy.service` | Reverse proxy and portal, port 80 |
| `survive-sync.service` | Oneshot full sync job (runs `sync-all.sh`) |
| `survive-sync.timer` | Weekly timer, Sunday 02:00, Persistent=true |
| `survive-books.service` | Oneshot books-only sync (runs `sync-books.sh`) |
| `survive-books.timer` | Hourly timer, Persistent=true — NAS book ingest |

All unit files live in `/etc/systemd/system/` and are sourced from this repo at `systemd/`.

---

## Repo Layout

```
survive-sync/
├── install.sh                  deploy script — run with: sudo bash install.sh
├── SURVIVE.md                  this file
├── AGENTS.md                   OpenCode session context (project rules + known issues)
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
│   ├── sync-books.sh           also run standalone by survive-books.service
│   ├── sync-maps.sh
│   └── sync-video.sh
├── postprocess/
│   ├── update-kiwix-library.sh
│   ├── update-catalog.sh
│   └── rebuild-indexes.sh
├── scripts/
│   └── survive-welcome.sh      login banner → /etc/profile.d/
└── systemd/                    unit files → /etc/systemd/system/
    ├── srv-offline.mount
    ├── kiwix.service
    ├── calibre-server.service
    ├── mbtileserver.service
    ├── caddy.service
    ├── survive-sync.service
    ├── survive-sync.timer
    ├── survive-books.service
    └── survive-books.timer
```
