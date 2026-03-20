#!/usr/bin/env bash
# /etc/profile.d/survive-welcome.sh
# Installed by install.sh — shown at every login shell (SSH, TTY).
# Does NOT modify any user config files.

_svc() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null)
    case "$s" in
        active)   printf '\033[0;32mup\033[0m' ;;
        inactive) printf '\033[1;33mdown\033[0m' ;;
        failed)   printf '\033[0;31mfailed\033[0m' ;;
        *)        printf '%s' "$s" ;;
    esac
}

cat <<EOF

  ┌─────────────────────────────────────────────────────┐
  │            SURVIVE — Offline Library                │
  ├─────────────────────────────────────────────────────┤
  │  Portal     http://survive/             caddy:           $(_svc caddy)
  │  Wikipedia  http://survive:8080/        kiwix:           $(_svc kiwix)
  │  Books      http://survive:8081/        calibre-server:  $(_svc calibre-server)
  │  Maps       http://survive:8082/        mbtileserver:    $(_svc mbtileserver)
  ├─────────────────────────────────────────────────────┤
  │  Sync:    sudo systemctl start survive-sync
  │  Log:     journalctl -u survive-sync -f
  │  Status:  systemctl status kiwix calibre-server mbtileserver caddy
  └─────────────────────────────────────────────────────┘

EOF
