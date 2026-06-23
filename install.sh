#!/usr/bin/env bash
# ============================================================================
# install.sh — Provisiona un servidor Ubuntu para app.doothemes desde cero.
#
#   1. Instala dependencias (Caddy, PHP-FPM + extensiones, MariaDB, composer…).
#   2. Crea la base de datos y el usuario MariaDB.
#   3. Descarga el último release del repo privado y lo despliega.
#   4. Configura Caddy (docroot = public/) con HTTPS automático (Let's Encrypt).
#
# Tras esto, abre https://TU-DOMINIO/install y completa el wizard web (pega las
# credenciales de BD que imprime este script al final).
#
#   sudo ./install.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
require_ubuntu
load_conf
apply_defaults

# --- Datos requeridos (pregunta lo que falte) -------------------------------
prompt_if_empty GITHUB_TOKEN "GitHub token (lectura del repo ${GITHUB_REPO})" secret
[ -n "${GITHUB_TOKEN:-}" ] || die "Se requiere un token de GitHub para bajar el release."

if [ -z "${DOMAIN:-}" ]; then
    warn "DOMAIN vacío: se servirá por HTTP en el puerto 80 (sin HTTPS)."
    warn "Para HTTPS automático, define DOMAIN (con DNS apuntando aquí) y reejecuta."
else
    # Caddy usa este email para los avisos de ACME/Let's Encrypt.
    prompt_if_empty LETSENCRYPT_EMAIL "Email para Let's Encrypt (HTTPS)"
fi

# ¿La app ya está instalada? El wizard web deja .env + writable/installed.lock.
# Si es así, re-correr install.sh NO debe tocar la BD ni su contraseña (rompería
# el .env existente): solo re-despliega código y reconfigura servicios.
INSTALLED=no
if [ -f "${APP_DIR}/.env" ] || [ -f "${APP_DIR}/writable/installed.lock" ]; then
    INSTALLED=yes
    warn "Instalación existente detectada (.env/installed.lock): se conservan la BD y el .env."
fi

# Autogenera la contraseña de BD si no se fijó (solo en instalación nueva).
if [ "$INSTALLED" != yes ] && [ -z "${DB_PASS:-}" ]; then
    DB_PASS="$(gen_password)"
    DB_PASS_GENERATED="yes"
fi

# ============================================================================
step "1/4 · Dependencias del sistema"
# ============================================================================
export DEBIAN_FRONTEND=noninteractive

log "Actualizando índices de apt…"
apt-get update -qq

log "Instalando utilidades base…"
apt-get install -y -qq software-properties-common ca-certificates curl unzip jq rsync gnupg debian-keyring debian-archive-keyring apt-transport-https

# PPA ondrej/php: garantiza PHP $PHP_VERSION en cualquier Ubuntu soportado.
if ! apt-cache policy "php${PHP_VERSION}-fpm" 2>/dev/null | grep -q Candidate; then
    log "Agregando PPA ondrej/php (para PHP ${PHP_VERSION})…"
    add-apt-repository -y ppa:ondrej/php >/dev/null
    apt-get update -qq
fi

# Repo oficial de Caddy.
if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
    log "Agregando el repositorio oficial de Caddy…"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
fi

log "Instalando Caddy, MariaDB y PHP ${PHP_VERSION} con extensiones…"
apt-get install -y -qq \
    caddy \
    mariadb-server \
    "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-intl" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-curl" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-zip" "php${PHP_VERSION}-bcmath"

# Composer (oficial) si no está.
if ! command -v composer >/dev/null 2>&1; then
    log "Instalando Composer…"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
fi

# Caddy corre como usuario 'caddy'; debe poder leer el socket de PHP-FPM
# (que por defecto pertenece al grupo www-data).
usermod -aG "$APP_USER" caddy 2>/dev/null || true

systemctl enable --now "${PHP_FPM_SVC}" mariadb caddy >/dev/null 2>&1 || true

