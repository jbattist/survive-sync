# AGENTS.md — survive-sync

This repo builds and maintains the **SURVIVE offline disaster library appliance** on a Raspberry Pi 5.
See `SURVIVE.md` for full architecture, install, and operations reference.

---

## Project Identity

- **Repo:** `git@github.com:jbattist/survive-sync.git`
- **Dev machine:** `bunker` — OpenCode runs here, local repo at `~/projects/survive-sync/`
- **Pi:** hostname `survive`, IP `192.168.8.2`, DNS `survive.travel`
- **Pi repo:** `~/survive-sync/` — deploy with `git pull && sudo bash install.sh`
- **Guiding principle:** Simple, repairable, rebuildable. No Docker. Plain Linux services.
- **Standard sync run:** `sudo systemctl start survive-sync.service`
- **Books-only sync:** `sudo systemctl start survive-books.service`
- **Monitor:** `journalctl -u survive-sync -f` or `journalctl -u survive-books -f`
- **TrueNAS NFS book share:** `truenas.home:/mnt/hdd/books` → mounted at `/mnt/truenas-books` (ro, automount)
  - `install.sh` adds the fstab entry and installs `nfs-utils`
  - `sync-books.sh` scans the mount after the Gutenberg/StandardEbooks phase and ingests any `.epub` found
  - `survive-books.timer` runs `sync-books.sh` every 30 min so NAS books appear in Calibre quickly
- **TrueNAS NFS classics share:** `truenas.home:/mnt/hdd/media-classics` → mounted at `/mnt/media-classics` (ro, automount)
  - `install.sh` adds the fstab entry
  - `sync-classics.sh` rsyncs all files to `/srv/offline/video/classics/` preserving folder structure
  - Wired into `sync-all.sh` as the `classics` module

## Workflow

- After every change: **commit and push immediately** (no need to ask)
- Joe pulls on `survive` to test: `git pull && sudo bash install.sh`

---

## Known Permanent Config Failures (need fixing)

None currently. See Previously Fixed table below for resolved items.

---

## Transient Issues (no action needed, re-test after next sync)

- **archive.org 503/403** — still ongoing as of March 29. All `milmanual-*` archive.org URLs are failing with wget exit 8 (HTTP error). Non-archive.org PDFs download fine. Re-run sync once archive.org recovers.
---

## Known Cosmetic Issues (low priority)

- `sync-video.sh` always reports `added=44 skipped=0` — yt-dlp exits 0 for both downloaded
  and already-archived items; script can't distinguish. No actual re-downloading occurs.

---

## Previously Fixed (do not re-fix)

| Commit | Fix |
|--------|-----|
| `45418c5` | Double-logging bug in sync scripts |
| `06df20f` | @StoptheBleed video — hijacked channel replaced |
| `919b476` | `calibre-server.service` unit suffix fix |
| `47a3f56`, `5164700`, `f5cd97c`, `3a823c5`, `5a4a883` | MapLibre portal fixes |
| `2892be6` | NFS book ingest from TrueNAS (install.sh + sync-books.sh) |
| `64b3dcf` | `survive-books.service` + `survive-books.timer` (hourly NAS ingest) |
| `0fcc8a2` | Fix bad systemd specifier in `survive-books.service` log path |
| `v1.0.0` | wiktionary slug fixed, ARRL/IAEA PDFs commented out, princess-of-mars commented out |
| v2 | `survive-books.timer` changed to 30 min; PDF search (poppler+pagefind) added to install.sh + rebuild-indexes.sh; `portal/search/index.html` + `portal/pdfs/index.html` generated on each sync |
| `936df26` | USGS topo state filtering — switched from `&q=` to `&state=`; both broken server-side |
| `9b0b126` | Client-side filename prefix filter — TNM `&state=` returns random 500 items from all states |
| latest | Switch to `&bbox=` + `&offset=` pagination in `map-regions.conf` + `sync-maps.sh`; bbox is spatially accurate; filename prefix filter retained for cross-border quads |

---

## Sync Log Pattern Reference

A healthy sync run shows:
- `[ZIM] OK` for each ZIM file (or `skipped` if already current)
- `[PDF] OK filename.pdf` for each download
- `[PDF] FAIL filename.pdf` — investigate: check if URL is dead/gated or transient outage
- `[VIDEO] added=N skipped=0` — cosmetic, see above
- `[MAPS] OK` per region
- `[BOOK] SKIP slug (in library)` — already ingested, no action
- `[BOOK] ADD title` — new download or NAS ingest
- `[BOOK] FAIL slug` — download failed; check if URL is broken or transient

Logs live at `/srv/offline/logs/sync-YYYY-MM-DD.log` on the Pi.
