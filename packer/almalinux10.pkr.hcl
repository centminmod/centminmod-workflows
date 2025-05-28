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
  type    = number
  default = 40960    # MiB (≈40 GiB)
}

variable "memory" {
  type    = number
  default = 4096     # MiB
}

variable "cpus" {
  type    = number
  default = 2
}

source "qemu" "almalinux10" {
  output_directory = "build/almalinux10"
  vm_name          = "almalinux10"

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  disk_size   = var.disk_size
  memory      = var.memory
  cpus        = var.cpus
  accelerator = "tcg"

  http_directory = "packer/http"
  http_port_min  = 8000
  http_port_max  = 9000

  boot_command = [
    "<esc><wait>",
    "linux inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux10-ks.cfg ",
    "inst.text console=ttyS0,115200n8<enter>"
  ]
  boot_wait = "10s"
  format    = "qcow2"

  # Headless mode (no GUI display)
  headless = true
  
  # VNC configuration (required for boot commands)
  vnc_bind_address = "127.0.0.1"
  vnc_port_min     = 5900
  vnc_port_max     = 6000

  # Use e1000 NIC + forward SSH to host:2222
  net_device     = "e1000"
  host_port_min  = 2222
  host_port_max  = 2222

  # Serial console & QEMU error logging
  qemuargs = [
    ["-serial", "file:serial.log"],
    ["-d",      "guest_errors"],
    ["-D",      "qemu-errors.log"],
  ]

  communicator = "ssh"
  ssh_username = "root"
  ssh_password = "changeme"
  ssh_timeout  = "15m"
  ssh_pty      = true
  
  # Keep VM running on disconnect
  shutdown_command = "shutdown -P now"
}

build {
  sources = ["source.qemu.almalinux10"]
  
  provisioner "shell" {
    inline = [
      "echo '=== VM up; post-install check ==='",
      "hostname",
      "date",
      "ip addr show"
    ]
  }
}