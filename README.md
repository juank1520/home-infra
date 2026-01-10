## Primeros pasos
1. Instalar Ubuntu server.
2. Deshabilitar DHCP, asignar ip estatico y dehabilitar wifi en Netplan. ```cp system/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml```
3. Ejecutar el init.sh. ```./init.sh```
4. Agregar la llave SSH generada en el init.sh a Github para poder clonar el repositiorio
5. Cumplir con el assestment de seguridad de init.sh
6. De ser necesario correr nuevamente el assestment de seguridad ```./scripts/security-assestment.sh```
7. Clonar el repositorio `home-infra` ```git clone git@github.com:juank1520/home-infra.git```

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
