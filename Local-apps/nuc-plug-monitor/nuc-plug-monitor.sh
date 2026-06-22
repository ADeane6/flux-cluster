#!/usr/bin/env bash
# nuc-plug-monitor.sh
#
# Polls the ESPHome smart plug powering the NUC (tomnuc.home) and logs
# voltage / current / power to disk, so we can capture the power trace through
# the next NUC power-loss event.
#
# Run this on TrueNAS, NOT on the NUC. The whole point is that the recorder has
# to survive the NUC dying, and TrueNAS is the box proven to stay up (see
# docs/nuc-power-crash-investigation-2026-06.md). Everything that normally
# observes the plug (Home Assistant, Mosquitto, Prometheus, Loki) runs on the
# NUC, so it all dies at the exact moment we want to observe.
#
# What the data tells us at the moment of a crash:
#   - voltage steady (~240V), power drops to ~0W, plug still reachable
#       -> NUC stopped drawing while power was present = internal PSU/board fault
#   - voltage sags just before power collapses
#       -> mains brownout the PSU couldn't ride through
#   - plug goes UNREACHABLE (curl fails)
#       -> upstream mains / plug itself lost power
#
# ESPHome web_server v2 REST API, no auth:
#   GET http://<ip>/sensor/{voltage,current,power,energy} -> {"value": <num>, ...}

set -u

PLUG_IP="${PLUG_IP:-10.0.1.89}"
INTERVAL="${INTERVAL:-2}"                                  # seconds between samples
RETAIN_DAYS="${RETAIN_DAYS:-30}"                           # delete CSVs older than this
LOG_DIR="${LOG_DIR:-/mnt/all/config/nuc-plug-logs}"
BASE_URL="http://${PLUG_IP}"

mkdir -p "$LOG_DIR"

read_sensor() {
  # $1 = sensor id. Prints the numeric value, or nothing on failure.
  curl -s --connect-timeout 2 --max-time 3 "${BASE_URL}/sensor/$1" \
    | jq -r '.value // empty' 2>/dev/null
}

while true; do
  ts_epoch="$(date -u +%s)"
  ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  logfile="${LOG_DIR}/nuc-plug-$(date -u +%Y-%m-%d).csv"

  if [ ! -f "$logfile" ]; then
    echo "epoch_s,iso_utc,status,voltage_v,current_a,power_w,energy_kwh" >> "$logfile"
    # new day rolled over: prune CSVs older than the retention window
    find "$LOG_DIR" -name 'nuc-plug-*.csv' -type f -mtime "+${RETAIN_DAYS}" -delete 2>/dev/null
  fi

  voltage="$(read_sensor voltage)"
  current="$(read_sensor current)"
  power="$(read_sensor power)"
  energy="$(read_sensor energy)"

  if [ -n "$voltage" ] || [ -n "$power" ]; then
    status="OK"
  else
    status="UNREACHABLE"
  fi

  echo "${ts_epoch},${ts_iso},${status},${voltage},${current},${power},${energy}" >> "$logfile"
  sleep "$INTERVAL"
done
