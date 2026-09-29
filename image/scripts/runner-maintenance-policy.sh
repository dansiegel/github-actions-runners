#!/usr/bin/env bash
set -Eeuo pipefail

maintenance_timers=(apt-daily.timer apt-daily-upgrade.timer fwupd-refresh.timer)
package_services=(apt-daily.service apt-daily-upgrade.service)
maintenance_units=("${maintenance_timers[@]}" "${package_services[@]}" unattended-upgrades.service fwupd-refresh.service fwupd.service)

prepare_maintenance_policy() {
  local root="${1:-}" attempts="${2:-120}" busy unit
  # Stop future scheduling first. Let any package transaction already running
  # finish; stopping dpkg mid-transaction is not a safe way to prepare an image.
  for unit in "${maintenance_timers[@]}"; do
    if [[ "$(systemctl show --property=LoadState --value "$unit")" != not-found ]]; then
      systemctl stop "$unit" || return
    fi
  done
  while true; do
    busy=false
    for unit in "${package_services[@]}"; do
      if systemctl is-active --quiet "$unit"; then busy=true; fi
    done
    if [[ "$busy" == false ]]; then break; fi
    if (( attempts == 0 )); then
      printf 'Package maintenance did not finish before the image-build deadline\n' >&2
      return 1
    fi
    attempts=$((attempts - 1))
    sleep 5
  done
  # fwupd has no firmware-management role on a disposable Azure VM. Mask its
  # service too so D-Bus activation cannot bypass the disabled refresh timer.
  systemctl mask --now "${maintenance_units[@]}" || return
  install -d -m 0755 "$root/etc/apt/apt.conf.d"
  cat > "$root/etc/apt/apt.conf.d/99-runner-image-maintenance" <<'POLICY'
// Apply updates while building the immutable image, never during its one CI job.
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
POLICY
}

verify_maintenance_policy() {
  local unit state setting
  for unit in "${maintenance_units[@]}"; do
    state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    if [[ "$state" != masked ]]; then
      printf 'Expected masked image maintenance unit: %s (found %s)\n' "$unit" "$state" >&2
      return 1
    fi
    if systemctl is-active --quiet "$unit"; then
      printf 'Image maintenance unit is unexpectedly active: %s\n' "$unit" >&2
      return 1
    fi
  done
  # Validate the effective configuration, including precedence over vendor files.
  local apt_policy
  apt_policy="$(apt-config dump)"
  for setting in Enable Update-Package-Lists Unattended-Upgrade; do
    if ! grep -Fxq "APT::Periodic::$setting \"0\";" <<< "$apt_policy"; then
      printf 'APT periodic policy is not disabled: %s\n' "$setting" >&2
      return 1
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    prepare) prepare_maintenance_policy ;;
    verify) verify_maintenance_policy ;;
    *) printf 'Usage: %s prepare|verify\n' "$0" >&2; exit 2 ;;
  esac
fi
