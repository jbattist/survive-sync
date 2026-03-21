#!/usr/bin/env bash
# rebuild-indexes.sh — regenerate the three markdown index files from the catalog
#
# Outputs:
#   /srv/offline/indexes/top-25-essential.md   — P1 items only
#   /srv/offline/indexes/top-100-phone-first.md — P1+P2, mobile-formatted
#   /srv/offline/indexes/print-first-binder.md  — P1, formatted for printing
set -euo pipefail

CATALOG="/srv/offline/metadata/library_catalog.csv"
INDEX_DIR="/srv/offline/indexes"

log() { echo "[POSTPROCESS][indexes] $*"; }

mkdir -p "${INDEX_DIR}"

if [[ ! -f "${CATALOG}" ]]; then
    log "WARN: catalog not found at ${CATALOG} — skipping index rebuild"
    exit 0
fi

# ── shared helper: render a markdown table from catalog rows ──────────────────
build_index() {
    local out_file="$1"
    local title="$2"
    local description="$3"
    local priority_filter="$4"   # P1 | P1|P2 | all
    local max_rows="${5:-9999}"

    python3 - "${CATALOG}" "${out_file}" "${title}" "${description}" \
        "${priority_filter}" "${max_rows}" <<'PYEOF'
import sys, csv, os

catalog_file, out_file, title, description, priority_filter, max_rows = sys.argv[1:]
max_rows = int(max_rows)

priorities = set(priority_filter.split("|"))

rows = []
try:
    with open(catalog_file, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if "all" in priorities or row.get("priority", "P3") in priorities:
                rows.append(row)
except Exception as e:
    print(f"[indexes] ERROR reading catalog: {e}", file=sys.stderr)
    sys.exit(1)

# Sort: priority P1 first, then category, then title
priority_order = {"P1": 0, "P2": 1, "P3": 2}
rows.sort(key=lambda r: (
    priority_order.get(r.get("priority","P3"), 2),
    r.get("category",""),
    r.get("title","")
))
rows = rows[:max_rows]

with open(out_file, "w", encoding="utf-8") as f:
    f.write(f"# {title}\n\n")
    f.write(f"{description}\n\n")
    f.write(f"_Generated: {__import__('datetime').date.today()}_  \n")
    f.write(f"_Entries: {len(rows)}_\n\n")
    f.write("---\n\n")

    current_category = None
    for row in rows:
        cat = row.get("category", "other")
        if cat != current_category:
            current_category = cat
            f.write(f"\n## {cat}\n\n")

        path = row.get("local_path", "")
        title_text = row.get("title", path)
        priority = row.get("priority", "")
        author = row.get("author_org", "")
        year = row.get("publication_year", "")
        summary = row.get("summary", "")
        media = row.get("media_type", "").split("/")[-1]

        meta_parts = [x for x in [author, year, media, priority] if x]
        meta = " · ".join(meta_parts)

        f.write(f"- **{title_text}**")
        if meta:
            f.write(f"  `{meta}`")
        if summary:
            f.write(f"  \n  _{summary}_")
        if path:
            f.write(f"  \n  `{path}`")
        f.write("\n")

print(f"[indexes] Wrote {len(rows)} entries to {out_file}")
PYEOF
}

# ── top-25-essential.md ───────────────────────────────────────────────────────
build_index \
    "${INDEX_DIR}/top-25-essential.md" \
    "Top 25 Essential Resources" \
    "P1 priority items — lifesaving and critical. These should be the first items reviewed, printed, or accessed in an emergency." \
    "P1" \
    25

# ── top-100-phone-first.md ────────────────────────────────────────────────────
build_index \
    "${INDEX_DIR}/top-100-phone-first.md" \
    "Top 100 Resources — Phone First" \
    "P1 and P2 priority items. This index is formatted for quick reference on a mobile phone. Open links from the portal at http://survive.travel" \
    "P1|P2" \
    100

# ── print-first-binder.md ─────────────────────────────────────────────────────
build_index \
    "${INDEX_DIR}/print-first-binder.md" \
    "Print-First Binder Index" \
    "P1 priority items to print and keep in the physical binder with the device. These are the documents that matter most when power or screens are unavailable." \
    "P1"

log "Index rebuild complete:"
log "  $(wc -l < "${INDEX_DIR}/top-25-essential.md") lines  → top-25-essential.md"
log "  $(wc -l < "${INDEX_DIR}/top-100-phone-first.md") lines → top-100-phone-first.md"
log "  $(wc -l < "${INDEX_DIR}/print-first-binder.md") lines → print-first-binder.md"
