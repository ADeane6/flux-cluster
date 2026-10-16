#!/bin/sh
# NUC watchdog — runs from TrueNAS cron every 2 minutes
# Requires 3 ping failures, then ping+SSH confirmation, then 5-min recheck before power cycling
#
# Discord alerts (3 types):
#   :red_circle:        TrueNAS is power-cycling the NUC (first cycle of an incident)
#   :red_circle:        NUC STILL down after the power-cycle (manual intervention needed)
#   :green_circle:      NUC back up (only after a power-cycle, with total downtime)
# The two red alerts ping MENTION; the green all-clear does not.
# Incident state (nuc_incident_start, nuc_powercycle_count) persists across cron runs
# until the NUC recovers. The all-clear is gated on a power-cycle having happened, so
# brief network blips that never reach a power-cycle stay silent.
#
# NOTE: NOTIFY_WEBHOOK is a secret and is blank here on purpose. The deployed copy on
# TrueNAS (/mnt/all/config/scripts/nuc-watchdog.sh) has the real Discord webhook URL.
# Set it there, not in git.

NUC_HOST="10.0.0.1"
SMART_PLUG_IP="10.0.1.89"
POOL_PATH="/mnt/all/config/scripts"
FAIL_FILE="${POOL_PATH}/nuc_ping_failures"
CONFIRM_TIME_FILE="${POOL_PATH}/nuc_confirm_start"
INCIDENT_FILE="${POOL_PATH}/nuc_incident_start"
CYCLE_FILE="${POOL_PATH}/nuc_powercycle_count"
LOCKFILE="${POOL_PATH}/nuc-watchdog.lock"
FAIL_THRESHOLD=3
CONFIRM_WAIT=300    # seconds to wait before final check
LOG="${POOL_PATH}/nuc-watchdog.log"
NOTIFY_WEBHOOK=""   # set to the Discord webhook URL on TrueNAS (secret, not committed)
MENTION=""   # set to "<@DISCORD_USER_ID>" on TrueNAS to ping someone on the red alerts

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

check_ping() { ping -c 2 -t 5 "$NUC_HOST" > /dev/null 2>&1; }
check_ssh()  { nc -z -w 5 "$NUC_HOST" 22 > /dev/null 2>&1; }

PLUG_URL="http://${SMART_PLUG_IP}/switch/smart_plug_v2"

# Prints "true", "false", or nothing if the plug didn't answer.
plug_state() {
    curl -s --connect-timeout 5 --max-time 10 "$PLUG_URL" | grep -o '"value":[a-z]*' | cut -d: -f2
}

# $1 = turn_on|turn_off, $2 = expected state (true|false). The plug has been seen
# accepting a command but applying it ~40s late or not at all, so read the state back
# rather than trusting the POST.
set_plug() {
    attempt=1
    while [ "$attempt" -le 6 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -X POST "${PLUG_URL}/$1")
        sleep 2
        state=$(plug_state)
        echo "$(timestamp) Plug $1 attempt ${attempt}: HTTP ${code}, state ${state:-unreachable}" >> "$LOG"
        [ "$state" = "$2" ] && return 0
        sleep 8
        attempt=$((attempt + 1))
    done
    return 1
}

# Send a Discord message. $1 must not contain " or \ (our messages don't).
notify() {
    [ -n "$NOTIFY_WEBHOOK" ] || return 0
    curl -s -o /dev/null --max-time 10 -X POST "$NOTIFY_WEBHOOK" \
        -H "Content-Type: application/json" \
        --data-binary "{\"username\":\"NUC Watchdog\",\"content\":\"$1\"}" >> "$LOG" 2>&1
}

# Minutes since the incident started, as "Nm" (or "?" if unknown).
downtime_str() {
    start=$(cat "$INCIDENT_FILE" 2>/dev/null || echo "")
    if [ -z "$start" ]; then echo "?"; return; fi
    now=$(date +%s)
    echo "$(( (now - start) / 60 ))m"
}

