# Create virtual links to handle docker inicialization with systemctl
sudo ln -s /home/juanca/infra/system/docker-compose@.service /etc/systemd/system/docker-compose@.service
sudo ln -s /home/juanca/infra/system/stacks.target /etc/systemd/system/stacks.target


sudo systemctl enable docker-compose@networks
sudo systemctl enable docker-compose@pi-hole
sudo systemctl enable docker-compose@traefik
