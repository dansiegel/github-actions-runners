# Testing

## Local automated checks

Controller unit tests cover:

- configuration rejects any nonzero minimum and any per-pool maximum above 20;
- a desired count of 20 creates 20 VMs;
- a desired count of zero removes all known-idle VMs;
- busy runners survive queue-driven scale-down and are removed after `JobCompleted`;
- stopped orphan VMs are reconciled;
- Azure VM payloads use the managed image and contain no managed identity;
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
  -var subscription_id=d901cbec-f20d-4272-a0b4-9ee06b850880 \
  -var resource_group_name=gha-runners-prod \
  -var managed_image_name=validation-only \
  image/runner.pkr.hcl
```

Syntax-check deployment/image scripts:

```bash
bash -n scripts/deploy-azure.sh
bash -n scripts/destroy-azure.sh
bash -n image/scripts/install-runner-toolchain.sh
```

The Packer build aliases the Canonical package installation to
`/usr/share/dotnet`, then creates and removes a probe directory there as the
`actions-runner` account. This makes reuse of the baked SDK and compatibility
with the default Linux install directory used by `actions/setup-dotnet` image-
build invariants.

The image build also validates the runner-specific sudoers file with `visudo`
and executes `sudo --non-interactive true` as `actions-runner`. This preserves
compatibility with Linux workflows that rely on GitHub's passwordless `sudo`
contract without waiting for a live job to expose a configuration error.

The pinned Aspire CLI is also executed as `actions-runner` during the image
build. This catches NativeAOT tool-package permission changes that would be
invisible when the root image provisioner writes the version manifest.

## Live smoke test

Automated local tests do not prove Azure quota, GitHub App installation, runner-group access, or marketplace availability. Before migrating a production repository, run a temporary workflow:

```yaml
name: Runner smoke test
on: workflow_dispatch

jobs:
  verify:
    runs-on: avp-linux
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
      - run: azd version
      - run: pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
      - run: aspire --version
      - run: cat /opt/runner-image/manifest.txt
      - run: docker run --rm hello-world
```

Verify the following lifecycle:

1. queued job causes one tagged VM to appear;
2. runner registers and accepts the job;
3. Docker workload succeeds;
4. runner disappears from GitHub after the job;
5. VM, disk, NIC, and public IP disappear from Azure;
6. controller remains healthy;
7. tagged runner-resource query returns empty.

## Burst test

Use a workflow-dispatch matrix matching the deployed capacity only after quota is confirmed (12 jobs for this subscription). Observe that no more than the configured maximum is created, then verify complete scale-to-zero. Testing the controller ceiling of 20 requires at least 80 available Dsv5-family vCPUs. Do not run a paid burst merely to validate source changes; schedule it as a controlled acceptance test with an approved spend window.

## Completion requirements

The implementation is ready for repository migration only when:

- controller tests pass;
- controller image builds;
- Bicep compiles without errors;
- Packer validates;
- the image-build write probe succeeds for `/usr/share/dotnet`;
- the image-build passwordless-sudo probe succeeds as `actions-runner`;
- the pinned Aspire CLI executes successfully as `actions-runner`;
- phase-one and phase-two Azure deployments succeed;
- the live Docker smoke test succeeds;
- an idle observation proves zero runner VMs and zero tagged runner NICs/public IPs;
- a controlled parallel test proves the required concurrency without quota failures.
