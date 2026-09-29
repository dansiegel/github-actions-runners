#!/usr/bin/env bash
set -Eeuo pipefail

/usr/local/sbin/runner-maintenance-policy verify
if [[ -e /var/run/reboot-required ]]; then
  printf 'Image still requires a reboot after package updates\n' >&2
  exit 1
fi
package_audit="$(dpkg --audit)"
if [[ -n "$package_audit" ]]; then
  printf 'Image contains incomplete package transactions:\n%s\n' "$package_audit" >&2
  exit 1
fi
kernel="$(uname -r)"
dpkg-query -W -f='${Package}\t${Version}\n' "linux-image-$kernel"
systemctl is-active --quiet docker
runuser --user actions-runner -- sudo --non-interactive true
runuser --user actions-runner -- env HOME=/home/actions-runner /usr/local/bin/aspire --version
runuser --user actions-runner -- env HOME=/home/actions-runner az bicep version
dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Abbrev}\n' > /opt/runner-image/packages.tsv
chmod 0444 /opt/runner-image/packages.tsv
chmod u+w /opt/runner-image/manifest.txt
{
  printf 'verified_after_reboot_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'kernel=%s\n' "$kernel"
  printf 'kernel_signature=%s\n' "$(cat /proc/version_signature)"
  printf 'package_manifest_sha256=%s\n' "$(sha256sum /opt/runner-image/packages.tsv | cut -d ' ' -f 1)"
  printf 'automatic_maintenance=masked\n'
} >> /opt/runner-image/manifest.txt
chmod 0444 /opt/runner-image/manifest.txt
cat /opt/runner-image/manifest.txt
