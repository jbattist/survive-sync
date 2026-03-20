#!/usr/bin/env bash
# update-catalog.sh — scan /srv/offline for new files and append rows to
# library_catalog.csv if they are not already recorded.
#
# Catalog columns (from spec §14):
#   id, title, source_url, local_path, sha256, media_type, category,
#   subcategory, author_org, publication_year, edition, language, region,
#   tags, priority, legal_status, summary
set -euo pipefail

CATALOG="/srv/offline/metadata/library_catalog.csv"
SCAN_DIRS=(
    "/srv/offline/pdfs"
    "/srv/offline/books/epub"
    "/srv/offline/kiwix/zim"
    "/srv/offline/video"
    "/srv/offline/maps/topo"
)

log() { echo "[POSTPROCESS][catalog] $*"; }

mkdir -p "/srv/offline/metadata"

# Write header if catalog doesn't exist
if [[ ! -f "${CATALOG}" ]]; then
    log "Creating catalog with header"
    echo "id,title,source_url,local_path,sha256,media_type,category,subcategory,author_org,publication_year,edition,language,region,tags,priority,legal_status,summary" \
        > "${CATALOG}"
fi

# Load existing paths to avoid duplicates
declare -A KNOWN_PATHS
if [[ -f "${CATALOG}" ]]; then
    while IFS=, read -r id title source_url local_path rest; do
        [[ "${id}" == "id" ]] && continue  # skip header
        KNOWN_PATHS["${local_path}"]="1"
    done < "${CATALOG}"
fi

added=0

# ── infer metadata from file path and name ────────────────────────────────────
infer_metadata() {
    local file="$1"
    local rel_path="${file#/srv/offline/}"
    local basename
    basename=$(basename "${file}")
    local ext="${basename##*.}"
    local stem="${basename%.*}"

    # Generate a deterministic ID from path
    local id
    id=$(echo "${rel_path}" | sha256sum | cut -c1-12)

    # Infer media type
    local media_type
    case "${ext,,}" in
        pdf)    media_type="application/pdf" ;;
        epub)   media_type="application/epub+zip" ;;
        zim)    media_type="application/x-zim" ;;
        mp4|mkv|webm) media_type="video/mp4" ;;
        *)      media_type="application/octet-stream" ;;
    esac

    # Infer category from path
    local category subcategory
    local path_parts
    IFS='/' read -ra path_parts <<< "${rel_path}"
    category="${path_parts[0]:-other}"
    subcategory="${path_parts[1]:-}"

    # Infer from PDF filename convention: category__source__title__year.pdf
    local title source_url author_org pub_year priority
    title="${stem}"
    source_url=""
    author_org=""
    pub_year=""
    priority="P3"

    if [[ "${stem}" =~ ^([0-9]+-[a-z]+)__([a-z]+)__(.+)__([0-9]{4})$ ]]; then
        category="${BASH_REMATCH[1]}"
        author_org="${BASH_REMATCH[2]}"
        title=$(echo "${BASH_REMATCH[3]}" | tr '-' ' ')
        pub_year="${BASH_REMATCH[4]}"
    fi

    # Assign priority by category
    case "${category}" in
        00-start-here|01-medical|02-water) priority="P1" ;;
        03-food|04-agriculture|05-shelter|06-power|07-repair) priority="P2" ;;
    esac

    # Compute SHA-256
    local sha256
    sha256=$(sha256sum "${file}" | awk '{print $1}')

    # Escape commas in title for CSV
    title=$(echo "${title}" | tr ',' ' ')

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,,en,US-NE,%s,%s,open,\n' \
        "${id}" \
        "${title}" \
        "${source_url}" \
        "${rel_path}" \
        "${sha256}" \
        "${media_type}" \
        "${category}" \
        "${subcategory}" \
        "${author_org}" \
        "${pub_year}" \
        "${ext}" \
        "${priority}"
}

# ── scan each directory ───────────────────────────────────────────────────────
for scan_dir in "${SCAN_DIRS[@]}"; do
    [[ -d "${scan_dir}" ]] || continue

    while IFS= read -r -d '' file; do
        rel_path="${file#/srv/offline/}"

        # Skip if already in catalog
        if [[ -n "${KNOWN_PATHS[${rel_path}]:-}" ]]; then
            continue
        fi

        # Skip index files, logs, metadata
        [[ "${file}" =~ /metadata/ ]] && continue
        [[ "${file}" =~ /logs/ ]] && continue
        [[ "${file}" =~ \.txt$ ]] && continue
        [[ "${file}" =~ \.md5$ ]] && continue

        row=$(infer_metadata "${file}" 2>/dev/null) || continue
        echo "${row}" >> "${CATALOG}"
        KNOWN_PATHS["${rel_path}"]="1"
        (( added++ )) || true

    done < <(find "${scan_dir}" -type f -print0 2>/dev/null)
done

log "Catalog updated: ${added} new entries appended (total: $(wc -l < "${CATALOG}") rows)"
