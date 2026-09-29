#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/runner-maintenance-policy.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
events="$fixture/events"
polls=0
busy_polls=0
enabled_state=masked
active_verify=false
bad_policy=false
missing_timer=false
fail_stop=false

systemctl() {
  printf '%s\n' "$*" >> "$events"
  case "$1" in
    show)
      if [[ "$missing_timer" == true && "${@: -1}" == fwupd-refresh.timer ]]; then
        printf 'not-found\n'
      else printf 'loaded\n'; fi ;;
    stop) [[ "$fail_stop" == false ]] ;;
    mask) return 0 ;;
    is-enabled) printf '%s\n' "$enabled_state" ;;
    is-active)
      if [[ "$active_verify" == true ]]; then return 0; fi
      if [[ "${@: -1}" == apt-daily-upgrade.service && $polls -lt $busy_polls ]]; then
        polls=$((polls + 1)); return 0
      fi
      return 3 ;;
    *) printf 'Unexpected systemctl command\n' >&2; return 2 ;;
  esac
}
sleep() { printf 'wait\n' >> "$events"; }
apt-config() {
  if [[ "$bad_policy" == true ]]; then printf 'APT::Periodic::Enable "1";\n'; return; fi
  cat "$fixture/etc/apt/apt.conf.d/99-runner-image-maintenance"
}

busy_polls=2
prepare_maintenance_policy "$fixture" 2
! grep -Eq '^stop apt-daily(-upgrade)?\.service|^mask --now' "$events"
[[ $(grep -c '^wait$' "$events") == 2 ]]
[[ $(grep -n '^mask ' "$events" | cut -d: -f1) -gt $(grep -n '^wait$' "$events" | tail -1 | cut -d: -f1) ]]
verify_maintenance_policy
printf 'PASS: waits for active package work before masking; effective policy verifies\n'

: > "$events"
polls=0
busy_polls=10
if prepare_maintenance_policy "$fixture" 1; then
  printf 'Expected package deadline failure\n' >&2; exit 1
fi
! grep -q '^mask ' "$events"
printf 'PASS: package deadline fails without killing or masking active package work\n'

: > "$events"
busy_polls=0
missing_timer=true
prepare_maintenance_policy "$fixture" 1
! grep -q '^stop fwupd-refresh.timer$' "$events"
grep -q '^mask .*fwupd-refresh.timer' "$events"
printf 'PASS: absent optional timer is safely masked against future activation\n'

: > "$events"
fail_stop=true
if prepare_maintenance_policy "$fixture" 1; then
  printf 'Expected timer stop failure\n' >&2; exit 1
fi
! grep -q '^mask ' "$events"
fail_stop=false
printf 'PASS: timer-stop failure does not proceed with maintenance changes\n'

enabled_state=enabled
if verify_maintenance_policy; then exit 1; fi
enabled_state=masked
active_verify=true
if verify_maintenance_policy; then exit 1; fi
active_verify=false
bad_policy=true
if verify_maintenance_policy; then exit 1; fi
printf 'PASS: verification rejects unmasked, active and overridden package policy states\n'
