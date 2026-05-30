#!/usr/bin/env bash
# sync-classics.sh — selectively rsync classic movies from TrueNAS NFS share to local storage
#
# Source:      /mnt/media-classics  (NFS ro automount, truenas.home:/mnt/hdd/media-classics)
# Destination: /srv/offline/video/classics/
#
# Hybrid selection model:
# - If RADARR_URL and RADARR_API_KEY are set, refresh a cached manifest from the
#   Radarr tag named by RADARR_SYNC_TAG (default: survive).
# - Sync uses the cached manifest only, so the Pi is not hard-dependent on Radarr
#   being available for every run.
# - The manifest is one relative movie directory per line, e.g.:
#     Casablanca (1942)/
#
# Deselected content is intentionally deleted from DEST_DIR by rsync --delete.
# Run manual/debug invocations as the `library` user; root-owned leftovers in
# DEST_DIR can prevent future `library` syncs from deleting deselected movies.
# Called by sync-all.sh with:
#   sync-classics.sh --log <log_file>
set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────────────
LOG_FILE="/srv/offline/logs/sync-$(date +%Y-%m-%d).log"
CLASSICS_DRY_RUN="${CLASSICS_DRY_RUN:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log) LOG_FILE="$2"; shift 2 ;;
        --dry-run) CLASSICS_DRY_RUN="1"; shift ;;
        *) shift ;;
    esac
done

ENV_FILE="${CLASSICS_ENV_FILE:-/etc/survive-sync/classics.env}"
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
fi

NFS_MOUNT="${CLASSICS_NFS_MOUNT:-/mnt/media-classics}"
DEST_DIR="${CLASSICS_DEST_DIR:-/srv/offline/video/classics}"
METADATA_DIR="${CLASSICS_METADATA_DIR:-/srv/offline/metadata}"
MANIFEST_FILE="${CLASSICS_MANIFEST_FILE:-${METADATA_DIR}/classics-survive-manifest.txt}"
RADARR_SYNC_TAG="${RADARR_SYNC_TAG:-survive}"
CLASSICS_BWLIMIT="${CLASSICS_BWLIMIT:-50000}"

added=0; deleted=0; updated=0; failed=0

