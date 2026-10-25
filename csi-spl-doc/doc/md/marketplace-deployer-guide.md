# Spool Hub Google Cloud Marketplace Deployer Guide

**Specification Reference**: `csi-spl-doc/specs/156-gcp-marketplace-listing` (GAP-09)  
**Target Product**: Spool Hub (Virtual Machine / Docker Compose Solution)  
**License**: GNU Affero General Public License v3.0 (AGPL-3.0)  

---

## 1. Overview & Architecture

Spool Hub deploys directly into your Google Cloud project as a self-contained Compute Engine virtual machine running a containerized production stack via Docker Compose. The architecture is engineered to provide complete data privacy and sovereignty while eliminating the high idle costs of managed cloud databases.

### 1.1 Stack Components
- **Spool Hub Core API (`hub`)**: Compiled Go daemon serving the REST/WebSocket messaging engine, agent mailbox endpoints, and lock management.
- **Web UI & Reverse Proxy (`web`)**: Nuxt 3 static web interface served securely by Caddy reverse proxy, providing automatic TLS certificates.
- **Relational Database (`pg`)**: PostgreSQL 16 container with local persistent storage and automated forward-only migrations.
- **Object Storage (`s3`)**: SeaweedFS container providing high-throughput S3-compatible blob storage for message attachments and session logs.
- **Process Supervisor**: Host systemd unit (`spool-hub.service`) managing lifecycle, boot ordering, and automatic restart policies.

---

## 2. Prerequisites & Sizing

### 2.1 Google Cloud Prerequisites
Before launching Spool Hub from the Google Cloud Marketplace, ensure:
1. An active Google Cloud project with billing enabled.
2. The Compute Engine API (`compute.googleapis.com`) is enabled in your project.
3. Your IAM user or service account has the **Compute Admin** (`roles/compute.admin`) role or equivalent deployment permissions.

### 2.2 Sizing & Infrastructure Costs
The Spool Hub software license is 100% free ($0.00). Infrastructure costs are billed directly by Google Cloud according to your selected machine type and disk configuration:

| Profile | Compute Engine Machine Type | Boot Disk | Estimated Monthly Cost | Target Workload |
|---|---|---|---|---|
| **Recommended (Standard)** | `e2-standard-2` (2 vCPU, 8 GB RAM) | 50 GB Balanced Persistent Disk | **~$50 – $65 / month** | Fleets of active coding agents, long-lived message history, and multi-user Web UI. |
| **Economy (Minimal)** | `e2-medium` (1 vCPU, 4 GB RAM) | 30 GB Standard Persistent Disk | **~$25 – $35 / month** | Small test environments, single-agent sandboxes, or initial evaluation. |

---

## 3. Deployment Walkthrough

### 3.1 Launching via Google Cloud Marketplace
1. Navigate to the **Google Cloud Marketplace** within the Google Cloud Console.
2. Search for **Spool Hub** and open the product listing.
3. Review the overview, pricing ($0 software fee), and click **Launch**.

### 3.2 Instance Configuration
In the deployment configuration form:
1. **Deployment Name**: Enter a name for your deployment (default: `spool-hub-1`).
2. **Zone / Region**: Select your preferred Google Cloud region and zone (e.g., `europe-north1-a` or `us-central1-a`).
3. **Machine Type**: Select `e2-standard-2` (recommended) or `e2-medium` (minimal).
4. **Boot Disk**: Set disk size to at least 50 GB Balanced Persistent Disk (SSD recommended for optimal database performance).
5. **Networking & Firewalls**:
   - Verify that **Allow HTTP traffic** (TCP port 80) is checked.
   - Verify that **Allow HTTPS traffic** (TCP port 443) is checked.
   - Ensure the VPC network permits inbound SSH (TCP port 22) for administrator management.
6. Click **Deploy** to begin VM provisioning.

---

## 4. Post-Deployment Access & Initial Setup

### 4.1 Accessing the Web UI
1. Once the deployment completes, note the **External IP address** assigned to the instance.
2. In your web browser, navigate to:
   ```
   https://<EXTERNAL_IP>
   ```
3. When accessing directly via IP, Caddy serves a self-signed TLS certificate. You may proceed past the initial browser certificate warning for direct IP access.

### 4.2 Mapping a Custom Domain (Recommended)
To enable automated, trusted Let's Encrypt TLS certificates:
1. Create a DNS **A record** in your domain registrar or Cloud DNS pointing your chosen domain (e.g. `spool.example.com`) to the VM's external IP address.
2. SSH into your Spool Hub VM:
   ```bash
   gcloud compute ssh spool-hub-1 --zone=<ZONE>
   ```
3. Update the `DOMAIN` variable in `/opt/spool-hub/.env`:
   ```bash
   sudo sed -i 's/^DOMAIN=.*/DOMAIN=spool.example.com/' /opt/spool-hub/.env
   sudo systemctl restart spool-hub
   ```
4. Caddy will automatically negotiate an ACME certificate with Let's Encrypt. Navigate to `https://spool.example.com`.

---

## 5. Operations, Maintenance & Troubleshooting

### 5.1 Service Management
Spool Hub runs as a systemd service managing the Docker Compose stack:

```bash
# Check overall service status
sudo systemctl status spool-hub

# Restart the complete stack
sudo systemctl restart spool-hub

# Stop all services
sudo systemctl stop spool-hub
```

### 5.2 Checking Container Health & Logs
To inspect individual containers and stream logs:

```bash
# View container status and port bindings
sudo docker compose -f /opt/spool-hub/docker-compose.yml ps

# Follow logs from all containers
sudo docker compose -f /opt/spool-hub/docker-compose.yml logs -f

# Follow logs for specific service (hub, web, pg, s3)
sudo docker compose -f /opt/spool-hub/docker-compose.yml logs -f hub
```

### 5.3 Backup & Data Persistence
All persistent data (PostgreSQL database records and SeaweedFS object blobs) resides in named Docker volumes mapped under `/var/lib/docker/volumes/` on the persistent disk:
- **Snapshots**: Use Google Cloud Persistent Disk Scheduled Snapshots to take daily automated point-in-time disk snapshots.
- **Database Dump**:
  ```bash
  sudo docker compose -f /opt/spool-hub/docker-compose.yml exec -T pg pg_dumpall -U spool > /backup/spool_db_$(date +%Y%m%d).sql
  ```

---

## 6. Open-Source Licensing & Compliance

Spool Hub is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.
- In compliance with Google Cloud Marketplace copyleft distribution requirements, the full source code archive and license notices are pre-installed directly on the instance at:
  ```
  /usr/local/share/doc/spool-hub/
  ```
- End User License Agreement (EULA): https://github.com/csitea/csi-spl/blob/master/LICENSE
- Community Issue Tracker & Source Code: https://github.com/csitea/csi-spl
