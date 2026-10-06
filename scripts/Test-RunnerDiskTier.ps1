$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$poolFile = Join-Path ([IO.Path]::GetTempPath()) ("runner-tier-test-" + [Guid]::NewGuid().ToString('N') + '.json')
$deploymentScript = Join-Path $PSScriptRoot 'deploy-azure.ps1'

# Exercise the same pure normalizer without running any deployment statements.
$tokens = $null
$parseErrors = $null
$deploymentAst = [System.Management.Automation.Language.Parser]::ParseFile($deploymentScript, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw "Deployment script did not parse: $parseErrors" }
$normalizer = $deploymentAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-NormalizedRunnerPools'
}, $false)
if ($null -eq $normalizer) { throw 'Deployment pool normalizer was not found' }
. ([scriptblock]::Create($normalizer.Extent.Text))

function Test-PoolDryRun {
    param(
        [string] $Name,
        [object] $Pools,
        [bool] $Valid = $true,
        [string[]] $Expected = @()
    )
    ConvertTo-Json -InputObject $Pools -Depth 5 | Set-Content -LiteralPath $poolFile -Encoding utf8
    $output = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'deploy-azure.ps1') `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 -GitHubOrganization ExampleOrg -RunnerPoolsFile $poolFile 2>&1
    if (($LASTEXITCODE -eq 0) -ne $Valid) { throw "PowerShell validation mismatch for ${Name}: $output" }
    foreach ($pattern in $Expected) {
        if (($output -join "`n") -notmatch $pattern) { throw "PowerShell dry run omitted '$pattern' for $Name" }
    }
    if ($Valid) {
        $RunnerPoolsFile = $poolFile
        $normalized = @(Get-NormalizedRunnerPools)
        $source = Get-Content -LiteralPath $poolFile -Raw | ConvertFrom-Json -NoEnumerate
        for ($index = 0; $index -lt $source.Count; $index++) {
            foreach ($field in @('maxRunners', 'enabled', 'imageId', 'osType')) {
                $present = $null -ne $source[$index].PSObject.Properties[$field]
                if ($normalized[$index].Contains($field) -ne $present) { throw "Normalization changed presence of $field for $Name" }
                if ($present) {
                    $expectedValue = if ($field -eq 'imageId') { $source[$index].imageId.Trim() } else { $source[$index].$field }
                    if ($normalized[$index][$field] -cne $expectedValue) { throw "Normalization changed $field for $Name" }
                }
            }
        }
    }
    if ($IsLinux) {
        $output = & bash (Join-Path $PSScriptRoot 'deploy-azure.sh') --dry-run `
            --subscription-id 00000000-0000-0000-0000-000000000000 --github-organization ExampleOrg --runner-pools-file $poolFile 2>&1
        if (($LASTEXITCODE -eq 0) -ne $Valid) { throw "Bash validation mismatch for ${Name}: $output" }
        foreach ($pattern in $Expected) {
            if (($output -join "`n") -notmatch $pattern) { throw "Bash dry run omitted '$pattern' for $Name" }
        }
    }
}

