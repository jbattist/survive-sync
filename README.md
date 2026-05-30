# survive-sync

Builds and maintains the **SURVIVE offline disaster library appliance** on a Raspberry Pi 5. Downloads and keeps current a curated collection of offline knowledge: books, maps, PDFs, ZIM files (Wikipedia, etc.), and video — all browsable via a local web portal without internet access.

## What it does

- Syncs ZIM files (Kiwix — Wikipedia, Wiktionary, etc.)
- Downloads survival/reference PDFs from curated sources
- Archives YouTube videos via yt-dlp
- Downloads offline maps (USGS topo, MBTiles)
- Ingests ebooks from Project Gutenberg, Standard Ebooks, and a TrueNAS NAS share
- Serves everything via a web portal (Kiwix, Calibre, Jellyfin, MapLibre)

## Selective classics movie sync

Classics are selected through a Radarr tag, then mirrored from the TrueNAS classics NFS share to the Survive appliance. The Pi keeps a cached manifest so Radarr only has to be reachable when refreshing the selection; a later offline run can still sync from the last known-good list.

Flow:

```text
Radarr movie tag: survive
        ↓
/etc/survive-sync/classics.env
        ↓
/srv/offline/metadata/classics-survive-manifest.txt
        ↓
rsync /mnt/media-classics/ → /srv/offline/video/classics/
```

1. Tag desired movies in Radarr with `survive`.
2. On the Pi, configure `/etc/survive-sync/classics.env`:

```bash
RADARR_URL="http://radarr.home:7878"
RADARR_API_KEY="..."
RADARR_SYNC_TAG="survive"
```

Optional overrides:

```bash
CLASSICS_NFS_MOUNT="/mnt/media-classics"
CLASSICS_DEST_DIR="/srv/offline/video/classics"
CLASSICS_MANIFEST_FILE="/srv/offline/metadata/classics-survive-manifest.txt"
CLASSICS_BWLIMIT="50000"   # KiB/s; set 0 for unlimited
```

3. Run a dry run first:

```bash
sudo -u library /srv/offline/scripts/sync/sync-classics.sh --dry-run
```

4. Run the real sync as the content owner:

```bash
sudo -u library /srv/offline/scripts/sync/sync-classics.sh
```

A real run refreshes `/srv/offline/metadata/classics-survive-manifest.txt`, copies only selected classics, and intentionally deletes deselected/stale classics from `/srv/offline/video/classics/` via `rsync --delete --delete-excluded`. Run the sync as `library` so manifests, logs, and media remain writable by the systemd units and future sync runs.

Quick verification:

```bash
sudo wc -l /srv/offline/metadata/classics-survive-manifest.txt
sudo find /srv/offline/video/classics -mindepth 1 -maxdepth 1 -type d | wc -l
```

For the current `survive` tag both counts should be `20`.

## Guiding principle

Simple, repairable, rebuildable. No Docker. Plain Linux services.

## Requirements

- Raspberry Pi 5 (aarch64, Arch Linux ARM)
- Internet connection for initial sync (offline after)
- TrueNAS NFS share (optional — for book and media-classics ingest)

## Deploy

```bash
git clone git@github.com:jbattist/survive-sync.git
cd survive-sync
sudo bash install.sh
```

Re-deploy after changes:
```bash
git pull && sudo bash install.sh
```

## Running

```bash
# Full content sync
sudo systemctl start survive-sync.service

# Books only (from NAS + Gutenberg)
sudo systemctl start survive-books.service

# Monitor logs
journalctl -u survive-sync -f
journalctl -u survive-books -f
```

## Layout

```
config/         Source lists (ZIMs, PDFs, videos, maps, books)
sync/           Sync scripts (one per content type)
postprocess/    Index rebuilding, Kiwix library update, catalog update
portal/         Web portal index
systemd/        Service and timer unit files
scripts/        Helper scripts (welcome screen, etc.)
install.sh      Full setup — idempotent, safe to re-run
SURVIVE.md      Full architecture, service map, and operations reference
NETWORK.md      Network topology notes
```

## Content on the Pi

All content lives under `/srv/offline/` on the Pi:

```
/srv/offline/
  zim/          Kiwix ZIM files
  pdfs/         Reference PDFs
  video/        YouTube archives and classics
  maps/         MBTiles offline maps
  books/        Calibre library
  logs/         Sync logs (sync-YYYY-MM-DD.log)
```

## Services on the Pi

| Service | Purpose | Port |
|---------|---------|------|
| kiwix | ZIM browser | 8888 |
| calibre-server | Ebook library | 8080 |
| jellyfin | Video library | 8096 |
| mbtileserver | Offline maps | 7070 |
| survive-sync.timer | Daily content sync | — |
| survive-books.timer | 30-min book ingest | — |

## License

MIT
