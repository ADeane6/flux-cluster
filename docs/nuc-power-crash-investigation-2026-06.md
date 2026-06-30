# NUC Power Crash Investigation (June 2026)

**Status: ONGOING.** The failure mode is identified (instant, unlogged power loss to the NUC) and a prime suspect named (internal PSU / DC input), but the root cause is not confirmed. Confirmation needs the next event captured with the power-side telemetry that is now in place (see Next steps). We can't yet separate an internal PSU fault from a brief mains sag without that trace. The mitigations (auto power-on, split plugs, plug monitor) are done; the diagnosis is not. When the next event lands, work [nuc-outage-runbook.md](nuc-outage-runbook.md).

**Update 30 June 2026:** the NUC has hung four times over three days (25, 28, and twice on 30 June). Every one was a hang, not a power loss (steady voltage, non-zero draw, watchdog-recovered), and nothing was captured (no panic, no kdump). All four self-recovered via the watchdog + auto power-on. Leading suspect is the non-ECC RAM (uncleared); next step is memtest86+. Details in the Update sections below.

## Summary

`tomnuc.home` died three times over Fri 19 / Sat 20 June 2026, then sat dead for ~40h until it was manually rebooted on Sun 21 June. After investigation the leading cause is an instant, unlogged power loss localised to the NUC itself (most likely the PSU / DC power input), not a software hang, not a circuit/mains outage, and not the crash-capture watchdog. This is the prime suspect, not a confirmed root cause.

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

## Update — 25 June 2026: hang event (recovery stack validated)

First outage since the instrumentation landed. It was **not** a power loss, and the watchdog + auto-power-on + Discord stack recovered it unattended in ~13 minutes. This is the stack's first real-world test, and it worked end to end.

### Timeline (UTC)

