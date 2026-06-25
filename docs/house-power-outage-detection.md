# House Power Outage Detection (dead-man's switch)

## Purpose

Get notified when the **whole house** loses power. The NUC watchdog Discord alerting can't help here: in a full power cut the NUC, TrueNAS, and router all die at once, so there's nothing left inside the house to send an alert. The alarm has to originate *outside* the house.

## Design

A dead-man's switch. Always-on boxes ping an external service ([healthchecks.io](https://healthchecks.io)) on a schedule. The service alerts (Discord) when the pings **stop**. Because the service is in the cloud, the alert path doesn't depend on the house having power.

Key choice: **multiple sources ping the same check.** healthchecks.io keeps a check green as long as *any* source pings it in time, so the check only goes red when **every** source has gone dark. That means red = the whole house is down (a real power cut), not just one box crashing. This is what kills false alarms from a single device rebooting on its own.

Trade-off accepted: this can't tell a power cut from a total internet/ISP outage (both look like "house stopped checking in"). A UPS + NUT is the only thing that positively says "mains lost" (see `nuc-power-crash-investigation-2026-06.md` next steps); the dead-man's switch is the cheap, no-hardware layer that catches everything.

## healthchecks.io check settings

- **Period:** 2 min (matches the ping cadence)
- **Grace:** ~5 min (so a single missed ping from a transient blip doesn't false-alarm)
- **Integration:** Discord, pointed at the same channel as the NUC watchdog.

The real check UUID lives in the deployed cron jobs only; it's a capability token, kept out of git.

## Sources

| Source | Status | Cadence |
|---|---|---|
| TrueNAS (cron) | Done | every 2 min |
| Router (UCG Ultra) | TODO (see below) | every 2 min |

Ping command (same on every source):

```sh
curl -fsS -m 10 --retry 5 -o /dev/null https://hc-ping.com/<check-uuid>
```

## Adding the router (UCG Ultra) long-term — loose steps

The router is the best second source: independent of TrueNAS, and its power state best represents the house. The UCG Ultra runs UniFi OS (Debian-based, has `curl` and `cron`), but **wipes custom changes on reboot and firmware updates**, so a plain crontab entry won't persist. Make it persistent with the community `on_boot.d` boot-script hook.

1. Enable SSH on the gateway: UniFi OS -> Settings -> System -> enable SSH, set a password.
2. SSH in: `ssh root@10.0.3.254`. Confirm `curl --version` works (fall back to `wget` if not).
3. Install the `on_boot.d` mechanism (udm-utilities / unifios-utilities). It stores scripts under `/data` (which survives reboots) and runs them on every boot.
4. Add a boot script (e.g. `/data/on_boot.d/10-hc-ping.sh`) that installs a cron entry pinging the same `hc-ping` URL every 2 min. Because `on_boot.d` re-runs on each boot, the cron is reinstalled after reboots and firmware updates.
5. Reboot the gateway and confirm the cron entry came back and healthchecks.io is seeing pings from the router.
6. Test the alarm: stop both pings (TrueNAS + router) and confirm the check goes red and fires the Discord alert.

Caveats:
- Re-verify after major UniFi OS firmware updates; the `on_boot.d` hook itself occasionally needs reinstalling.
- Keep the check UUID out of git.
