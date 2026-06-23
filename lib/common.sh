#!/usr/bin/env bash
# ============================================================================
# lib/common.sh — utilidades compartidas por todos los scripts del instalador.
# No se ejecuta directo; se hace `source` desde install.sh / update.sh / etc.
# ============================================================================

# --- Salida con color (se degrada a texto plano si no hay TTY) --------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

log()   { printf '%s\n' "${C_BLUE}▸${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s\n' "${C_BOLD}== $* ==${C_RESET}"; }

# --- Pre-condiciones --------------------------------------------------------

# Exige privilegios de root (los scripts tocan apt, systemd, /var/www, …).
require_root() {
    [ "$(id -u)" -eq 0 ] || die "Ejecuta como root (usa: sudo $0)."
}

# Verifica que el SO sea Ubuntu/Debian (apt). Solo advierte si no es Ubuntu.
require_ubuntu() {
    [ -f /etc/os-release ] || die "No se encontró /etc/os-release; SO no soportado."
    # shellcheck disable=SC1091
    . /etc/os-release
    command -v apt-get >/dev/null 2>&1 || die "Se requiere apt (Ubuntu/Debian)."
    case "${ID:-}" in
        ubuntu) : ;;
        debian) warn "SO Debian detectado; pensado para Ubuntu, puede funcionar." ;;
        *)      warn "SO '${ID:-desconocido}' no probado; se asume compatible con apt." ;;
    esac
}

# --- Configuración ----------------------------------------------------------

# Carga installer.conf si existe (en la raíz del instalador, junto al script que
# hace `source`). Si una variable ya viene definida y NO vacía desde el entorno,
# se respeta (útil para automatización: VAR=x ./install.sh).
load_conf() {
    local dir conf
    dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    conf="${dir}/installer.conf"
    if [ -f "$conf" ]; then
        log "Cargando configuración: $conf"
        # shellcheck disable=SC1090
        . "$conf"
    else
        warn "Sin installer.conf; se usan defaults y prompts (ver installer.conf.example)."
    fi
}

# Defaults para variables no definidas en el conf ni el entorno.
apply_defaults() {
    : "${APP_DIR:=/var/www/app.doothemes}"
    : "${APP_USER:=www-data}"
    : "${PHP_VERSION:=8.3}"
    : "${GITHUB_REPO:=doothemes/app.doothemes}"
    : "${DB_NAME:=doothemes}"
    : "${DB_USER:=doothemes}"
    : "${ENABLE_SSL:=yes}"
    PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
    PHP_FPM_SVC="php${PHP_VERSION}-fpm"
}

# Pide un valor por stdin si la variable está vacía. uso: prompt_if_empty VAR "Etiqueta"
prompt_if_empty() {
    local var="$1" label="$2" silent="${3:-}" val=""
    [ -n "${!var:-}" ] && return 0
    if [ "$silent" = "secret" ]; then
        read -r -s -p "$label: " val; echo
    else
        read -r -p "$label: " val
    fi
    printf -v "$var" '%s' "$val"
}

# Genera una contraseña fuerte (alfanumérica, 28 chars).
gen_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28
}

# --- Releases ---------------------------------------------------------------

# Descarga el zipball del último release a $3. Imprime el tag por stdout.
# uso: tag=$(download_latest_release "$REPO" "$TOKEN" /tmp/app.zip)
download_latest_release() {
    local repo="$1" token="$2" out="$3"
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local json tag zipurl
    local -a auth=(-H "Authorization: Bearer ${token}"
                   -H "Accept: application/vnd.github+json"
                   -H "X-GitHub-Api-Version: 2022-11-28")

    json="$(curl -fsSL "${auth[@]}" "$api")" \
        || { err "No se pudo consultar el último release (¿token o repo inválido?)."; return 1; }

    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
    zipurl="$(printf '%s' "$json" | jq -r '.zipball_url // empty')"
    [ -n "$zipurl" ] || { err "El release no trae zipball_url."; return 1; }

    curl -fsSL "${auth[@]}" -L "$zipurl" -o "$out" \
        || { err "Falló la descarga del zipball del release."; return 1; }

    printf '%s' "$tag"
}

# Extrae el zip y devuelve (por stdout) la ruta de la carpeta raíz extraída.
# El zipball de GitHub envuelve todo en `owner-repo-<sha>/`.
extract_release() {
    local zip="$1" dest="$2"
    mkdir -p "$dest"
    unzip -q "$zip" -d "$dest" || { err "Falló unzip del release."; return 1; }
    find "$dest" -mindepth 1 -maxdepth 1 -type d | head -n1
}

# --- Permisos ---------------------------------------------------------------

# Aplica el esquema de permisos estándar de CI4 sobre $APP_DIR.
fix_permissions() {
    local dir="$1" user="$2"
    log "Ajustando permisos en $dir (dueño: $user)…"
    mkdir -p "$dir/writable"
    chown -R "$user:$user" "$dir"
    find "$dir" -type d -exec chmod 755 {} +
    find "$dir" -type f -exec chmod 644 {} +
    chmod -R 775 "$dir/writable"
    [ -f "$dir/spark" ] && chmod +x "$dir/spark"
    ok "Permisos aplicados."
}
