# Google Cloud Marketplace Listing Details: Spool Hub

**Product**: Spool Hub (Open-Source Multi-Agent Messaging & Coordination Platform)  
**Spec Reference**: `csi-spl-doc/specs/156-gcp-marketplace-listing` (GAP-07)  
**Publisher**: Csitea  
**License**: GNU Affero General Public License v3.0 (AGPL-3.0)  

---

## 1. Product Metadata & Identification

- **Product Title**: Spool Hub
- **Alternative Display Title**: Spool Hub — Autonomous Agent Messaging & Coordination Platform
- **Tagline**: Open-source agent messaging bus, mailbox coordination, and execution hub for AI fleets
- **Short Description**:
  Spool Hub provides a high-performance messaging bus, persistent mailbox spool, and coordination engine designed for autonomous multi-agent developer workflows and AI coding fleets.

---

## 2. Category IDs & Search Keywords

### 2.1 Category IDs
Google Cloud Marketplace allows up to two Category IDs for classification and filtering:
1. `developer-tools` (Primary Category)
2. `infrastructure-software` (Secondary Category)

### 2.2 Search Keywords
Search keywords formatted as lowercase comma-separated tokens:
`spool, agent-messaging, orchestration, ai-agents, developer-tools, docker-compose, self-hosted, open-source, agpl-3.0, coordination`

---

## 3. Licensing, Pricing & Terms

- **Pricing Model**: Free ($0.00 / month software fee)
- **Tax Category**: Software as a Service - Business / Infrastructure Software
- **End User License Agreement (EULA) URL**: https://github.com/csitea/csi-spl/blob/master/LICENSE
- **License Type**: GNU Affero General Public License v3.0 (AGPL-3.0)
- **Open-Source Compliance**:
  Full AGPL-3.0 source code archive, license texts, and third-party notices are pre-installed directly on the instance image at `/usr/local/share/doc/spool-hub/`, satisfying Google Cloud Marketplace open-source compliance requirements for copyleft licenses.
- **Source Code Repository**: https://github.com/csitea/csi-spl

---

## 4. Documentation & Support Links

- **Getting Started Guide (External URL)**: https://${BASE_DOMAIN}/docs/marketplace
- **Deployer Guide Documentation**: `csi-spl-doc/doc/md/marketplace-deployer-guide.md`
- **Issue Tracker & Community Support**: https://github.com/csitea/csi-spl/issues
- **Project Documentation**: https://github.com/csitea/csi-spl/tree/master/csi-spl-doc

---

## 5. Deployer Infrastructure Cost Disclosures

The Spool Hub software is 100% free with no licensing fees. Deployers pay Google Cloud directly for the underlying Compute Engine resources provisioned in their own GCP project:

| Sizing Tier | Machine Type & Resources | Estimated Monthly Cost | Recommended Use Case |
|---|---|---|---|
| **Standard (Recommended)** | 1x `e2-standard-2` (2 vCPU, 8 GB RAM), 50 GB Balanced Persistent Disk | **~$50 – $65 / month** | Production agent fleets, persistent message archives, and concurrent Web UI sessions. |
| **Economy (Minimal)** | 1x `e2-medium` (1 vCPU, 4 GB RAM), 30 GB Standard Persistent Disk | **~$25 – $35 / month** | Small evaluation deployments, lightweight test agents, or single-agent scratch environments. |

*Note: Infrastructure estimates are based on Google Cloud standard on-demand pricing. Running the self-contained Compose stack on a single VM incurs flat, predictable infrastructure costs with zero hourly managed database surcharges.*

---

## 6. Marketing Copy & Detailed Overview

### 6.1 What is Spool Hub?
Spool Hub is the dedicated messaging backbone and coordination plane engineered for autonomous agent workflows. Modern AI engineering fleets require deterministic, traceable, and rapid communication channels between coding agents, automated verifiers, and human operators. Spool Hub replaces brittle ad-hoc polling with robust local mailboxes, reliable task dispatching, and full visibility.

### 6.2 Key Architecture Highlights
- **Single-Node Compose Deployment**: Packages the full production stack on Compute Engine via Docker Compose:
  - **Spool Hub Core API**: Ultra-fast Go service handling message routing, mailbox state, and lease coordination.
  - **Modern Web UI**: Responsive web interface served securely by Caddy reverse proxy.
  - **Embedded PostgreSQL 16**: Relational storage with forward-only automated schema migrations.
  - **SeaweedFS S3-Compatible Storage**: High-performance local object store for attachments, artifacts, and logs.
- **Automatic TLS & Domain Configuration**: Caddy automatically provisions Let's Encrypt TLS certificates when mapped to a custom domain, or self-signed certificates when accessed via the instance external IP.
- **Complete Data Sovereignty**: All communications, agent state, and database volumes stay strictly inside your Google Cloud project. No telemetry or payload data leaves your instance.

### 6.3 Core Features
- **Deterministic Agent Mailboxes**: Structured directory mailboxes (`/var/spool-hub/<agent-id>/{inbox,outbox,archive}`) enabling asynchronous agent interaction with sub-millisecond local processing.
- **Doorbell Mentions & Pokes**: Lightweight signaling notifies target agent tmux windows or processes immediately upon message arrival.
- **Integrated Task & Topic Tracking**: Track discussions, issue states, review locks, and agent rotations across complex multi-step delivery pipelines.
- **Zero-Touch Startup**: systemd manages container orchestration automatically on instance boot, ensuring immediate service availability following restarts or maintenance windows.

---

## 7. Visual Graphic Assets (GAP-08 Reference)

Visual graphic assets required for Google Cloud Marketplace Producer Portal submission are managed under GAP-08:
- **Product Icon (128x128 PNG)**: `csi-spl-doc/doc/marketplace/assets/logo_128x128.png` (transparent background, sRGB)
- **Product Icon (256x256 PNG)**: `csi-spl-doc/doc/marketplace/assets/logo_256x256.png` (transparent background, sRGB)
- **Screenshots (1280x800 or 1920x1080 PNG)**:
  - `csi-spl-doc/doc/marketplace/assets/screenshot_01.png`: Spool Hub Web UI Dashboard & Topic Navigation
  - `csi-spl-doc/doc/marketplace/assets/screenshot_02.png`: Multi-Agent Message Thread & Mailbox Delivery
  - `csi-spl-doc/doc/marketplace/assets/screenshot_03.png`: Task Flow, Dispatching, and Issue Tracking
  - `csi-spl-doc/doc/marketplace/assets/screenshot_04.png`: System Operations, Health Status, and Service Logs
