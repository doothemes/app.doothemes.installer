#!/usr/bin/env bash
# ============================================================================
# tools/phpmyadmin.sh — Instala phpMyAdmin como add-on del despliegue.
#
# Lo sirve un subdominio propio en Caddy (HTTPS automático) con Basic Auth
# delante, y crea un usuario admin de MariaDB para entrar. NO toca la app.
#
# El bloque de Caddy va en /etc/caddy/conf.d/ (lo importa el Caddyfile), así
# sobrevive a las re-ejecuciones de install.sh.
#
# Variables (por entorno o installer.conf):
#   PMA_DOMAIN      subdominio a servir (default: db.<DOMAIN>)
#   PMA_BASIC_USER  usuario de Basic Auth (default: admin)
#   PMA_DB_USER     usuario admin de MariaDB a crear (default: dbadmin)
#
#   sudo ./tools/phpmyadmin.sh
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

PMA_DOMAIN="${PMA_DOMAIN:-${DOMAIN:+db.${DOMAIN}}}"
BASIC_USER="${PMA_BASIC_USER:-admin}"
DBADMIN_USER="${PMA_DB_USER:-dbadmin}"
PMA_DIR="/var/www/phpmyadmin"

[ -n "$PMA_DOMAIN" ] || die "Define PMA_DOMAIN (o DOMAIN en installer.conf) para el subdominio."

# Credenciales generadas (se imprimen al final, una sola vez).
DBADMIN_PASS="$(gen_password)"
BASIC_PASS="$(gen_password)"
BLOWFISH="$(openssl rand -hex 16)"   # 32 chars, sin pipe (evita SIGPIPE)

# ============================================================================
step "1/4 · Descargando phpMyAdmin"
# ============================================================================
command -v unzip >/dev/null 2>&1 || apt-get install -y -qq unzip >/dev/null 2>&1 || true

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

log "Desplegando en ${PMA_DIR}…"
rm -rf "$PMA_DIR"
mkdir -p "$PMA_DIR"
cp -a "$SRC"/. "$PMA_DIR"/
ok "phpMyAdmin desplegado."

# ============================================================================
step "2/4 · Configuración"
# ============================================================================
log "Escribiendo config.inc.php…"
cat > "${PMA_DIR}/config.inc.php" <<PHPCONF
<?php
// Generado por tools/phpmyadmin.sh — no editar a mano.
\$cfg['blowfish_secret'] = '${BLOWFISH}';
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
# El config lleva el blowfish_secret: legible solo por root y el usuario de PHP.
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
step "4/4 · Caddy (subdominio + Basic Auth + HTTPS)"
# ============================================================================
mkdir -p /etc/caddy/conf.d

# Hash bcrypt para el Basic Auth (lo genera el propio Caddy).
BASIC_HASH="$(caddy hash-password --plaintext "$BASIC_PASS")"

log "Escribiendo /etc/caddy/conf.d/phpmyadmin.caddy (sitio: ${PMA_DOMAIN})…"
cat > /etc/caddy/conf.d/phpmyadmin.caddy <<CADDYPMA
${PMA_DOMAIN} {
	root * ${PMA_DIR}
	encode zstd gzip

	# Capa extra: usuario/clave HTTP antes de ver phpMyAdmin.
	basic_auth {
		${BASIC_USER} ${BASIC_HASH}
	}

	php_fastcgi unix/${PHP_FPM_SOCK}
	file_server

	@hidden {
		path_regexp hiddenfiles /\.
		not path /.well-known/*
	}
	respond @hidden 403
}
CADDYPMA

# Asegura que el Caddyfile principal importe los add-ons de conf.d.
if ! grep -q 'import /etc/caddy/conf.d' /etc/caddy/Caddyfile 2>/dev/null; then
    log "Agregando 'import /etc/caddy/conf.d/*.caddy' al Caddyfile principal…"
    printf '\nimport /etc/caddy/conf.d/*.caddy\n' >> /etc/caddy/Caddyfile
fi

log "Validando y recargando Caddy…"
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy || systemctl restart caddy
ok "Caddy recargado."

# ============================================================================
cat <<SUMMARY

${C_BOLD}${C_GREEN}phpMyAdmin instalado.${C_RESET}

  URL          : ${C_BLUE}https://${PMA_DOMAIN}${C_RESET}
  (Requiere un registro DNS A: ${PMA_DOMAIN%%.*} → la IP del server, DNS only.
   El certificado se emite cuando el DNS propague.)

  ${C_BOLD}Basic Auth${C_RESET} (primera puerta, HTTP):
    Usuario    : ${BASIC_USER}
    Contraseña : ${BASIC_PASS}

  ${C_BOLD}Login de MariaDB${C_RESET} (dentro de phpMyAdmin):
    Usuario    : ${DBADMIN_USER}
    Contraseña : ${DBADMIN_PASS}
    (privilegios totales sobre todas las bases)

  ${C_YELLOW}Guarda estas credenciales: no se vuelven a mostrar.${C_RESET}
SUMMARY
