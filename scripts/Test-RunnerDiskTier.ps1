$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$poolFile = Join-Path ([IO.Path]::GetTempPath()) ("runner-tier-test-" + [Guid]::NewGuid().ToString('N') + '.json')
try {
    foreach ($tier in @('P10', 'P15', 'P20', 'P30', 'P99', 'p20')) {
        @(@{ name = 'test-pool'; vmSize = 'Standard_D4s_v5'; maxRunners = 1; osDiskTier = $tier }) |
            ConvertTo-Json -AsArray | Set-Content -LiteralPath $poolFile -Encoding utf8
        $output = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'deploy-azure.ps1') `
            -SubscriptionId 00000000-0000-0000-0000-000000000000 -GitHubOrganization ExampleOrg -RunnerPoolsFile $poolFile 2>&1
        $valid = $tier -cin @('P10', 'P15', 'P20', 'P30')
        if (($LASTEXITCODE -eq 0) -ne $valid) { throw "PowerShell tier validation mismatch for $tier" }
        if ($valid -and ($output -join "`n") -notmatch "OS disk tier: $tier") { throw 'Dry run omitted disk tier' }
        if ($IsLinux) {
            $output = & bash (Join-Path $PSScriptRoot 'deploy-azure.sh') --dry-run `
                --subscription-id 00000000-0000-0000-0000-000000000000 --github-organization ExampleOrg --runner-pools-file $poolFile 2>&1
            if (($LASTEXITCODE -eq 0) -ne $valid) { throw "Bash tier validation mismatch for $tier" }
            if ($valid -and ($output -join "`n") -notmatch "OS disk tier: $tier") { throw 'Bash dry run omitted disk tier' }
        }
    }
    Write-Output 'Per-pool tier dry-run validation passed.'
}
finally {
    Remove-Item -LiteralPath $poolFile -ErrorAction SilentlyContinue
}
