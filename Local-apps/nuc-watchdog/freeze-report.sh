#!/bin/sh
# Weekly NUC freeze summary to Discord, built from the watchdog log.
# Runs from TrueNAS cron (Fridays 09:00). Reuses the webhook from the deployed watchdog.

POOL_PATH="/mnt/all/config/scripts"
LOG="${POOL_PATH}/nuc-watchdog.log"
DAYS="${DAYS:-7}"

eval "$(grep '^NOTIFY_WEBHOOK=' "${POOL_PATH}/nuc-watchdog.sh")"
[ -n "$NOTIFY_WEBHOOK" ] || exit 1

since=$(date -v-"${DAYS}"d '+%Y-%m-%d %H:%M:%S')

# An outage starts at the first confirmed failure ("Starting ...s wait"); that line repeats
# after every power-cycle, so only count it again once the NUC has been reachable.
summary=$(awk -v since="$since" '
    substr($0, 1, 19) < since { next }
    /NUC reachable|recovered|check passed|Confirmation passed/ { in_outage = 0 }
    /Starting [0-9]+s wait before final check/ && !in_outage {
        in_outage = 1; outages++
        times = times sprintf("%s%s", (times ? ", " : ""), substr($0, 6, 11))
    }
    /initiating power cycle/                     { cycles++ }
    /recovered without power-cycle/              { self++ }
    /Power cycle FAILED/                         { failed++ }
    END {
        printf "%d outage(s): %d power-cycle(s), %d self-recovered, %d failed cycle(s)", outages, cycles, self, failed
        if (times) printf ". Started (BST): %s", times
    }' "$LOG")

if echo "$summary" | grep -q '^0 outage'; then
    msg=":bar_chart: NUC weekly report: no freezes in the last ${DAYS} days."
else
    msg=":bar_chart: NUC weekly report (last ${DAYS} days): ${summary}"
fi

[ -n "${DRY_RUN:-}" ] && { echo "$msg"; exit 0; }

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$NOTIFY_WEBHOOK" \
    -H "Content-Type: application/json" \
    --data-binary "{\"username\":\"NUC Watchdog\",\"content\":\"${msg}\"}")
echo "$(date '+%Y-%m-%d %H:%M:%S') Weekly report sent: HTTP ${code} (${summary})" >> "$LOG"
