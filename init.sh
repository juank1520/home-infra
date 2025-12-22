# Create virtual links to handle docker inicialization with systemctl
sudo ln -s /home/juanca/infra/system/docker-compose@.service /etc/systemd/system/docker-compose@.service
sudo ln -s /home/juanca/infra/system/stacks.target /etc/systemd/system/stacks.target


# Link docker services into stack.target docker-compose@DOCKER-FILE-NAME
sudo systemctl enable docker-compose@networks
sudo systemctl enable docker-compose@pi-hole
sudo systemctl enable docker-compose@traefik
sudo systemctl enable docker-compose@qbittorrent
sudo systemctl enable docker-compose@sonarr
sudo systemctl enable docker-compose@radarr
# Enable stacks.target to inicilize when the system starts
sudo systemctl enable stacks.target
