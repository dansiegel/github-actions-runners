packer {
  required_version = ">= 1.15.4"
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "= 2.6.3"
    }
  }
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "resource_group_name" {
  type = string
}

variable "managed_image_name" {
  type = string
}

variable "build_vm_size" {
  type    = string
  default = "Standard_D4s_v5"
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
  default = "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"
}

variable "aspire_cli_version" {
  type    = string
  default = "13.4.6"
}

source "azure-arm" "runner" {
  use_azure_cli_auth                = true
  subscription_id                   = var.subscription_id
  location                          = var.location
  managed_image_resource_group_name = var.resource_group_name
  managed_image_name                = var.managed_image_name
  os_type                           = "Linux"
  image_publisher                   = "Canonical"
  image_offer                       = "ubuntu-24_04-lts"
  image_sku                         = "server"
  image_version                     = var.base_image_version
  vm_size                           = var.build_vm_size

  azure_tags = {
    project       = "github-actions-runners"
    managed-by    = "packer"
    dotnet        = "10.0"
    node          = "24"
    runner        = var.runner_version
    image-purpose = "ephemeral-github-runner"
  }
}

build {
  name    = "github-runner-image"
  sources = ["source.azure-arm.runner"]

  provisioner "file" {
    source      = "${path.root}/scripts/runner-maintenance-policy.sh"
    destination = "/tmp/runner-maintenance-policy"
  }

  provisioner "shell" {
    inline = ["sudo install -m 0755 /tmp/runner-maintenance-policy /usr/local/sbin/runner-maintenance-policy"]
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/install-runner-toolchain.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E env {{ .Vars }} {{ .Path }}"
    environment_vars = [
      "RUNNER_VERSION=${var.runner_version}",
      "RUNNER_SHA256=${var.runner_sha256}",
      "ASPIRE_CLI_VERSION=${var.aspire_cli_version}",
      "BASE_IMAGE_VERSION=${var.base_image_version}"
    ]
  }

  provisioner "shell" {
    inline            = ["sudo reboot"]
    expect_disconnect = true
    pause_after       = "30s"
  }

  provisioner "shell" {
    script              = "${path.root}/scripts/verify-runner-image.sh"
    execute_command     = "chmod +x {{ .Path }}; sudo -E env {{ .Vars }} {{ .Path }}"
    start_retry_timeout = "10m"
  }

  provisioner "shell" {
    inline = [
      "sudo /usr/sbin/waagent -force -deprovision",
      "sync"
    ]
  }
}
