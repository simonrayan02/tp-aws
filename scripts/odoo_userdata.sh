#!/bin/bash
set -euo pipefail
exec > /var/log/odoo-setup.log 2>&1

echo "=== [$(date)] Bootstrap Odoo démarré ==="

DB_PASSWORD="${db_password}"
REPL_PASSWORD="${repl_password}"
ODOO_ADMIN_PASS="${odoo_admin_pass}"
VPC_CIDR="${vpc_cidr}"

PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
NODE_NAME="odoo-master-$${INSTANCE_ID: -6}"

echo "=== Noeud : $NODE_NAME | IP : $PRIVATE_IP | AZ : $AZ ==="

dnf update -y
dnf install -y docker curl
systemctl start docker
systemctl enable docker

curl -SL "https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir -p /opt/odoo/{config,addons,data,pg-init,nginx}
cd /opt/odoo

cat > /opt/odoo/config/odoo.conf <<ODOOCONF
[options]
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
data_dir = /var/lib/odoo
admin_passwd = $ODOO_ADMIN_PASS
db_host = db
db_port = 5432
db_user = odoo
db_password = $DB_PASSWORD
db_name = odoo
workers = 4
max_cron_threads = 2
longpolling_port = 8072
proxy_mode = True
log_level = info
ODOOCONF

cat > /opt/odoo/pg-init/01_replication.sh <<PGINIT
#!/bin/bash
psql -v ON_ERROR_STOP=1 --username "\$POSTGRES_USER" <<SQL
DO \\\$\\\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator REPLICATION LOGIN PASSWORD '$REPL_PASSWORD';
  END IF;
END
\\\$\\\$;
SQL
PGINIT
chmod +x /opt/odoo/pg-init/01_replication.sh

cat > /opt/odoo/nginx/nginx.conf <<'NGINX'
upstream odoo_backend { server odoo:8069; }
upstream odoo_longpoll { server odoo:8072; }
server {
    listen 80;
    server_name _;
    proxy_read_timeout 720s;
    location /longpolling {
        proxy_pass http://odoo_longpoll;
    }
    location / {
        proxy_pass http://odoo_backend;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX

cat > /opt/odoo/docker-compose.yml <<COMPOSE
version: "3.9"
networks:
  odoo-net:
    driver: bridge
volumes:
  pg-data:
  odoo-data:
services:
  db:
    image: postgres:15
    container_name: odoo-db
    restart: always
    environment:
      POSTGRES_DB: odoo
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: $DB_PASSWORD
    volumes:
      - pg-data:/var/lib/postgresql/data
      - /opt/odoo/pg-init:/docker-entrypoint-initdb.d:ro
    command: >
      postgres
        -c wal_level=logical
        -c max_wal_senders=10
        -c max_replication_slots=10
        -c listen_addresses='*'
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - odoo-net
  odoo:
    image: odoo:17
    container_name: odoo-app
    restart: always
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - odoo-data:/var/lib/odoo
      - /opt/odoo/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - /opt/odoo/addons:/mnt/extra-addons
    ports:
      - "8069:8069"
      - "8072:8072"
    environment:
      HOST: db
      PORT: "5432"
      USER: odoo
      PASSWORD: $DB_PASSWORD
    networks:
      - odoo-net
  nginx:
    image: nginx:alpine
    container_name: odoo-nginx
    restart: always
    volumes:
      - /opt/odoo/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "80:80"
    depends_on:
      - odoo
    networks:
      - odoo-net
COMPOSE

docker-compose -f /opt/odoo/docker-compose.yml up -d

cat > /etc/systemd/system/odoo-stack.service <<'SYSTEMD'
[Unit]
Description=Odoo Stack
Requires=docker.service
After=docker.service

[Service]
WorkingDirectory=/opt/odoo
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
RemainAfterExit=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable odoo-stack

echo "=== [$(date)] Bootstrap Odoo terminé sur $NODE_NAME ==="