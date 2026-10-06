# Runs on the Packer operator, using its existing Azure CLI login. Never reads a token.
[CmdletBinding()]
param(
    [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $VmName,
    [string] $Location,
    [string] $FinalizerSHA256,
    [string] $AttemptId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FinalizationProperty {
    param($Object, [string] $Name)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
}

function Invoke-WindowsImageRest {
    param([string] $Method, [string] $Uri, $Body)
    $errorFile = [IO.Path]::GetTempFileName()
    $bodyFile = $null
    try {
        $arguments = @('rest', '--method', $Method, '--url', $Uri, '--only-show-errors', '--output', 'json')
        if ($null -ne $Body) {
            $bodyFile = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 15 -Compress), [Text.UTF8Encoding]::new($false))
            $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
        }
        $PSNativeCommandUseErrorActionPreference = $false
        # Windows PowerShell 5.1 wraps redirected native stderr in ErrorRecord.
        # Classify it after exit instead of throwing before reading the status.
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $response = & az @arguments 2> $errorFile
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        if ($exitCode -ne 0) {
            $detail = [IO.File]::ReadAllText($errorFile)
            $status = 0
            if ($detail -match '(?i)ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|\bNotFound\b|\b404\b') { $status = 404 }
            elseif ($detail -match '(?i)AuthorizationFailed|Forbidden|\b403\b') { $status = 403 }
            elseif ($detail -match '(?i)Unauthorized|\b401\b') { $status = 401 }
            elseif ($detail -match '(?i)TooManyRequests|\b429\b') { $status = 429 }
            elseif ($detail -match '(?i)BadRequest|InvalidParameter|\b400\b') { $status = 400 }
            elseif ($detail -match '(?i)InternalServerError|ServiceUnavailable|GatewayTimeout|\b50[0234]\b') { $status = 503 }
            $failure = [InvalidOperationException]::new("Azure $Method failed (HTTP classification $status); no response body is logged.")
            $failure.Data['StatusCode'] = $status
            throw $failure
        }
        if (-not [string]::IsNullOrWhiteSpace(($response -join "`n"))) { return ($response -join "`n") | ConvertFrom-Json }
    } finally {
        Remove-Item -LiteralPath $errorFile -Force
        if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -Force }
    }
}

function Get-WindowsFinalizationTime { return [DateTime]::UtcNow }
function Wait-WindowsFinalizationPoll { Start-Sleep -Seconds 5 }

function Assert-WindowsFinalizationPermissions {
    param($Permissions)
    foreach ($action in @('Microsoft.Compute/virtualMachines/runCommands/read', 'Microsoft.Compute/virtualMachines/runCommands/write', 'Microsoft.Compute/virtualMachines/runCommands/delete')) {
        $allowed = $false
        foreach ($rule in $Permissions) {
            $matches = @((Get-FinalizationProperty $rule 'actions') | Where-Object { $action -like $_ }).Count -gt 0
            $excluded = @((Get-FinalizationProperty $rule 'notActions') | Where-Object { $action -like $_ }).Count -gt 0
            if ($matches -and -not $excluded) { $allowed = $true }
        }
        if (-not $allowed) { throw "Existing build identity lacks $action; no grant will be added." }
    }
}

function Read-WindowsFinalizationProof {
    param($Command, [string] $ExpectedAttempt, [string] $ExpectedSHA256)
    $view = Get-FinalizationProperty $Command.properties 'instanceView'
    if ($null -eq $view -or (Get-FinalizationProperty $view 'executionState') -cne 'Succeeded' -or
        $null -eq (Get-FinalizationProperty $view 'exitCode') -or $view.exitCode -ne 0) { throw 'Managed command did not report successful execution with exit code zero' }
    $lines = @(([string] (Get-FinalizationProperty $view 'output') -split '\r?\n') | Where-Object { $_.StartsWith('GHA_IMAGE_FINALIZATION ') })
    if ($lines.Count -ne 1) { throw 'Missing or ambiguous per-attempt finalization proof' }
    $proof = $lines[0].Substring('GHA_IMAGE_FINALIZATION '.Length) | ConvertFrom-Json
    if ($proof.schemaVersion -ne 1 -or $proof.attemptId -cne $ExpectedAttempt -or $proof.scriptSHA256 -cne $ExpectedSHA256 -or $proof.status -cne 'Succeeded' -or $proof.sysprepState -cne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw 'Finalization proof does not match this build attempt and source' }
    foreach ($field in @('buildAccountRetired', 'privateKeyAbsent', 'certificateAbsent', 'winrmListenersAbsent', 'buildFirewallRuleAbsent', 'tokenPolicyRestored', 'runtimeTaskPresent')) {
        $value = Get-FinalizationProperty $proof $field
        if ($value -isnot [bool] -or -not $value) { throw "Finalization proof lacks verified $field" }
    }
    return $proof
}

