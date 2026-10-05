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
variable "base_image_version" {
  type    = string
  default = "latest"
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
# Packer creates temporary credentials and a TLS WinRM listener restricted to
# the supplied /32. Its ephemeral self-signed certificate requires explicit
# operator approval before execution. Runtime runners expose neither WinRM nor RDP.
source "azure-arm" "windows_runner" {
  use_azure_cli_auth                 = true
  subscription_id                   = var.subscription_id
  location                          = var.location
  managed_image_resource_group_name = var.resource_group_name
  managed_image_name                = var.managed_image_name
  os_type                           = "Windows"
  image_publisher                   = "MicrosoftWindowsServer"
  image_offer                       = "WindowsServer"
  image_sku                         = "2025-datacenter"
  image_version                     = var.base_image_version
  vm_size                           = "Standard_D4s_v5"
  os_disk_size_gb                    = 128
  communicator                      = "winrm"
  winrm_username                    = "packer"
  winrm_use_ssl                     = true
  winrm_insecure                    = true
  winrm_timeout                     = "15m"
  allowed_inbound_ip_addresses       = [var.build_source_cidr]

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
  provisioner "powershell" {
    script     = "${path.root}/scripts/Complete-WindowsRunnerImage.ps1"
    skip_clean = true
  }
}
