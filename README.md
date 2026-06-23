# app.doothemes.installer

Instalador y herramientas de operación para desplegar **app.doothemes** (aplicación **PHP
8.3**) en un servidor **Ubuntu** desde cero, con **HTTPS automático**.

Este repo es **público** y contiene solo fontanería de despliegue: **no incluye el código
del sistema**. El release se descarga en tiempo de ejecución desde el repositorio **privado**
con un token que aporta el operador (el mismo mecanismo de zipball que usa el actualizador
interno de la app). Ver [SECURITY.md](SECURITY.md).

---

## Contenido

- [Arquitectura del despliegue](#arquitectura-del-despliegue)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Operación](#operación) · [Actualizar](#actualizar) · [Rollback](#rollback) · [Reiniciar](#reiniciar) · [HTTPS](#https)
- [Rutas y servicios](#rutas-y-servicios-en-el-servidor)
- [Troubleshooting](#troubleshooting)
- [Decisiones de diseño](#decisiones-de-diseño)

---

## Arquitectura del despliegue

```
┌──────────────────────── Servidor Ubuntu ────────────────────────┐
│                                                                  │
│   Internet ──443/80──►  Caddy  ──► PHP-FPM 8.3 ──► app.doothemes │
│                          │ TLS automático        (app PHP)       │
│                          │ (Let's Encrypt)           │           │
│                          └─ docroot: /var/www/app.doothemes/public│
│                                                       │          │
│                                                       ▼          │
│                                                   MariaDB (local)│
└──────────────────────────────────────────────────────────────────┘
        ▲
        │ release (zipball) por token
   GitHub (repo privado de releases)
```

**Capas y quién hace qué:**

| Capa | Responsable | Qué hace |
|---|---|---|
| Provisión del SO | `install.sh` (este repo) | Instala Caddy, PHP-FPM, MariaDB, Composer; baja y despliega el release; crea la BD; configura Caddy + HTTPS. |
| Configuración de la app | **Wizard web** (`/install`, en la app) | Crea el `.env`, genera las claves de seguridad, migra el esquema y crea el admin. |
| Actualización | `update.sh` (este repo) **o** el actualizador del panel admin | Bajan el último release y lo aplican preservando el estado. |

> El instalador **no** escribe el `.env` ni migra: eso es dueño del wizard web, para no
> duplicar lógica del sistema. El instalador solo deja la infraestructura lista y te entrega
> las credenciales de BD para pegarlas en el wizard.

---

## Requisitos

- **Ubuntu** 22.04 o 24.04 (probado), con acceso `root`/`sudo`.
- **Puertos 80 y 443** abiertos hacia el servidor (Caddy los necesita para emitir el cert).
- Para HTTPS: un **dominio** con un registro **DNS A** apuntando a la IP del servidor
  **antes** de instalar. Si usas **Cloudflare**, déjalo en **DNS only** (nube gris) — ver
  [Ajuste de DNS (Cloudflare)](#ajuste-de-dns-cloudflare).
- Un **GitHub token** con **Contents: Read** sobre el repo de releases. Recomendado:
  *fine-grained*, acotado a ese único repo (ver [SECURITY.md](SECURITY.md)).
- PHP **8.3** se instala automáticamente vía PPA `ondrej/php` (la app exige ≥ 8.2; 8.3 es la
  versión objetivo soportada).

---

## Instalación

```bash
# 1. Clona el instalador
git clone https://github.com/doothemes/app.doothemes.installer
cd app.doothemes.installer

# 2. Configura (recomendado)
cp installer.conf.example installer.conf
chmod 600 installer.conf
nano installer.conf          # DOMAIN, LETSENCRYPT_EMAIL, GITHUB_TOKEN…

# 3. Instala
sudo ./install.sh

# 4. Termina en el navegador
#    Abre https://TU-DOMINIO/install y completa el wizard:
#    pega las credenciales de BD que imprimió install.sh + crea el admin.
```

Sin `installer.conf`, el script pregunta lo imprescindible (token, dominio, email). También
acepta variables por entorno: `DOMAIN=x GITHUB_TOKEN=y sudo -E ./install.sh`.

### Qué hace `install.sh`, paso a paso

1. **Dependencias** — añade los repos de PHP (ondrej) y Caddy (anclados por GPG) e instala
   Caddy, PHP-FPM 8.3 + extensiones (`intl, mbstring, mysql, curl, xml, gd, zip, bcmath`),
   MariaDB y Composer. Agrega el usuario `caddy` al grupo `www-data` (para leer el socket FPM).
2. **Base de datos** — crea la BD `doothemes` (utf8mb4) y un usuario local con contraseña
   autogenerada.
3. **Release** — consulta el último release del repo privado, descarga el zipball con el
   token, lo extrae en `/var/www/app.doothemes`, corre `composer install --no-dev` e instala
   el **cron del scheduler** de la app (`/etc/cron.d/doothemes`, cada minuto).
4. **Web + HTTPS** — escribe `/etc/caddy/Caddyfile` (docroot = `public/`), valida y recarga.
   Con dominio, Caddy emite y renueva el certificado solo.

Al final imprime las **credenciales de BD** (una sola vez) y la URL del wizard.

---

## Operación

### Actualizar

```bash
sudo ./update.sh
```

Baja el último release y lo copia **sobre** la instalación **preservando** `.env`,
`writable/`, `vendor/` y `.git` — igual que el actualizador interno de la app. Secuencia:

1. **Respaldo** del código actual en `/var/backups/app.doothemes-<fecha>.tar.gz` (sin `vendor/`).
2. **Overlay** del release (rsync con exclusiones).
3. `composer install --no-dev`.
4. Aplica las **migraciones** nuevas que traiga el release.
5. **Reload** de PHP-FPM y Caddy (sin cortar conexiones).

Si la raíz tiene un `.git` (deploy por git), `update.sh` **se niega**: ahí la vía correcta es
`git checkout <tag>`, no extraer un zip (misma regla que el `UpdateService`).

### Rollback

Cada `update.sh` deja un respaldo previo. Para volver atrás:

```bash
ls -t /var/backups/app.doothemes-*.tar.gz | head        # elige el respaldo
sudo tar -xzf /var/backups/app.doothemes-AAAAMMDD-HHMMSS.tar.gz -C /var/www/app.doothemes
sudo ./restart.sh reload
```

> El respaldo no incluye `vendor/`; si restauras a una versión con dependencias distintas,
> corre `composer install` en `/var/www/app.doothemes`. La BD no se revierte (las migraciones
> son hacia adelante): para esquema, restaura un dump de MariaDB aparte.

### Reiniciar

```bash
sudo ./restart.sh           # reinicia php-fpm, caddy y mariadb
sudo ./restart.sh reload    # recarga en caliente (php-fpm + caddy), sin cortar conexiones
sudo ./restart.sh status    # estado de los servicios
```

`restart` y `reload` **validan el Caddyfile** antes de actuar, para no dejar el sitio caído
por un config roto.

### HTTPS

No hay script de SSL: **Caddy gestiona el certificado automáticamente** (emisión y renovación
con Let's Encrypt) cuando `DOMAIN` está definido. Si cambias de dominio, edita
`/etc/caddy/Caddyfile` y `sudo ./restart.sh reload`. Sin dominio, el sitio se sirve por HTTP
en el puerto 80 (acceso por IP).

### Ajuste de DNS (Cloudflare)

Para emitir el certificado, Let's Encrypt debe alcanzar el servidor **directamente** en los
puertos 80/443. Si el dominio está detrás del **proxy de Cloudflare** (nube **naranja**), el
reto ACME llega a Cloudflare —no a tu servidor— y el certificado **nunca se emite**
(`challenge failed`). La configuración correcta:

1. **Cloudflare → tu dominio → DNS → Records.**
2. Crea o edita el registro del host:
   - **Type:** `A`
   - **Name:** `@` (raíz) o el subdominio (ej. `app`).
   - **IPv4 address:** la IP pública del servidor.
   - **Proxy status:** **DNS only** (nube **gris**, no naranja). ← lo más importante.
3. Guarda (propaga en segundos/minutos).
4. (Re)ejecuta `sudo ./install.sh` o `sudo ./restart.sh reload`; Caddy reintenta y emite el cert.

**Notas:**

- Usa un registro **A (IPv4)**. Evita dejar **solo un AAAA (IPv6)** si el IPv6 del servidor
  no es alcanzable: Let's Encrypt prioriza IPv6 y, si falla, el reto no se completa. Borra el
  AAAA o apúntalo a un IPv6 que responda.
- Verifica a dónde resuelve **desde el servidor**: `getent hosts TU-DOMINIO` debe devolver la
  **IP del servidor**, no IPs de Cloudflare (`104.x` / `172.6x` / `2606:4700:…`).
- Comprueba la emisión con `journalctl -u caddy -e` (busca `certificate obtained successfully`).
- **¿Necesitas mantener el proxy de Cloudflare?** Entonces no uses ACME por HTTP. Opciones
  (fuera de este instalador): **Origin Certificate** de Cloudflare en Caddy con SSL
  *Full (strict)*, o el reto **DNS-01** con el plugin `caddy-dns/cloudflare` y un API token.

---

## Rutas y servicios en el servidor

| Elemento | Ruta / nombre |
|---|---|
| Código de la app | `/var/www/app.doothemes` |
| Docroot (web) | `/var/www/app.doothemes/public` |
| Config de Caddy | `/etc/caddy/Caddyfile` |
| Logs de Caddy | journald → `journalctl -u caddy` |
| Respaldos de update | `/var/backups/app.doothemes-*.tar.gz` |
| Cron del scheduler | `/etc/cron.d/doothemes` (runner de tareas de la app, cada minuto) |
| Servicios systemd | `php8.3-fpm`, `caddy`, `mariadb`, `cron` |
| Socket PHP-FPM | `/run/php/php8.3-fpm.sock` |

---

## Troubleshooting

| Síntoma | Causa probable / arreglo |
|---|---|
| `No se pudo descargar el release` | Token sin permiso de Contents, repo mal escrito, o no hay releases publicados. Verifica con `curl -H "Authorization: Bearer <token>" https://api.github.com/repos/<repo>/releases/latest`. |
| Caddy no emite el certificado (`challenge failed`) | (a) DNS no apunta a la IP del servidor; (b) **firewall** bloquea 80/443 — el instalador abre `ufw`, pero si usas otro firewall (o el del proveedor) ábrelos a mano; (c) registro **solo AAAA/IPv6** con IPv6 no alcanzable → usa un registro **A** a la IPv4. Diagnostica con `journalctl -u caddy -e`. |
| Error 502 Bad Gateway | PHP-FPM caído o el usuario `caddy` no accede al socket. `sudo ./restart.sh` y confirma que `caddy` está en el grupo `www-data`. |
| El wizard `/install` no carga | Permisos de `writable/`. Reaplica con: `sudo chown -R www-data:www-data /var/www/app.doothemes && sudo chmod -R 775 /var/www/app.doothemes/writable`. |
| `update.sh` se niega | Existe `/var/www/app.doothemes/.git` (deploy por git). Usa `git checkout <tag>`. |
| Olvidé la contraseña de BD | Está en el `.env` de la app (`database.default.password`) tras completar el wizard. |

---

## Decisiones de diseño

- **Caddy** en vez de nginx + certbot: HTTPS automático, config mínima, menos piezas que
  mantener (sin timer de renovación).
- **MariaDB local, desatendido**: crea BD + usuario con clave aleatoria y te la imprime; el
  **wizard web** sigue siendo el dueño del `.env`, la migración y el admin (no se duplica).
- **Release por token (zipball API)**: mismo mecanismo que el `UpdateService` de la app, así
  instalación y actualización comparten una sola vía y el deploy queda **sin `.git`**.
- **PHP vía PPA `ondrej/php`**: garantiza PHP 8.3 en cualquier Ubuntu soportado.
- **Sin Node/npm**: los assets viajan **compilados** en el release; `vendor/` no viaja
  (export-ignore), por eso el instalador corre `composer install`.

---

## Add-ons

### phpMyAdmin (opcional)

```bash
sudo PMA_PATH=mirutadatabase ./tools/phpmyadmin.sh
```

Instala phpMyAdmin en una **ruta personalizada del dominio principal**
(`https://<DOMAIN>/<PMA_PATH>`, default `/mirutadatabase`). Sin Basic Auth: la puerta es el
**login de phpMyAdmin** (un usuario admin de MariaDB que crea el script). No requiere DNS
extra (usa el dominio existente). El bloque de Caddy va en
`/etc/caddy/conf.d/main/phpmyadmin.caddy`, que el bloque del sitio importa — así sobrevive a
las re-ejecuciones de `install.sh` (requiere `install.sh` ≥ la versión que genera ese import).
Variables: `PMA_PATH`, `PMA_DB_USER`. Imprime la contraseña de MariaDB una sola vez.

> El Caddyfile separa el enrutamiento en bloques `handle`: los add-ons de subpath
> (`conf.d/main/*.caddy`) se evalúan antes que la app, que captura el resto.

## Seguridad

El manejo de secretos, la cadena de suministro y las recomendaciones de hardening están en
[SECURITY.md](SECURITY.md). En corto: el token y la clave de BD **nunca** se versionan
(`installer.conf` está en `.gitignore`); solo se publica `installer.conf.example` con valores
vacíos.
