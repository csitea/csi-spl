# Customer Marketplace VM. Not an estate step. Docker and Compose start the
# pinned images. The AGPL tree is intended at /usr/local/share/doc/spool-hub/.
# Passwords are generated on the VM into /opt/spool-hub/runtime.env. The
# customer edits that file. They are not stored in terraform state.

resource "google_compute_network" "spool" {
  project                 = var.project_id
  name                    = format("%s-net", substr(var.goog_cm_deployment_name, 0, 59))
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "spool" {
  project                  = var.project_id
  name                     = format("%s-subnet", substr(var.goog_cm_deployment_name, 0, 56))
  region                   = var.region
  network                  = google_compute_network.spool.id
  ip_cidr_range            = "10.80.0.0/24"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "web" {
  # checkov:skip=CKV_GCP_106: The customer WUI is served on tcp 80 of the ephemeral address. SSH is not open.

  project       = var.project_id
  name          = format("%s-web", substr(var.goog_cm_deployment_name, 0, 59))
  network       = google_compute_network.spool.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["spool-web"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_service_account" "spool" {
  project      = var.project_id
  account_id   = format("spoolhub%s", substr(md5(var.goog_cm_deployment_name), 0, 8))
  display_name = "Spool Hub VM"
}

resource "google_compute_instance" "spool" {
  # checkov:skip=CKV_GCP_38: Google-managed encryption. A customer-supplied key would land in tfvars and state.
  # checkov:skip=CKV_GCP_40: The WUI is served on the ephemeral public address. SSH is not open. The address is released when the VM stops.

  project                   = var.project_id
  name                      = var.goog_cm_deployment_name
  machine_type              = var.machine_type
  zone                      = var.zone
  tags                      = ["spool-web"]
  can_ip_forward            = false
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = var.boot_disk_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.spool.id
    # trivy:ignore:GCP-0031 The customer WUI is served on the ephemeral address. SSH is not open. SPL-3363
    access_config {}
  }

  metadata = {
    block-project-ssh-keys = "TRUE"
    enable-oslogin         = "TRUE"
    serial-port-enable     = "FALSE"
  }

  service_account {
    email = google_service_account.spool.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata_startup_script = <<EOT
#!/bin/bash
install -d -m 0755 /usr/local/share/doc/spool-hub
if [ ! -d /usr/local/share/doc/spool-hub/.git ]; then
  git clone --depth 1 https://github.com/csitea/csi-spl.git /usr/local/share/doc/spool-hub || true
fi
cat > /usr/local/share/doc/spool-hub/SOURCE.txt <<'SRC'
https://github.com/csitea/csi-spl
AGPL-3.0
SRC
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl ca-certificates git openssl
if ! apt-get install -y docker-compose-plugin; then
  apt-get install -y docker-compose
fi
systemctl enable --now docker
i=0
while [ "$i" -lt 30 ]; do
  if docker info >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 2
done
install -d -m 0700 /opt/spool-hub
owner_pw=$(openssl rand -hex 24)
runtime_pw=$(openssl rand -hex 24)
s3_pw=$(openssl rand -hex 24)
ip=$(curl -fsS -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)
if [ -z "$ip" ]; then
  ip=127.0.0.1
fi
umask 077
cat > /opt/spool-hub/runtime.env <<ENV
# Customer starter. Edit this file, then re-run the compose file in this directory.
# The first confirmed sign-up becomes the tenant owner while bootstrap owner is true.
SPOOL_DB_OWNER_PASSWORD=$owner_pw
SPOOL_DB_RUNTIME_PASSWORD=$runtime_pw
SPOOL_S3_SECRET_KEY=$s3_pw
SPOOL_PUBLIC_URL=http://$ip
ENV
chmod 600 /opt/spool-hub/runtime.env
cat > /opt/spool-hub/compose.yml <<'COMPOSE'
name: spoolhub
services:
  pg:
    image: ${var.spool_pg_image}
    container_name: spool-hub-pg
    environment:
      POSTGRES_USER: spool_hub
      POSTGRES_PASSWORD: $${SPOOL_DB_OWNER_PASSWORD}
      POSTGRES_DB: spool_hub
    volumes:
      - pg-data:/var/lib/postgresql/data
    restart: unless-stopped
  s3:
    image: ${var.spool_s3_image}
    container_name: spool-hub-s3
    user: seaweed
    command: ["mini", "-dir=/data", "-ip=s3", "-s3.port=9000"]
    environment:
      AWS_ACCESS_KEY_ID: spool-hub
      AWS_SECRET_ACCESS_KEY: $${SPOOL_S3_SECRET_KEY}
    volumes:
      - s3-data:/data
    restart: unless-stopped
  hub-init:
    image: ${var.spool_hub_image}
    container_name: spool-hub-init
    user: "10001:10001"
    command: ["init"]
    environment:
      SPOOL_OWNER_DSN: "postgres://spool_hub:$${SPOOL_DB_OWNER_PASSWORD}@pg:5432/spool_hub?sslmode=disable"
      SPOOL_OWNER_PASSWORD: $${SPOOL_DB_OWNER_PASSWORD}
      SPOOL_RUNTIME_ROLE: spool_hub_rt
      SPOOL_RUNTIME_PASSWORD: $${SPOOL_DB_RUNTIME_PASSWORD}
      SPOOL_TENANT: main
      SPOOL_PUBLIC_URL: http://127.0.0.1
      SPOOL_BIND: 127.0.0.1
    volumes:
      - hub-state:/var/lib/spool/state
    restart: "no"
  hub:
    image: ${var.spool_hub_image}
    container_name: spool-hub
    user: "10001:10001"
    command: ["serve"]
    environment:
      SPOOL_HUB_ENV: prd
      SPOOL_CLOUD_PROVIDER: none
      SPOOL_S3_ENDPOINT: http://s3:9000
      SPOOL_S3_BUCKET: spool-files
      SPOOL_S3_ACCESS_KEY: spool-hub
      SPOOL_S3_SECRET_KEY: $${SPOOL_S3_SECRET_KEY}
      SPOOL_S3_USE_PATH_STYLE: "true"
      SPOOL_HUB_DB_DSN: "postgres://spool_hub_rt:$${SPOOL_DB_RUNTIME_PASSWORD}@pg:5432/spool_hub?sslmode=disable"
      SPOOL_HUB_FILES_DIR: /var/lib/spool/files
      SPOOL_PUBLIC_URL: $${SPOOL_PUBLIC_URL}
      SPOOL_BIND: 0.0.0.0
      SPOOL_HUB_AUTH_APP_URL: $${SPOOL_PUBLIC_URL}
      SPOOL_HUB_VIEW_CORS_ORIGINS: $${SPOOL_PUBLIC_URL}
      SPOOL_HUB_VIEW_DOOR: session
      SPOOL_HUB_TRUSTED_PROXY_HOPS: "1"
      SPOOL_HUB_AUTH_NATIVE_TRUSTED_PROXY_HOPS: "1"
      SPOOL_HUB_AUTH_NATIVE_ENABLED: "true"
      SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS: "false"
      SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED: "false"
      SPOOL_HUB_AUTH_BOOTSTRAP_OWNER: "true"
      SPOOL_HUB_AUTH_COOKIE_SECURE: "false"
      SPOOL_HUB_MAIL_TRANSPORT: log
      SPOOL_HUB_MAIL_PREFLIGHT: warn
    volumes:
      - hub-state:/var/lib/spool/state:ro
      - hub-files:/var/lib/spool/files
    restart: unless-stopped
  web:
    image: ${var.spool_web_image}
    container_name: spool-hub-web
    environment:
      SPOOL_SITE_ADDRESS: ":80"
      SPOOL_PUBLIC_URL: $${SPOOL_PUBLIC_URL}
      SPOOL_TENANT: main
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - web-data:/data
    restart: unless-stopped
volumes:
  pg-data:
  s3-data:
  hub-state:
  hub-files:
  web-data:
COMPOSE
chmod 644 /opt/spool-hub/compose.yml
cd /opt/spool-hub
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose --env-file /opt/spool-hub/runtime.env "$@"
  else
    docker-compose --env-file /opt/spool-hub/runtime.env "$@"
  fi
}
compose up -d pg s3
i=0
while [ "$i" -lt 60 ]; do
  if docker exec spool-hub-pg pg_isready -h 127.0.0.1 -U spool_hub >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 2
done
if ! compose up --exit-code-from hub-init --abort-on-container-exit hub-init; then
  echo "hub-init failed" >&2
  exit 1
fi
compose up -d hub web
EOT
}
