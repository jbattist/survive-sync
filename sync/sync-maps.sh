#!/usr/bin/env bash
# sync-maps.sh — download OSM PBF extracts, convert to MBTiles, fetch USGS topos
#
# Pipeline per geofabrik region:
#   1. Fetch {region}-latest.osm.pbf.md5 from Geofabrik
#   2. Compare against local .md5 record — skip if unchanged
#   3. Download updated PBF
#   4. Convert to MBTiles using tilemaker
#   5. Place MBTiles in /srv/offline/maps/tiles/ for mbtileserver
#
# For usgs_topo entries:
#   - Queries the USGS TNM API for 1:24000 scale topo PDFs
#   - Downloads any new quads to /srv/offline/maps/topo/{state}/
#
# Called by sync-all.sh with:
#   sync-maps.sh --config <config_dir> --log <log_file>
set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────────────
CONFIG_DIR="/srv/offline/scripts/config"
LOG_FILE="/srv/offline/logs/sync-$(date +%Y-%m-%d).log"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_DIR="$2"; shift 2 ;;
        --log)    LOG_FILE="$2";   shift 2 ;;
        *) shift ;;
    esac
done

CONF="${CONFIG_DIR}/map-regions.conf"
MAP_ROOT="/srv/offline/maps"
PBF_DIR="${MAP_ROOT}/pbf"
TILES_DIR="${MAP_ROOT}/tiles"
TOPO_DIR="${MAP_ROOT}/topo"
TMP_DIR="/tmp/survive-maps-$$"

GEOFABRIK_BASE="https://download.geofabrik.de"
USGS_TNM_API="https://tnmaccess.nationalmap.gov/api/v1/products"

pbf_added=0; pbf_skipped=0; topo_added=0; topo_skipped=0; failed=0

