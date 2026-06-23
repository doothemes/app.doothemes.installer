#!/usr/bin/env bash
# ============================================================================
# update.sh — Actualiza la instalación al último release del repo privado.
#
# Replica la semántica de UpdateService de la app: baja el zipball del último
# release y lo copia SOBRE la instalación PRESERVANDO el estado local
# (.env, writable/, vendor/, .git). Luego corre composer y las migraciones.
#
# Antes de tocar nada hace un respaldo del código en /var/backups.
#
#   sudo ./update.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu
load_conf
apply_defaults

[ -d "$APP_DIR" ] || die "No existe ${APP_DIR}. ¿Ya corriste install.sh?"

# Deploy por git: la actualización por zip podría pisar el working tree.
if [ -d "${APP_DIR}/.git" ]; then
    die "Se detectó ${APP_DIR}/.git (deploy por git). Actualiza con 'git checkout <tag>', no por zip."
fi

prompt_if_empty GITHUB_TOKEN "GitHub token (lectura del repo ${GITHUB_REPO})" secret
[ -n "${GITHUB_TOKEN:-}" ] || die "Se requiere un token de GitHub."

# --- Descarga ---------------------------------------------------------------
step "Descargando el último release"
TMP_ZIP="$(mktemp --suffix=.zip)"
TMP_EXTRACT="$(mktemp -d)"
trap 'rm -rf "$TMP_ZIP" "$TMP_EXTRACT"' EXIT

RELEASE_TAG="$(download_latest_release "$GITHUB_REPO" "$GITHUB_TOKEN" "$TMP_ZIP")" \
    || die "No se pudo descargar el release."
SRC_DIR="$(extract_release "$TMP_ZIP" "$TMP_EXTRACT")"
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || die "No se halló la carpeta raíz del release."
ok "Release ${RELEASE_TAG:-?} listo para aplicar."

# --- Respaldo ---------------------------------------------------------------
step "Respaldo previo"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/app.doothemes-${STAMP}.tar.gz"
mkdir -p /var/backups
log "Empaquetando código actual (sin vendor/) en ${BACKUP}…"
tar --exclude='./vendor' -czf "$BACKUP" -C "$APP_DIR" . \
    && ok "Respaldo creado: ${BACKUP}" \
    || warn "No se pudo crear el respaldo; continúo bajo tu criterio."

# --- Aplicar (overlay preservando estado) -----------------------------------
step "Aplicando archivos"
log "Copiando sobre ${APP_DIR} (preservo .env, writable/, vendor/, .git)…"
rsync -a \
    --exclude='.env' \
    --exclude='writable/' \
    --exclude='vendor/' \
    --exclude='.git/' \
    "$SRC_DIR"/ "$APP_DIR"/
ok "Archivos aplicados."

log "Actualizando dependencias PHP…"
( cd "$APP_DIR" && sudo -u "$APP_USER" -H \
    composer install --no-dev --optimize-autoloader --no-interaction --quiet ) \
    || die "Falló composer install."

fix_permissions "$APP_DIR" "$APP_USER"

# --- Migraciones ------------------------------------------------------------
# Solo si la app ya está instalada (.env presente); un release puede traer
# migraciones nuevas que hay que aplicar al esquema existente.
if [ -f "${APP_DIR}/.env" ]; then
    step "Migraciones"
    log "Ejecutando php spark migrate…"
    ( cd "$APP_DIR" && sudo -u "$APP_USER" -H php spark migrate --all ) \
        || warn "Las migraciones fallaron; revisa manualmente (php spark migrate)."
else
    warn "Sin .env: la app aún no está instalada (no se migra). Abre /install."
fi

# --- Reinicio ---------------------------------------------------------------
step "Reiniciando servicios"
systemctl reload "${PHP_FPM_SVC}" 2>/dev/null || systemctl restart "${PHP_FPM_SVC}"
systemctl reload caddy 2>/dev/null || systemctl restart caddy
ok "Servicios recargados."

printf '\n%s%sActualización completada → %s%s\n' "$C_BOLD" "$C_GREEN" "${RELEASE_TAG:-?}" "$C_RESET"
printf '  Respaldo: %s\n' "$BACKUP"