| When | Event |
|---|---|
| ~00:23 | Netdata stops collecting on the NUC. |
| 00:27:31 | NUC's last log line: k3s failing to patch `tigera-operator` pod status, container `exitCode 137` / `ContainerStatusUnknown` (the runtime seizing up). Journal goes silent. |
| 00:28:05 | TrueNAS watchdog's first failed ping. |
| 00:28:13 | Plug draw drops from ~17W to the ~8W idle floor (voltage steady ~247V). |
| 00:39:35 | Watchdog power-cycles the plug (cycle #1) after 3 fails + confirm + 5-min recheck. Brief 0W as the relay opens. |
| 00:40:02 | Auto-power-on boots the NUC on power restore. |
| 00:42 | Watchdog logs "recovered, down 13m total" -> 🔴 + 🟢 Discord alerts fired. |

### It was a hang, not a power loss

The plug trace is decisive: **voltage rock-steady at ~247V throughout, and draw dropped to the ~8W idle floor and held for 11 minutes.** A power fault is an instant drop to 0W; the only 0W reading is at 00:39:44, which is the watchdog opening the relay. So the box stayed powered but the CPU halted = a freeze.

### Distinct from both prior signatures

| Signature | This event |
|---|---|
| June 19-20 power loss (instant 0W) | No. Voltage steady, draw at idle floor, not 0W. |
| May/June iowait + OOM hang | No. Netdata shows **zero anomalies** in the half hour before; iowait ~0.06%, ~54GB RAM free, CPU flat-normal up to the wedge. No resource buildup. |

### Nothing was captured

Every capture path came up empty: `/sys/fs/pstore` empty (no panic), `/var/crash` empty (kdump never fired, so the NMI watchdog saw no spinning lockup — consistent with the CPU going *idle*, not stuck), kernel log silent, Netdata no anomalies. An empty pstore means the kernel did not panic; it froze (or the hardware stopped) below the level where the kernel could react.

### Conclusion

A healthy, idle-ish box silently hard-froze with no software trigger and no trace anywhere. That points at **hardware**, and the leading suspect is the **non-ECC RAM** (still uncleared from the original hygiene checks): a bad bit produces exactly this (silent freeze, nothing logged), and non-ECC means EDAC can't report it. Intermittent board / CPU is the fallback. This may be a separate fault from the June power-loss theory, or the same flaky whitebox showing a second failure mode.

**Action: memtest86+ overnight** (now the priority hygiene check). If clean, suspicion moves to the board/CPU and we watch for recurrence with the now-proven capture + alert stack.

## Update — 30 June 2026: recurring hangs

The 25 June hang was not a one-off. The NUC has hung four times over three days (25, 28, 30 June), all the same signature.

| # | Froze (UTC) | Recovered (UTC) | Down | Draw during freeze |
|---|---|---|---|---|
| 1 | 25 Jun 00:27 | 00:40 | ~13 min | ~8W idle floor |
| 2 | 28 Jun 11:12 | 11:23 | ~11 min | ~12.7W floor |
| 3 | 30 Jun 07:53 | 08:03 | ~11 min | full ~16W (CPU still busy) |
| 4 | 30 Jun 08:07 | 08:18 | ~13 min | ~12W |

(Watchdog log timestamps these +1, i.e. BST. The TrueNAS watchdog power-cycled all four and auto-power-on booted each on power restore, so every one self-recovered in ~11-13 min.)

### All four are hangs, not power losses

Confirmed from the plug traces: in every case **voltage held steady (~244-247V) and the draw never hit 0W** (the only 0W readings are the watchdog opening the relay). And `/var/crash` is empty across all of them, so no kdump fired = no kernel panic = silent freeze, the same class each time. None resembles the June 19-20 instant-0W power-loss events.

The draw *during* the freeze varies (8W / 12.7W / 16W / 12W), which just reflects the CPU being in different states when it wedged (deep idle through to still-spinning). Not a meaningful difference, all are "powered but frozen".

### Intervals

- 25th -> 28th: 3 days. 28th -> 30th: 2 days.
- The two events on the 30th were ~12 min apart: event 3 booted at 08:03, event 4 froze at 08:07 (~4 min after recovery).
- All four self-recovered in 11-13 min via the watchdog power-cycle + auto power-on.

### Assessment

The pattern (silent freeze, no log, no panic, no resource cause) points at hardware rather than software. The non-ECC RAM is the leading suspect and is still uncleared: silent freezes with no log are a known RAM symptom, and non-ECC means EDAC can't report bad bits. The recovery stack self-healed all four, but that's mitigation, not a diagnosis.

**Next step: memtest86+** to confirm or clear the RAM. If clean, the suspect moves to the board / CPU.

## Next steps

1. ~~Split the NUC and TrueNAS onto independent plugs so they can be observed separately and one can't take the other down.~~ Done (24 June 2026).
2. ~~Enable the NUC plug's voltage sensor (if the chip supports it) and sample fast (~1s).~~ Done (24 June 2026). The plug reports voltage (~242V), and it's being recorded. Note the real resolution is capped by the ESPHome `update_interval` (in the `esphome_config` repo), not the 2s poll, so a sub-second brownout may still be missed. This is what distinguishes the three remaining possibilities:
   - relay reported on, draw drops to 0W instantly -> internal PSU / board fault (expected)
   - relay off / plug stops reporting -> plug or upstream cut power
   - input voltage sags just before draw collapses -> mains brownout the PSU couldn't ride through
3. ~~Record that plug telemetry on TrueNAS.~~ Done (24 June 2026). A poller hits the plug's ESPHome REST endpoint every 2s and appends to a daily CSV on the pool, reboot-persistent via a TrueNAS Post-Init entry. See [nuc-plug-monitor README](../Local-apps/nuc-plug-monitor/README.md). This is the authoritative power-side record, on the one box proven to stay up.
4. ~~Set the NUC BIOS to power on after AC loss, so it self-recovers instead of sitting dead for ~40h.~~ Done (24 June 2026). The BIOS has no such option, so it's handled in software by clearing the PCH `GEN_PMCON_A` AFTERG3 bit at every boot. See [nuc-auto-power-on.md](nuc-auto-power-on.md).
5. After the next event, check the NUC BIOS / board event log (logs unexpected power loss independently of the OS).
6. Exclusion checks for hygiene:
   - `sudo smartctl -a /dev/sda` (check `Unexpect_Power_Loss_Ct` / `Power-Off_Retract_Count`, which should have bumped by ~2 over the weekend if it lost power, plus reallocated sectors and CRC errors)
   - memtest86+ overnight to definitively clear the RAM. **Priority after the 25 June hang** — RAM is now the leading suspect for that event (silent freeze, no trace, non-ECC so EDAC can't report bad bits).
7. Likely fix: swap the PSU / DC barrel jack, and put the NUC on a UPS so a sag or a flaky supply can't drop it (and the UPS gives an independent power-event log).
8. ~~Add detection/alerting for unattended events.~~ Done (24 June 2026). The TrueNAS watchdog (`nuc-watchdog.sh`) now sends Discord alerts when it power-cycles the NUC, again if the cycle didn't recover it, and an all-clear when it's back. See the "Detecting an event you weren't awake for" section of [nuc-outage-runbook.md](nuc-outage-runbook.md). Caveat: only catches events long enough to cross the watchdog's ~6-min fail threshold; shorter blips show only in the plug log.
