cd /infra/docker/traefik
mkdir -p certs
cd certs

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt \
  -subj "/C=GT/O=Juank Homelab/CN=Juank Root CA"

openssl genrsa -out local.key 4096

openssl req -new -key local.key \
  -out local.csr \
  -subj "/CN=*.lan"

openssl x509 -req -in local.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out local.crt -days 825 -sha256 \
  -extfile < (printf "subjectAltName=DNS:*.lan,DNS:pihole.lan")