function Remove-WindowsFinalizationCommand {
    param([string] $Uri, [string] $ExpectedAttempt, [string] $ExpectedSHA256)
    $deadline = (Get-WindowsFinalizationTime).AddSeconds(120)
    $deleted = $false
    while ((Get-WindowsFinalizationTime) -lt $deadline) {
        try { $command = Invoke-WindowsImageRest GET $Uri $null }
        catch {
            if ($_.Exception.Data['StatusCode'] -eq 404) { return }
            if ($_.Exception.Data['StatusCode'] -notin @(429, 503)) { throw }
            Wait-WindowsFinalizationPoll; continue
        }
        if ($command.tags.'finalization-attempt' -cne $ExpectedAttempt -or $command.tags.'finalizer-sha256' -cne $ExpectedSHA256) { throw 'Refusing cleanup of an unrelated managed command' }
        if (-not $deleted) {
            $deleted = $true
            try { $null = Invoke-WindowsImageRest DELETE $Uri $null }
            catch {
                if ($_.Exception.Data['StatusCode'] -in @(400, 401, 403)) { throw }
                # An uncertain deletion is reconciled by GET; never execute again.
            }
        }
        Wait-WindowsFinalizationPoll
    }
    throw 'Managed finalization command deletion was not confirmed'
}

