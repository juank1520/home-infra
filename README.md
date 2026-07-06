## Primeros pasos

### Preparacion (desde tu computadora personal)
1. Flashear Ubuntu Server en la SD con [Raspberry Pi Imager](https://www.raspberrypi.com/software/). En las opciones avanzadas configurar:
   - Hostname: `homeserver`
   - Habilitar SSH con tu llave publica personal
   - Usuario y contraseña
2. Generar el comando de instalación con la CLI de `gh` (requiere tener `gh` instalado y autenticado):
   ```sh
   ./scripts/generate-install-cmd.sh
   ```
   - Pregunta si tambien quieres configurar el self-hosted runner de auto-despliegue; si dices
     que si, el comando generado ya incluye el `RUNNER_TOKEN` junto al `GITHUB_PAT`.

### Instalacion (desde la rasp por SSH)
1. Conectarse a la rasp: ```ssh juanca@homeserver.local```
2. Pegar y ejecutar el comando generado por `generate-install-cmd.sh`
   - Esto clona el repositorio en la rasp y ejecuta el `init.sh` automáticamente

## Auto-despliegue

Cada push a `main` reinicia automáticamente `stacks.target` en la rasp — no hace falta entrar
por SSH a correr `git pull` ni `systemctl restart` a mano.

Cómo funciona: un self-hosted GitHub Actions runner corre en la rasp como usuario de sistema
`deploy-bot`, sin login y sin privilegios. El workflow (`.github/workflows/deploy.yml`) solo
escucha eventos `push` sobre `main` — como este repo es público pero sin colaboradores externos,
ningún fork puede disparar ese evento, así que no hay vector de ataque vía Pull Request. El
workflow no usa `actions/checkout` ni Actions de terceros: ejecuta directamente (sin `sudo`) un
script fijo y no editable (`/usr/local/bin/home-infra-deploy.sh`, root:root). El `git fetch` +
`reset --hard` sobre el clon ya existente nunca corre como root: corre como tu propio usuario (el
dueño real del clon), vía un sudoers acotado a ese único script. Lo que sí corre como root son dos
comandos fijos, sin argumentos: `home-infra-sync-units.sh` (regenera la unit
`docker-compose@.service` desde la plantilla del repo y habilita un `docker-compose@<stack>` por
cada carpeta nueva en `docker/`) y `systemctl restart stacks.target`. Deliberadamente **no**
tocamos nada más (SSH, firewall, usuarios, sudoers) desde el pipeline automático — esos cambios
siguen requiriendo entrar por SSH y correr `init.sh`/`harden.sh` a mano (ver `/etc/sudoers.d/deploy-bot`,
verificado en cada corrida de `harden.sh`).

Si un push modifica `init.sh` o cualquier `scripts/*.sh`, el deploy detecta el archivo cambiado
(vía `git diff` entre el commit viejo y el nuevo) y el correo de notificación avisa que hace falta
aplicar ese cambio a mano — el resto del push (docker-compose, configs, etc.) sí se aplica solo.

Para desactivar temporalmente un stack sin borrarlo del repo, agrega un archivo `.disabled` dentro
de su carpeta (ej. `docker/portainer/.disabled`) — `home-infra-sync-units.sh` lo salta.

### Variables de entorno (`.env`) via GitHub secrets
`.env.example` es la fuente única de qué variables existen (hoy: `SSH_PORT`, `PIHOLE_WEBPASSWORD`,
`CUPS_ADMIN_PASSWORD`, `SERVER_IP`, `TZ`, `DESEC_TOKEN`, `BASE_DOMAIN`, `ACME_EMAIL`). Ninguno de estos valores vive en el repo (es público) —
en cada deploy, el workflow pasa estos valores desde GitHub Actions secrets como variables de
entorno al runner, y `home-infra-write-env.sh` (corriendo como tu usuario, no como `deploy-bot`)
los escribe en `$REPO_DIR/.env` con permisos `600`. `docker-compose@.service` siempre arranca los
stacks con `docker compose --env-file=$REPO_DIR/.env`, así que cualquier stack puede usar estas
variables sin configuración adicional. `install_runner.sh` deriva la lista de variables leyendo
los nombres de `.env.example`, así que no hay una segunda lista que mantener sincronizada ahí.

Los secrets se cargan a mano en GitHub (Settings → Secrets and variables → Actions → New
repository secret, o `gh secret set NAME`) — uno por cada nombre en `.env.example`. Como el deploy
solo corre en push a `main`, la primera vez (o después de rotar un secret) hace falta aplicar los
valores manualmente sin esperar un commit:
```sh
gh workflow run deploy.yml --repo juank1520/home-infra
```

Para agregar una variable nueva: agregarla a `.env.example`, agregar la línea
`NAME: ${{ secrets.NAME }}` en `.github/workflows/deploy.yml`, y crear el secret en GitHub. Nada
más requiere cambios (GitHub Actions no permite enumerar secrets dinámicamente, por eso el paso en
`deploy.yml` sigue siendo manual).

`init.sh` crea un `.env` vacío (copiado de `.env.example`) si no existe, solo para que
`docker compose --env-file` nunca falle por archivo faltante en el primer boot — las contraseñas
reales llegan recién cuando corre el deploy de arriba.

Nota: la IP también sigue hardcodeada en `docker/pi-hole/etc-dnsmasq.d/99-pihole.conf` y en
`system/50-cloud-init.yaml` (netplan) — ninguno de los dos pasa por interpolación de
`docker compose`, así que `SERVER_IP` no los cubre todavía. Sigue pendiente.

### Setup del runner (una sola vez)
Si ya respondiste que si en `generate-install-cmd.sh`, este paso ya quedo hecho — `init.sh` corre
`scripts/install_runner.sh` automaticamente y es idempotente (si no hay `RUNNER_TOKEN` y el runner
no esta registrado, simplemente lo omite sin fallar).

Para configurarlo despues, o volver a registrarlo:
1. En tu computadora personal (requiere `gh` autenticado con permisos de admin sobre el repo):
   ```sh
   ./scripts/generate-runner-token.sh
   ```
2. Copiar y correr en la rasp el comando que imprime (usa `RUNNER_TOKEN`):
   ```sh
   RUNNER_TOKEN=... ./scripts/install_runner.sh
   ```
3. En GitHub → Settings → Secrets and variables → Actions, agregar `GMAIL_ADDRESS` y
   `GMAIL_APP_PASSWORD` (un [App Password](https://myaccount.google.com/apppasswords) dedicado,
   no la contraseña principal de tu cuenta) para que lleguen las notificaciones por correo.

## TLS / Certificados (deSEC + Let's Encrypt)
Traefik obtiene un certificado wildcard real de Let's Encrypt (`*.$BASE_DOMAIN`) vía el reto
DNS-01 — sin exponer ningún puerto a internet: solo crea un registro TXT temporal para validar que
controlas el dominio. Los nombres de cada servicio (`pihole.$BASE_DOMAIN`,
`jellyfin.$BASE_DOMAIN`, etc.) solo existen en el DNS interno de Pi-hole; nunca se publican hacia
afuera. El resultado es un certificado válido de fábrica en cualquier dispositivo (incluyendo TVs
con Plex/Jellyfin), sin instalar ninguna CA propia.

Setup (una sola vez):
1. Crear cuenta en [desec.io](https://desec.io), y crear un dominio `*.dedyn.io` (ej. `jchome.dedyn.io`).
2. Crear un token de API: en la consola de deSEC → *Token Management* → crear token (se muestra una
   sola vez, cópialo). Puede acotarse por dominio/subred para menor privilegio.
3. Cargar 3 secrets en GitHub (mismo mecanismo que el resto de variables, ver sección de arriba):
   `DESEC_TOKEN` (el token), `BASE_DOMAIN` (el **dominio completo**, ej. `jchome.dedyn.io`
   — no solo `jchome`; las plantillas lo usan tal cual, sin añadir el sufijo),
   `ACME_EMAIL` (correo para avisos de expiración de Let's Encrypt).
4. Aplicar: `gh workflow run deploy.yml --repo juank1520/home-infra` (o re-correr `init.sh`).

`docker/traefik/traefik.yml.template` y `docker/pi-hole/etc-dnsmasq.d/99-pihole.conf.template` se
renderizan con `BASE_DOMAIN` (mismo patrón de plantillas que `SERVER_IP`); el certificado se
persiste en `docker/traefik/acme.json` (gitignored, permisos 600 — contiene la clave privada).
El pre-chequeo de propagación de lego se desactiva (`propagation.disableChecks`) porque esta
LAN bloquea el DNS saliente por UDP 53; Let's Encrypt hace la validación real desde sus servidores.

Migrar más adelante a un dominio propio en Cloudflare solo implica cambiar `BASE_DOMAIN` por el
dominio real, cambiar el provider en `traefik.yml.template` (`desec` → `cloudflare`) y rotar el
token (`DESEC_TOKEN` → el nombre que espere el provider de Cloudflare, `CF_DNS_API_TOKEN`) — la
arquitectura de split-horizon y las labels de los servicios no cambian.

## Dashboard (Homepage)
`docker/homepage` corre [gethomepage/homepage](https://gethomepage.dev) en la raíz de `BASE_DOMAIN`
(`https://$BASE_DOMAIN`, sin subdominio) — muestra un box por servicio con su descripción y un link
directo a su URL. A diferencia de los demás servicios, su router de Traefik pide un certificado
propio para el dominio raíz (`tls.domains[0].main=$BASE_DOMAIN`) en vez del wildcard
(`*.$BASE_DOMAIN`) que usan los subdominios — el wildcard no cubre el dominio raíz.

Homepage descubre los servicios leyendo labels `homepage.*` directamente de los contenedores (monta
`/var/run/docker.sock` de solo lectura), no hay un `services.yaml` que mantener a mano. Para agregar
un servicio nuevo al dashboard, agregar a su `docker-compose.yml`:
```yaml
labels:
  - "homepage.group=Descargas"
  - "homepage.name=MiServicio"
  - "homepage.icon=miservicio.png"   # ver https://github.com/walkxcode/dashboard-icons
  - "homepage.href=https://miservicio.${BASE_DOMAIN}"
  - "homepage.description=Que hace este servicio"
```
Como las labels son parte de la config del contenedor, un `docker compose up -d` (recreate) es
necesario para que Homepage las vea — un simple `restart` no basta.

Portainer no está incluido en el dashboard (no se usa activamente), aunque sí quedó expuesto vía
Traefik (`portainer.$BASE_DOMAIN`) por consistencia con el resto del stack.

## Networks
Existen dos redes
1. dns_net: Resuelve los DNS, ecucha en el puerto 53/tcp y 53/udp, y resuleve los nombres como pihole.$BASE_DOMAIN a la ip de la rasperry, esta red solo debe de ser visible para pi-hole
2. proxy_net: Hace que traefik redireccione el trafico al contenedor dependiendo de que Host venga el trafico

## Almacenamiento (disco externo para Jellyfin/Sonarr/Radarr/qBittorrent)
El stack de streaming (`docker/jellyfin`, `docker/qbittorrent`, `docker/sonarr`,
`docker/radarr`) comparte un único disco externo montado en `/mnt/media` (`/mnt/media/movies`,
`/mnt/media/tv`, `/mnt/media/downloads`), para que qBittorrent pueda descargar, Sonarr/Radarr
importar/organizar y Jellyfin reproducir desde las mismas rutas de host. Nada de esto se aplica
solo — es manual, la primera vez que conectes el disco:

1. Conectar el disco por USB.
2. Correr el script interactivo (sin argumentos):
   ```sh
   sudo ./scripts/setup_media_mount.sh
   ```
   El script:
   - Detecta los discos conectados (excluyendo el disco del sistema) y te muestra una lista
     numerada con tamaño, sistema de archivos y si ya está montado en otro lado.
   - Vos elegís cuál usar — pide confirmación explícita antes de tocar nada.
   - Si el disco elegido no tiene sistema de archivos, ofrece formatearlo como ext4 (recomendado,
     nativo de Linux), pidiendo otra confirmación aparte porque **borra todo su contenido**.
   - Agrega la entrada a `fstab` (con `nofail`, para que un boot sin el disco conectado no se
     cuelgue), monta en `/mnt/media`, crea `movies`/`tv`/`downloads` con dueño `1000:1000`, y
     agrega un override de systemd (`RequiresMountsFor=/mnt/media`) a
     `docker-compose@jellyfin/qbittorrent/sonarr/radarr` para que esos 4 stacks se nieguen a
     arrancar si el disco no está montado (en vez de escribir silenciosamente sobre la carpeta
     vacía en la SD).
   - Es idempotente: correrlo de nuevo sobre un disco ya configurado no duplica la entrada de
     `fstab`.
3. Verificar: `mount | grep /mnt/media` y `ls -la /mnt/media`.

Gluetun/VPN delante de qBittorrent (para no exponer tu IP real en los swarms de torrent) queda
fuera de este setup — es una tarea aparte a futuro.

## Conectar los servicios entre sí
La red Docker ya conecta los contenedores (`internal_media_net` + `proxy_net`), y con el disco
montado todos comparten las mismas rutas de host — pero el cableado a nivel de aplicación vive en
la base de datos interna de cada servicio, no en archivos del repo, así que no se aplica solo con
un push. Checklist manual, una sola vez, desde cada web UI:

- **Prowlarr**: agregar indexers, y en *Settings → Apps* conectar Sonarr y Radarr (sync automático
  de indexers hacia ambos). Algunos indexers públicos (ej. 1337x) están detrás de Cloudflare y
  necesitan **FlareSolverr** (ver sección propia abajo) para pasar el desafío.
- **Sonarr / Radarr**: en *Settings → Download Clients* agregar qBittorrent (host `qbittorrent`,
  puerto `8080` — el nombre del contenedor resuelve por DNS de Docker dentro de
  `internal_media_net`); confirmar los root folders `/tv` y `/movies` respectivamente.
- **Jellyfin**: agregar bibliotecas apuntando a `/data/tvshows` y `/data/movies` (ya montados).
- **Jellyseerr** (`jellyseerr.${BASE_DOMAIN}`): portal de búsqueda y solicitudes de cara al
  usuario. En su wizard inicial: conectar a **Jellyfin** (server URL `http://jellyfin:8096`, para
  login y ver qué hay en la biblioteca) y a **Sonarr**/**Radarr** en *Settings → Services*
  (`http://sonarr:8989` y `http://radarr:7878`, con las API keys de `SONARR_API_KEY`/
  `RADARR_API_KEY` en `.env` — no hace falta entrar a la UI de Sonarr/Radarr a buscarlas, ver
  sección Configarr) para que los pedidos disparen las descargas. Los nombres de contenedor
  resuelven por DNS de Docker (Sonarr/Radarr vía `internal_media_net`, Jellyfin vía `proxy_net`).
  Jellyseerr en sí no tiene mecanismo de config por archivo, así que este paso sigue siendo manual
  por su propia naturaleza (no hay forma de automatizarlo vía git).

  Corre sobre la imagen oficial `fallenbagel/jellyseerr` (LinuxServer no publica una), por eso su
  config va en `/app/config` y no usa `PUID/PGID` como el resto del stack. El proyecto se está
  unificando con Overseerr bajo el nombre **Seerr** — cuando saque imagen estable (hoy solo hay
  tags `preview-seerr`), migrar es solo cambiar la imagen. Está detrás del mismo `ipallowlist`
  LAN-only que los *arr; si más adelante querés darle acceso remoto (como Jellyfin), quitá el
  middleware `jellyseerr-ipallowlist`.

## FlareSolverr (indexers detrás de Cloudflare)
Algunos indexers públicos de Prowlarr (1337x es el caso típico) están protegidos por Cloudflare y
Prowlarr no puede pasarlos solo — tira `Unable to access ..., blocked by CloudFlare Protection`.
[FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) es un proxy que resuelve el desafío
lanzando un Chrome headless real vía Selenium y devolviéndole las cookies a Prowlarr.

**Costo real en esta rasp**: cada request a un indexer protegido lanza un browser Chrome completo
— mucho más pesado que el pico de memoria que ya casi tumbó el sistema con Configarr (ver sección
"Memoria" abajo). `DISABLE_MEDIA=true` en el compose reduce algo el consumo (no carga imágenes/CSS
durante el desafío), pero no lo elimina. Si después de agregarlo notás que la rasp se pone lenta al
buscar releases, la alternativa sana es simplemente no usar los indexers que lo requieren (ej.
quedarte con TorrentGalaxy/LimeTorrents/Bitsearch, que no necesitan Cloudflare-bypass) en vez de
forzar el proxy.

Setup en Prowlarr (una sola vez, vía UI — no hay archivos de config para esto):
1. *Settings → Indexers → Indexer Proxies* → Add → **FlareSolverr**.
2. `Tags`: escribí un tag simple, ej. `flaresolverr` (en minúsculas).
3. `Host`: `http://flaresolverr:8191`.
4. Click el ícono de engranaje → `Request Timeout` = `180` (el desafío de Cloudflare puede tardar).
5. **Test** → **Save**.
6. Volver al indexer que lo necesita (ej. 1337x) → editarlo → agregarle el **mismo tag**
   (`flaresolverr`) en su campo `Tags` → **Save**.

Prowlarr solo enruta por FlareSolverr cuando **coinciden los tags** entre el proxy y el indexer, y
únicamente si detecta Cloudflare en la respuesta — los demás indexers siguen yendo directo, sin
pasar por el browser.

## Memoria (zram swap)
Esta rasp es una **Pi 4 con 2GB de RAM y sin swap** (`free -h` muestra `Swap: 0B`). Corriendo el
stack completo (Jellyfin, qBittorrent, Sonarr, Radarr, Prowlarr, Jellyseerr, Traefik, Pi-hole,
Homepage) ya deja menos de 200MB libres — cualquier pico de memoria adicional (por ejemplo, correr
`docker compose run --rm configarr`, que clona TRaSH-Guides y parsea JSON en memoria) puede agotar
la RAM disponible. Sin swap, el kernel no tiene colchón: en vez de que ese proceso puntual se
ponga más lento, todo el sistema empieza a competir por páginas de memoria (una request HTTP normal
entre contenedores puede tardar más de un minuto en vez de milisegundos).

`scripts/setup_zram.sh` instala `zram-tools` y habilita `zramswap.service` — swap comprimido en
RAM en vez de un swapfile tradicional en la SD (evita desgastarla con escrituras). Se deja el
`PERCENT=50`/`ALGO=lz4` por defecto de `/etc/default/zramswap`: `lz4` prioriza bajo costo de CPU
sobre mejor ratio de compresión, que es lo que conviene en los núcleos ARM de una Pi 4. Correr una
sola vez por SSH:
```sh
sudo ./scripts/setup_zram.sh
```
Verificar con `swapon --show` y `free -h` (debería aparecer una línea `zram0` en el swap).

## Configarr (perfiles de calidad de Sonarr/Radarr)
[Configarr](https://github.com/raydak-labs/configarr) sincroniza automáticamente quality profiles
y custom formats de TRaSH-Guides hacia Sonarr y Radarr vía su API — evita tener que copiarlos a
mano en cada UI. Se evaluó [Buildarr](https://github.com/buildarr/buildarr) para esto mismo (hace
más, incluyendo el wiring completo Prowlarr↔Sonarr/Radarr), pero **su último commit es de mayo de
2024** y tiene issues abiertos de 2025 donde crashea al leer configs de Radarr/Sonarr por cambios
en sus APIs (drift real, sin nadie arreglándolo) — por eso el wiring de apps sigue siendo manual
(ver arriba) y solo Configarr (activo, con commits semanales) se automatiza.

**Modelo de ejecución — importante**: a diferencia del resto del stack, Configarr **no es un
servicio persistente** — es un job de un solo disparo (corre, sincroniza, termina) sin cron ni
scheduler interno. Por eso `docker/configarr/` tiene un archivo `.disabled`, para que no se enable
como `docker-compose@configarr` bajo `stacks.target` (que asume servicios persistentes con
`restart: unless-stopped`). Por ahora se corre a mano, cuando quieras aplicar cambios de
TRaSH-Guides — todavía no hay ningún mecanismo de scheduling/timer automático para esto.

Las API keys de Sonarr/Radarr **no se copian a mano**: `docker/sonarr/docker-compose.yml` y
`docker/radarr/docker-compose.yml` fijan la key de cada app vía `SONARR__AUTH__APIKEY`/
`RADARR__AUTH__APIKEY` (variables de entorno que Sonarr/Radarr leen para sobreescribir
`config.xml` en cada arranque — no generan una key aleatoria propia), y `docker/configarr`
lee esas mismas variables directo (`api_key: !env SONARR_API_KEY` en `config.yml`, sin ningún
`secrets.yml`). Las dos viven en `SONARR_API_KEY`/`RADARR_API_KEY` de `.env.example`, cargadas
como GitHub Secrets igual que `DESEC_TOKEN` (ver "Para agregar una variable nueva" arriba) —
generalas una sola vez (ej. `openssl rand -hex 16`) y nunca más hay que tocarlas a mano.

Para aplicar/actualizar los perfiles cuando quieras:
```sh
cd docker/configarr && docker compose --env-file=../../.env run --rm configarr
```
Esto sincroniza el perfil `WEB-1080p` (Sonarr) / `HD Bluray + WEB` (Radarr) contra tus instancias.

## Orden de servicios para levantar
1. network ```sudo systemctl start docker-compose@networks```
2. traefik (reverse proxy) ```sudo systemctl start docker-compose@traefik```
3. pi-hole (DNS) ```sudo systemctl start docker-compose@pi-hole```

## Creamos los link virutales
Creamos los links virtuales de docker-compose@.service y stacks.target para poder manejar las imagenes de docker con systemctl y ejecutarlas en la inicializacion
`scripts/docker_services.sh` (setup inicial) y `home-infra-sync-units.sh` (auto-deploy) recorren `docker/*/` dinámicamente y hacen `systemctl enable docker-compose@<carpeta>` por cada stack, saltando las que tengan un archivo `.disabled` — un stack nuevo solo necesita su propia carpeta `docker/<nombre>/`, no requiere editar `init.sh` ni ningún script a mano.

Para ver la lista de servicios que corren con stacks.target 
```systemctl list-dependencies stacks.target```

Para levantar todos los servicios de stacks.target
```systemctl start stacks.target```

Para detenerlos `stop` reiniciarlos `restart`


## Gestion de imagenes en docker para arranque automatico
### Paso 1
Creamos el archivo docker-compose@.service dentro del repo

### Paso 2
Hacemos un enlace virtual para enlazar nuestro archivo docker-compose@.service con /etc/systemd/system
```sudo ln -s /home/juanca/infra/system/docker-compose@.service /etc/systemd/system/docker-compose@.service```

### Paso 3
Reiniciamos los servicios
```sudo systemctl daemon-reexec```
```sudo systemctl daemon-reload```

### Paso 4
Vemos si funcionó con el siguiente comando
```systemctl status docker-compose@portainer```

### Paso 5
Probamos iniciar el container
```sudo systemctl start docker-compose@portainer```

### Paso 6
Habilitamos para el inicio
```sudo systemctl enable docker-compose@portainer```


Logs
```journalctl -u docker-compose@portainer```
