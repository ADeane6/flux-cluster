# nuc-watchdog

Runs on **TrueNAS** (not in k8s, not on the NUC). Pings `tomnuc.home` every 2 minutes from cron; if it's unreachable for long enough, power-cycles it via the ESPHome smart plug and sends Discord alerts. TrueNAS is the box proven to stay up when the NUC dies (see `docs/nuc-power-crash-investigation-2026-06.md`), which is why the watchdog lives here.

## Behaviour

1. Ping fails 3x (~6 min) -> confirm with ping + SSH port check -> 5-min recheck.
2. Still unreachable -> power-cycle the plug (`10.0.1.89`). Each command is retried (up to 6x) until a read-back of the relay state confirms it, and ON is re-checked 30s later. Every attempt's HTTP code and state go to the log. The plug has applied commands late or not at all (21 Sept 2026), and it reboots every 15 min while Home Assistant is down (ESPHome `api` reboot_timeout).
3. Discord alerts:
   - 🔴 power-cycling (first cycle of an incident, pings the user)
   - 🔴 STILL down after the cycle (second cycle = manual intervention needed, pings the user)
   - 🔴 power-cycle failed: the plug never confirmed ON, so the NUC may be sitting unpowered (pings the user)
   - 🟢 back up, with total downtime (only after a power-cycle; no ping)

A blip the NUC rides through or recovers from in under ~6 min won't cross the fail threshold, so it won't alert. The TrueNAS plug log (`Local-apps/nuc-plug-monitor/`) is the forensic record for those.

## Deploy

```sh
scp nuc-watchdog.sh truenas:/mnt/all/config/scripts/nuc-watchdog.sh
ssh truenas chmod 0711 /mnt/all/config/scripts/nuc-watchdog.sh
```

Then on TrueNAS:

1. Set `NOTIFY_WEBHOOK` in the deployed script to the real Discord webhook URL, and `MENTION` to `"<@DISCORD_USER_ID>"` for the user to ping on the red alerts. **Both are blank in the git copy on purpose** — never commit them.
2. Ensure the cron job exists (TrueNAS UI: Tasks -> Cron Jobs, every 2 min, `sh /mnt/all/config/scripts/nuc-watchdog.sh`). Cron config is stored in the TrueNAS middleware, so it survives reboots.
