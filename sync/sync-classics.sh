#!/usr/bin/env bash
# sync-classics.sh — rsync classic movies from TrueNAS NFS share to local storage
#
# Source:      /mnt/media-classics  (NFS ro automount, truenas.home:/mnt/hdd/media-classics)
# Destination: /srv/offline/video/classics/
#
# Folder structure is preserved exactly as it exists on the NAS.
# Already-present files are skipped (rsync --ignore-existing).
# Deletions on the NAS are NOT propagated — files stay on the Pi until manually removed.
#
# Called by sync-all.sh with:
#   sync-classics.sh --log <log_file>
set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────────────
LOG_FILE="/srv/offline/logs/sync-$(date +%Y-%m-%d).log"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log) LOG_FILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

NFS_MOUNT="/mnt/media-classics"
DEST_DIR="/srv/offline/video/classics"

added=0; skipped=0; failed=0

log()  { echo "[CLASSICS][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "${DEST_DIR}"

# ── check NFS mount ───────────────────────────────────────────────────────────
if ! mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
    log "  ${NFS_MOUNT} not mounted — triggering systemd mount unit..."
    sudo systemctl start mnt-media-classics.mount 2>/dev/null || true
    sleep 2
fi

if ! mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
    fail "NFS mount ${NFS_MOUNT} unavailable — skipping classics sync"
    exit 1
fi

VIDEO_COUNT=$(find "${NFS_MOUNT}" -maxdepth 3 \
    \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" \) \
    2>/dev/null | wc -l)
log "NFS mount OK — ${VIDEO_COUNT} video file(s) visible in ${NFS_MOUNT}"

# ── rsync ─────────────────────────────────────────────────────────────────────
# --archive        : preserve permissions, timestamps, symlinks, recursive
# --ignore-existing: never overwrite files already on the Pi
# --no-perms       : don't try to set NFS-side permissions on local dest
# --omit-dir-times : don't fail on directory timestamp updates
# --itemize-changes: one line per file so we can count adds
log "Syncing ${NFS_MOUNT} → ${DEST_DIR} ..."

while IFS= read -r line; do
    # itemize format: "YXcstpoguax filename"
    # Lines starting with '>' are received files (new copies)
    if [[ "${line}" =~ ^\> ]]; then
        fname="${line#* }"   # strip the flags prefix
        log "  ADD ${fname}"
        (( added++ )) || true
    fi
done < <(rsync \
    --archive \
    --ignore-existing \
    --no-perms \
    --omit-dir-times \
    --itemize-changes \
    --timeout=60 \
    "${NFS_MOUNT}/" "${DEST_DIR}/" \
    2>&1 | tee -a "${LOG_FILE}")

log "Done: added=${added} skipped_existing=$(( VIDEO_COUNT - added )) failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
