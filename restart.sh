#!/usr/bin/env bash
# ============================================================================
# restart.sh — Reinicia (o recarga) los servicios de la plataforma.
#
#   sudo ./restart.sh           # reinicia php-fpm, caddy y mariadb
#   sudo ./restart.sh reload    # recarga sin cortar conexiones (php-fpm + caddy)
#   sudo ./restart.sh status    # solo muestra el estado
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
load_conf
apply_defaults

ACTION="${1:-restart}"
SERVICES=("${PHP_FPM_SVC}" caddy mariadb)

case "$ACTION" in
    restart)
        step "Reiniciando servicios"
        # Valida el Caddyfile antes para no quedar caído por un config roto.
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
        for svc in "${SERVICES[@]}"; do
            log "restart ${svc}…"
            systemctl restart "$svc" && ok "${svc} reiniciado." || err "${svc} falló."
        done
        ;;
    reload)
        step "Recargando servicios (sin cortar conexiones)"
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
        systemctl reload "${PHP_FPM_SVC}" && ok "${PHP_FPM_SVC} recargado."
        systemctl reload caddy && ok "caddy recargado."
        log "mariadb no se recarga (sin cambios de config)."
        ;;
    status)
        : ;;
    *)
        die "Acción desconocida: '${ACTION}'. Usa: restart | reload | status."
        ;;
esac

step "Estado"
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        ok "${svc}: $(systemctl is-active "$svc")"
    else
        err "${svc}: $(systemctl is-active "$svc" || true)"
    fi
done
