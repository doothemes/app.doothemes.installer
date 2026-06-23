# Política de seguridad

Este repositorio contiene **solo el instalador** de app.doothemes (scripts de provisión y
operación). **No contiene el código del sistema** ni credenciales: el release se descarga en
tiempo de ejecución desde el repositorio privado usando un token que aporta el operador.

## Reportar una vulnerabilidad

Si encuentras una vulnerabilidad en estos scripts (ej. inyección de comandos, manejo
inseguro de secretos, permisos peligrosos), **no abras un issue público**. Repórtala de
forma privada a:

**security@doothemes.com**

Incluye, en la medida de lo posible:
- Descripción del problema y su impacto.
- Pasos para reproducirlo (PoC si aplica).
- Commit afectado.

Agradecemos la divulgación responsable y no emprenderemos acciones contra investigadores
que actúen de buena fe.

## Manejo de secretos

El instalador trabaja con dos datos sensibles. Ninguno se versiona ni se transmite a
terceros:

| Secreto | Dónde vive | Garantía |
|---|---|---|
| **GitHub token** (lectura de releases) | `installer.conf` (gitignored) o se pide por prompt | `installer.conf` está en `.gitignore`; en modo prompt se lee con `read -s` y **no se escribe a disco**. Solo se envía a `api.github.com` como cabecera `Authorization`. |
| **Contraseña de BD** | Generada en el servidor | Se autogenera (28 chars, `/dev/urandom`), se aplica a MariaDB local y se **imprime una sola vez** al final de `install.sh`. No se guarda en el repo ni en logs. |

> Lo único versionado es `installer.conf.example`, con todos los valores **vacíos**.

### Recomendaciones para el operador

- Usa un **token fine-grained** acotado: solo el repo de releases y permiso
  **Contents: Read-only**. No uses un PAT clásico con `repo` completo si puedes evitarlo.
- Si pasas el token por entorno, evita que quede en el historial del shell
  (`HISTCONTROL=ignorespace` y antepón un espacio, o usa `installer.conf`).
- Trata `installer.conf` y la salida final de `install.sh` (que muestra la clave de BD)
  como material sensible. `chmod 600 installer.conf`.
- Revoca y rota el token tras un despliegue si fue de un solo uso.

## Cadena de suministro (supply chain)

`install.sh` confía en estas fuentes externas. Audítalas si tu modelo de amenaza lo exige:

| Fuente | Para qué | Notas |
|---|---|---|
| `api.github.com` / `codeload.github.com` | Bajar el release (zipball) | Autenticado con el token; TLS. |
| PPA `ppa:ondrej/php` | PHP 8.3 + extensiones | Repo APT firmado (GPG). |
| Repo APT de Caddy (`dl.cloudsmith.io`) | Caddy | Se ancla con su llave GPG (`/usr/share/keyrings`). |
| `getcomposer.org` | Instalar Composer | Se descarga el instalador oficial. |
| `apt` (Ubuntu) | nginx-no / MariaDB / utilidades | Repos oficiales de la distro. |

El script no ejecuta `curl | bash` de orígenes anónimos: cada repo de terceros se ancla con
su llave GPG antes de instalar.

## Lo que el instalador NO endurece (responsabilidad del operador)

Esto queda **fuera de alcance** del instalador; configúralo según tu entorno:

- **Firewall**: el instalador abre **80/443** en `ufw` si está activo (los necesita el
  sitio y el reto ACME). Restringir el acceso a **22/SSH** y cualquier otra regla queda a tu cargo.
- **SSH**: deshabilita login por contraseña / root; usa llaves.
- **MariaDB**: queda escuchando solo en `localhost` (default), sin acceso remoto.
- **Actualizaciones del SO**: habilita `unattended-upgrades` aparte.
- **Hardening de PHP-FPM** más allá de los defaults (límites de recursos, `open_basedir`).

## Garantías de seguridad del propio sistema

La seguridad de la aplicación (auth, hashing, tokens, pasarelas) vive en el repositorio
privado y su propia [política de seguridad](https://github.com/doothemes/app.doothemes).
El instalador delega en el **wizard web** (`/install`) la creación del `.env`, la generación
de claves de seguridad y la cuenta de administrador.