try {
    foreach ($tier in @('P10', 'P15', 'P20', 'P30', 'P99', 'p20')) {
        $valid = $tier -cin @('P10', 'P15', 'P20', 'P30')
        $expected = if ($valid) { @("OS disk tier: $tier") } else { @() }
        Test-PoolDryRun -Name "tier $tier" -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; maxRunners = 1; osDiskTier = $tier }) -Valid $valid -Expected $expected
    }
    foreach ($maximum in @(0, 21, 2147483647)) {
        $capacity = if ($maximum -eq 0) { '0\.\.demand \(uncapped\)' } else { "0\.\.$maximum " }
        Test-PoolDryRun -Name "maximum $maximum" -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; maxRunners = $maximum }) -Expected @($capacity)
    }
    foreach ($maximum in @(-1, 2147483648, 1.5, '4', $true, $null)) {
        Test-PoolDryRun -Name "invalid maximum '$maximum'" -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; maxRunners = $maximum }) -Valid $false
    }
    Test-PoolDryRun -Name 'omitted maximum and enabled' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5' }) -Expected @('0\.\.demand \(uncapped\)', 'one shared Container App')
    foreach ($imageId in @('', '   ', '/subscriptions/example/resourceGroups/runners/providers/Microsoft.Compute/images/validated-image')) {
        $source = if ($imageId.Trim()) { 'pool imageId override' } else { 'shared RUNNER_IMAGE_ID' }
        Test-PoolDryRun -Name "image override '$imageId'" -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; imageId = $imageId }) -Expected @("image: $source")
    }
    foreach ($imageId in @($null, 1, $true, @('image'), @{ id = 'image' })) {
        Test-PoolDryRun -Name 'invalid image override type' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; imageId = $imageId }) -Valid $false
    }
    Test-PoolDryRun -Name 'omitted image override' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5' }) -Expected @('image: shared RUNNER_IMAGE_ID')
    Test-PoolDryRun -Name 'unknown pool field' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; unknownField = 'image' }) -Valid $false
    Test-PoolDryRun -Name 'redundant pool ID' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; id = 'test-pool' }) -Valid $false
    Test-PoolDryRun -Name 'scalar pool entry' -Pools @('test-pool') -Valid $false
    Test-PoolDryRun -Name 'enabled pool' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; enabled = $true }) -Expected @('0\.\.demand \(uncapped\)')
    Test-PoolDryRun -Name 'disabled one-core profile' -Pools @(@{ name = 'avp-linux-s'; vmSize = 'Standard_F1als_v7'; osDiskTier = 'P10'; enabled = $false }, @{ name = 'test-pool'; vmSize = 'Standard_D4s_v5' }) -Expected @('avp-linux-s: disabled', 'OS disk tier: P10')
    foreach ($enabled in @('false', 0, $null)) {
        Test-PoolDryRun -Name "invalid enabled '$enabled'" -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; enabled = $enabled }) -Valid $false
    }
    Test-PoolDryRun -Name 'shared automatic OS tags' -Pools @(@{ name = 'linux-one'; vmSize = 'Standard_D4s_v5'; labels = @('linux-one', 'Linux') }, @{ name = 'linux-two'; vmSize = 'Standard_D2s_v5'; labels = @('linux-two', 'linux') }) -Expected @('OS tag: Linux')
    Test-PoolDryRun -Name 'Windows OS tag' -Pools @(@{ name = 'win'; vmSize = 'Standard_D4s_v5'; osType = 'Windows'; imageId = '/images/windows'; labels = @('win', 'WINDOWS') }) -Expected @('OS tag: Windows')
    foreach ($labels in @(@('Windows', 'profile'), @('macOS', 'profile'), @('Linux'))) {
        Test-PoolDryRun -Name 'invalid Linux OS tag or missing profile' -Pools @(@{ name = 'linux'; vmSize = 'Standard_D4s_v5'; labels = $labels }) -Valid $false
    }
    Test-PoolDryRun -Name 'all profiles disabled' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; enabled = $false }) -Valid $false
    Test-PoolDryRun -Name 'duplicate labels' -Pools @(@{ name = 'pool-one'; vmSize = 'Standard_D4s_v5'; labels = @('shared') }, @{ name = 'pool-two'; vmSize = 'Standard_D4s_v5'; labels = @('SHARED'); enabled = $false }) -Valid $false
    $manyPools = @(1..9 | ForEach-Object { @{ name = "test-pool-$_"; vmSize = 'Standard_D4s_v5' } })
    Test-PoolDryRun -Name 'more than eight pools' -Pools $manyPools -Expected @('test-pool-9: 0\.\.demand')
    Test-PoolDryRun -Name 'empty array' -Pools @() -Valid $false
    Test-PoolDryRun -Name 'object instead of array' -Pools @{ name = 'test-pool'; vmSize = 'Standard_D4s_v5' } -Valid $false
    Test-PoolDryRun -Name 'duplicate names' -Pools @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5' }, @{ name = 'TEST-POOL'; vmSize = 'Standard_D4s_v5' }) -Valid $false

    foreach ($maximum in @('0', '21', '2147483647', '2147483648', '-1', '1.5', '18446744073709551616')) {
        $valid = $maximum -in @('0', '21', '2147483647')
        $output = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'deploy-azure.ps1') `
            -SubscriptionId 00000000-0000-0000-0000-000000000000 -GitHubOrganization ExampleOrg -RunnerMaxCapacity $maximum 2>&1
        if (($LASTEXITCODE -eq 0) -ne $valid) { throw "PowerShell shorthand maximum validation mismatch for ${maximum}: $output" }
        if ($IsLinux) {
            $output = & bash (Join-Path $PSScriptRoot 'deploy-azure.sh') --dry-run `
                --subscription-id 00000000-0000-0000-0000-000000000000 --github-organization ExampleOrg --runner-max-capacity $maximum 2>&1
            if (($LASTEXITCODE -eq 0) -ne $valid) { throw "Bash shorthand maximum validation mismatch for ${maximum}: $output" }
        }
    }

    $example = Get-Content (Join-Path $PSScriptRoot '../runner-pools.example.json') -Raw | ConvertFrom-Json -NoEnumerate
    if ($example.Count -ne 14 -or @($example | Where-Object { $_.enabled -eq $false }).Count -ne 8) {
        throw 'Example must have eight Linux profiles and six disabled Windows profiles, with Linux small profiles also disabled'
    }
    if ($example[0].name -cne 'avp-linux') { throw 'The legacy avp-linux pool must remain first for compatibility values' }
    foreach ($profile in @(@('s', 'Standard_F1als_v7'), @('m', 'Standard_D2s_v5'), @('l', 'Standard_D4s_v5'), @('xl', 'Standard_D8s_v5'))) {
        foreach ($tier in @('P10', 'P20')) {
            $suffix = if ($tier -ceq 'P20') { 'p' } else { '' }
            $label = 'avp-linux-{0}{1}' -f $profile[0], $suffix
            $name = if ($label -ceq 'avp-linux-l') { 'avp-linux' } else { $label }
            $matching = @($example | Where-Object { $_.name -ceq $name -and $_.vmSize -ceq $profile[1] -and $_.osDiskTier -ceq $tier })
            if ($matching.Count -ne 1 -or ($matching[0].enabled -eq $false) -ne ($profile[0] -ceq 's')) { throw "Incorrect example profile: $label" }
            $expectedLabels = if ($name -ceq 'avp-linux') { @('avp-linux', $label) } else { @($label) }
            if (($matching[0].labels -join ',') -cne ($expectedLabels -join ',')) { throw "Incorrect example labels: $label" }
            foreach ($omittedField in @('maxRunners', 'imageId', 'id')) {
                if ($null -ne $matching[0].PSObject.Properties[$omittedField]) { throw "Example profile must omit ${omittedField}: $label" }
            }
            if ($profile[0] -cne 's' -and $null -ne $matching[0].PSObject.Properties['enabled']) { throw "Enabled example profile must use the default: $label" }
        }
    }
    if (@($example | Where-Object { $_.osType -ceq 'Windows' }).Count -ne 6 -or @($example | Where-Object { $_.labels -contains 'avp-windows-s' -or $_.labels -contains 'avp-windows-sp' }).Count -ne 0) {
        throw 'The Windows catalog supports only M/MP, L/LP, and XL/XLP'
    }
    foreach ($profile in @(@('m', 'Standard_D2s_v5'), @('l', 'Standard_D4s_v5'), @('xl', 'Standard_D8s_v5'))) {
        foreach ($premium in @($false, $true)) {
            $label = 'avp-windows-' + $profile[0] + $(if ($premium) { 'p' } else { '' })
            $tier = if ($premium) { 'P20' } else { 'P10' }
            $matching = @($example | Where-Object { $_.name -ceq $label -and $_.vmSize -ceq $profile[1] -and $_.osDiskTier -ceq $tier })
            if ($matching.Count -ne 1 -or $matching[0].enabled -ne $false -or $matching[0].osType -cne 'Windows' -or ($matching[0].labels -join ',') -cne $label) { throw "Incorrect Windows profile: $label" }
        }
    }
    Test-PoolDryRun -Name 'Windows requires a qualified image' -Pools @(@{ name = 'win'; vmSize = 'Standard_D4s_v5'; osType = 'Windows' }) -Valid $false
    Test-PoolDryRun -Name 'qualified Windows image' -Pools @(@{ name = 'win'; vmSize = 'Standard_D4s_v5'; osType = 'Windows'; imageId = '/qualified/windows' }) -Expected @('pool imageId override')
    Test-PoolDryRun -Name 'plaintext password rejected' -Pools @(@{ name = 'win'; vmSize = 'Standard_D4s_v5'; osType = 'Windows'; imageId = '/qualified/windows'; adminPassword = 'not-accepted' }) -Valid $false
    foreach ($os in @($null, 'windows', '', 1, $true)) {
        Test-PoolDryRun -Name 'invalid OS type' -Pools @(@{ name = 'invalid'; vmSize = 'Standard_D4s_v5'; osType = $os }) -Valid $false
    }
    Test-PoolDryRun -Name 'Linux and Windows example profiles' -Pools $example -Expected @('avp-linux-s: disabled', 'avp-linux-xlp: 0\.\.demand', 'avp-linux labels: avp-linux, avp-linux-l;', 'avp-linux-lp labels: avp-linux-lp;')
    Write-Output 'Shared-controller pool and disk-tier dry-run validation passed.'
}
finally {
    Remove-Item -LiteralPath $poolFile -ErrorAction SilentlyContinue
}
