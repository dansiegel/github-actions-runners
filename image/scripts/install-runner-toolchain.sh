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
ln -s /opt/aspire/aspire /usr/local/bin/aspire

# The runner binary is also pinned and checksum-verified. JIT configuration is
# injected only when an ephemeral VM is created.
id actions-runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash actions-runner
usermod -aG docker actions-runner
install -d -o actions-runner -g actions-runner /opt/actions-runner
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
  printf 'azd=%s\n' "$(azd version | head -n 1)"
  printf 'powershell=%s\n' "$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
  printf 'aspire=%s\n' "$(aspire --version)"
  printf 'java=%s\n' "$(java -version 2>&1 | head -n 1)"
} > /opt/runner-image/manifest.txt

chmod 0444 /opt/runner-image/manifest.txt
