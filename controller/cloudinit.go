package main

import (
	"encoding/base64"
	"fmt"
	"strings"
)

func renderCloudInit(c Config, encodedJITConfig string) string {
	// The JIT value is base64-wrapped a second time so it can be embedded in
	// cloud-init without shell interpolation. GitHub's one-time JIT value is
	// consumed before any workflow code runs.
	jitEnvelope := base64.StdEncoding.EncodeToString([]byte(encodedJITConfig))
	asset := fmt.Sprintf("actions-runner-linux-x64-%s.tar.gz", c.RunnerVersion)
	download := fmt.Sprintf("https://github.com/actions/runner/releases/download/v%s/%s", c.RunnerVersion, asset)

	script := fmt.Sprintf(`#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/gha-runner-bootstrap.log | logger -t gha-runner -s 2>/dev/console) 2>&1

RUNNER_ROOT=/opt/actions-runner
RUNNER_USER=%s
RUNNER_ASSET=%s
RUNNER_DOWNLOAD=%s
JIT_ENVELOPE=%s

shutdown_runner() {
  exit_code=$?
  if [[ -d "$RUNNER_ROOT/_diag" ]]; then
    find "$RUNNER_ROOT/_diag" -type f -maxdepth 1 -print0 | sort -z | xargs -0 -r tail -n 80 || true
  fi
  sync
  shutdown -h now || poweroff || true
  exit "$exit_code"
}
trap shutdown_runner EXIT

export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends docker.io
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl jq tar gzip
fi

systemctl enable --now docker
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_ROOT"

if [[ ! -x "$RUNNER_ROOT/run.sh" ]]; then
  cd "$RUNNER_ROOT"
  curl --fail --show-error --silent --location --output "$RUNNER_ASSET" "$RUNNER_DOWNLOAD"
  printf '%%s  %%s\n' %s "$RUNNER_ASSET" | sha256sum --check --strict
  tar xzf "$RUNNER_ASSET"
  rm -f "$RUNNER_ASSET"
  ./bin/installdependencies.sh
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_ROOT"
fi

JIT_CONFIG="$(printf '%%s' "$JIT_ENVELOPE" | base64 --decode)"
unset JIT_ENVELOPE

# Remove the local cloud-init copies before workflow code is allowed to run.
# Azure IMDS can still expose customData, but the JIT credential is one-time and
# has already been consumed by the runner when a job starts.
find /var/lib/cloud/instances -type f \( -name user-data.txt -o -name user-data.txt.i \) -delete 2>/dev/null || true
rm -f -- "$0"

cd "$RUNNER_ROOT"
sudo -Eu "$RUNNER_USER" env ACTIONS_RUNNER_INPUT_JITCONFIG="$JIT_CONFIG" ./run.sh
`, shellQuote(c.RunnerUser), shellQuote(asset), shellQuote(download), shellQuote(jitEnvelope), shellQuote(c.RunnerSHA256))

	return "#cloud-config\n" +
		"package_update: false\n" +
		"write_files:\n" +
		"  - path: /usr/local/sbin/start-ephemeral-runner\n" +
		"    owner: root:root\n" +
		"    permissions: '0700'\n" +
		"    encoding: b64\n" +
		"    content: " + base64.StdEncoding.EncodeToString([]byte(script)) + "\n" +
		"runcmd:\n" +
		"  - [ /usr/local/sbin/start-ephemeral-runner ]\n"
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}
