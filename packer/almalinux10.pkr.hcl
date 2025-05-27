packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "URL or path to the AlmaLinux 10 minimal ISO"
}

variable "iso_checksum" {
  type        = string
  description = "SHA256 checksum for the ISO"
}

source "qemu" "almalinux10" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum

  output_directory = "build/almalinux10"
  format           = "qcow2"
  disk_size        = 40960       # 40 GB disk
  memory           = 4096        # 4 GB RAM for build VM
  cpus             = 2           # 2 vCPUs
  accelerator      = "auto"     # auto-select KVM or TCG for hosted runners
  headless         = true

  http_directory   = "packer/http"
  boot_wait        = "5s"
  boot_command     = [
    "<tab><wait>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux10-ks.cfg",
    " inst.sshd",
    "<enter><wait>"
  ]

  communicator     = "ssh"
  ssh_username     = "root"
  ssh_password     = "changeme"
  ssh_timeout      = "20m"

  shutdown_command = "echo 'changeme' | sudo -S shutdown -P now"
}

build {
  sources = ["source.qemu.almalinux10"]

  provisioner "shell" {
    inline = [
      "echo 'Packer build complete.'"
    ]
  }
}
