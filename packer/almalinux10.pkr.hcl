packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "isos/x86_64/AlmaLinux-10-latest-x86_64-minimal.iso"
}

variable "iso_checksum" {
  type    = string
  default = "auto"
}

variable "disk_size" {
  type    = string
  default = "40960"    # MiB (≈40 GiB)
}

variable "memory" {
  type    = string
  default = "4096"     # MiB
}

variable "cpus" {
  type    = number
  default = 2
}

source "qemu" "almalinux10" {
  # Where to drop the built QCOW2 and logs
  output_directory = "build/almalinux10"
  vm_name         = "almalinux10"
  
  # Base ISO
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  
  # VM sizing & acceleration
  disk_size   = var.disk_size
  memory      = var.memory
  cpus        = var.cpus
  accelerator = "tcg"
  
  # HTTP server for Kickstart
  http_directory = "packer/http"
  http_port_min  = 8000
  http_port_max  = 9000
  
  # Kernel cmdline: serial console, Kickstart, and early DHCP
  boot_command = [
    "<esc><wait>",
    "linux inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux10-ks.cfg console=ttyS0,115200n8 ip=dhcp<enter>"
  ]
  boot_wait = "10s"
  format    = "qcow2"
  
  # Serial-only + error logging + user-mode networking + host-forward + e1000 NIC
  qemuargs = [
    ["-serial",    "mon:stdio"],
    ["-nographic", ""],
    ["-d",         "guest_errors"],
    ["-D",         "qemu-errors.log"],
    ["-netdev",    "user,id=net0,hostfwd=tcp::{{ .SSHHostPort }}-:22"],
    ["-device",    "e1000,netdev=net0"],
  ]
  
  # SSH communicator
  communicator = "ssh"
  ssh_username = "root"
  ssh_password = "changeme"
  ssh_timeout  = "10m"
  ssh_pty      = true
}

build {
  sources = ["source.qemu.almalinux10"]
  
  provisioner "shell" {
    inline = [
      "echo '=== VM up; running post-install shell provisioner ==='",
      "hostname && date"
    ]
  }
}