# Límites de PHP-FPM: la app sube media (imágenes de producto) y Caddy ya acepta
# 64MB de body; alineamos PHP para que no corte antes (defaults son 2M/8M).
log "Ajustando límites de PHP (subida de media)…"
cat > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-doothemes.ini" <<PHPINI
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
PHPINI
systemctl restart "${PHP_FPM_SVC}" 2>/dev/null || true
ok "Dependencias instaladas (PHP $(php -r 'echo PHP_VERSION;'); upload/post 64M)."

# ============================================================================
step "2/4 · Base de datos (MariaDB)"
# ============================================================================
# MariaDB recién instalada usa auth por socket para root → `mysql` como root SO.
if [ "$INSTALLED" = yes ]; then
    log "App ya instalada: no se crea ni modifica la BD (se conserva la existente)."
else
    log "Creando base de datos '${DB_NAME}' y usuario '${DB_USER}'…"
    mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Base de datos lista."
fi

# ============================================================================
step "3/4 · Descarga y despliegue del release"
# ============================================================================
TMP_ZIP="$(mktemp --suffix=.zip)"
TMP_EXTRACT="$(mktemp -d)"
trap 'rm -rf "$TMP_ZIP" "$TMP_EXTRACT"' EXIT

log "Consultando el último release de ${GITHUB_REPO}…"
RELEASE_TAG="$(download_latest_release "$GITHUB_REPO" "$GITHUB_TOKEN" "$TMP_ZIP")" \
    || die "No se pudo descargar el release."
ok "Release descargado: ${RELEASE_TAG:-(sin tag)}"

SRC_DIR="$(extract_release "$TMP_ZIP" "$TMP_EXTRACT")"
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || die "No se halló la carpeta raíz del release."

log "Desplegando en ${APP_DIR}…"
mkdir -p "$APP_DIR"
rsync -a "$SRC_DIR"/ "$APP_DIR"/
ok "Código desplegado."

log "Instalando dependencias PHP (composer, sin dev)…"
# Se corre como root (los archivos recién copiados son de root) con un HOME
# escribible para la caché; luego fix_permissions deja vendor/ como $APP_USER.
( cd "$APP_DIR" \
    && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_HOME=/tmp/composer-doothemes \
       composer install --no-dev --optimize-autoloader --no-interaction --no-progress ) \
    || die "Falló composer install en $APP_DIR (revisa el detalle de composer arriba)."

fix_permissions "$APP_DIR" "$APP_USER"

# --- Cron del scheduler -----------------------------------------------------
# La app usa un scheduler central: UNA línea de cron cada minuto dispara
# `spark tasks:run`, que evalúa el registro (Config\Tasks) y corre lo vencido.
# Se instala en /etc/cron.d con nombre SIN punto (cron ignora los que tienen '.').
log "Configurando el cron del scheduler (tasks:run cada minuto)…"
PHP_BIN="$(command -v "php${PHP_VERSION}" || command -v php || echo /usr/bin/php)"
cat > /etc/cron.d/doothemes <<CRON
# app.doothemes — scheduler central (lo regenera el instalador; no editar a mano).
# Cada minuto evalúa las tareas programadas y ejecuta las vencidas.
MAILTO=""
* * * * * ${APP_USER} cd ${APP_DIR} && ${PHP_BIN} spark tasks:run >> /dev/null 2>&1
CRON
chmod 644 /etc/cron.d/doothemes
systemctl enable --now cron >/dev/null 2>&1 || true
ok "Cron instalado (/etc/cron.d/doothemes, usuario ${APP_USER})."

# ============================================================================
step "4/4 · Servidor web + HTTPS (Caddy)"
# ============================================================================
CADDYFILE="/etc/caddy/Caddyfile"

if [ -n "${DOMAIN:-}" ]; then
    SITE_ADDR="$DOMAIN"   # dominio → Caddy emite y renueva TLS automáticamente
else
    SITE_ADDR=":80"       # sin dominio → solo HTTP por IP
