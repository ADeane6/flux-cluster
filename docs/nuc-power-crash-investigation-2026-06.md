# NUC Power Crash Investigation (June 2026)

## Summary

`tomnuc.home` died three times over Fri 19 / Sat 20 June 2026, then sat dead for ~40h until it was manually rebooted on Sun 21 June. After investigation the cause is an instant, unlogged power loss localised to the NUC itself (most likely the PSU / DC power input), not a software hang, not a circuit/mains outage, and not the crash-capture watchdog.

The crash-capture infrastructure added after the June 4 hang (pstore, kdump, lockup panic) captured nothing, because it is built to catch a kernel panic and this failure mode removes power before the kernel ever reaches the panic path. The right instrument for this class of fault is power-side telemetry, which we don't currently retain off-NUC (see Monitoring Gap).

## Timeline

All times BST (UTC+1). UTC in parentheses where useful. Two of the restarts were manual interventions, marked below.

| When (BST) | Event |
|---|---|
| Fri 19, ~03:43 | UniFi router (UCG Ultra) reboots, likely firmware auto-update. Recovers immediately, up continuously after. Unrelated to the NUC. |
| Fri 19, **15:30** (14:30 UTC) | **NUC crash #1.** Instant death of a healthy box. The triggering failure. |
| Fri 19, 15:30 → 21:17 | NUC down (~5.7h). TrueNAS still up and serving NFS. |
| Fri 19, ~21:13 | TrueNAS cleanly shut down (manual, while troubleshooting). |
| Fri 19, 21:17 (20:17 UTC) | NUC powered back up (manual). |
| Fri 19, ~23:05 (22:05 UTC) | NUC down again. This one was the plug being manually powered off, not a fault. Excluded. |
| Fri 19, 23:16 (22:16 UTC) | NUC powered back up (manual). |
| Sat 20, **03:32** (02:32 UTC) | **NUC crash #2 (the real second fault).** Same instant-death signature. |
| Sat 20 → Sun 21 | NUC down ~40h. TrueNAS also down (since the Fri 21:13 manual shutdown). |
| Sun 21, 19:39 (18:39 UTC) | NUC manually rebooted. Healthy since. |
| Sun 21, 19:41 | TrueNAS booted (manual), ~2 min after the NUC. |
| Mon 22 | Both up ~23h+, healthy. |

So the two genuine internal-fault crashes are Fri 15:30 and Sat 03:32. The Fri 23:05 restart was a manual power-off, and the long gap was the NUC sitting dead plus TrueNAS being off from the Friday shutdown.

## What the crash looked like

Every genuine crash has the same signature, and it is the opposite of the May/June iowait-and-disk hangs documented in CLAUDE.md:

- The log just stops mid-line. No systemd shutdown targets, no "Powering off", no ACPI power-key event.
- Nothing in `/sys/fs/pstore` or `/var/crash`, even though `hardlockup_panic=1`, `softlockup_panic=1`, `pstore.backend=efi` and `crashkernel=512M` are all confirmed armed in the boot cmdline.
- `last -x` shows a boot with no preceding shutdown record (unclean stop), unlike the deliberate reboots on June 6 and 9 which logged a clean shutdown.
- The system was healthy right up to the cutoff. For crash #1 (the cleanest example): `journalctl -b -3 --priority=warning` returned no entries at all, CPU was at idle baseline (load1 ~2, iowait <1%), and the last kernel line was the routine every-30-min CNI `eth0 link becomes ready` event at 14:30:00, gone by 14:30:09.

A healthy, lightly-loaded box does not vanish in 9 seconds via software. With no panic captured and no warnings, the conclusion is that power was removed, the kernel did not crash.

## What was ruled out