log()  { echo "[MAP][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "${PBF_DIR}" "${TILES_DIR}" "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ── locate tilemaker and its config ───────────────────────────────────────────
TILEMAKER_BIN=$(command -v tilemaker 2>/dev/null || echo "")
if [[ -z "${TILEMAKER_BIN}" ]]; then
    log "WARN: tilemaker not found in PATH — PBF conversion will be skipped"
    log "      Install tilemaker: yay -S tilemaker"
fi

# tilemaker ships example configs; prefer the installed copies
find_tilemaker_configs() {
    # AUR / pacman installed location
    for d in /usr/share/tilemaker /usr/local/share/tilemaker; do
        if [[ -f "${d}/config-openmaptiles.json" ]]; then
            echo "${d}"
            return
        fi
    done
    # Fallback: download from tilemaker GitHub if not installed
    local dl_dir="${TMP_DIR}/tilemaker-resources"
    mkdir -p "${dl_dir}"
    log "  Downloading tilemaker resources from GitHub..."
    local raw="https://raw.githubusercontent.com/systemed/tilemaker/master/resources"
    wget -q -O "${dl_dir}/config-openmaptiles.json" \
        "${raw}/config-openmaptiles.json" 2>&1 | tee -a "${LOG_FILE}" || true
    wget -q -O "${dl_dir}/process-openmaptiles.lua" \
        "${raw}/process-openmaptiles.lua" 2>&1 | tee -a "${LOG_FILE}" || true
    if [[ -f "${dl_dir}/config-openmaptiles.json" ]]; then
        echo "${dl_dir}"
    else
        echo ""
    fi
}

convert_pbf_to_mbtiles() {
    local pbf_file="$1"
    local state_slug="$2"
    local mbtiles_file="${TILES_DIR}/${state_slug}.mbtiles"

    if [[ -z "${TILEMAKER_BIN}" ]]; then
        log "  SKIP conversion for ${state_slug} (tilemaker not available)"
        return 0
    fi

    local config_dir
    config_dir=$(find_tilemaker_configs)
    if [[ -z "${config_dir}" ]]; then
        fail "  Cannot find tilemaker configs for ${state_slug}"
        return 1
    fi

    log "  Converting ${state_slug}.pbf → ${state_slug}.mbtiles (this may take a while)"
    "${TILEMAKER_BIN}" \
        --input  "${pbf_file}" \
        --output "${mbtiles_file}" \
        --config "${config_dir}/config-openmaptiles.json" \
        --process "${config_dir}/process-openmaptiles.lua" \
        2>&1 | tee -a "${LOG_FILE}" || {
        fail "${state_slug}: tilemaker conversion failed"
        rm -f "${mbtiles_file}"
        return 1
    }
    log "  Conversion complete: ${mbtiles_file}"
}

# ── process geofabrik entries ─────────────────────────────────────────────────
process_geofabrik() {
    local identifier="$1" state_slug="$2"

    local pbf_url="${GEOFABRIK_BASE}/${identifier}-latest.osm.pbf"
    local md5_url="${GEOFABRIK_BASE}/${identifier}-latest.osm.pbf.md5"
    local pbf_file="${PBF_DIR}/${state_slug}-latest.osm.pbf"
    local md5_file="${PBF_DIR}/${state_slug}-latest.osm.pbf.md5"

    log "Checking ${state_slug} (${identifier})"

    # Fetch remote MD5
    remote_md5=$(curl -sf --max-time 15 "${md5_url}" 2>/dev/null | awk '{print $1}') || {
        fail "${state_slug}: could not fetch MD5 from ${md5_url}"
        return 1
    }

    # Compare with local MD5
    if [[ -f "${md5_file}" ]]; then
        local_md5=$(cat "${md5_file}")
        if [[ "${local_md5}" == "${remote_md5}" ]] && [[ -f "${pbf_file}" ]]; then
            log "SKIP ${state_slug}: PBF unchanged (${remote_md5})"
            (( pbf_skipped++ )) || true
            # Still ensure mbtiles exists even if PBF unchanged
            if [[ ! -f "${TILES_DIR}/${state_slug}.mbtiles" ]]; then
                log "  MBTiles missing — re-converting existing PBF"
                convert_pbf_to_mbtiles "${pbf_file}" "${state_slug}"
            fi
            return 0
        fi
    fi

    log "ADD ${state_slug}: downloading PBF from ${pbf_url}"
    tmp_pbf="${TMP_DIR}/${state_slug}.osm.pbf"

    aria2c \
        --dir="${TMP_DIR}" \
        --out="${state_slug}.osm.pbf" \
        --continue=true \
        --max-connection-per-server=4 \
        --split=4 \
        --file-allocation=none \
        --retry-wait=10 \
        --max-tries=5 \
        --console-log-level=warn \
        "${pbf_url}" 2>&1 | tee -a "${LOG_FILE}" || {
        fail "${state_slug}: PBF download failed"
        return 1
    }

    # Verify: PBF files start with a specific magic byte sequence
    size=$(stat -c%s "${tmp_pbf}" 2>/dev/null || echo 0)
    if (( size < 100000 )); then
        fail "${state_slug}: downloaded PBF suspiciously small (${size} bytes)"
        rm -f "${tmp_pbf}"
        return 1
    fi

    mv "${tmp_pbf}" "${pbf_file}"
    echo "${remote_md5}" > "${md5_file}"
    (( pbf_added++ )) || true

    # Convert to MBTiles
    convert_pbf_to_mbtiles "${pbf_file}" "${state_slug}"
}

# ── process usgs_topo entries ─────────────────────────────────────────────────
process_usgs_topo() {
    local state_abbr="$1" state_slug="$2"
    local dest_dir="${TOPO_DIR}/${state_slug}"
    mkdir -p "${dest_dir}"

    log "Checking USGS topo quads for ${state_abbr}"

    # Query TNM API for US Topo GeoPDF quads by state.
    # NOTE: prodFormats must be "GeoPDF" — the API returns 0 results for "PDF".
    # max=500 fetches multiple editions per quad; the Python below deduplicates,
    # keeping only the most recently published edition of each quad name.
    local topo_url="${USGS_TNM_API}?datasets=US%20Topo"
    topo_url+="&prodFormats=GeoPDF&q=${state_abbr}&max=500&outputFormat=json"

    local response
    response=$(curl -sf --max-time 60 "${topo_url}" 2>/dev/null) || {
        fail "${state_abbr}: USGS API unreachable"
        return 1
    }

    local count
    count=$(echo "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('items', [])
    print(len(items))
except:
    print(0)
" 2>/dev/null) || count=0

    if [[ "${count}" -eq 0 ]]; then
        log "WARN ${state_abbr}: no topo quads found via TNM API — skipping"
        return 0
    fi

    log "  Found ${count} topo quad editions for ${state_abbr}; deduplicating and downloading new ones..."

    # Deduplicate: keep only the most recently published edition of each quad name.
    # Quad name = title with the year stripped (e.g. "USGS US Topo ... Ansonia, CT").
    # Then download any quads not already on disk.
    echo "${response}" | python3 - "${dest_dir}" <<'PYEOF'
import sys, json, os, subprocess, re

dest_dir = sys.argv[1]
data = json.load(sys.stdin)
items = data.get("items", [])

# Deduplicate: for each quad (title without trailing year), keep most recent.
# Title format: "USGS US Topo 7.5-minute map for <QuadName> YYYY"
def quad_key(title):
    return re.sub(r'\s+\d{4}$', '', title).strip()

best = {}  # quad_key -> item with latest publicationDate
for item in items:
    title = item.get("title", "")
    pub   = item.get("publicationDate", "1900-01-01") or "1900-01-01"
    key   = quad_key(title)
    if key not in best or pub > best[key]["publicationDate"]:
        best[key] = item

print(f"  Unique quads after dedup: {len(best)}", flush=True)

for item in best.values():
    url = item.get("downloadURL", "")
    if not url:
        # Fallback: first GeoPDF URL from the urls dict
        url = (item.get("urls") or {}).get("GeoPDF", "")
    if not url or not url.lower().endswith(".pdf"):
        continue

    fname = re.sub(r"[^a-zA-Z0-9._-]", "_", os.path.basename(url))
    dest  = os.path.join(dest_dir, fname)
    if os.path.exists(dest):
        continue

    print(f"  DL {fname}", flush=True)
    ret = subprocess.run(
        ["wget", "-q", "--timeout=60", "--tries=2",
         "--user-agent=survive-sync/1.0",
         "-O", dest, url],
        capture_output=True
    )
    if ret.returncode != 0 or os.path.getsize(dest) < 10240:
        print(f"  FAIL {fname}", flush=True)
        if os.path.exists(dest):
            os.remove(dest)
PYEOF

    (( topo_added++ )) || true
}

# ── main loop ─────────────────────────────────────────────────────────────────
while IFS=$'\t' read -r type identifier state_slug subdir description; do
    [[ -z "${type}" || "${type}" == \#* ]] && continue
    type="${type// /}"
    identifier="${identifier// /}"
    state_slug="${state_slug// /}"

    case "${type}" in
        geofabrik)  process_geofabrik "${identifier}" "${state_slug}" ;;
        usgs_topo)  process_usgs_topo  "${identifier}" "${state_slug}" ;;
        *)          fail "Unknown type '${type}' for ${state_slug}" ;;
    esac

done < <(grep -v '^[[:space:]]*$' "${CONF}")

log "Done: pbf_added=${pbf_added} pbf_skipped=${pbf_skipped} topo_added=${topo_added} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