function Invoke-WindowsImageFinalization {
    param([string] $Subscription, [string] $Group, [string] $VM, [string] $Region, [string] $SourceSHA256, [string] $Attempt)
    $guidPattern = '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
    if ($Subscription -inotmatch $guidPattern -or $Group -cnotmatch '^[A-Za-z0-9_.()-]+$' -or $VM -cnotmatch '^pkrvm[A-Za-z0-9]+$' -or $Region -cne 'eastus2' -or $SourceSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $Attempt -cnotmatch $guidPattern) { throw 'Invalid Packer finalization target or attempt' }
    $vmId = "/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.Compute/virtualMachines/$VM"
    $baseUri = "https://management.azure.com$vmId"
    $machine = Invoke-WindowsImageRest GET ($baseUri + '?api-version=2023-03-01') $null
    if ($machine.id -ine $vmId -or $machine.location -ine $Region -or $machine.tags.'managed-by' -cne 'packer' -or $machine.tags.project -cne 'github-actions-runners' -or $machine.properties.storageProfile.osDisk.osType -cne 'Windows') { throw 'Target is not the expected Packer Windows builder' }
    $permissions = @()
    $permissionUri = $baseUri + '/providers/Microsoft.Authorization/permissions?api-version=2022-04-01'
    while ($permissionUri) {
        if (-not $permissionUri.StartsWith($baseUri + '/providers/Microsoft.Authorization/permissions?', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected permission pagination target' }
        $page = Invoke-WindowsImageRest GET $permissionUri $null
        $permissions += @($page.value)
        $permissionUri = [string] (Get-FinalizationProperty $page 'nextLink')
    }
    Assert-WindowsFinalizationPermissions -Permissions $permissions
    $commandUri = $baseUri + '/runCommands/gha-image-finalize-' + $Attempt.Replace('-', '') + '?api-version=2023-03-01'
    $readUri = $commandUri + '&$expand=instanceView'
    $source = @'
$ErrorActionPreference = 'Stop'
$attempt = '__ATTEMPT__'
$sha = '__SHA__'
$completed = "$env:ProgramData\GitHubRunner\image-finalization.complete.json"
if (-not (Test-Path -LiteralPath $completed)) {
    $script = 'C:\Windows\Temp\Complete-WindowsRunnerImage.ps1'
    if ((Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha) { throw 'Staged finalizer checksum mismatch' }
    & $script -AttemptId $attempt -ExpectedScriptSHA256 $sha
}
$record = Get-Content -LiteralPath $completed -Raw | ConvertFrom-Json
if ($record.attemptId -cne $attempt -or $record.scriptSHA256 -cne $sha -or $record.status -cne 'Succeeded') { throw 'Finalization record belongs to another attempt or failed' }
Write-Output ('GHA_IMAGE_FINALIZATION ' + ($record | ConvertTo-Json -Depth 5 -Compress))
'@
    $source = $source.Replace('__ATTEMPT__', $Attempt).Replace('__SHA__', $SourceSHA256)
    $body = @{ location = $Region; tags = @{ 'finalization-attempt' = $Attempt; 'finalizer-sha256' = $SourceSHA256 }; properties = @{ source = @{ script = $source }; asyncExecution = $true; timeoutInSeconds = 1200; treatFailureAsDeploymentFailure = $true } }
    $ownsCommand = $false
    $failure = $null
    try {
        $existing = $null
        try { $existing = Invoke-WindowsImageRest GET $readUri $null }
        catch { if ($_.Exception.Data['StatusCode'] -ne 404) { throw } }
        if ($null -ne $existing -and ($existing.tags.'finalization-attempt' -cne $Attempt -or $existing.tags.'finalizer-sha256' -cne $SourceSHA256)) { throw 'Managed command identity is already owned by another attempt' }
        $ownsCommand = $true
        if ($null -eq $existing) {
            # Submit once. An uncertain PUT is reconciled by reading this identity.
            try { $null = Invoke-WindowsImageRest PUT $commandUri $body }
            catch { if ($_.Exception.Data['StatusCode'] -in @(400, 401, 403)) { throw } }
        }
        $deadline = (Get-WindowsFinalizationTime).AddSeconds(1320)
        $missingDeadline = (Get-WindowsFinalizationTime).AddSeconds(90)
        while ((Get-WindowsFinalizationTime) -lt $deadline) {
            try { $command = Invoke-WindowsImageRest GET $readUri $null }
            catch {
                $status = $_.Exception.Data['StatusCode']
                if ($status -eq 404 -and (Get-WindowsFinalizationTime) -lt $missingDeadline) { Wait-WindowsFinalizationPoll; continue }
                if ($status -in @(429, 503)) { Wait-WindowsFinalizationPoll; continue }
                throw
            }
            if ($command.tags.'finalization-attempt' -cne $Attempt -or $command.tags.'finalizer-sha256' -cne $SourceSHA256) { throw 'Managed command ownership changed while polling' }
            $view = Get-FinalizationProperty $command.properties 'instanceView'
            $state = [string] (Get-FinalizationProperty $view 'executionState')
            if ($state -ceq 'Succeeded') { return Read-WindowsFinalizationProof -Command $command -ExpectedAttempt $Attempt -ExpectedSHA256 $SourceSHA256 }
            if ($state -in @('Failed', 'TimedOut', 'Canceled') -or (Get-FinalizationProperty $command.properties 'provisioningState') -eq 'Failed') {
                # Preserve only our fixed phase labels, not raw guest errors or
                # provider payloads which could contain unrelated machine data.
                $phase = @(([string] (Get-FinalizationProperty $view 'output') -split '\r?\n') | Where-Object { $_ -cmatch '^Finalization phase: [a-z-]+$' } | Select-Object -Last 1)
                throw "Managed finalization failed: executionState=$state; $($phase -join '')"
            }
            Wait-WindowsFinalizationPoll
        }
        throw 'Managed finalization timed out without independent completion proof'
    } catch {
        $failure = $_
        throw
    } finally {
        if ($ownsCommand) {
            try { Remove-WindowsFinalizationCommand -Uri $commandUri -ExpectedAttempt $Attempt -ExpectedSHA256 $SourceSHA256 }
            catch {
                if ($null -ne $failure) { Write-Warning $failure.Exception.Message }
                throw
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $proof = Invoke-WindowsImageFinalization -Subscription $SubscriptionId -Group $ResourceGroupName -VM $VmName -Region $Location -SourceSHA256 $FinalizerSHA256 -Attempt $AttemptId
    Write-Output "Verified image finalization for attempt $($proof.attemptId); managed command cleanup confirmed."
}
