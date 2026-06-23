# app.doothemes.installer

Instalador y herramientas de operación para desplegar **app.doothemes** (CI4 / PHP 8.2+)
en un servidor **Ubuntu** desde cero, con HTTPS automático.

Stack que provisiona: **Caddy** (web + TLS automático) · **PHP-FPM** + extensiones ·
**MariaDB** · **Composer**. Las releases se bajan del **repo privado** vía token de GitHub
(el mismo mecanismo de zipball que usa el `UpdateService` de la app).

## Requisitos

- Ubuntu (probado en 22.04 / 24.04), acceso `root`/`sudo`.
- Puertos **80** y **443** abiertos hacia el servidor.
- Para HTTPS: un **dominio** con DNS apuntando a la IP del servidor.
- Un **GitHub token** (fine-grained o clásico) con **lectura de Contents** del repo de releases.

## Uso rápido

```bash
# 1. Configura (opcional pero recomendado)
cp installer.conf.example installer.conf
nano installer.conf          # DOMAIN, LETSENCRYPT_EMAIL, GITHUB_REPO, GITHUB_TOKEN…

# 2. Instala
sudo ./install.sh

# 3. Termina en el navegador
#    Abre https://TU-DOMINIO/install y completa el wizard:
#    pega las credenciales de BD que imprimió install.sh + crea el admin.
```

Si no usas `installer.conf`, `install.sh` te pregunta lo imprescindible (token, dominio).
También puedes pasar variables por entorno: `DOMAIN=x GITHUB_TOKEN=y sudo -E ./install.sh`.

## Scripts

| Script | Qué hace |
|---|---|
| `install.sh` | Provisión completa: dependencias → BD → release → Caddy + HTTPS. |
| `update.sh` | Actualiza al último release (respaldo → overlay → composer → `migrate` → reload). |
| `restart.sh` | `restart` / `reload` / `status` de php-fpm, caddy y mariadb. |
| `lib/common.sh` | Utilidades compartidas (no se ejecuta directo). |

### Actualizar

```bash
sudo ./update.sh
```

Baja el último release y lo copia **sobre** la instalación **preservando**
`.env`, `writable/`, `vendor/` y `.git` — igual que el actualizador interno de la app.
Antes hace un respaldo en `/var/backups/app.doothemes-<fecha>.tar.gz` y al final corre
`php spark migrate`. Si la raíz tiene un `.git` (deploy por git), se niega: ahí la vía es
`git checkout <tag>`.

### Reiniciar

```bash
sudo ./restart.sh           # reinicio completo
sudo ./restart.sh reload    # recarga en caliente (sin cortar conexiones)
sudo ./restart.sh status    # estado de los servicios
```

### HTTPS

No hay script de SSL: **Caddy gestiona el certificado automáticamente** (emisión y
renovación con Let's Encrypt) cuando `DOMAIN` está definido. Para forzar una recarga tras
cambiar el dominio, edita `/etc/caddy/Caddyfile` y `sudo ./restart.sh reload`.

## Decisiones de diseño

- **Caddy** en vez de nginx+certbot: HTTPS automático, config mínima, menos piezas que mantener.
- **MariaDB local, desatendido**: crea BD + usuario con clave aleatoria y te las imprime; el
  **wizard web** sigue siendo el dueño del `.env`, la migración y el admin (no se duplica).
- **Release por token (zipball API)**: mismo mecanismo que `UpdateService`, así instalación y
  actualización comparten una sola vía y el deploy queda **sin `.git`** (como espera la app).
- **PHP vía PPA `ondrej/php`**: garantiza la versión pedida en cualquier Ubuntu soportado.

## Notas

- Los assets viven **compilados** en el repo (se incluyen en el release), así que **no** se
  instala Node/npm en el servidor.
- `vendor/` no viaja en el release (export-ignore): por eso el instalador corre `composer install`.
- La contraseña de BD autogenerada se muestra **una sola vez** al final de `install.sh`.