| Cause | Verdict | Evidence |
|---|---|---|
| TrueNAS watchdog | Ruled out | Watchdog was disabled before these crashes. |
| Circuit / mains outage | Ruled out | UniFi router on the same circuit has continuous uptime (Netdata `systemUptime` advanced ~42h across the ~42h gap with no reset, current uptime matches console). It never lost power. |
| Smart plug / shared circuit | Ruled out | TrueNAS shares the same plug and was still up during crash #1 at Fri 15:30 (TrueNAS ran continuously from June 9 until a clean manual shutdown at Fri 21:13). If the plug had cut power, TrueNAS would have died too. It didn't, so the plug was delivering power. |
| Software / resource exhaustion | Ruled out | Idle baseline before each crash, no OOM, no memory pressure, no warnings. The cleanup CronJobs were enabled May 31 / June 3, ~3 weeks before, so not a new trigger. |
| RAM | Unlikely, not yet excluded | No segfault / GPF / oops / kernel BUG / machine-check / soft or hard lockup / OOM in the logs since June 19. A bad DIMM can hard-freeze with no log, and the RAM is non-ECC so EDAC can't report bit errors, so it is not 100% excluded. Confirm with memtest86+ overnight. |
| SSD | Very unlikely | No ATA / NVMe / I/O errors, no failed commands, no read-only remounts. The only disk lines are normal XFS journal recovery at the Sunday boot, which is the expected footprint of a hard power cut, not disk damage. Disk is a `Qunion SSD 1TB` (cheap brand), worth a SMART check for hygiene. |

## Prime suspect

The NUC's own power delivery (PSU / DC input) cutting out intermittently. This fits everything: instant off, no kernel trace, recovery only via a manual power-cycle (hence the 5.7h and 40h gaps, the box sat dead until someone intervened), and TrueNAS on the same plug staying up.

A brief mains sag that the router and TrueNAS supplies ride through but the NUC's PSU cannot would look identical from the NUC side, so it can't be separated from an internal PSU fault without power-side telemetry (voltage in particular).

## Why the crash-capture infra caught nothing

pstore + kdump + `*_panic=1` are designed to capture a kernel panic. A power loss removes power before the kernel runs the panic path, so there is nothing to write. This isn't a misconfiguration, it's the wrong tool for this failure mode. For power loss the useful capture is power-side (plug draw + voltage, or a UPS event log), recorded somewhere that is not the NUC.

## Monitoring gap

Everything that could observe the plug (Home Assistant, Mosquitto, Prometheus, Loki) runs on the NUC, so it all dies at the exact instant we want to observe. The one box proven to stay up through the crashes is TrueNAS. To catch the next event we need to record the plug's power and voltage on TrueNAS (or another always-on device that isn't the NUC).

The ESPHome plugs don't retain history themselves, so the data has to be pushed/pulled to a persistent store off-NUC.

## Next steps

1. Split the NUC and TrueNAS onto independent plugs so they can be observed separately and one can't take the other down.
2. Enable the NUC plug's voltage sensor (if the chip supports it) and sample fast (~1s). This is what distinguishes the three remaining possibilities:
   - relay reported on, draw drops to 0W instantly -> internal PSU / board fault (expected)
   - relay off / plug stops reporting -> plug or upstream cut power
   - input voltage sags just before draw collapses -> mains brownout the PSU couldn't ride through
3. Record that plug telemetry on TrueNAS (simplest: a small poller on TrueNAS hitting the ESPHome web server REST endpoint every 1-2s, appending timestamp/volts/watts to the pool). MQTT to a broker on TrueNAS or a Prometheus scrape are heavier alternatives.
4. Set the NUC BIOS to power on after AC loss, so it self-recovers instead of sitting dead for ~40h.
5. After the next event, check the NUC BIOS / board event log (logs unexpected power loss independently of the OS).
6. Exclusion checks for hygiene:
   - `sudo smartctl -a /dev/sda` (check `Unexpect_Power_Loss_Ct` / `Power-Off_Retract_Count`, which should have bumped by ~2 over the weekend if it lost power, plus reallocated sectors and CRC errors)
   - memtest86+ overnight to definitively clear the RAM
7. Likely fix: swap the PSU / DC barrel jack, and put the NUC on a UPS so a sag or a flaky supply can't drop it (and the UPS gives an independent power-event log).
