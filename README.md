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
`CUPS_ADMIN_PASSWORD`, `SERVER_IP`, `TZ`). Ninguno de estos valores vive en el repo (es público) —
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

## Networks
Existen dos redes
1. dns_net: Resuelve los DNS, ecucha en el puerto 53/tcp y 53/udp, y resuleve los nombres como pihole.lan a la ip de la rasperry, esta red solo debe de ser visible para pi-hole
2. proxy_net: Hace que traefik redireccione el trafico al contenedor dependiendo de que Host venga el trafico

## TLS / Certificados
`docker/traefik/init.certs.sh` corre automáticamente en `init.sh` (antes de levantar los stacks) y genera, si no existe uno válido, una CA local (`Juank Root CA`) y un certificado wildcard `*.lan` en `docker/traefik/certs/`. Traefik lo sirve para `pihole.lan` y demás hosts `*.lan`. Los certificados están en `.gitignore` — se regeneran por host en cada instalación.

Para que el navegador **no** muestre aviso de certificado, hay que importar **una sola vez** la CA (`docker/traefik/certs/ca.crt`) en el almacén de confianza de cada dispositivo cliente (no se puede automatizar desde el servidor). Cópiala a tu equipo, por ejemplo:
```
scp -P <SSH_PORT> juanca@<SERVER_IP>:~/home-infra/docker/traefik/certs/ca.crt .
```
y añádela como CA de confianza en el sistema/navegador. Sin este paso, la página carga igual pero con la advertencia de "no seguro".

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
