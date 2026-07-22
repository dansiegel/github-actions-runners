#!/usr/bin/env bash
set -Eeuo pipefail

: "${RUNNER_VERSION:?RUNNER_VERSION is required}"
: "${RUNNER_SHA256:?RUNNER_SHA256 is required}"
: "${ASPIRE_CLI_VERSION:?ASPIRE_CLI_VERSION is required}"

export DEBIAN_FRONTEND=noninteractive
install -d -m 0755 /etc/apt/keyrings /opt/runner-image

apt-get update
apt-get install -y --no-install-recommends \
  apt-transport-https \
  build-essential \
  ca-certificates \
  curl \
  git \
  gnupg \
  jq \
  libicu74 \
  lsb-release \
  openjdk-21-jdk \
  python3 \
  python3-pip \
  python3-venv \
  rsync \
  software-properties-common \
  sudo \
  tar \
  unzip \
  zip

# .NET 10 is supplied by Canonical's Ubuntu 24.04 feed.
apt-get install -y --no-install-recommends dotnet-sdk-10.0

# Docker Engine, CLI, Buildx, and Compose from Docker's signed Ubuntu feed.
curl --fail --show-error --silent --location https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker

# Node.js 24 LTS. The immutable image records the resolved package version below.
curl --fail --show-error --silent --location https://deb.nodesource.com/setup_24.x -o /tmp/nodesource-setup.sh
bash /tmp/nodesource-setup.sh
apt-get install -y --no-install-recommends nodejs
rm -f /tmp/nodesource-setup.sh

# Azure CLI, Azure Developer CLI, and PowerShell use their vendors' stable channels.
curl --fail --show-error --silent --location https://aka.ms/InstallAzureCLIDeb -o /tmp/install-azure-cli.sh
bash /tmp/install-azure-cli.sh
rm -f /tmp/install-azure-cli.sh

curl --fail --show-error --silent --location https://aka.ms/install-azd.sh -o /tmp/install-azd.sh
bash /tmp/install-azd.sh
rm -f /tmp/install-azd.sh

curl --fail --show-error --silent --location https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
apt-get update
apt-get install -y --no-install-recommends powershell

# Aspire CLI is version-pinned because it participates directly in build behavior.
dotnet tool install Aspire.Cli --tool-path /opt/aspire --version "$ASPIRE_CLI_VERSION"
chmod -R a+rX /opt/aspire
ln -s /opt/aspire/aspire /usr/local/bin/aspire

# The runner binary is also pinned and checksum-verified. JIT configuration is
# injected only when an ephemeral VM is created.
id actions-runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash actions-runner
usermod -aG docker actions-runner
install -d -o actions-runner -g actions-runner /opt/actions-runner

# Azure CLI installs Bicep on demand beneath the invoking user's home. Install
# it while the image is built so concurrent workflow processes never race to
# create or replace the executable on a newly started runner.
install -d -o actions-runner -g actions-runner /home/actions-runner/.azure
runuser --user actions-runner -- env HOME=/home/actions-runner az bicep install
bicep_path=/home/actions-runner/.azure/bin/bicep
if [[ ! -x "$bicep_path" ]]; then
  printf 'Expected an executable Bicep CLI at %s\n' "$bicep_path" >&2
  exit 1
fi
chown -R actions-runner:actions-runner /home/actions-runner/.azure
runuser --user actions-runner -- env HOME=/home/actions-runner az bicep version

# GitHub-hosted Linux runners allow workflows to use sudo without an
# interactive password. Match that contract on the single-use VM; Docker group
# membership already gives this account equivalent host-level privileges.
printf 'actions-runner ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/actions-runner
chmod 0440 /etc/sudoers.d/actions-runner
visudo --check --file /etc/sudoers.d/actions-runner
runuser --user actions-runner -- sudo --non-interactive true
runuser --user actions-runner -- env HOME=/home/actions-runner /usr/local/bin/aspire --version

# Canonical installs .NET under /usr/lib, while actions/setup-dotnet uses
# /usr/share/dotnet by default on Linux. Alias the action's default to the
# baked installation so matching SDKs are reused instead of downloaded again.
dotnet_install_dir=/usr/share/dotnet
dotnet_root="$(dirname "$(readlink -f "$(command -v dotnet)")")"
if [[ ! -e "$dotnet_install_dir" ]]; then
  ln -s "$dotnet_root" "$dotnet_install_dir"
fi
dotnet_install_root="$(readlink -f "$dotnet_install_dir")"
if [[ "$dotnet_install_root" != "$dotnet_root" ]]; then
  printf 'Expected %s to resolve to the baked .NET root %s, but found %s\n' \
    "$dotnet_install_dir" "$dotnet_root" "$dotnet_install_root" >&2
  exit 1
fi

# Give the single-use runner account access to extend that installation while
# retaining a dedicated group instead of making it world-writable.
chgrp -R actions-runner "$dotnet_install_root"
chmod -R g+rwX "$dotnet_install_root"
find "$dotnet_install_root" -type d -exec chmod g+s {} +

# Fail the image build if a packaging or permission change would make
# actions/setup-dotnet unusable by the unprivileged runner account.
dotnet_write_probe="$dotnet_install_dir/.runner-write-probe"
runuser --user actions-runner -- mkdir "$dotnet_write_probe"
rmdir "$dotnet_write_probe"

runner_asset="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
runner_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${runner_asset}"
curl --fail --show-error --silent --location "$runner_url" -o "/tmp/${runner_asset}"
printf '%s  %s\n' "$RUNNER_SHA256" "/tmp/${runner_asset}" | sha256sum --check --strict
tar xzf "/tmp/${runner_asset}" -C /opt/actions-runner
rm -f "/tmp/${runner_asset}"
/opt/actions-runner/bin/installdependencies.sh
chown -R actions-runner:actions-runner /opt/actions-runner

# Remove mutable package caches; the installed SDKs and tools remain in the
# managed image while every job starts without another job's cache contents.
npm cache clean --force
dotnet nuget locals all --clear
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*

{
  printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'runner=%s\n' "$RUNNER_VERSION"
  printf 'dotnet_sdks=%s\n' "$(dotnet --list-sdks | paste -sd ',' -)"
  printf 'node=%s\n' "$(node --version)"
  printf 'npm=%s\n' "$(npm --version)"
  printf 'docker=%s\n' "$(docker --version)"
  printf 'buildx=%s\n' "$(docker buildx version)"
  printf 'azure_cli=%s\n' "$(az version --query '"azure-cli"' -o tsv)"
  printf 'bicep=%s\n' "$(runuser --user actions-runner -- env HOME=/home/actions-runner az bicep version)"
  printf 'azd=%s\n' "$(azd version | head -n 1)"
  printf 'powershell=%s\n' "$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
  printf 'aspire=%s\n' "$(aspire --version)"
  printf 'java=%s\n' "$(java -version 2>&1 | head -n 1)"
} > /opt/runner-image/manifest.txt

chmod 0444 /opt/runner-image/manifest.txt
