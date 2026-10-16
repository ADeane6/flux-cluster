# Flux Cluster

Home infrastructure GitOps repo managed by Flux. All changes go through git, never `kubectl apply` directly.

## Infrastructure Overview

### Compute

- **k3s node:** `tomnuc.home` (10.0.0.1), single-node cluster, 64GB RAM, Fedora 37 (kernel 6.0.7), k3s v1.34.7
- **TrueNAS:** TrueNAS CORE 13, Intel Xeon E3-1220 v3 (4 cores, 3.1GHz), no iGPU. Provides NFS storage and hosts FreeBSD jails.

### TrueNAS Jails

- **Plex (`plex-stable`):** FreeBSD 13.2-RELEASE-p10, stopped since Plex was migrated to k8s. Alloy installed for log shipping to Loki, Netdata streaming to parent.
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
- **Home Assistant:** Runs in k8s (not hostNetwork; ESPHome is the hostNetwork pod), manages automations, Zigbee devices via zigbee2mqtt/MQTT. Remote Logger HACS integration sends structured OTLP logs to Loki.
- **MQTT broker:** Mosquitto in k8s
- **Voice assistant stack:** Piper (TTS), Whisper (STT), OpenWakeWord (wake word detection)
- **ESPHome:** Config synced from git (github.com/ADeane6/esphome_config), runs with hostNetwork + privileged for mDNS
- **NUC smart plug** (`10.0.1.89`, Athom Plug V2, ESPHome device `nuc-smart-plug`): powers the NUC, used by the TrueNAS watchdog and plug monitor. Config has `api`/`wifi` `reboot_timeout: 0s` (HA runs on the NUC, so the default 15-min timeout made the plug reboot-loop during NUC outages), `early_pin_init: "false"` (otherwise every plug restart/OTA cuts the NUC), and `Power On State: Always On`. REST URLs use entity names (`/switch/Switch`, `/sensor/Voltage`); don't rename entities.

### Media Stack

- **Plex:** Runs in k8s on the NUC (linuxserver image, LB `10.0.0.22`), migrated from the TrueNAS jail mainly for hardware transcoding: `/dev/dri` from the NUC's Intel UHD 620 (Quick Sync) is passed into the pod. Media via the NFS PVCs, transcode dir is an emptyDir. Primary client: NVIDIA SHIELD Android TV with Onkyo TX-SR333 receiver.
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
- **10.0.0.22:** Plex (port 32400)

### DNS & Networking

- **AdGuard Home:** DNS ad-blocking
- **k8s-gateway:** CoreDNS plugin for external DNS resolution of k8s services
- **external-dns:** Manages Cloudflare DNS records from ingress annotations
- **cert-manager:** Let's Encrypt certs via Cloudflare DNS-01 challenge (JSON logging enabled)
- **Cloudflared:** Cloudflare tunnel for services not on ingress
- **NFS mounts:** TrueNAS (freenas.home/10.0.0.129) serves media via NFS to plex/radarr/sonarr pods. Mounts configured as soft (timeo=50, retrans=3) to prevent node lockups.
- **Node DNS (host config, not in git):** NetworkManager `enp1s0` uses `ipv4.dns 10.0.0.8 1.1.1.1` (AdGuard first, public fallback) via systemd-resolved, and `/etc/hosts` pins `10.0.0.129 freenas.home`. AdGuard runs on this node, so the node must never depend on it alone. CoreDNS forwards public names to 8.8.8.8/1.1.1.1 and `home`/`lan` to AdGuard, with a `hosts` override for `freenas.home`. The node is not Ansible-managed despite the marker in `/etc/hosts`.
- **TrueNAS DNS:** nameserver1 `10.0.0.8` (AdGuard), nameserver2 `1.1.1.1` (set in the UI, Network → Global Configuration). Without the fallback, every hostname-based call from TrueNAS (watchdog Discord alerts, healthchecks.io pings) fails exactly when the NUC is down. Anything that has to work during a NUC outage must not depend on AdGuard alone.

### Other

- **Hajimari:** Dashboard/start page

## Performance Investigation Areas

### Plex Transcoding
- See docs/plex-optimisation.md for detailed findings (written while Plex was in the TrueNAS jail without hardware transcode)
- Hardware transcode via the NUC iGPU (UHD 620 Quick Sync) since the move to k8s
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
- **2026-06-04 crash:** Node hard-locked at ~23:31 UTC, down 36.5 hours. Last kernel event: Netdata child pod OOM-killed at 23:30:55 (go.d.plugin exceeded 512Mi cgroup limit). Disk was at 100% utilisation, iowait 36.8%. Root cause of actual kernel lock unknown — no pstore/kdump configured at the time. Fix: bumped Netdata child memory limit to 1Gi; crash capture infrastructure added (see below).

