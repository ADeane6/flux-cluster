# NUC Outage Runbook

Run this after any unexpected `tomnuc.home` reboot or outage, or when a power alert fires.

The point of the runbook is that we've now seen several distinct failure modes on this node, and they look nothing alike. Don't assume the newest one. Every time, re-confirm which class it was before acting:

- **NFS / iowait hang** (17 May 2026): hard mount hang + degraded 100Mbps link, iowait climbed for an hour before the lock.
- **OOM-driven lock** (4 June 2026): Netdata child OOM-killed, disk at 100%, kernel hard-locked, nothing captured (no pstore/kdump at the time).
- **Kernel panic class** (not yet seen): the reason pstore + kdump + `*_panic=1` were armed. Would leave data in `/sys/fs/pstore` or `/var/crash`.
- **Power loss, unconfirmed cause** (19-20 June 2026): instant, unlogged, no kernel trace, prime suspect internal PSU. See [nuc-power-crash-investigation-2026-06.md](nuc-power-crash-investigation-2026-06.md). Still ONGOING.

Work the checklist top to bottom every time. The whole list is cheap and the failure modes overlap (e.g. a power cut and an OOM can both end with an unclean boot), so confirm by exclusion, don't pattern-match on the last incident.

## Detecting an event you weren't awake for

This is the new problem since auto power-on: a night-time power blip now self-recovers, the NUC is back in ~30s, and nothing tells you it happened. Two layers.

### After the fact (data already captured, no alerting needed)

- **TrueNAS plug log (authoritative).** `/mnt/all/config/nuc-plug-logs/nuc-plug-YYYY-MM-DD.csv`. A power event shows as rows where `power_w` drops to ~0 while `status=OK`, or `status=UNREACHABLE`, or a gap in the 2s timestamps. TrueNAS stays up, so this is recorded even if the NUC was down. This is the single most reliable signal.
- **Unclean boot on the NUC.** `last -x reboot shutdown` shows a boot with no `shutdown` record before it (the power-loss signature). `journalctl --list-boots` lists every boot, so a new boot ID you didn't trigger = an event.
- **TrueNAS watchdog log.** `/mnt/all/config/scripts/nuc-watchdog.log` records failed pings / power-cycles, so a NUC that briefly went dark may show here.
- **Netdata / Netdata Cloud.** A `systemUptime` reset or a gap in NUC metrics marks the window.
- **SMART counter.** `Unexpect_Power_Loss_Ct` (see checklist) bumps once per hard power loss.

### Proactive alerting (built)

The TrueNAS watchdog (`nuc-watchdog.sh`, cron every 2 min) sends Discord alerts. It's the right place for this: it already detects the NUC is gone and decides whether to power-cycle, so an alert means TrueNAS actually had to intervene, not a guess from power readings. It runs on TrueNAS, so it fires even when the NUC is the thing that's down.

Three messages:

- 🔴 **NUC down, power-cycling** — fired when the watchdog performs the restart (after 3 ping fails + ping/SSH confirm + 5-min recheck).
- 🔴 **STILL down after power-cycle** — fired on the second power-cycle of an incident, i.e. the first restart didn't bring it back (the manual-intervention / 40h case). Silent after that to avoid spam.
- 🟢 **NUC back up (down Xm total)** — all-clear, gated on a power-cycle having happened, so brief network blips that never reached a restart stay silent.

