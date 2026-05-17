# Flux Cluster

Home infrastructure GitOps repo managed by Flux. All changes go through git, never `kubectl apply` directly.

## Infrastructure Overview

### Compute

- **k3s node:** `tomnuc.home` (10.0.0.1), single-node cluster, 64GB RAM, Fedora 37 (kernel 6.0.7), k3s v1.34.7
- **TrueNAS:** TrueNAS CORE 13, Intel Xeon E3-1220 v3 (4 cores, 3.1GHz), no iGPU. Provides NFS storage and hosts FreeBSD jails.

### TrueNAS Jails

- **Plex:** FreeBSD 13.2-RELEASE-p10, media server (no hardware transcoding). Alloy installed for log shipping to Loki. Netdata installed streaming to parent.
- **Transmission:** FreeBSD 11.2-RELEASE-p15, torrent client. Too old for modern monitoring agents.

### Network

- **Router/Firewall:** UniFi Cloud Gateway Ultra (10.0.3.254, SNMP v2c)
- **Access Point:** UniFi AP (10.0.1.187)
- **Managed Switches:**
  - TP-Link TL-SG108E 6.0 x2 (8-port, no SNMP support, no syslog support)
  - Netgear GS724T (24-port, 10.0.3.253, SNMP v2c, community string `public`)
- **k3s node NIC:** Realtek r8169 on enp1s0 -- known to negotiate 100Mbps with bad cables
- **MetalLB range:** 10.0.0.2 - 10.0.0.128

### Smart Home

- **Zigbee radio:** UZG-01 XZG gateway (10.0.1.52), connected to zigbee2mqtt via TCP (tcp://10.0.1.52:6638)
- **Home Assistant:** Runs in k8s with hostNetwork, manages automations, Zigbee devices via zigbee2mqtt/MQTT. Remote Logger HACS integration sends structured OTLP logs to Loki.
- **MQTT broker:** Mosquitto in k8s
- **Voice assistant stack:** Piper (TTS), Whisper (STT), OpenWakeWord (wake word detection)
- **ESPHome:** Config synced from git (github.com/ADeane6/esphome_config), runs with hostNetwork + privileged for mDNS

### Media Stack

- **Plex:** In TrueNAS jail (not k8s), media server. No hardware transcode (Xeon E3-1220 v3 has no iGPU). Primary client: NVIDIA SHIELD Android TV with Onkyo TX-SR333 receiver.
- **Radarr:** Movie management (hotio image, CLEF JSON logging)
- **Sonarr:** TV management (hotio image, CLEF JSON logging)
- **Jackett:** Torrent indexer proxy (linuxserver image)
- **Overseerr:** Media request management
- **Tautulli:** Plex monitoring/analytics (API key: check config.ini, http_proxy must be enabled for reverse proxy)
- **Kometa:** Plex metadata management
- **Plex Trakt Sync:** Syncs Plex watch history to Trakt
- **Maintainerr:** Automated Plex library maintenance
- **Notifiarr:** Notification relay (Discord/Telegram) for *arr apps and Plex

### Monitoring Stack

- **Grafana:** UI at grafana.${SECRET_DOMAIN}, Cloudflare Access auth proxy
- **Loki:** Log storage, monolithic mode, 50Gi, 60-day retention, schema v13, OTLP ingestion enabled
- **Alloy:** DaemonSet for k8s pod log collection, syslog listener (10.0.0.18:514 UDP, 1514 TCP, RFC 3164), host journal log collection
- **Prometheus:** Scrapes graphite-exporter (TrueNAS metrics) and k8s auto-discovered targets. 20Gi, 30-day retention.
- **Graphite-exporter:** Receives TrueNAS Graphite metrics on 10.0.0.21:2003, converts to Prometheus format
- **Netdata:** Parent + child DaemonSet for node/container metrics, SNMP polling (Netgear GS724T, UniFi UCG Ultra). Netdata Cloud claimed. MCP server available.
- **Grafana MCP:** In-cluster MCP server for Claude Code to query Grafana/Loki

### MetalLB Service IPs

- **10.0.0.18:** Alloy syslog listener
- **10.0.0.19:** Loki push API (used by Plex jail Alloy)
- **10.0.0.20:** Netdata parent (used by Plex jail Netdata streaming)
- **10.0.0.21:** Graphite-exporter (receives TrueNAS Graphite data)

### DNS & Networking

- **AdGuard Home:** DNS ad-blocking
- **k8s-gateway:** CoreDNS plugin for external DNS resolution of k8s services
- **external-dns:** Manages Cloudflare DNS records from ingress annotations
- **cert-manager:** Let's Encrypt certs via Cloudflare DNS-01 challenge (JSON logging enabled)
- **Cloudflared:** Cloudflare tunnel for services not on ingress
- **NFS mounts:** TrueNAS (freenas.home/10.0.0.129) serves media via NFS to radarr/sonarr pods. Mounts configured as soft (timeo=50, retrans=3) to prevent node lockups.

### Other

- **Hajimari:** Dashboard/start page

## Performance Investigation Areas

### Plex Transcoding
- See docs/plex-optimisation.md for detailed findings
- No hardware transcode available (Xeon E3-1220 v3 has no iGPU)
- Primary issue was audio-only transcoding on SHIELD due to disabled HDMI passthrough (now fixed)
- Remote users transcode due to client bandwidth limits

### TrueNAS Tuning
- ZFS ARC size tuning (current ARC ~11.6GB on a system with available RAM)
- Disk I/O performance for NFS shares serving media
- Pool health, SMART status, disk temperatures
- Metrics available via Prometheus (truenas_* metrics from graphite-exporter)

### Network Performance
- Switch port utilisation via Netdata SNMP
- k3s node NIC: Realtek r8169 -- previously negotiated 100Mbps due to bad cable (fixed, now 1Gbps)

### Known Issues (Resolved)
- **2026-05-17 crash:** Node locked up due to NFS hard mount hang, compounded by degraded 100Mbps network link (bad cable). iowait climbed from 14% to 39% over an hour before the node became unresponsive. Fix: replaced cable (1Gbps restored), changed NFS mounts from hard to soft.

## Repo Structure

```
cluster/
├── flux/           # Flux config, helm repos, cluster variables
├── apps/
│   ├── default/    # Main application workloads
│   ├── games/      # Game servers
│   ├── kube-system/ # System services (cert-manager, metallb, ingress, etc.)
│   ├── monitoring/ # Grafana, Loki, Alloy, Netdata, Prometheus, graphite-exporter
│   └── system-upgrade/ # k3s upgrade controller
docs/               # Design docs, implementation plans, optimisation notes
Local-apps/         # Apps running outside k8s (recyclarr config)
```

## Key Conventions

- **GitOps only.** No `kubectl apply`, no `helm install`. Commit -> push -> Flux reconciles.
- **Helm charts:** Most apps use bjw-s `app-template` chart. System services use upstream charts.
- **Secrets:** SOPS-encrypted with age key. Files named `secret.sops.yaml`.
- **Ingress:** nginx ingress class, cert-manager for TLS, external-dns for Cloudflare records.
- **Domain:** `${SECRET_DOMAIN}` substituted by Flux from cluster-settings ConfigMap.
- **Flux variable escaping:** Use `$${1}` instead of `${1}` in ConfigMaps to prevent Flux kustomize substitution.
