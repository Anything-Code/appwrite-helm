# Appwrite Helm Chart

![Version: 1.3.0](https://img.shields.io/badge/Version-1.3.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.9.0](https://img.shields.io/badge/AppVersion-1.9.0-informational?style=flat-square)

A Helm chart for deploying [Appwrite](https://appwrite.io) on Kubernetes. Supports MariaDB or MongoDB as the database backend, Redis for caching/queues, and the OpenRuntimes executor for Cloud Functions and Sites.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [Database Choice](#database-choice)
5. [Storage Architecture](#storage-architecture)
6. [Executor & Docker Requirement](#executor--docker-requirement)
7. [Ingress](#ingress)
8. [Sites (Static Site Hosting)](#sites-static-site-hosting)
9. [Chart Dependencies](#chart-dependencies)
10. [Configuration Reference](#configuration-reference)
11. [Examples](#examples)
12. [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Kubernetes** | v1.25+ (tested on K3s v1.30) |
| **Helm** | v3.10+ |
| **Ingress Controller** | nginx-ingress or equivalent (ingress class: `nginx`) |
| **Docker daemon** | Must be installed **on every node** alongside the container runtime (containerd/CRI-O). Required by the executor to build and run cloud functions/sites. |
| **Storage** | ReadWriteOnce (RWO) PVCs at minimum. ReadWriteMany (RWX) recommended for multi-node setups without affinity constraints. |

### Docker Alongside Containerd

Appwrite's executor creates Docker containers directly via the Docker socket to run function and site builds. This is separate from the Kubernetes container runtime.

On each node that will run executor pods:

```bash
# Example for Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

Verify Docker is running alongside K8s:

```bash
docker version       # Docker daemon
crictl version       # K8s container runtime (containerd)
```

Both must be operational. The executor mounts `/var/run/docker.sock` from the host.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Ingress Controller                       │
│                  (nginx, traefik, etc.)                          │
├──────────┬──────────────┬───────────────────────────────────────┤
│ /console │ appwrite.dom │ *.sites.dom    │ /v1/realtime         │
│          │ /v1/*        │                │                      │
▼          ▼              ▼                ▼                      │
┌────────┐ ┌────────────┐ ┌────────────┐  ┌──────────┐           │
│Console │ │    Core    │ │    Core    │  │ Realtime │           │
│  (UI)  │ │   (API)    │ │  (router)  │  │(websocket│           │
└────────┘ └─────┬──────┘ └────────────┘  └────┬─────┘           │
                 │                              │                 │
        ┌────────┴─────────────────┬────────────┘                 │
        ▼                          ▼                              │
  ┌───────────┐             ┌───────────┐                         │
  │   Redis   │             │ MariaDB / │                         │
  │  (queue   │             │  MongoDB  │                         │
  │  + cache) │             │           │                         │
  └─────┬─────┘             └───────────┘                         │
        │                                                         │
        ▼                                                         │
  ┌───────────────────────────────────────────────────────────────┐
  │              Background Workers                                │
  │  builds · functions · deletes · databases                      │
  │  mails · messaging · webhooks · certificates                   │
  │  audits · migrations · stats-usage                             │
  │  stats-resources · scheduler-*                                 │
  └───────────┬───────────────────────────────────────────────────┘
              │ HTTP (same-node only)
              ▼
  ┌───────────────────┐          ┌────────────────────┐
  │    Executor        │ Docker  │  Runtime Containers │
  │   (DaemonSet)      │────────▶│  (node, python,    │
  │                    │  socket │   php, ruby, etc.)  │
  └────────────────────┘         └────────────────────┘
         ▲
         │ hostPath mounts
  ┌──────┴──────────────────┐
  │  /var/appwrite/builds   │
  │  /var/appwrite/functions│
  │  /var/appwrite/sites    │
  │  /tmp (build workspace) │
  └─────────────────────────┘
```

### Components

| Component | Kind | Replicas | Purpose |
|---|---|---|---|
| **core** | Deployment | 1 (HPA optional) | REST API, dashboard backend, site router |
| **console** | Deployment | 1 | Appwrite Console web UI |
| **realtime** | Deployment | 1 (HPA optional) | WebSocket server for real-time events |
| **executor** | DaemonSet | 1 per node | Manages Docker containers for function/site builds and executions |
| **maintenance** | Deployment | 1 | Periodic cleanup tasks (cache, logs, sessions) |
| **scheduler-functions** | Deployment | 1 | Cron scheduler for cloud functions |
| **scheduler-executions** | Deployment | 1 | Scheduler for function executions |
| **scheduler-messages** | Deployment | 1 | Scheduler for messaging |
| **worker-builds** | Deployment | 1 | Processes function/site build jobs |
| **worker-functions** | Deployment | 1 | Processes function execution jobs |
| **worker-databases** | Deployment | 1 | Database operation worker |
| **worker-deletes** | Deployment | 1 | Handles resource deletion |
| **worker-certificates** | Deployment | 1 | SSL certificate provisioning |
| **worker-mails** | Deployment | 1 | Email delivery |
| **worker-messaging** | Deployment | 1 | Push/SMS message delivery |
| **worker-webhooks** | Deployment | 1 | Webhook delivery |
| **worker-audits** | Deployment | 1 | Audit log processing |
| **worker-migrations** | Deployment | 1 | Data migration processing |
| **worker-stats-usage** | Deployment | 1 | Usage statistics aggregation |
| **worker-stats-resources** | Deployment | 1 | Resource statistics |
| **stats-resources** | Deployment | 1 | Stats collection |
| **usage** | Deployment | 1 | Usage data collection |
| **clamav** | Deployment | 1 | Antivirus scanning for uploads |
| **redis** | StatefulSet | 1 | Cache, pub/sub, and message queue (Bitnami subchart) |
| **mariadb** / **mongodb** | StatefulSet | 1 | Primary database (Bitnami subchart) |

---

## Quick Start

```bash
# Add Bitnami repo for subchart dependencies
helm repo add bitnami https://charts.bitnami.com/bitnami

# Build dependencies
cd appwrite-helm
helm dependency build

# Install with MariaDB (default)
helm install appwrite . -n appwrite --create-namespace

# Install with MongoDB
helm install appwrite . -n appwrite --create-namespace \
  --set database.type=mongodb \
  --set mariadb.enabled=false \
  --set mongodb.enabled=true

# Install with custom values file
helm install appwrite . -n appwrite --create-namespace -f my-values.yaml
```

### Upgrade

```bash
helm upgrade appwrite . -n appwrite -f my-values.yaml
```

> **Note:** If you change the executor service type (e.g., from headless to ClusterIP), you must delete the service first since `clusterIP` is immutable:
> ```bash
> kubectl delete svc appwrite-executor -n appwrite
> helm upgrade appwrite . -n appwrite -f my-values.yaml
> ```

---

## Database Choice

Set `database.type` to either `mariadb` or `mongodb`. Enable the corresponding subchart and disable the other:

### MariaDB (default)

```yaml
database:
  type: mariadb

mariadb:
  enabled: true
  auth:
    rootPassword: "your-root-password"
    database: appwrite
    username: appwrite
    password: "your-password"

mongodb:
  enabled: false
```

### MongoDB

```yaml
database:
  type: mongodb

mariadb:
  enabled: false

mongodb:
  enabled: true
  auth:
    enabled: true
    rootPassword: "your-root-password"
    usernames: [appwrite]
    passwords: [your-password]
    databases: [appwrite]
```

> **Important:** Appwrite 1.9.0 defaults to MongoDB internally. Both backends are fully supported. Do not switch database types on existing deployments without migrating your data.

---

## Storage Architecture

### Volume Types

The chart uses two classes of volumes:

**PersistentVolumeClaims (PVCs)** — for data managed only by Kubernetes pods:

| Volume | Default Size | Used By |
|---|---|---|
| `uploads` | 1Gi | core, builds, deletes |
| `cache` | 1Gi | core, deletes |
| `config` | 1Gi | core |
| `certificates` | 1Gi | core, certificates worker, deletes |
| `imports` | 1Gi | core, migrations |

**hostPath volumes** — for data shared between Kubernetes pods and Docker containers:

| Path | Default | Used By |
|---|---|---|
| `/var/appwrite/builds` | `executor.hostPaths.builds` | executor, core, builds, deletes, functions |
| `/var/appwrite/functions` | `executor.hostPaths.functions` | executor, core, builds, deletes, functions |
| `/var/appwrite/sites` | `executor.hostPaths.sites` | executor, core, builds, deletes, functions |
| `/tmp` | (system) | executor build workspace |

hostPath volumes are necessary because the executor creates Docker containers (outside Kubernetes) that must read build artifacts from the same filesystem. PVCs are not visible to Docker containers.

### Pod Affinity (coreAffinity)

When using ReadWriteOnce (RWO) PVCs, all pods that share a volume must run on the same node. The chart provides a `coreAffinity` mechanism:

```yaml
appwrite:
  volumes:
    coreAffinity:
      enabled: true   # default: true
```

When enabled, worker pods (builds, functions, deletes, certificates, migrations) are scheduled on the same node as the core pod using pod affinity rules. **Disable this only if you use ReadWriteMany (RWX) storage.**

---

## Executor & Docker Requirement

The executor is deployed as a **DaemonSet** — one pod per node. It manages function and site runtime containers through the Docker socket.

### How It Works

1. A build/function request arrives at the core API
2. Core enqueues a job via Redis
3. The builds/functions worker picks up the job and calls the executor HTTP API
4. The executor creates a Docker container with the appropriate runtime image
5. The Docker container reads source code from `/tmp` (host bind mount) and produces build output
6. The executor copies the output to `/var/appwrite/builds` (hostPath)

### Same-Node Routing

The executor service uses `internalTrafficPolicy: Local` to ensure worker pods only communicate with the executor on their own node. This is critical because:

- Build source files are written to hostPath on a specific node
- The Docker container must be on the same node to see those files via bind mounts
- The `/tmp` directory is node-local

### Executor Configuration

```yaml
executor:
  enabled: true
  image:
    repository: openruntimes/executor
    tag: "0.11.4"
  dockerSocketPath: "/var/run/docker.sock"
  runtimesNetwork: "appwrite_runtimes"
  inactiveThreshold: 60           # seconds before idle containers are removed
  maintenanceInterval: 60         # cleanup interval in seconds
  hostPaths:
    builds: "/var/appwrite/builds"
    functions: "/var/appwrite/functions"
    sites: "/var/appwrite/sites"
  # Docker Hub credentials (optional, avoids rate limits)
  dockerHub:
    username: ""
    password: ""
```

### Compute Limits

System-wide maximums for function and site runtime specifications:

```yaml
compute:
  maxCpus: 8        # max CPU cores per runtime container
  maxMemory: 8192   # max memory (MB) per runtime container
  buildTimeout: 900  # build timeout in seconds
  sizeLimit: 30000000  # max payload size in bytes
```

---

## Ingress

The chart creates up to four Ingress resources:

| Ingress | Host | Path | Backend |
|---|---|---|---|
| **core** | `appwrite.domain` | `/` | core service |
| **console** | `appwrite.domain` | `/console` | console service |
| **realtime** | `appwrite.domain` | `/v1/realtime` | realtime service |
| **sites** | `*.sites.domain` | `/` | core service |

All ingresses use `ingressClassName: nginx`. Customize via annotations:

```yaml
appwrite:
  domain: appwrite.example.com
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
    tls:
      enabled: true
```

### Sites Ingress (Wildcard)

Sites require a wildcard DNS entry and wildcard TLS certificate:

```yaml
sites:
  domain: "sites.example.com"
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
    tls:
      enabled: true
      secretName: "sites-wildcard-tls"
```

DNS: `*.sites.example.com` → your ingress controller IP.

---

## Sites (Static Site Hosting)

Appwrite Sites lets you deploy static and SSR sites. Requirements:

1. Set `sites.domain` to your sites base domain
2. Enable `sites.ingress` for wildcard routing
3. Add site runtimes (e.g., `node-16.0`) to `sites.runtimes` or `functions.runtimes`
4. Ensure Docker is installed on nodes (executor builds sites as Docker containers)

```yaml
sites:
  domain: "sites.example.com"
  runtimes: []          # additional runtimes beyond functions.runtimes
  timeout: 900
  ingress:
    enabled: true
```

---

## Chart Dependencies

| Repository | Name | Version | Condition |
|---|---|---|---|
| https://charts.bitnami.com/bitnami | mariadb | 11.5.5 | `mariadb.enabled` |
| https://charts.bitnami.com/bitnami | mongodb | 15.1.2 | `mongodb.enabled` |
| https://charts.bitnami.com/bitnami | redis | 17.9.0 | always |

Build them before installing:

```bash
helm dependency build
```

---

## Configuration Reference

### Global

| Parameter | Description | Default |
|---|---|---|
| `nameOverride` | Partial name override (keeps release name) | `""` |
| `fullnameOverride` | Full name override | `""` |
| `namespaceOverride` | Namespace override | `""` |
| `commonLabels` | Extra labels for all resources | `{}` |

### Appwrite Core

| Parameter | Description | Default |
|---|---|---|
| `appwrite.image.repository` | Appwrite image | `appwrite/appwrite` |
| `appwrite.image.tag` | Image tag | Chart `appVersion` |
| `appwrite.replicaCount` | Core API replicas | `1` |
| `appwrite.env` | Environment (`development` / `production`) | `development` |
| `appwrite.sslKey` | Encryption key for secrets (base64) | `changeme` |
| `appwrite.domain` | Primary domain for API and console | `appwrite.local` |
| `appwrite.workersPerCore` | Swoole workers per CPU core | `2` |
| `appwrite.ingress.enabled` | Enable core ingress | `true` |
| `appwrite.autoscaling.enabled` | Enable HPA for core | `false` |

### Console

| Parameter | Description | Default |
|---|---|---|
| `console.enabled` | Deploy the Console UI | `true` |
| `console.image.repository` | Console image | `appwrite/console` |
| `console.image.tag` | Console image tag | `7.5.7` |

### Database

| Parameter | Description | Default |
|---|---|---|
| `database.type` | Backend: `mariadb` or `mongodb` | `mariadb` |
| `mariadb.enabled` | Deploy MariaDB subchart | `true` |
| `mongodb.enabled` | Deploy MongoDB subchart | `false` |

### Storage

| Parameter | Description | Default |
|---|---|---|
| `storage.device` | Storage adapter: `local`, `s3`, `dospaces`, `backblaze`, `linode`, `wasabi` | `local` |
| `storage.uploadLimit` | Max upload size | `30Mi` |
| `storage.bucket.*` | S3-compatible bucket settings | — |

### Executor

| Parameter | Description | Default |
|---|---|---|
| `executor.enabled` | Deploy executor DaemonSet | `true` |
| `executor.image.tag` | Executor version | `0.11.4` |
| `executor.dockerSocketPath` | Docker socket path on host | `/var/run/docker.sock` |
| `executor.hostPaths.builds` | Host path for build storage | `/var/appwrite/builds` |
| `executor.hostPaths.functions` | Host path for function storage | `/var/appwrite/functions` |
| `executor.hostPaths.sites` | Host path for site storage | `/var/appwrite/sites` |
| `executor.nodeSelector` | Node selector for executor pods | `{}` |
| `executor.tolerations` | Tolerations for executor pods | `[]` |

### Compute

| Parameter | Description | Default |
|---|---|---|
| `compute.maxCpus` | Max CPU cores per runtime | `8` |
| `compute.maxMemory` | Max memory (MB) per runtime | `8192` |
| `compute.buildTimeout` | Build timeout (seconds) | `900` |

### Functions

| Parameter | Description | Default |
|---|---|---|
| `functions.timeout` | Function execution timeout (seconds) | `900` |
| `functions.cpus` | CPU limit per function | `1` |
| `functions.memory` | Memory limit per function (MB) | `256` |
| `functions.runtimes` | Enabled runtimes list | `[node-16.0, php-8.0, ...]` |

### Sites

| Parameter | Description | Default |
|---|---|---|
| `sites.domain` | Sites base domain | `""` |
| `sites.runtimes` | Additional site runtimes | `[]` |
| `sites.ingress.enabled` | Wildcard ingress for sites | `false` |

### SMTP

| Parameter | Description | Default |
|---|---|---|
| `smtp.host` | SMTP host (empty = disable mail) | `maildev` |
| `smtp.port` | SMTP port | `1025` |
| `smtp.secure` | Use TLS | `false` |
| `smtp.user` | SMTP username | `""` |
| `smtp.pass` | SMTP password | `""` |

### ClamAV

| Parameter | Description | Default |
|---|---|---|
| `clamav.enabled` | Enable antivirus scanning | `true` |
| `clamav.image.repository` | ClamAV image | `clamav/clamav` |

---

## Examples

### Minimal Production Setup (MongoDB)

```yaml
appwrite:
  env: production
  sslKey: "<your-base64-encryption-key>"
  domain: appwrite.example.com
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
    tls:
      enabled: true
  volumes:
    coreAffinity:
      enabled: true

database:
  type: mongodb

mariadb:
  enabled: false

mongodb:
  enabled: true
  auth:
    rootPassword: "<strong-password>"
    usernames: [appwrite]
    passwords: ["<strong-password>"]
    databases: [appwrite]
  persistence:
    size: 10Gi

redis:
  auth:
    enabled: false
  master:
    persistence:
      size: 2Gi

smtp:
  host: smtp.example.com
  port: 587
  secure: true
  user: apikey
  pass: "<smtp-api-key>"

executor:
  hostPaths:
    builds: /var/appwrite/builds
    functions: /var/appwrite/functions
    sites: /var/appwrite/sites
```

### With S3 Storage

```yaml
storage:
  device: s3
  bucket:
    accessKey: AKIA...
    secret: "<secret>"
    region: us-east-1
    name: my-appwrite-bucket
    endpoint: ""   # leave empty for AWS, set for S3-compatible
```

### With Sites Enabled

```yaml
sites:
  domain: "sites.example.com"
  ingress:
    enabled: true
    tls:
      enabled: true
      secretName: sites-wildcard-tls

functions:
  runtimes:
    - node-16.0
    - python-3.9
```

---

## Troubleshooting

### "tar: /tmp/code.tar.gz: Cannot open: No such file or directory"

The executor's internal Swoole table has a 64-byte key limit for runtime names. If the executor pod hostname is too long, the runtime is not tracked, and the maintenance task deletes build files mid-build. The chart sets `hostname: "exc"` on executor pods to keep the key within limits.

If you see this error, verify the executor hostname:

```bash
kubectl exec -n appwrite <executor-pod> -- hostname
# Should output: exc
```

### Executor service not routing correctly

The executor service uses `internalTrafficPolicy: Local`. If you upgraded from a version that used a headless service (`clusterIP: None`), the `clusterIP` field is immutable and Helm cannot change it. Delete and recreate:

```bash
kubectl delete svc appwrite-executor -n appwrite
helm upgrade appwrite . -n appwrite -f values.yaml
```

Verify the service has a real ClusterIP:

```bash
kubectl get svc appwrite-executor -n appwrite
# Should show a ClusterIP (not "None")
```

### "No matching executor found. Please check the value of OPR_EXECUTOR_IMAGE"

This warning appears at executor startup because the executor pod runs in Kubernetes (containerd) but tries to find itself in Docker. It is **non-fatal** — builds and function executions still work. The executor simply cannot auto-join the Docker runtime network; it creates the network and connects runtime containers to it.

### Build worker can't reach executor

Ensure all pods that access shared hostPath volumes are on the same node:

```bash
kubectl get pods -n appwrite -o wide | grep -E 'core|builds|executor'
```

Core, builds, and the executor should all show the same `NODE`. If not, check that `appwrite.volumes.coreAffinity.enabled` is `true`.

### Docker not available on nodes

The executor requires Docker. Verify on each node:

```bash
docker version
ls -la /var/run/docker.sock
```

If Docker is not installed, the executor will fail to create runtime containers.
