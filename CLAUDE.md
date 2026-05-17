# Flux Cluster

Home infrastructure GitOps repo managed by Flux. All changes go through git, never `kubectl apply` directly.

## Infrastructure Overview

### Compute

- **k3s node:** `tomnuc.home` (10.0.0.1), single-node cluster, 64GB RAM, k3s v1.34.7
- **TrueNAS:** TrueNAS CORE 13.0-U3.1, provides NFS storage and hosts FreeBSD jails

### TrueNAS Jails

- **Plex:** FreeBSD 13.2-RELEASE-p10, media server with hardware transcoding. Logs at `/usr/local/plexdata/Plex Media Server/Logs/`. Alloy installable via pkg for log shipping to Loki.
- **Transmission:** FreeBSD 11.2-RELEASE-p15, torrent client. Too old for modern monitoring agents.

### Network

- **Router/Firewall:** UniFi Cloud Gateway Ultra (10.0.3.254, SNMP v2c)
- **Access Point:** UniFi AP (10.0.1.187, SNMP v2c)
- **Managed Switches:**
  - TP-Link TL-SG108E 6.0 x2 (8-port, no SNMP support)
  - Netgear GS724T (24-port, 10.0.3.253, SNMP v2c, community string `public`)
- **MetalLB range:** 10.0.0.2 - 10.0.0.128

### Smart Home

- **Zigbee radio:** UZG-01 XZG gateway (10.0.1.52), connected to zigbee2mqtt via TCP (tcp://10.0.1.52:6638)
- **Home Assistant:** Runs in k8s with hostNetwork, manages automations, Zigbee devices via zigbee2mqtt/MQTT
- **MQTT broker:** Mosquitto in k8s
- **Voice assistant stack:** Piper (TTS), Whisper (STT), OpenWakeWord (wake word detection)
- **ESPHome:** Config synced from git (github.com/ADeane6/esphome_config), runs with hostNetwork + privileged for mDNS

### Media Stack

- **Plex:** In TrueNAS jail (not k8s), media server with transcoding
- **Radarr:** Movie management (hotio image)
- **Sonarr:** TV management (hotio image)
- **Jackett:** Torrent indexer proxy (linuxserver image)
- **Overseerr:** Media request management
- **Tautulli:** Plex monitoring/analytics
- **Kometa:** Plex metadata management
- **Plex Trakt Sync:** Syncs Plex watch history to Trakt
- **Maintainerr:** Automated Plex library maintenance
- **Notifiarr:** Notification relay (Discord/Telegram) for *arr apps and Plex

### Monitoring Stack

- **Grafana:** UI at grafana.${SECRET_DOMAIN}, Cloudflare Access auth proxy
- **Loki:** Log storage, monolithic mode, 50Gi, 60-day retention, schema v13, OTLP ingestion enabled
- **Alloy:** DaemonSet for k8s pod log collection + syslog listener on 10.0.0.18
- **Grafana MCP:** In-cluster MCP server for Claude Code to query Grafana/Loki

### DNS & Networking

- **AdGuard Home:** DNS ad-blocking
- **k8s-gateway:** CoreDNS plugin for external DNS resolution of k8s services
- **external-dns:** Manages Cloudflare DNS records from ingress annotations
- **cert-manager:** Let's Encrypt certs via Cloudflare DNS-01 challenge
- **Cloudflared:** Cloudflare tunnel for services not on ingress

### Other

- **Hajimari:** Dashboard/start page

## Performance Investigation Areas

### Plex Transcoding
- Plex runs in a TrueNAS FreeBSD jail, not in k8s
- Hardware transcoding capability depends on the tomnuc hardware (check for Intel QuickSync/GPU passthrough to jail)
- Monitor via Tautulli for stream stats, Plex logs for transcode errors
- Key metrics: CPU usage during transcode, concurrent stream count, direct play vs transcode ratio

### TrueNAS Tuning
- ZFS ARC size tuning (competes with k3s for the 64GB RAM)
- Disk I/O performance for NFS shares serving media to Plex and *arr apps
- Pool health, SMART status, disk temperatures
- Network throughput between TrueNAS and k3s node

### Network Performance
- Switch port utilisation (SNMP via Netdata)
- Link speeds (watch for degraded 100Mbps links on gigabit ports)
- Inter-VLAN routing performance through UniFi gateway
- k3s node NIC: Realtek r8169 on enp1s0 — known to negotiate 100Mbps with bad cables

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
│   ├── monitoring/ # Grafana, Loki, Alloy
│   └── system-upgrade/ # k3s upgrade controller
docs/               # Design docs and implementation plans
Local-apps/         # Apps running outside k8s (recyclarr config)
```

## Key Conventions

- **GitOps only.** No `kubectl apply`, no `helm install`. Commit → push → Flux reconciles.
- **Helm charts:** Most apps use bjw-s `app-template` chart. System services use upstream charts.
- **Secrets:** SOPS-encrypted with age key. Files named `secret.sops.yaml`.
- **Ingress:** nginx ingress class, cert-manager for TLS, external-dns for Cloudflare records.
- **Domain:** `${SECRET_DOMAIN}` substituted by Flux from cluster-settings ConfigMap.
