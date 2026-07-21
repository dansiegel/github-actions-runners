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

variable "runner_version" {
  type    = string
  default = "2.335.1"
}

variable "runner_sha256" {
  type    = string
  default = "4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf"
}

variable "aspire_cli_version" {
  type    = string
  default = "13.4.0"
}

source "azure-arm" "runner" {
  use_azure_cli_auth                 = true
  subscription_id                   = var.subscription_id
  location                          = var.location
  managed_image_resource_group_name = var.resource_group_name
  managed_image_name                = var.managed_image_name
  os_type                           = "Linux"
  image_publisher                   = "Canonical"
  image_offer                       = "ubuntu-24_04-lts"
  image_sku                         = "server"
  vm_size                           = var.build_vm_size

  azure_tags = {
    project      = "github-actions-runners"
    managed-by   = "packer"
    dotnet       = "10.0"
    node         = "24"
    runner       = var.runner_version
    image-purpose = "ephemeral-github-runner"
  }
}

build {
  name    = "avp-github-runner"
  sources = ["source.azure-arm.runner"]

  provisioner "shell" {
    script          = "${path.root}/scripts/install-runner-toolchain.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E env {{ .Vars }} {{ .Path }}"
    environment_vars = [
      "RUNNER_VERSION=${var.runner_version}",
      "RUNNER_SHA256=${var.runner_sha256}",
      "ASPIRE_CLI_VERSION=${var.aspire_cli_version}"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo /usr/sbin/waagent -force -deprovision",
      "sync"
    ]
  }
}