Incident state (`nuc_incident_start`, `nuc_powercycle_count` in the scripts dir) persists across cron runs until recovery. The script is version-controlled at [`Local-apps/nuc-watchdog/`](../Local-apps/nuc-watchdog/) with the webhook blanked; the real Discord webhook URL is set only in the deployed copy on TrueNAS (it's a secret, kept out of git).

Note the gap this leaves: a power blip that the NUC rides through or recovers from in under ~6 min (before the watchdog crosses its fail threshold) won't trigger an alert. For those, the TrueNAS plug log (above) is still the forensic record. If catching short events proves important, add a plug-side watcher as a second source.

This all assumes TrueNAS is up to do the watching. A **whole-house power cut** takes TrueNAS down too, so it's handled separately by a cloud dead-man's switch (TrueNAS + router ping healthchecks.io; the cloud alerts when the pings stop). See [house-power-outage-detection.md](house-power-outage-detection.md).

## Post-outage checklist

NUC commands run on `tomnuc.home` (`ssh personalServer`). `-b -1` is the previous boot; use the right offset if more than one boot has happened since.

### A. Power-side (do this first, it's the discriminator)

```sh
# On TrueNAS: pull the rows around the event. Look for power_w -> ~0, UNREACHABLE, or a timestamp gap.
grep -nE 'UNREACHABLE|,OK,,' /mnt/all/config/nuc-plug-logs/nuc-plug-*.csv
# Eyeball the window directly:
less /mnt/all/config/nuc-plug-logs/nuc-plug-<date>.csv
```

### B. Clean vs unclean stop

```sh
last -x reboot shutdown | head        # a boot with no preceding "shutdown" = unclean stop
journalctl --list-boots | tail
```

### C. Kernel panic captured (would mean it was NOT a power loss)

```sh
ls -la /sys/fs/pstore/                 # kernel ring buffer saved to EFI on panic
ls -la /var/crash/                     # kdump memory dump on panic
```

### D. Software hang / iowait / NFS (the May 2026 signature)

```sh
journalctl -b -1 --priority=warning | tail -50
journalctl -b -1 | grep -iE 'nfs|server not responding|hung task|blocked for more than'
# Disk / iowait in the hour before: check Netdata or Loki for the window.
```

### E. OOM kills (the June 2026 signature)

```sh
journalctl -b -1 | grep -iE 'oom|killed process|out of memory'
```

### F. Thermal / machine-check / hardware errors

```sh
journalctl -b -1 | grep -iE 'thermal|mce|machine check|hardware error|cpu.*throttl'
```

### G. Watchdog actions (rule out a self-inflicted reboot)

```sh
journalctl -b -1 -u watchdog                       # software watchdog daemon (load>80 / mem<64MB / router ping)
# On TrueNAS:
tail -50 /mnt/all/config/scripts/nuc-watchdog.log  # ping fail / SSH check / plug power-cycle
```

### H. Network / NIC (the bad-cable signature)

```sh
journalctl -b -1 | grep -iE 'r8169|enp1s0|link is|link becomes|100Mbps'
ethtool enp1s0 | grep -i speed                     # confirm 1Gbps, not renegotiated to 100Mbps
```

### I. SMART (hygiene, and confirms hard power loss)

```sh
sudo smartctl -a /dev/sda | grep -iE 'Power_Loss|Power-Off|Reallocated|CRC|Unexpect'
```

### J. Auto power-on still armed

```sh
# bit0 should read 0 (power-on). If 1, the afterg3-poweron service didn't run. See nuc-auto-power-on.md.
sudo python3 -c "import mmap,struct; f=open('/dev/mem','r+b'); m=mmap.mmap(f.fileno(),4096,offset=0xfe001000); print('bit0', struct.unpack('<I',m[0x20:0x24])[0] & 1)"
systemctl status afterg3-poweron
```

## Interpreting the plug trace

Once you have the TrueNAS plug rows around the event:

| What the plug shows | Conclusion |
|---|---|
| `status=OK`, voltage steady (~240V), `power_w` drops to ~0 instantly | NUC stopped drawing while power was present = **internal PSU / board fault** (the prime suspect) |
| voltage sags noticeably just before `power_w` collapses | **mains brownout** the PSU couldn't ride through |
| `status=UNREACHABLE` / plug stops reporting | **plug or upstream** lost power (and check whether TrueNAS, now on its own plug, was affected too) |

Caveat: sub-second brownouts may slip between samples. The poll is 2s and the true resolution is capped by the ESPHome `update_interval`. If a sag is suspected but not captured, drop the voltage/power `update_interval` in the `esphome_config` repo.

## After confirming the class

- **Power loss:** append the event (timestamp, plug trace, which outcome) to the investigation doc's timeline. Once there's a clean confirmation of internal-PSU-vs-mains, action the fix: swap the PSU / DC barrel jack and put the NUC on a UPS (the UPS also gives an independent power-event log).
- **Anything else (hang / OOM / panic / NIC):** it's a different incident, not this investigation. Treat it on its own and update CLAUDE.md's Known Issues if it's a new mode.
