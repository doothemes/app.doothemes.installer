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
# Como root (el overlay dejó archivos de root) con HOME de caché escribible;
# fix_permissions luego deja todo, incluido vendor/, como $APP_USER.
( cd "$APP_DIR" \
    && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_HOME=/tmp/composer-doothemes \
       composer install --no-dev --optimize-autoloader --no-interaction --no-progress ) \
    || die "Falló composer install (revisa el detalle de composer arriba)."

fix_permissions "$APP_DIR" "$APP_USER"

# --- Respaldo de BD + Migraciones -------------------------------------------
# Solo si la app ya está instalada (.env presente); un release puede traer
# migraciones nuevas. Como son hacia adelante, antes se respalda la BD.
if [ -f "${APP_DIR}/.env" ]; then
    step "Respaldo de base de datos"
    # Nombre real de la BD desde el .env de la app; fallback al de installer.conf.
    DBN="$(grep -E '^database\.default\.database' "${APP_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "')"
    DBN="${DBN:-$DB_NAME}"
    BACKUP_DB="/var/backups/doothemes-db-${STAMP}.sql.gz"
    log "Volcando la BD '${DBN}' a ${BACKUP_DB}…"
    # root usa auth por socket → mysqldump sin contraseña.
    if mysqldump --single-transaction --quick "$DBN" 2>/dev/null | gzip > "$BACKUP_DB"; then
        ok "Respaldo de BD creado."
    else
        rm -f "$BACKUP_DB"
        warn "No se pudo respaldar la BD; continúo bajo tu criterio."
    fi

    step "Migraciones"
    log "Aplicando migraciones…"
    ( cd "$APP_DIR" && sudo -u "$APP_USER" -H php spark migrate --all ) \
        || warn "Migraciones fallaron. Restaura la BD con: gunzip -c ${BACKUP_DB} | mysql ${DBN}"
else
    warn "Sin .env: la app aún no está instalada (no se migra). Abre /install."
fi

# Prune: conserva los 10 respaldos más recientes (código y BD) para no llenar disco.
for pat in 'app.doothemes-*.tar.gz' 'doothemes-db-*.sql.gz'; do
    ls -1t /var/backups/$pat 2>/dev/null | tail -n +11 | xargs -r rm -f || true
done

# --- Reinicio ---------------------------------------------------------------
step "Reiniciando servicios"
systemctl reload "${PHP_FPM_SVC}" 2>/dev/null || systemctl restart "${PHP_FPM_SVC}"
systemctl reload caddy 2>/dev/null || systemctl restart caddy
ok "Servicios recargados."

printf '\n%s%sActualización completada → %s%s\n' "$C_BOLD" "$C_GREEN" "${RELEASE_TAG:-?}" "$C_RESET"
printf '  Respaldo: %s\n' "$BACKUP"