# NUC is reachable again: send all-clear if we'd power-cycled, then clear all state.
recover() {
    if [ -f "$CYCLE_FILE" ]; then
        dt=$(downtime_str)
        notify ":green_circle: NUC back up (down ${dt} total)"
        echo "$(timestamp) NUC recovered, down ${dt} total" >> "$LOG"
    fi
    rm -f "$FAIL_FILE" "$CONFIRM_TIME_FILE" "$INCIDENT_FILE" "$CYCLE_FILE"
}

# Prevent concurrent runs — if a previous instance is still running, exit
if [ -e "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

# If ping succeeds, send all-clear (if needed), clear state and exit
if check_ping; then
    recover
    echo "$(timestamp) NUC reachable" >> "$LOG"
    exit 0
fi

# Ping failed — increment counter, record incident start on first failure
count=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$FAIL_FILE"
[ -f "$INCIDENT_FILE" ] || date +%s > "$INCIDENT_FILE"
echo "$(timestamp) NUC ping failed, count: $count" >> "$LOG"

if [ "$count" -lt "$FAIL_THRESHOLD" ]; then
    exit 0
fi

# Threshold reached — confirm with ping + SSH port check
echo "$(timestamp) Threshold reached, running confirmation check (ping + SSH port)" >> "$LOG"

if check_ping || check_ssh; then
    echo "$(timestamp) Confirmation passed — network partially up" >> "$LOG"
    recover
    exit 0
fi

echo "$(timestamp) Confirmation failed — both ping and SSH port unreachable" >> "$LOG"

# Start or check 5-minute wait before final check
if [ ! -f "$CONFIRM_TIME_FILE" ]; then
    date +%s > "$CONFIRM_TIME_FILE"
    echo "$(timestamp) Starting ${CONFIRM_WAIT}s wait before final check" >> "$LOG"
    exit 0
fi

confirm_start=$(cat "$CONFIRM_TIME_FILE")
now=$(date +%s)
elapsed=$((now - confirm_start))

if [ "$elapsed" -lt "$CONFIRM_WAIT" ]; then
    echo "$(timestamp) Waiting for final check (${elapsed}s / ${CONFIRM_WAIT}s elapsed)" >> "$LOG"
    exit 0
fi

# 5 minutes elapsed — final check
echo "$(timestamp) Final check after ${elapsed}s wait" >> "$LOG"

if check_ping || check_ssh; then
    echo "$(timestamp) Final check passed" >> "$LOG"
    recover
    exit 0
fi

# All checks failed — power cycle. Keep incident state; only reset the fail/confirm counters.
echo "$(timestamp) All checks failed — initiating power cycle" >> "$LOG"
rm -f "$FAIL_FILE" "$CONFIRM_TIME_FILE"

cycles=$(cat "$CYCLE_FILE" 2>/dev/null || echo 0)
cycles=$((cycles + 1))
echo "$cycles" > "$CYCLE_FILE"

dt=$(downtime_str)
if [ "$cycles" -eq 1 ]; then
    notify ":red_circle: ${MENTION} NUC down — TrueNAS power-cycling tomnuc.home (down ~${dt})"
elif [ "$cycles" -eq 2 ]; then
    notify ":red_circle: ${MENTION} NUC STILL down after power-cycle — manual intervention needed (down ~${dt})"
fi
# cycles >= 3: stay silent to avoid spam, just keep cycling and logging

set_plug turn_off false || echo "$(timestamp) Could not confirm plug OFF, turning on anyway" >> "$LOG"
sleep 10

# A late-applied turn_off can land after turn_on was confirmed, so re-check once.
plug_failed=0
if set_plug turn_on true; then
    sleep 30
    [ "$(plug_state)" = "true" ] || set_plug turn_on true || plug_failed=1
else
    plug_failed=1
fi

if [ "$plug_failed" -eq 0 ]; then
    echo "$(timestamp) Power cycle complete (cycle #${cycles})" >> "$LOG"
else
    echo "$(timestamp) Power cycle FAILED, plug not confirmed ON (cycle #${cycles})" >> "$LOG"
    notify ":red_circle: ${MENTION} Power-cycle failed — plug did not confirm ON, NUC may be left unpowered"
fi