- **2026-10-16 cluster stuck after reboot:** the root disk hit 86% because kubelet had been flooding `/var/log/messages` (713G, never rotated) since the 1.24→1.34 k3s upgrade on 2026-05-12. It was failing to patch status on 794 stale evicted pods (`qosClass` immutable). Image GC then removed the pause image, and the node's only DNS server was AdGuard on the node itself, so no sandbox could start. Fix: node DNS fallback + `/etc/hosts`, CoreDNS `freenas.home` override, deleted Failed pods, truncated `messages`. If Failed/Evicted pods pile up again, delete them. Details: `docs/nuc-power-crash-investigation-2026-06.md`.
- **Silent freezes (ONGOING, ~35 between June and Oct 2026):** the NUC freezes with power present and nothing captured, and recovers via a watchdog power-cycle or a self-reset. The freezes began 5 days after the kubelet log flood started, and that flood was removed 16 Oct 2026; the weekly report tracks whether they stop. memtest86+ is next if they don't. Also fixed 16 Oct: the watchdog didn't verify power-cycles (21 Sept: NUC left unpowered 40 min), the plug reboot-looped during outages, and Discord alerts never arrived (TrueNAS DNS was AdGuard-only).

### Crash Capture Infrastructure

Set up on `tomnuc.home` to capture data from the next hang:

- **pstore** (`pstore.backend=efi efi_pstore_disable_old=0`): writes kernel ring buffer to EFI NVRAM on panic, survives hard reset. Check `/sys/fs/pstore/` after reboot.
- **NMI watchdog** (`nmi_watchdog=1`, `hardlockup_panic=1` via sysctl, `softlockup_panic=1`): forces a kernel panic if a CPU freezes for >10s, enabling pstore/kdump to capture it.
- **kdump** (`crashkernel=512M`): kexec crash kernel saves full memory dump to `/var/crash/` on panic. Analyse with `crash` + `debuginfo-install kernel-$(uname -r)`.
- **Software watchdog** (`watchdog` daemon): reboots if load average >80 (1min) or free memory <64MB. Pings router (10.0.3.254) to detect NIC failure. Required `setcap cap_net_raw+ep /usr/sbin/watchdog` for ping to work.
- **TrueNAS watchdog** (`/mnt/all/config/scripts/nuc-watchdog.sh`, cron every 2min): pings NUC, then SSH port check, then 5-min recheck before power-cycling via ESPHome smart plug (10.0.1.89). Each plug command is verified by reading the relay state back. Discord alerts on freeze detection (🟠), power-cycle, failed cycle and recovery, plus a weekly freeze report (Fridays 09:00, `nuc-freeze-report.sh`). Logs to `/mnt/all/config/scripts/nuc-watchdog.log` (BST timestamps). Source + deploy steps: `Local-apps/nuc-watchdog/`.

Full setup guide: `docs/nuc-crash-capture-setup.md`

### Auto Power-On After AC Loss

The board (no-name Whiskey Lake mini-PC, Cannon Point-LP PCH, BIOS `GWHL4 5.04`) has no BIOS "power on after AC loss" option, so it stayed dead for ~40h after the June 2026 power crashes. Handled in software instead: a systemd oneshot (`afterg3-poweron.service`) clears bit 0 (`SLEEP_AFTER_POWER_FAIL`) of the PCH `GEN_PMCON_A` register at `0xFE001020` on every boot (BIOS resets it each POST). Files version-controlled at `Local-apps/nuc-auto-power-on/`. Full writeup: `docs/nuc-auto-power-on.md`.

### Post-Hang Investigation Checklist

For any unexpected reboot or outage, work `docs/nuc-outage-runbook.md` (full checklist + how to detect a self-recovered event + plug-trace interpretation). The power-loss investigation is still ONGOING (`docs/nuc-power-crash-investigation-2026-06.md`); since the NUC now auto-recovers, night-time events can be silent, so check the TrueNAS plug log after any blip.

Quick version, after the next hard lock and reboot:
1. `journalctl --list-boots` — confirm boot -1 logs are available
2. `journalctl -b -1 -k | tail -100` — last kernel messages before crash
3. `journalctl -b -1 | grep -i "oom\|killed process"` — OOM kills
4. `journalctl -b -1 | grep -i "thermal\|mce\|machine.check"` — hardware errors
5. `ls /sys/fs/pstore/` — kernel panic data (if panic occurred)
6. `ls /var/crash/` — kdump memory dump (if panic occurred)
7. `cat /mnt/all/config/scripts/nuc-watchdog.log` — when node went dark from TrueNAS perspective
8. Netdata/Loki — disk I/O, load, cgroup memory in the hour before the crash

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
