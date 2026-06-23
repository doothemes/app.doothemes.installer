#!/usr/bin/env bash
# ============================================================================
# tools/phpmyadmin.sh — Instala phpMyAdmin como add-on del despliegue, servido
# en una RUTA personalizada del dominio principal (ej. /mirutadatabase).
#
# Sin Basic Auth: la puerta es el propio login de phpMyAdmin (usuario MariaDB).
# La ruta es "secreta" (no enlazada) y configurable.
#
# El bloque de Caddy va en /etc/caddy/conf.d/main/ (lo importa el bloque del
# sitio en el Caddyfile que genera install.sh), así sobrevive a re-ejecuciones.
#
# Variables (por entorno o installer.conf):
#   PMA_PATH        ruta sin barra inicial (default: mirutadatabase)
#   PMA_DB_USER     usuario admin de MariaDB a crear (default: dbadmin)
#
#   sudo PMA_PATH=mirutadatabase ./tools/phpmyadmin.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
. "${ROOT_DIR}/lib/common.sh"

require_root
require_ubuntu

# Config: toma DOMAIN/APP_USER/PHP_VERSION de installer.conf si existe.
[ -f "${ROOT_DIR}/installer.conf" ] && . "${ROOT_DIR}/installer.conf"
: "${DOMAIN:=}"
: "${APP_USER:=www-data}"
: "${PHP_VERSION:=8.3}"
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

PMA_PATH="${PMA_PATH:-mirutadatabase}"
PMA_PATH="${PMA_PATH#/}"          # sin barra inicial
PMA_PATH="${PMA_PATH%/}"          # sin barra final
DBADMIN_USER="${PMA_DB_USER:-dbadmin}"
PMA_DIR="/var/www/${PMA_PATH}"    # la carpeta = la ruta (URL ↔ filesystem, sin reescritura)

[ -n "$PMA_PATH" ] || die "PMA_PATH no puede estar vacío."

# Credenciales del usuario admin de MariaDB (se imprimen al final).
DBADMIN_PASS="$(gen_password)"
BLOWFISH="$(openssl rand -hex 16)"   # 32 chars, sin pipe (evita SIGPIPE)

# ============================================================================
step "1/4 · Descargando phpMyAdmin"
# ============================================================================
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "Bajando el último phpMyAdmin (all-languages)…"
curl -fsSL https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz \
    -o "$TMP/pma.tar.gz" || die "No se pudo descargar phpMyAdmin."
tar -xzf "$TMP/pma.tar.gz" -C "$TMP" || die "Falló al extraer phpMyAdmin."

# Carpeta extraída (glob, sin find|head para no disparar SIGPIPE).
SRC=""
for d in "$TMP"/phpMyAdmin-*-all-languages/; do [ -d "$d" ] && SRC="${d%/}" && break; done
[ -n "$SRC" ] || die "No se halló la carpeta de phpMyAdmin extraída."

# Limpia un eventual setup viejo por subdominio (migración a subpath).
rm -f /etc/caddy/conf.d/phpmyadmin.caddy
[ -d /var/www/phpmyadmin ] && [ "$PMA_DIR" != /var/www/phpmyadmin ] && rm -rf /var/www/phpmyadmin

log "Desplegando en ${PMA_DIR}…"
rm -rf "$PMA_DIR"
mkdir -p "$PMA_DIR"
cp -a "$SRC"/. "$PMA_DIR"/
ok "phpMyAdmin desplegado."

# ============================================================================
step "2/4 · Configuración"
# ============================================================================
log "Escribiendo config.inc.php…"
# PmaAbsoluteUri fija la URL base (la ruta NO se reescribe, así que coincide).
ABS_URI=""
[ -n "$DOMAIN" ] && ABS_URI="\$cfg['PmaAbsoluteUri'] = 'https://${DOMAIN}/${PMA_PATH}/';"
cat > "${PMA_DIR}/config.inc.php" <<PHPCONF
<?php
// Generado por tools/phpmyadmin.sh — no editar a mano.
\$cfg['blowfish_secret'] = '${BLOWFISH}';
${ABS_URI}
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type']       = 'cookie';
\$cfg['Servers'][\$i]['host']            = 'localhost';
\$cfg['Servers'][\$i]['compress']        = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '${PMA_DIR}/tmp';
PHPCONF

# Permisos: archivos de root (solo lectura para el web), tmp escribible por PHP.
chown -R root:root "$PMA_DIR"
find "$PMA_DIR" -type d -exec chmod 755 {} +
find "$PMA_DIR" -type f -exec chmod 644 {} +
mkdir -p "${PMA_DIR}/tmp"
chown "${APP_USER}:${APP_USER}" "${PMA_DIR}/tmp"
chmod 770 "${PMA_DIR}/tmp"
chown "root:${APP_USER}" "${PMA_DIR}/config.inc.php"
chmod 640 "${PMA_DIR}/config.inc.php"
ok "Configuración aplicada."

# ============================================================================
step "3/4 · Usuario admin de MariaDB"
# ============================================================================
log "Creando usuario '${DBADMIN_USER}'@'localhost' con todos los privilegios…"
mysql <<SQL
CREATE USER IF NOT EXISTS '${DBADMIN_USER}'@'localhost' IDENTIFIED BY '${DBADMIN_PASS}';
ALTER USER '${DBADMIN_USER}'@'localhost' IDENTIFIED BY '${DBADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DBADMIN_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
ok "Usuario admin de MariaDB listo."

# ============================================================================
step "4/4 · Caddy (subpath del dominio principal)"
# ============================================================================
mkdir -p /etc/caddy/conf.d/main

# El handle NO quita el prefijo: la URL /${PMA_PATH}/… mapea a /var/www/${PMA_PATH}/…
log "Escribiendo /etc/caddy/conf.d/main/phpmyadmin.caddy (ruta: /${PMA_PATH})…"
cat > /etc/caddy/conf.d/main/phpmyadmin.caddy <<CADDYPMA
# phpMyAdmin en https://${DOMAIN:-este-host}/${PMA_PATH}  (add-on; lo gestiona tools/phpmyadmin.sh)
handle /${PMA_PATH}* {
	root * /var/www
	php_fastcgi unix/${PHP_FPM_SOCK}
	file_server
}
CADDYPMA

# El bloque del sitio (generado por install.sh) debe importar conf.d/main.
if ! grep -q 'conf.d/main' /etc/caddy/Caddyfile 2>/dev/null; then
    warn "El Caddyfile no importa conf.d/main. Re-ejecuta install.sh (versión nueva) para que tome la ruta."
fi

log "Validando y recargando Caddy…"
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy || systemctl restart caddy
ok "Caddy recargado."

# ============================================================================
cat <<SUMMARY

${C_BOLD}${C_GREEN}phpMyAdmin instalado.${C_RESET}

  URL          : ${C_BLUE}https://${DOMAIN:-TU-DOMINIO}/${PMA_PATH}${C_RESET}
  (ruta secreta, sin Basic Auth; la puerta es el login de phpMyAdmin)

  ${C_BOLD}Login de MariaDB${C_RESET}:
    Usuario    : ${DBADMIN_USER}
    Contraseña : ${DBADMIN_PASS}
    (privilegios totales sobre todas las bases)

  ${C_YELLOW}Guarda la contraseña: no se vuelve a mostrar.${C_RESET}
SUMMARY
