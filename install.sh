#!/usr/bin/env bash
# install.sh — deploy survive-sync to the field node (Raspberry Pi 5 / EndeavourOS ARM)
#
# Run this script on the Pi after cloning or copying the survive-sync directory:
#
#   git clone <repo> ~/survive-sync
#   cd ~/survive-sync
#   sudo bash install.sh
#
# Or copy the directory over SSH and run:
#   rsync -av survive-sync/ pi@survive:~/survive-sync/
#   ssh pi@survive 'cd ~/survive-sync && sudo bash install.sh'
#
# What this script does:
#   1.  Checks dependencies; installs tilemaker, mbtileserver, yt-dlp if missing
#   2.  Creates all required directories under /srv/offline
#   3.  Copies scripts, configs, and portal assets to /srv/offline
#   4.  Downloads MapLibre GL JS and OpenMapTiles fonts for offline map viewer
#   5.  Installs systemd units for mbtileserver, survive-sync.service/.timer
#   6.  Patches /etc/caddy/Caddyfile to add map tile and download routes
#   7.  Patches /etc/nftables.conf to allow port 8082 (mbtileserver)
#   8.  Reloads services
#
# Idempotent — safe to re-run after updates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[install]${NC} $*"; }
warn()  { echo -e "${YELLOW}[install WARN]${NC} $*"; }
error() { echo -e "${RED}[install ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── root check ────────────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || die "Run with sudo: sudo bash install.sh"

# ── target paths ──────────────────────────────────────────────────────────────
OFFLINE_ROOT="/srv/offline"
SCRIPTS_DST="${OFFLINE_ROOT}/scripts"
PORTAL_DST="${OFFLINE_ROOT}/portal"
MAPS_TILES_DIR="${OFFLINE_ROOT}/maps/tiles"
# MAPS_DL_DIR: same as MAPS_TILES_DIR — Caddy's /maps/download/ route serves .mbtiles from here
FONTS_DIR="${PORTAL_DST}/maps/fonts"
SYSTEMD_DIR="/etc/systemd/system"
CADDY_CONF="/etc/caddy/Caddyfile"
NFTABLES_CONF="/etc/nftables.conf"

# ── step 1: check / install extra packages ────────────────────────────────────
info "Step 1: Checking extra dependencies"

install_aur_pkg() {
    local pkg="$1"
    if pacman -Qi "${pkg}" &>/dev/null; then
        info "  ${pkg}: already installed"
        return
    fi
    warn "  ${pkg}: not installed — attempting AUR install via yay/paru"
    if command -v yay &>/dev/null; then
        sudo -u "${SUDO_USER:-nobody}" yay -S --noconfirm "${pkg}" || \
            warn "  yay install failed for ${pkg} — install manually: yay -S ${pkg}"
    elif command -v paru &>/dev/null; then
        sudo -u "${SUDO_USER:-nobody}" paru -S --noconfirm "${pkg}" || \
            warn "  paru install failed for ${pkg} — install manually: paru -S ${pkg}"
    else
        warn "  No AUR helper found.  Install ${pkg} manually:"
        warn "    yay -S ${pkg}   OR   paru -S ${pkg}"
    fi
}

# tilemaker — converts OSM PBF to MBTiles
install_aur_pkg tilemaker

# mbtileserver — serves MBTiles over HTTP
if ! command -v mbtileserver &>/dev/null; then
    # Try AUR first
    install_aur_pkg mbtileserver
    # Fallback: install via Go if available
    if ! command -v mbtileserver &>/dev/null && command -v go &>/dev/null; then
        info "  Installing mbtileserver via go install..."
        GOPATH=/usr/local go install github.com/consbio/mbtileserver@latest || \
            warn "  go install failed — install mbtileserver manually"
        # Symlink to /usr/bin if installed to /usr/local/bin
        [[ -f /usr/local/bin/mbtileserver ]] && \
            ln -sf /usr/local/bin/mbtileserver /usr/bin/mbtileserver || true
    fi
else
    info "  mbtileserver: already installed"
fi

# yt-dlp — video downloader
if ! command -v yt-dlp &>/dev/null; then
    info "  Installing yt-dlp..."
    if pacman -Qi yt-dlp &>/dev/null; then
        info "  yt-dlp: already installed via pacman"
    else
        # Try pacman community/extra repo first
        pacman -S --noconfirm yt-dlp 2>/dev/null || true
        # Fallback: pip install
        if ! command -v yt-dlp &>/dev/null; then
            pip install --break-system-packages -q yt-dlp || \
                warn "  yt-dlp install failed — install manually: sudo pacman -S yt-dlp"
        fi
    fi
else
    info "  yt-dlp: already installed ($(yt-dlp --version 2>/dev/null || echo unknown))"
fi

# ── step 2: create directory structure ────────────────────────────────────────
info "Step 2: Creating directory structure under ${OFFLINE_ROOT}"

# Ensure library user exists (spec §6)
if ! id library &>/dev/null; then
    useradd -r -m -d /var/lib/library -s /usr/bin/nologin library
    info "  Created system user: library"
else
    info "  User library: exists"
fi

dirs=(
    "${OFFLINE_ROOT}/portal/splash"
    "${OFFLINE_ROOT}/kiwix/zim"
    "${OFFLINE_ROOT}/pdfs/00-start-here"
    "${OFFLINE_ROOT}/pdfs/01-medical"
    "${OFFLINE_ROOT}/pdfs/02-water"
    "${OFFLINE_ROOT}/pdfs/03-food"
    "${OFFLINE_ROOT}/pdfs/04-agriculture"
    "${OFFLINE_ROOT}/pdfs/05-shelter"
    "${OFFLINE_ROOT}/pdfs/06-power"
    "${OFFLINE_ROOT}/pdfs/07-repair"
    "${OFFLINE_ROOT}/pdfs/08-comms"
    "${OFFLINE_ROOT}/pdfs/09-navigation"
    "${OFFLINE_ROOT}/pdfs/10-security"
    "${OFFLINE_ROOT}/pdfs/11-reference"
    "${OFFLINE_ROOT}/pdfs/12-technology"
    "${OFFLINE_ROOT}/books/epub"
    "${OFFLINE_ROOT}/books/calibre-library"
    "${OFFLINE_ROOT}/maps/tiles"
    "${OFFLINE_ROOT}/maps/pbf"
    "${OFFLINE_ROOT}/maps/topo"
    "${OFFLINE_ROOT}/maps/printable"
    "${OFFLINE_ROOT}/maps/geojson"
    "${OFFLINE_ROOT}/video/first-aid"
    "${OFFLINE_ROOT}/video/repair"
    "${OFFLINE_ROOT}/video/power"
    "${OFFLINE_ROOT}/video/food"
    "${OFFLINE_ROOT}/video/morale"
    "${OFFLINE_ROOT}/indexes"
    "${OFFLINE_ROOT}/metadata"
    "${OFFLINE_ROOT}/scripts/sync"
    "${OFFLINE_ROOT}/scripts/config"
    "${OFFLINE_ROOT}/scripts/postprocess"
    "${OFFLINE_ROOT}/scripts/admin"
    "${OFFLINE_ROOT}/logs"
    "${OFFLINE_ROOT}/incoming"
    "${OFFLINE_ROOT}/staging"
    "${OFFLINE_ROOT}/releases"
    "${FONTS_DIR}"
    "${PORTAL_DST}/maps"
)

for d in "${dirs[@]}"; do
    mkdir -p "${d}"
done
info "  Directories: OK"

# ── step 3: copy scripts and configs ──────────────────────────────────────────
info "Step 3: Copying scripts and configs"

cp -r "${SCRIPT_DIR}/sync/."        "${SCRIPTS_DST}/sync/"
cp -r "${SCRIPT_DIR}/config/."      "${SCRIPTS_DST}/config/"
cp -r "${SCRIPT_DIR}/postprocess/." "${SCRIPTS_DST}/postprocess/"

# Also copy existing spec admin scripts if present in the repo
if [[ -d "${SCRIPT_DIR}/admin" ]]; then
    cp -r "${SCRIPT_DIR}/admin/." "${SCRIPTS_DST}/admin/"
fi

chmod +x "${SCRIPTS_DST}/sync/"*.sh
chmod +x "${SCRIPTS_DST}/postprocess/"*.sh
[[ -d "${SCRIPTS_DST}/admin" ]] && chmod +x "${SCRIPTS_DST}/admin/"*.sh || true

# Copy portal maps viewer
cp -r "${SCRIPT_DIR}/portal/." "${PORTAL_DST}/"

info "  Scripts and portal assets: OK"

# ── step 4: download MapLibre GL JS (offline dependency) ─────────────────────
info "Step 4: Downloading MapLibre GL JS for offline map viewer"

MAPLIBRE_JS="${PORTAL_DST}/maps/maplibre-gl.js"
MAPLIBRE_CSS="${PORTAL_DST}/maps/maplibre-gl.css"

if [[ -f "${MAPLIBRE_JS}" ]] && [[ -s "${MAPLIBRE_JS}" ]]; then
    info "  MapLibre GL JS: already present"
else
    info "  Fetching latest MapLibre GL JS release..."
    ML_VERSION=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/maplibre/maplibre-gl-js/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" \
        2>/dev/null) || ML_VERSION="4.5.2"
    info "  MapLibre GL JS version: ${ML_VERSION}"

    ML_BASE="https://github.com/maplibre/maplibre-gl-js/releases/download/v${ML_VERSION}"
    curl -L --max-time 120 -o "${MAPLIBRE_JS}"  "${ML_BASE}/maplibre-gl.js"  || \
        warn "  Failed to download maplibre-gl.js — map viewer requires manual install"
    curl -L --max-time 30  -o "${MAPLIBRE_CSS}" "${ML_BASE}/maplibre-gl.css" || \
        warn "  Failed to download maplibre-gl.css"
fi

# ── step 5: download OpenMapTiles fonts for map labels ────────────────────────
info "Step 5: Downloading OpenMapTiles fonts for offline map labels"

# Check if fonts are already installed (look for any .pbf glyph file)
if find "${FONTS_DIR}" -name "*.pbf" -print -quit 2>/dev/null | grep -q .; then
    info "  Fonts: already present"
else
    info "  Fetching OpenMapTiles fonts..."
    # Try the GitHub release package (pre-built PBF glyphs)
    FONTS_VERSION="3.0"
    FONTS_URL="https://github.com/openmaptiles/fonts/releases/download/v${FONTS_VERSION}/v${FONTS_VERSION}.zip"
    FONTS_TMP="/tmp/omtfonts-$$.zip"

    if curl -L --max-time 300 -o "${FONTS_TMP}" "${FONTS_URL}" 2>/dev/null; then
        info "  Extracting fonts..."
        unzip -q -o "${FONTS_TMP}" -d "${FONTS_DIR}/"
        rm -f "${FONTS_TMP}"
        font_count=$(find "${FONTS_DIR}" -name "*.pbf" | wc -l)
        info "  Fonts installed: ${font_count} glyph files"
    else
        warn "  Fonts download failed.  Map labels will not render."
        warn "  To fix later: download https://github.com/openmaptiles/fonts/releases"
        warn "  and extract to ${FONTS_DIR}/"
    fi
fi

# ── step 6: install systemd units ─────────────────────────────────────────────
info "Step 6: Installing systemd units"

cp "${SCRIPT_DIR}/systemd/mbtileserver.service"  "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/survive-sync.service"  "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/survive-sync.timer"    "${SYSTEMD_DIR}/"

systemctl daemon-reload

systemctl enable --now mbtileserver.service && \
    info "  mbtileserver.service: enabled and started" || \
    warn "  mbtileserver.service: enable failed (check: systemctl status mbtileserver)"

systemctl enable survive-sync.timer && \
    info "  survive-sync.timer: enabled" || \
    warn "  survive-sync.timer: enable failed"

# Start the timer (does not start the service immediately)
systemctl start survive-sync.timer 2>/dev/null || true

info "  Systemd units: OK"
info "  Next sync: $(systemctl show survive-sync.timer --property=NextElapseUSecRealtime 2>/dev/null | cut -d= -f2 || echo unknown)"
info "  Manual trigger: systemctl start survive-sync.service"

# ── step 7: patch Caddyfile ───────────────────────────────────────────────────
info "Step 7: Patching Caddy config"

if [[ ! -f "${CADDY_CONF}" ]]; then
    warn "  ${CADDY_CONF} not found — skipping Caddy patch"
    warn "  Add these routes manually to your Caddyfile:"
    cat <<'CADDY_SNIPPET'
    handle /maps/tiles/* {
        uri strip_prefix /maps/tiles
        reverse_proxy 127.0.0.1:8082
    }
    handle /maps/download/* {
        root * /srv/offline/maps/tiles
        uri strip_prefix /maps/download
        file_server
    }
CADDY_SNIPPET
else
    # Check if already patched
    if grep -q 'maps/tiles' "${CADDY_CONF}"; then
        info "  Caddyfile: already patched"
    else
        info "  Patching Caddyfile..."
        # Create backup
        cp "${CADDY_CONF}" "${CADDY_CONF}.bak-$(date +%Y%m%d%H%M%S)"

        # Insert the two new handle blocks before the closing file_server line
        # Uses a Python script for reliable insertion (no fragile sed multi-line)
        python3 - "${CADDY_CONF}" <<'PYEOF'
import sys

conf_file = sys.argv[1]
with open(conf_file) as f:
    content = f.read()

new_blocks = """
    handle /maps/tiles/* {
        uri strip_prefix /maps/tiles
        reverse_proxy 127.0.0.1:8082
    }

    handle /maps/download/* {
        root * /srv/offline/maps/tiles
        uri strip_prefix /maps/download
        file_server
    }

"""

# Insert before the bare `root * /srv/offline/portal` line
marker = "root * /srv/offline/portal"
if marker in content:
    content = content.replace(marker, new_blocks + "    " + marker, 1)
    with open(conf_file, "w") as f:
        f.write(content)
    print("Caddyfile patched successfully")
else:
    print(f"WARNING: Could not find insertion point '{marker}' in Caddyfile")
    print("Add the following blocks manually before 'root * /srv/offline/portal':")
    print(new_blocks)
PYEOF

        # Validate and reload
        if caddy validate --config "${CADDY_CONF}" &>/dev/null; then
            systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || \
                warn "  Caddy reload failed — restart manually: systemctl restart caddy"
            info "  Caddyfile: patched and reloaded"
        else
            warn "  Caddyfile validation failed — restoring backup"
            latest_backup=$(ls -t "${CADDY_CONF}".bak-* 2>/dev/null | head -1)
            [[ -n "${latest_backup}" ]] && cp "${latest_backup}" "${CADDY_CONF}"
            warn "  Review ${CADDY_CONF} and add map routes manually"
        fi
    fi
fi

# ── step 8: patch nftables ────────────────────────────────────────────────────
info "Step 8: Patching nftables for port 8082"

if [[ ! -f "${NFTABLES_CONF}" ]]; then
    warn "  ${NFTABLES_CONF} not found — skipping nftables patch"
    warn "  Add port 8082 to your firewall rules manually"
else
    if grep -q '8082' "${NFTABLES_CONF}"; then
        info "  nftables: port 8082 already present"
    else
        info "  Adding port 8082 to nftables allow list..."
        cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak-$(date +%Y%m%d%H%M%S)"

        # Use Python for reliable multi-pattern nftables editing
        python3 - "${NFTABLES_CONF}" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Pattern 1: already has a tcp dport list — append 8082 after the last port number
# e.g.  tcp dport { 22, 80, 443, 8080, 8081 } accept
def add_to_dport_list(m):
    inner = m.group(1)
    ports = [p.strip() for p in inner.split(',')]
    if '8082' not in ports:
        ports.append('8082')
    return 'tcp dport { ' + ', '.join(ports) + ' } accept'

new_content, n = re.subn(
    r'tcp dport \{([^}]+)\} accept',
    add_to_dport_list,
    content
)

if n > 0:
    with open(path, 'w') as f:
        f.write(new_content)
    print(f"nftables: added port 8082 to existing tcp dport list ({n} match(es))")
else:
    # No existing dport list found — warn but don't error
    print("WARNING: could not find 'tcp dport { ... } accept' in nftables config")
    print("Add the following rule manually:")
    print("  tcp dport 8082 accept")
PYEOF

        if systemctl is-active --quiet nftables 2>/dev/null; then
            nft -f "${NFTABLES_CONF}" && info "  nftables: reloaded with port 8082" || \
                warn "  nftables reload failed — reload manually: nft -f ${NFTABLES_CONF}"
        else
            info "  nftables: config updated (service not active — will apply on next start)"
        fi
    fi
fi

# ── step 9: ownership ─────────────────────────────────────────────────────────
info "Step 9: Setting ownership"
chown -R library:library "${OFFLINE_ROOT}"
info "  ${OFFLINE_ROOT}: owned by library:library"

# ── step 10: allow library user to restart services via sudo ─────────────────
info "Step 10: Configuring sudo for service restarts"

SUDOERS_FILE="/etc/sudoers.d/survive-sync"
cat > "${SUDOERS_FILE}" <<'SUDOERS'
# Allow the library user to restart content services after a sync
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart kiwix.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart calibre-server.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart caddy.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart mbtileserver.service
SUDOERS
chmod 0440 "${SUDOERS_FILE}"
info "  Sudoers: ${SUDOERS_FILE}"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  survive-sync install complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "Scripts installed to:  ${SCRIPTS_DST}"
echo "Portal assets:         ${PORTAL_DST}/maps/"
echo "Map tiles directory:   ${MAPS_TILES_DIR}"
echo "Fonts directory:       ${FONTS_DIR}"
echo ""
echo "Systemd units installed:"
echo "  mbtileserver.service  (running now on port 8082)"
echo "  survive-sync.service  (oneshot — runs sync-all.sh)"
echo "  survive-sync.timer    (weekly, Sunday 02:00)"
echo ""
echo "Run a sync manually:"
echo "  systemctl start survive-sync.service"
echo "  journalctl -u survive-sync -f"
echo ""
echo "Or run individual modules:"
echo "  SYNC_MODULES='pdfs books' systemctl start survive-sync.service"
echo ""
echo "Map viewer: http://192.168.50.1/maps/"
echo ""
echo "Next steps:"
echo "  1. Ensure Pi is in sync mode (ethernet/wifi connected to internet)"
echo "  2. Run: systemctl start survive-sync.service"
echo "  3. Monitor: journalctl -u survive-sync -f"
echo "  4. Wikipedia ZIM is ~100 GB — first sync will take hours"
echo ""
