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
workflow no usa `actions/checkout` ni Actions de terceros: solo ejecuta, vía `sudo`, un script fijo
y no editable (`/usr/local/bin/home-infra-deploy.sh`, root:root) que hace `git fetch` + `reset
--hard` sobre el clon ya existente y reinicia `stacks.target`. `deploy-bot` tiene sudo acotado
únicamente a ese comando (ver `/etc/sudoers.d/deploy-bot`, verificado en cada corrida de
`harden.sh`). Al terminar, se manda un correo de notificación (éxito o falla) para detectar
cualquier deploy inesperado.

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

## Orden de servicios para levantar
1. network ```sudo systemctl start docker-compose@networks```
2. traefik (reverse proxy) ```sudo systemctl start docker-compose@traefik```
3. pi-hole (DNS) ```sudo systemctl start docker-compose@pi-hole```

## Creamos los link virutales
Creamos los links virtuales de docker-compose@.service y stacks.target para poder manejar las imagenes de docker con systemctl y ejecutarlas en la inicializacion
Cada vez que se crea un servicio se tiene que dar de alta el el stacks target con ```sudo systemctl enable docker-compose@SERVICE-DOCKER-FILE```
Y se tiene que agregar ese comando al ini.sh

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
