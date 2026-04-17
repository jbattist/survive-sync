# survive-sync

Builds and maintains the **SURVIVE offline disaster library appliance** on a Raspberry Pi 5. Downloads and keeps current a curated collection of offline knowledge: books, maps, PDFs, ZIM files (Wikipedia, etc.), and video — all browsable via a local web portal without internet access.

## What it does

- Syncs ZIM files (Kiwix — Wikipedia, Wiktionary, etc.)
- Downloads survival/reference PDFs from curated sources
- Archives YouTube videos via yt-dlp
- Downloads offline maps (USGS topo, MBTiles)
- Ingests ebooks from Project Gutenberg, Standard Ebooks, and a TrueNAS NAS share
- Serves everything via a web portal (Kiwix, Calibre, Jellyfin, MapLibre)

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
