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
  - `survive-books.timer` runs `sync-books.sh` hourly so NAS books appear in Calibre within an hour

## Workflow

- After every change: **commit and push immediately** (no need to ask)
- Joe pulls on `survive` to test: `git pull && sudo bash install.sh`

---

## Known Permanent Config Failures (need fixing)

These cause FAIL entries on every sync run. They are config bugs, not transient errors.

### 1. `config/zim-list.conf` — wiktionary slug wrong
- Current (broken): `wiktionary_en_all_maxi`
- Fix: change to `wiktionary_en_all_nopic` (confirmed exists: `wiktionary_en_all_nopic_2026-02.zim`, 8.2GB)
- Alternative: comment it out if 8.2GB is too large — Joe's call

### 2. `config/pdf-sources.conf` line ~200 — ARRL emcomm-guide gated
- URL: `https://www.arrl.org/files/file/Public%20Service/emcomm-guide.pdf`
- Returns 9771 bytes of HTML (login-gated). No Wayback Machine archive. Permanently broken.
- Fix: comment out with a note

### 3. `config/pdf-sources.conf` line ~305 — IAEA radiological manual bad URL
- URL: `https://www-pub.iaea.org/MTCD/Publications/PDF/EPR-FirstResponders_web.pdf`
- Downloads ~67KB HTML publications portal page, not a PDF
- Fix: comment out or find a working direct PDF URL before re-enabling

### 4. `config/book-list.conf` line ~110 — princess-of-mars Gutenberg URLs failing
- Both `gutenberg.org/ebooks/36102.epub.images` and `.epub` return errors
- Was failing during the March 23 archive.org outage — may still be transient, re-test
- Causes `survive-books.service` to exit 1 on every hourly run until fixed
- Fix: comment out until confirmed working, or leave and accept the cosmetic exit-1

---

## Transient Issues (no action needed, re-test after next sync)

- **archive.org 503** — March 23 run hit a service outage; caused ~114 PDF `wget failed` errors.
  All those PDFs should download fine once archive.org recovers. Re-run sync to confirm.
- **maps/ME USGS timeout** — Maine timed out (rate limiting). CT worked fine. Re-test.

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

---

## Immediate Next Steps

1. Fix `config/zim-list.conf` — change wiktionary slug (or ask Joe about commenting it out)
2. Fix `config/pdf-sources.conf` — comment out ARRL emcomm-guide with explanation
3. Fix `config/pdf-sources.conf` — comment out or fix IAEA radiological URL
4. Fix `config/book-list.conf` — comment out `princess-of-mars` until Gutenberg URL recovers
5. Commit and push, then deploy: `git pull && sudo bash install.sh`

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
