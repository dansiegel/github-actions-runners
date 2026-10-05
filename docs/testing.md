# Testing

## Local automated checks

Controller unit tests cover:

- configuration rejects any nonzero minimum and invalid caps, while zero or omitted caps follow demand;
- pool JSON preserves independent CPU/disk settings, optional image overrides, optional caps, and disabled profiles;
- the eight Linux and six Windows profile labels map to the expected SKUs and tiers, with all Windows profiles and Linux small profiles disabled, Windows S/SP excluded and `avp-linux-l` aliasing the existing `avp-linux` identity;
- omitted or empty Linux image overrides inherit the shared image; Windows never inherits it; explicit overrides are preserved; unknown fields and non-string/null image overrides are rejected;
- demand above 20 is supported, and positive optional caps are respected;
- a desired count of zero removes all known-idle VMs;
- busy runners survive queue-driven scale-down and are removed after `JobCompleted`;
- stopped orphan VMs are reconciled;
- Azure VM payloads use each pool's selected image and contain no managed identity;
- JIT data is envelope-encoded, cloud-init launches with the runner account's home directory and JIT environment, and the VM powers off on exit.

Run with the pinned toolchain:

```bash
docker run --rm \
  -v "$PWD/controller:/src" \
  -w /src \
  golang:1.25.7-alpine \
  go test ./...
```

Build the production container:

```bash
docker build --file controller/Dockerfile --tag gha-runner-controller:test controller
```

Compile Bicep:

```bash
az bicep build --file infra/main.bicep --stdout >/dev/null
```

Validate Packer without creating Azure resources:

```bash
packer init image/runner.pkr.hcl
packer validate \
  -var subscription_id=00000000-0000-0000-0000-000000000000 \
  -var resource_group_name=gha-runners-validation \
  -var managed_image_name=validation-only \
  image/runner.pkr.hcl
```

Syntax-check deployment/image scripts:

```bash
bash -n scripts/deploy-azure.sh
bash -n scripts/destroy-azure.sh
pwsh -NoProfile -File scripts/Test-RunnerDiskTier.ps1
bash -n image/scripts/install-runner-toolchain.sh
bash image/scripts/test-runner-maintenance-policy.sh
```

The Packer build aliases the Canonical package installation to
`/usr/share/dotnet`, then creates and removes a probe directory there as the
`actions-runner` account. This makes reuse of the baked SDK and compatibility
with the default Linux install directory used by `actions/setup-dotnet` image-
build invariants.

Maintenance-policy tests exercise a package transaction finishing before masking, the
bounded wait expiring without stopping that transaction, an absent optional timer,
timer-stop failure, and verification rejecting enabled/active units or overridden APT
settings. They mock systemd, so the real candidate image must also reboot and pass
`verify-runner-image.sh` before capture.

For a candidate rollout, record the image resource ID, manifest, booted kernel, package
inventory hash and previous image ID. Run an isolated candidate job with unchanged test
budgets and inspect maintenance unit/process state during the job. Only then choose a
controller rollout. Reverting `RUNNER_IMAGE_ID` affects future VMs in inheriting pools; revert a pinned pool's `imageId` separately if needed. Leave active jobs
and their disks alone. An image update does not establish that unrelated TCP or storage
failures are fixed.

Pass `-var base_image_version=<exact marketplace version>` to Packer for a candidate
comparison; the default `latest` deliberately accepts current base images for routine
refreshes. The selected base reference is included in the image manifest.

The image build also validates the runner-specific sudoers file with `visudo`
and executes `sudo --non-interactive true` as `actions-runner`. This preserves
compatibility with Linux workflows that rely on GitHub's passwordless `sudo`
contract without waiting for a live job to expose a configuration error.

The pinned Aspire CLI is also executed as `actions-runner` during the image
build. This catches NativeAOT tool-package permission changes that would be
invisible when the root image provisioner writes the version manifest.

Azure Bicep is installed beneath the same account's home and executed during
the build; the image build fails unless `$HOME/.azure/bin/bicep` is executable.

## Live smoke test

Automated local tests do not prove Azure quota, GitHub App installation, runner-group access, or marketplace availability. Before migrating a production repository, run a temporary workflow:

```yaml
name: Runner smoke test
on: workflow_dispatch

jobs:
  verify:
    runs-on: [Linux, avp-linux-m]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v5
        with:
          dotnet-version: 10.0.x
      - run: dotnet --list-sdks
      - run: node --version
      - run: docker version
      - run: docker buildx version
      - run: sudo --non-interactive true
      - run: az version
      - run: az bicep version
      - run: azd version
      - run: pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
      - run: aspire --version
      - run: cat /opt/runner-image/manifest.txt
      - run: docker run --rm hello-world
```

Repeat with one complete profile label per job for every enabled profile, including both `avp-linux` and its `avp-linux-l` alias to verify compatibility. Each alias must route to the same logical scale set and unchanged base hardware/image. Do not target the disabled small profiles before qualification.

Verify the following lifecycle:

1. queued job causes one tagged VM to appear;
2. runner registers and accepts the job;
3. Docker workload succeeds;
4. runner disappears from GitHub after the job;
5. VM, disk, NIC, and public IP disappear from Azure;
6. controller remains healthy;
7. tagged runner-resource query returns empty.

## Burst test

Use a bounded workflow-dispatch matrix only after quota and spend are approved, especially for an uncapped profile. Observe that demand is served and any explicit per-pool cap is respected, verify other pools are unaffected, then verify complete scale-to-zero. Test combined peaks only in a controlled acceptance window with an approved spend limit; local source validation does not justify a paid burst.

## Completion requirements

The implementation is ready for repository migration only when:

- controller tests pass;
- controller image builds;
- Bicep compiles without errors;
- Packer validates;
- the image-build write probe succeeds for `/usr/share/dotnet`;
- the image-build passwordless-sudo probe succeeds as `actions-runner`;
- the pinned Aspire CLI executes successfully as `actions-runner`;
- Azure Bicep is preinstalled and executes successfully as `actions-runner`;
- phase-one and phase-two Azure deployments succeed;
- the live Docker smoke test succeeds;
- an idle observation proves zero runner VMs and zero tagged runner NICs/public IPs;
- a controlled parallel test proves the required concurrency without quota failures.

## Windows source and runtime tests

The existing CI workflow also validates `image/windows-runner.pkr.hcl` without provisioning, parses every Windows image script, and runs `image/scripts/Test-WindowsRunner.ps1` on a GitHub-hosted Windows worker using Windows PowerShell 5.1. Fixtures cover raw/base64 custom data, strict schema, pinned version/checksum, payload deletion before the job, one-shot/reboot rejection, runner exit codes, and cleanup after failure. No fixture creates an Azure resource, enters a password, installs the image toolchain, or changes host remoting.

Go tests additionally cover mixed-OS image/checksum isolation, disabled placeholders, rejection of password inputs, Windows computer-name uniqueness, Azure-generated secure defaults without password values/outputs, no repeat PUT after a lost response, deployment metadata removal, cancel-before-delete ordering, and no billable resources for an unqualified profile. Existing race tests for profile isolation, simultaneous claims, restart adoption, demand above 20, job completion, quota backoff, and cleanup remain applicable to both OS types.

Source checks do not qualify a Windows image. Follow the bounded [Windows qualification procedure](operations.md#windows-profile-qualification) before enabling a profile. In addition to a real .NET/Node/Git job, inspect that the generalized image contains no Packer account, private build credential, JIT registration, or one-shot marker; runtime WinRM/RDP must be disabled. Collect Windows diagnostics before deletion during failure qualification. Test controller restart/cancellation during template provisioning to prove no late VM appears after cleanup, and verify all tagged VMs, disks, NICs, public IPs, and deployment records are removed.

OS-label regression checks cover automatic `Linux`/`Windows` scale-set labels, canonical deduplication of explicit matching OS labels, preservation of both legacy aliases, shared OS tags with unique profile labels, and rejection of mismatched or OS-only configurations. Before activation, compare Azure what-if results with Windows disabled and with only the bounded trial profile enabled: the existing lifecycle role must gain exactly six ARM deployment actions at the same resource-group scope. Re-disable and reprovision after the trial to remove them. Read back GitHub scale-set labels and execute combined-label smoke jobs before migrating existing custom-runner workflows.