log()  { echo "[CLASSICS][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "$(dirname "${LOG_FILE}")" "${DEST_DIR}" "${METADATA_DIR}"

# ── Radarr manifest refresh ───────────────────────────────────────────────────
refresh_manifest_from_radarr() {
    local radarr_url="${RADARR_URL:-}"
    local radarr_api_key="${RADARR_API_KEY:-}"

    if [[ -z "${radarr_url}" || -z "${radarr_api_key}" ]]; then
        return 1
    fi

    radarr_url="${radarr_url%/}"
    local tags_json movies_json new_manifest
    tags_json="$(mktemp "${METADATA_DIR}/radarr-tags.XXXXXX.json")"
    movies_json="$(mktemp "${METADATA_DIR}/radarr-movies.XXXXXX.json")"
    new_manifest="$(mktemp "${METADATA_DIR}/classics-survive-manifest.XXXXXX")"

    cleanup_radarr_tmp() { rm -f "${tags_json}" "${movies_json}" "${new_manifest}"; }
    trap cleanup_radarr_tmp RETURN

    if ! curl -fsS --max-time 30 -H "X-Api-Key: ${radarr_api_key}" \
        "${radarr_url}/api/v3/tag" >"${tags_json}"; then
        log "WARN Radarr tag API unavailable — keeping cached manifest ${MANIFEST_FILE}"
        return 1
    fi

    if ! curl -fsS --max-time 60 -H "X-Api-Key: ${radarr_api_key}" \
        "${radarr_url}/api/v3/movie" >"${movies_json}"; then
        log "WARN Radarr movie API unavailable — keeping cached manifest ${MANIFEST_FILE}"
        return 1
    fi

    if ! python3 - "${tags_json}" "${movies_json}" "${RADARR_SYNC_TAG}" "${NFS_MOUNT}" >"${new_manifest}" <<'PY'
import json
import os
import sys
from pathlib import PurePosixPath

tags_path, movies_path, wanted_label, nfs_mount = sys.argv[1:5]
with open(tags_path, encoding="utf-8") as f:
    tags = json.load(f)
with open(movies_path, encoding="utf-8") as f:
    movies = json.load(f)

wanted_id = None
for tag in tags:
    if str(tag.get("label", "")).lower() == wanted_label.lower():
        wanted_id = tag.get("id")
        break

if wanted_id is None:
    raise SystemExit(f"Radarr tag not found: {wanted_label}")

mount_name = PurePosixPath(nfs_mount).name
selected = []
for movie in movies:
    if wanted_id not in movie.get("tags", []):
        continue

    movie_path = str(movie.get("path") or "").rstrip("/")
    if movie_path:
        # Prefer the path relative to the classics root when paths line up. Fall
        # back to the movie folder basename when Radarr sees a different mount
        # prefix than this Pi does.
        parts = PurePosixPath(movie_path).parts
        if mount_name in parts:
            idx = parts.index(mount_name)
            rel_parts = parts[idx + 1:]
            rel = "/".join(rel_parts) if rel_parts else PurePosixPath(movie_path).name
        else:
            rel = PurePosixPath(movie_path).name
    else:
        title = str(movie.get("title") or "").strip()
        year = movie.get("year")
        rel = f"{title} ({year})" if title and year else title

    rel = rel.strip().strip("/")
    if not rel or rel.startswith("../") or "/../" in rel or rel == "..":
        raise SystemExit(f"Unsafe Radarr movie path resolved to {rel!r}: {movie_path!r}")
    selected.append(rel + "/")

for rel in sorted(set(selected), key=str.casefold):
    print(rel)
PY
    then
        log "WARN Radarr manifest generation failed — keeping cached manifest ${MANIFEST_FILE}"
        return 1
    fi

    mv "${new_manifest}" "${MANIFEST_FILE}"
    trap - RETURN
    rm -f "${tags_json}" "${movies_json}"

    local selected_count
    selected_count=$(wc -l <"${MANIFEST_FILE}" | tr -d ' ')
    log "Refreshed Radarr manifest: ${selected_count} movie(s) tagged ${RADARR_SYNC_TAG}"
    return 0
}

if refresh_manifest_from_radarr; then
    :
elif [[ -s "${MANIFEST_FILE}" ]]; then
    log "Using cached Radarr manifest ${MANIFEST_FILE}"
else
    fail "No Radarr config and no cached manifest at ${MANIFEST_FILE}; refusing to sync/delete classics"
    exit 1
fi

# ── check NFS mount ───────────────────────────────────────────────────────────
if [[ "${CLASSICS_SKIP_MOUNT_CHECK:-0}" != "1" ]]; then
    if ! mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
        log "  ${NFS_MOUNT} not mounted — triggering systemd mount unit..."
        sudo systemctl start mnt-media-classics.mount 2>/dev/null || true
        sleep 2
    fi

    if ! mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
        fail "NFS mount ${NFS_MOUNT} unavailable — skipping classics sync"
        exit 1
    fi
fi

VIDEO_COUNT=$(find "${NFS_MOUNT}" -maxdepth 3 \
    \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" \) \
    2>/dev/null | wc -l)
SELECTED_COUNT=$(grep -cvE '^[[:space:]]*(#|$)' "${MANIFEST_FILE}" || true)
log "NFS mount OK — ${VIDEO_COUNT} video file(s) visible in ${NFS_MOUNT}; ${SELECTED_COUNT} selected for survive"

# ── generate rsync filter from cached manifest ────────────────────────────────
FILTER_FILE="$(mktemp "${METADATA_DIR}/classics-rsync-filter.XXXXXX")"
cleanup_filter() { rm -f "${FILTER_FILE}"; }
trap cleanup_filter EXIT

python3 - "${MANIFEST_FILE}" >"${FILTER_FILE}" <<'PY'
import sys
from pathlib import PurePosixPath

manifest = sys.argv[1]
with open(manifest, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rel = line.strip("/")
        if rel.startswith("../") or "/../" in rel or rel in {"", ".."} or PurePosixPath(rel).is_absolute():
            raise SystemExit(f"Unsafe manifest path: {line!r}")
        # The /*** form includes the selected directory and everything below it.
        # Do NOT include a blanket "+ */" rule: with --delete-excluded it keeps
        # deselected movie directories around as empty shells after deleting files.
        print(f"+ {rel}/***")
print("- *")
PY

# ── rsync ─────────────────────────────────────────────────────────────────────
# --archive        : preserve permissions, timestamps, symlinks, recursive
# --delete         : remove deselected/stale files from the Pi classics mirror
# --no-perms       : don't try to set NFS-side permissions on local dest
# --omit-dir-times : don't fail on directory timestamp updates
# --itemize-changes: one line per file so we can count adds/updates/deletes
# --size-only      : media files are immutable here; avoid recopies when an old
#                    destination file has the same size but a different mtime
log "Syncing selected classics ${NFS_MOUNT} → ${DEST_DIR} ..."

RSYNC_ARGS=(
    --archive
    --size-only
    --delete
    --delete-excluded
    --no-perms
    --omit-dir-times
    --itemize-changes
    --timeout=120
    --filter="merge ${FILTER_FILE}"
)
if [[ "${CLASSICS_BWLIMIT}" != "0" ]]; then
    RSYNC_ARGS+=(--bwlimit="${CLASSICS_BWLIMIT}")
fi
if [[ "${CLASSICS_DRY_RUN}" == "1" ]]; then
    RSYNC_ARGS+=(--dry-run)
    log "DRY RUN enabled — no classics files will be copied or deleted"
fi

sync_output() {
    if command -v rsync >/dev/null 2>&1; then
        rsync "${RSYNC_ARGS[@]}" "${NFS_MOUNT}/" "${DEST_DIR}/" 2>&1
        return
    fi

    # Developer-workstation fallback: keep tests useful even if rsync is not
    # installed locally. The Pi should normally use rsync.
    log "  rsync not found; using Python mirror fallback"
    python3 - "${NFS_MOUNT}" "${DEST_DIR}" "${MANIFEST_FILE}" "${CLASSICS_DRY_RUN}" <<'PY'
import filecmp
import shutil
import sys
from pathlib import Path, PurePosixPath

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
manifest = Path(sys.argv[3])
dry_run = sys.argv[4] == "1"

def safe_rel(raw: str) -> Path:
    rel = raw.strip().strip("/")
    if not rel or rel.startswith("../") or "/../" in rel or PurePosixPath(rel).is_absolute():
        raise SystemExit(f"Unsafe manifest path: {raw!r}")
    return Path(rel)

selected = []
for raw in manifest.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if line and not line.startswith("#"):
        selected.append(safe_rel(line))
selected_set = {str(p).rstrip("/") for p in selected}

# Delete top-level deselected content.
for child in sorted(dest.iterdir() if dest.exists() else [], key=lambda p: str(p).casefold(), reverse=True):
    rel = child.name
    if rel not in selected_set:
        if child.is_dir():
            for path in sorted(child.rglob("*"), key=lambda p: len(p.parts), reverse=True):
                if path.is_file() or path.is_symlink():
                    print(f"*deleting   {path.relative_to(dest).as_posix()}")
                elif path.is_dir():
                    print(f"*deleting   {path.relative_to(dest).as_posix()}/")
            if not dry_run:
                shutil.rmtree(child)
        elif child.exists():
            print(f"*deleting   {child.relative_to(dest).as_posix()}")
            if not dry_run:
                child.unlink()

for rel in selected:
    src_dir = src / rel
    dest_dir = dest / rel
    if not src_dir.exists():
        continue
    if not dry_run:
        dest_dir.mkdir(parents=True, exist_ok=True)

    # Delete stale files inside selected directories.
    for path in sorted(dest_dir.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        counterpart = src_dir / path.relative_to(dest_dir)
        if not counterpart.exists():
            if path.is_file() or path.is_symlink():
                print(f"*deleting   {path.relative_to(dest).as_posix()}")
                if not dry_run:
                    path.unlink()
            elif path.is_dir():
                print(f"*deleting   {path.relative_to(dest).as_posix()}/")
                if not dry_run:
                    shutil.rmtree(path)

    # Copy new/changed files.
    for path in sorted(src_dir.rglob("*"), key=lambda p: str(p).casefold()):
        target = dest_dir / path.relative_to(src_dir)
        if path.is_dir():
            if not dry_run:
                target.mkdir(parents=True, exist_ok=True)
            continue
        if not dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or not filecmp.cmp(path, target, shallow=False):
            if not dry_run:
                shutil.copy2(path, target)
            print(f">f+++++++++ {target.relative_to(dest).as_posix()}")
PY
}

while IFS= read -r line; do
    # itemize format: "YXcstpoguax filename"; delete format: "*deleting   filename"
    if [[ "${line}" =~ ^\*deleting[[:space:]]+(.+) ]]; then
        log "  DEL ${BASH_REMATCH[1]}"
        (( deleted++ )) || true
    elif [[ "${line}" =~ ^\> ]]; then
        fname="${line#* }"
        log "  ADD ${fname}"
        (( added++ )) || true
    elif [[ "${line}" =~ ^\. ]]; then
        :
    elif [[ -n "${line}" ]]; then
        log "  ${line}"
        (( updated++ )) || true
    fi
done < <(sync_output | tee -a "${LOG_FILE}")

log "Done: selected=${SELECTED_COUNT} added=${added} updated=${updated} deleted=${deleted} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
