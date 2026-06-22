# nuc-plug-monitor

Logs the NUC's smart-plug power draw to disk on TrueNAS, to catch the next NUC
power-loss event. Background and reasoning: `docs/nuc-power-crash-investigation-2026-06.md`.

Runs on TrueNAS, not the NUC (the recorder has to outlive the thing it's watching:
Home Assistant, Mosquitto, Prometheus and Loki all run on the NUC, so they die at
the exact moment we want to observe).

## Deploy

Copy the script onto TrueNAS and make it executable:

```
scp nuc-plug-monitor.sh truenas:/mnt/all/config/scripts/
ssh truenas chmod +x /mnt/all/config/scripts/nuc-plug-monitor.sh
```

Launch it under FreeBSD's `daemon(8)`, which supervises the process properly
(no nohup/pgrep hack):

```
/usr/sbin/daemon -r -P /var/run/nuc-plug-monitor.pid /mnt/all/config/scripts/nuc-plug-monitor.sh
```

- `-r` restarts the script if it ever exits.
- `-P <pidfile>` writes the supervisor pid and makes it single-instance: a second
  `daemon` invocation with the same pidfile is a no-op while one is running.

Persist across reboots with a cron job (Tasks -> Cron Jobs -> Add, run as `root`,
schedule `* * * * *`) running the same line:

```
/usr/sbin/daemon -r -P /var/run/nuc-plug-monitor.pid /mnt/all/config/scripts/nuc-plug-monitor.sh
```

Because of the pidfile the once-a-minute cron is harmless when it's already up, so
cron gives you auto-start at boot (within a minute) plus a restart if the
supervisor itself ever dies. The script stays a long-running loop, `daemon`/cron
just keep it alive. No Post-Init script needed.

## File format

One CSV per day at `/mnt/all/config/nuc-plug-logs/nuc-plug-YYYY-MM-DD.csv`:

```
epoch_s,iso_utc,status,voltage_v,current_a,power_w,energy_kwh
1782158243,2026-06-22T19:57:23Z,OK,238.4408,0.567786,124.903,4.100567
```

| Column | Meaning |
|---|---|
| `epoch_s` | Unix timestamp (seconds, UTC). Use this for range filters. |
| `iso_utc` | Same instant, human-readable UTC. |
| `status` | `OK` = plug responded. `UNREACHABLE` = curl failed (numeric fields blank). |
| `voltage_v` | Mains voltage at the plug. |
| `current_a` | Current the NUC is drawing. |
| `power_w` | Power the NUC is drawing. |
| `energy_kwh` | Cumulative energy counter (monotonic, only resets if the plug reboots). |

Consecutive identical rows are normal: the plug's ESPHome sensor updates slower
than we poll, so we re-read the same value until it refreshes (see resolution
note under Config).

Healthy baseline (NUC idle-ish): ~240V, ~0.5A, ~120W, `status=OK`.

## Retention

The script prunes CSVs older than `RETAIN_DAYS` (default 30) at each daily
rollover, so the log dir stays bounded (~2.5MB/day at the default 2s interval).

## Checking it's healthy

Is the supervisor + script running:

```
ssh truenas 'pgrep -fl nuc-plug-monitor.sh'
```

Expect two lines: the `daemon:` supervisor and the `bash` child. Also
`cat /var/run/nuc-plug-monitor.pid` is the supervisor pid.

Is it still writing fresh data (last row should be within a few seconds, `OK`):

```
ssh truenas 'tail -3 /mnt/all/config/nuc-plug-logs/nuc-plug-$(date -u +%F).csv'
```

If it's stalled or missing: check the plug is reachable
(`curl -s http://10.0.1.89/sensor/power`), then just re-run the `daemon` line
(or wait for the cron minute) to restart it.

## Reading it after a NUC crash

Find the crash time from the NUC (`journalctl --list-boots`, or the last log line
before it died), then pull the plug rows around that window. `epoch_s` is column 1,
so an `awk` range filter is easiest:

```
ssh truenas "awk -F, '\$1>=<START_EPOCH> && \$1<=<END_EPOCH>' /mnt/all/config/nuc-plug-logs/nuc-plug-<DATE>.csv"
```

Then read the trace at the moment power/draw drops:

| What you see | Diagnosis |
|---|---|
| `voltage_v` steady ~240, `power_w` -> ~0, `status` still `OK` | Plug was delivering power, the NUC stopped drawing -> internal PSU / board fault |
| `voltage_v` sags before `power_w` collapses | Mains brownout the PSU couldn't ride through |
| `status` flips to `UNREACHABLE` | The plug itself / upstream mains lost power |

## Config

Env vars: `PLUG_IP` (default 10.0.1.89), `INTERVAL` (default 2s),
`RETAIN_DAYS` (default 30), `LOG_DIR` (default /mnt/all/config/nuc-plug-logs).

Resolution caveat: the real sampling resolution is capped by the sensor
`update_interval` in the ESPHome config (github.com/ADeane6/esphome_config), not by
`INTERVAL` here. Polling faster than the sensor updates just re-reads the same
value. To catch a fast brownout, drop the plug's power/voltage `update_interval`
to ~1s there.
