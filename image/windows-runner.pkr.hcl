packer {
  required_version = ">= 1.15.4"
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "= 2.6.3"
    }
  }
}

variable "subscription_id" { type = string }
variable "resource_group_name" { type = string }
variable "managed_image_name" { type = string }
variable "location" {
  type    = string
  default = "eastus2"
}
variable "build_source_cidr" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/32$", var.build_source_cidr)) && var.build_source_cidr != "0.0.0.0/32"
    error_message = "Supply the approved image builder's single public IPv4 /32; broad ingress is not accepted."
  }
}
variable "allow_unverified_winrm_certificate" {
  type    = bool
  default = false
  validation {
    condition     = var.allow_unverified_winrm_certificate
    error_message = "This builder uses an ephemeral self-signed WinRM certificate. Explicitly approve that temporary certificate-validation exception before setting allow_unverified_winrm_certificate=true."
  }
}
variable "base_image_version" {
  type    = string
  default = "26100.33438.260905"
}
variable "allow_temporary_batch_logon_assignment" {
  type    = bool
  default = false
  validation {
    condition     = var.allow_temporary_batch_logon_assignment
    error_message = "Approve Task Scheduler's possible explicit batch-logon assignment for the existing build administrator and restoration of the exact baseline before setting allow_temporary_batch_logon_assignment=true."
  }
}
variable "build_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
  validation {
    condition     = contains(["Standard_D2s_v5", "Standard_D4s_v5"], var.build_vm_size)
    error_message = "Use a D2s_v5 or D4s_v5 image builder; this does not change runtime profile hardware."
  }
}
variable "runner_version" {
  type    = string
  default = "2.337.0"
}
variable "runner_sha256" {
  type    = string
  default = "1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc"
}

# This separate, operator-approved image build is never invoked by deploy-azure.
# The guest creates its own temporary TLS key; no build Key Vault is created.
# Packer's temporary credential and the supplied /32 are operator-approved.
# Runtime runners expose neither WinRM nor RDP.
source "azure-arm" "windows_runner" {
  use_azure_cli_auth                 = true
  subscription_id                    = var.subscription_id
  location                           = var.location
  managed_image_resource_group_name  = var.resource_group_name
  managed_image_name                 = var.managed_image_name
  managed_image_storage_account_type = "Premium_LRS"
  os_type                            = "Windows"
  image_publisher                    = "MicrosoftWindowsServer"
  image_offer                        = "WindowsServer"
  image_sku                          = "2025-datacenter-g2"
  image_version                      = var.base_image_version
  vm_size                            = var.build_vm_size
  os_disk_size_gb                    = 128
  communicator                       = "winrm"
  skip_create_build_key_vault        = true
  # Only public bootstrap code and the approved source CIDR enter this command.
  # No password, private key, user data, or external script download is involved.
  custom_script                = "powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64encode(file("${path.root}/scripts/Initialize-WindowsRunnerImage.ps1"))}')))) -BuildSourceCidr '${var.build_source_cidr}'\""
  winrm_username               = "packer"
  winrm_use_ssl                = true
  winrm_use_ntlm               = true
  winrm_insecure               = var.allow_unverified_winrm_certificate
  winrm_timeout                = "15m"
  allowed_inbound_ip_addresses = [var.build_source_cidr]

  azure_tags = {
    project       = "github-actions-runners"
    managed-by    = "packer"
    os            = "Windows"
    dotnet        = "10.0"
    node          = "24"
    runner        = var.runner_version
    image-purpose = "ephemeral-github-runner"
  }
}

build {
  name    = "github-windows-runner-image"
  sources = ["source.azure-arm.windows_runner"]

  provisioner "file" {
    source      = "${path.root}/scripts/Start-WindowsRunner.ps1"
    destination = "C:/Windows/Temp/Start-WindowsRunner.ps1"
  }
  provisioner "powershell" {
    script = "${path.root}/scripts/Install-WindowsRunner.ps1"
    environment_vars = [
      "RUNNER_VERSION=${var.runner_version}",
      "RUNNER_SHA256=${var.runner_sha256}",
      "BASE_IMAGE_VERSION=${var.base_image_version}"
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "15m"
  }
  provisioner "file" {
    source      = "${path.root}/scripts/Complete-WindowsRunnerImage.ps1"
    destination = "C:/Windows/Temp/Complete-WindowsRunnerImage.ps1"
  }
  provisioner "powershell" {
    inline = [
      "& 'C:\\Windows\\Temp\\Complete-WindowsRunnerImage.ps1' -RegisterTask -AllowTemporaryBatchLogonAssignment:${var.allow_temporary_batch_logon_assignment ? "$true" : "$false"} -AttemptId '${build.PackerRunUUID}' -ExpectedScriptSHA256 '${sha256(file("${path.root}/scripts/Complete-WindowsRunnerImage.ps1"))}'"
    ]
  }
  # Generalization retires WinRM itself. Observe completion through the existing
  # VM agent and operator Azure login, without another WinRM authentication.
  provisioner "shell-local" {
    script      = "${path.root}/scripts/Invoke-WindowsImageFinalization.ps1"
    max_retries = 0
    timeout     = "25m"
    execute_command = [
      "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "{{.Script}}",
      "-SubscriptionId", var.subscription_id,
      "-ResourceGroupName", build.TempResourceGroupName,
      "-VmName", build.TempComputeName,
      "-Location", var.location,
      "-FinalizerSHA256", sha256(file("${path.root}/scripts/Complete-WindowsRunnerImage.ps1")),
      "-AttemptId", build.PackerRunUUID
    ]
  }
}