fi

log "Escribiendo ${CADDYFILE} (sitio: ${SITE_ADDR})…"
{
    if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
        printf '{\n\temail %s\n}\n\n' "$LETSENCRYPT_EMAIL"
    fi
    cat <<CADDY
${SITE_ADDR} {
	root * ${APP_DIR}/public
	encode zstd gzip

	# CI4: sirve el archivo si existe; si no, entra por index.php.
	php_fastcgi unix/${PHP_FPM_SOCK}
	file_server

	# Negar acceso a archivos/carpetas ocultas (dotfiles), salvo el reto ACME.
	# RE2 no soporta lookahead → se excluye .well-known con un matcher aparte.
	@hidden {
		path_regexp hiddenfiles /\.
		not path /.well-known/*
	}
	respond @hidden 403

	request_body {
		max_size 64MB
	}
}
CADDY
} > "$CADDYFILE"
# Nota: Caddy loguea a journald (stdout del servicio) → `journalctl -u caddy`.
# Se evita un `log { output file … }` para no chocar con permisos del archivo.

# Si ufw está activo, abrir los puertos web. Sin esto, el sitio es inalcanzable
# y —peor— el reto ACME de Let's Encrypt no llega a Caddy y el cert nunca se emite.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "ufw activo: abriendo puertos 80 y 443…"
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw reload        >/dev/null 2>&1 || true
    ok "Puertos 80/443 abiertos en ufw."
fi

log "Validando el Caddyfile…"
caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl reload caddy || systemctl restart caddy
ok "Caddy configurado."
[ -n "${DOMAIN:-}" ] && ok "HTTPS automático activo para ${DOMAIN} (Let's Encrypt)."

# ============================================================================
# Resumen
# ============================================================================
if [ -n "${DOMAIN:-}" ]; then
    BASE_URL="https://${DOMAIN}"
else
    BASE_URL="http://$(hostname -I | awk '{print $1}')"
fi

if [ "$INSTALLED" = yes ]; then
cat <<SUMMARY

${C_BOLD}${C_GREEN}Re-despliegue completado.${C_RESET}  (la app ya estaba instalada)

  Release desplegado : ${RELEASE_TAG:-?}
  Directorio         : ${APP_DIR}
  Web / HTTPS        : Caddy ${DOMAIN:+(TLS automático para ${DOMAIN})}

  Se conservaron el .env, la base de datos y las migraciones existentes; no se
  tocó ninguna credencial. Para aplicar un release nuevo con sus migraciones,
  usa ${C_BLUE}sudo ./update.sh${C_RESET} (respalda BD/código y corre migrate).

  Sitio: ${C_BLUE}${BASE_URL}${C_RESET}
SUMMARY
else
cat <<SUMMARY

${C_BOLD}${C_GREEN}Instalación completada.${C_RESET}

  Release desplegado : ${RELEASE_TAG:-?}
  Directorio         : ${APP_DIR}
  Docroot            : ${APP_DIR}/public
  PHP                : ${PHP_VERSION} (FPM: ${PHP_FPM_SVC})
  Web / HTTPS        : Caddy ${DOMAIN:+(TLS automático para ${DOMAIN})}

  ${C_BOLD}Credenciales de base de datos${C_RESET} (pégalas en el wizard web):
    Host       : 127.0.0.1
    Base       : ${DB_NAME}
    Usuario    : ${DB_USER}
    Contraseña : ${DB_PASS}${DB_PASS_GENERATED:+   ${C_YELLOW}(autogenerada — guárdala)${C_RESET}}

  ${C_BOLD}Siguiente paso${C_RESET}: abre ${C_BLUE}${BASE_URL}/install${C_RESET} y completa
  la configuración (BD + cuenta de administrador). El wizard crea el .env,
  migra el esquema y deja la app lista.

  Operación continua:
    Actualizar  : sudo ./update.sh
    Reiniciar   : sudo ./restart.sh
SUMMARY
fi
