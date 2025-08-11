#!/bin/bash
set -e

echo "=== Imzami Server Stack Installation ==="

# 1. IPSec VPN Environment File
cat <<EOF > .env
VPN_IPSEC_PSK=R01920280000
VPN_USER=imzami
VPN_PASSWORD=11221099
VPN_DNS_NAME=proxy.imzami.com
VPN_DNS_SRV1=45.90.28.89
VPN_DNS_SRV2=45.90.30.89

# Database
DB_ROOT_PASSWORD=rootpass
DB_NAME=imzamidb
DB_USER=imzami
DB_PASSWORD=dbpass

# phpMyAdmin
PMA_HOST=db
PMA_PORT=3306

# Redis
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=redispass
EOF

# 2. IPSec VPN Container
docker run --name vpn-ipsec --env-file .env --restart=always   -v ikev2-vpn-data:/etc/ipsec.d   -v /lib/modules:/lib/modules:ro   -p 500:500/udp -p 4500:4500/udp   -d --privileged imzami/vpn-ipsec

# 3. SOCKS5 Proxy Container
docker run -d   --name proxy-socks5   --restart=always   --dns=45.90.28.89   --dns=45.90.30.89   -p 99:1080   -e SOCKS5_USER=imzami   -e SOCKS5_PASSWORD=11221099   imzami/proxy-socks5

# 4. OpenVPN Proxy Container
mkdir -p openvpn-config
docker run -d     --name proxy-openvpn     --device=/dev/net/tun     --cap-add=NET_ADMIN     --dns=45.90.28.89 --dns=45.90.30.89     -e "OPENVPN_FILENAME=imzami-aes128.ovpn"     -e "LOCAL_NETWORK=192.168.1.0/24"     -e "ONLINECHECK_DELAY=300"     -v ./openvpn-config:/app/ovpn/config     -p 1099:1099     imzami/proxy-openvpn

# 5. Web Stack (docker-compose.yml)
cat <<'YAML' > docker-compose.yml
version: '3.9'

services:
  nginx:
    image: nginx:alpine
    container_name: imzami_nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./app:/var/www/html
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
      - /var/log/nginx:/var/log/nginx
    depends_on:
      - php
    networks:
      - imzami_net

  php:
    build:
      context: .
      dockerfile: Dockerfile
    image: imzami_php
    container_name: imzami_php
    restart: always
    working_dir: /var/www/html
    volumes:
      - ./app:/var/www/html
    depends_on:
      - db
      - redis
    networks:
      - imzami_net

  db:
    image: mariadb:lts
    container_name: imzami_db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: \${DB_NAME}
      MYSQL_USER: \${DB_USER}
      MYSQL_PASSWORD: \${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
      - ./docker/mariadb/my.cnf:/etc/mysql/my.cnf
      - /var/log/mysql:/var/log/mysql
    healthcheck:
      test: ["CMD-SHELL", "sh -c 'mariadb-admin -u\${DB_USER} -p\${DB_PASSWORD} ping -h 127.0.0.1 || exit 1'"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - imzami_net

  phpmyadmin:
    image: phpmyadmin:latest
    container_name: imzami_pma
    restart: always
    ports:
      - "8080:80"
    environment:
      PMA_HOST: \${PMA_HOST}
      PMA_PORT: \${PMA_PORT}
    depends_on:
      - db
    networks:
      - imzami_net

  redis:
    image: redis:alpine
    container_name: imzami_redis
    restart: always
    environment:
      REDIS_HOST: \${REDIS_HOST}
      REDIS_PORT: \${REDIS_PORT}
      REDIS_PASSWORD: \${REDIS_PASSWORD}
    volumes:
      - ./docker/redis/redis.conf:/usr/local/etc/redis/redis.conf
      - redis_data:/data
      - /var/log/redis:/var/log/redis
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - imzami_net

volumes:
  db_data:
  redis_data:

networks:
  imzami_net:
    driver: bridge
YAML

# 6. Start Web Stack
docker compose up -d

# 7. Add Cron Job for NextDNS Link Update
(crontab -l 2>/dev/null; echo "*/10 * * * * curl -s https://link-ip.nextdns.io/69b4bc/54dd79b6f240abc3 > /dev/null") | crontab -

echo "=== Installation Complete ==="
