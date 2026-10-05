# Runs once through Azure's Custom Script extension, before Packer connects.
# Contains no credentials; the TLS private key is generated inside this VM.
[CmdletBinding()]
param([string] $BuildSourceCidr)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-WindowsBuildRemoting {
    param([Parameter(Mandatory)][string] $SourceCidr)
    $address = $null
    $literal = $SourceCidr -replace '/32$', ''
    if ($SourceCidr -cnotmatch '^\d+\.\d+\.\d+\.\d+/32$' -or
        -not [Net.IPAddress]::TryParse($literal, [ref] $address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $address.ToString() -cne $literal -or $literal -eq '0.0.0.0') {
        throw 'Build remoting requires the approved single IPv4 /32'
    }

    Set-Service WinRM -StartupType Automatic
    Start-Service WinRM
    # Configure WinRS directly. Enable-PSRemoting would also enable HTTP ingress.
    Get-ChildItem WSMan:\localhost\Listener | Remove-Item -Recurse -Force
    Get-NetFirewallRule -Name 'WINRM*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule | Out-Null
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
    Set-Item WSMan:\localhost\Service\Auth\Negotiate -Value $true
    Set-Item WSMan:\localhost\Shell\AllowRemoteShellAccess -Value $true
    # Packer's temporary local administrator needs an unfiltered remote token.
    # The final image step resets this setting before capture.
    New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null

    Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'GitHubRunnerPackerWinRM' } | Remove-Item -DeleteKey -Force
    $certificate = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -FriendlyName 'GitHubRunnerPackerWinRM' -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(4)
    New-Item WSMan:\localhost\Listener -Transport HTTPS -Address '*' -CertificateThumbPrint $certificate.Thumbprint -Force | Out-Null
    Get-NetFirewallRule -Name 'WINRM-Packer-Build' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name 'WINRM-Packer-Build' -DisplayName 'Packer build WinRM HTTPS' -Enabled True -Profile Any -Action Allow -Direction Inbound -LocalPort 5986 -Protocol TCP -RemoteAddress $SourceCidr | Out-Null
}

if ($MyInvocation.InvocationName -ne '.') {
    Initialize-WindowsBuildRemoting -SourceCidr $BuildSourceCidr
}
