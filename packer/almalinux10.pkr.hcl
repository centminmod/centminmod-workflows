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

source "qemu" "almalinux10" {
  # Base ISO
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # VM sizing & acceleration
  disk_size   = "40960"  # MiB (≈40 GiB)
  memory      = "4096"   # MiB
  cpus        = 2
  accelerator = "tcg"

  # HTTP server for Kickstart (adjusted to where your ks.cfg actually lives)
  http_directory = "packer/http"
  http_port_min  = 8000
  http_port_max  = 9000

  # Boot loader & Kickstart
  boot_command = [
    "<esc><wait>",
    "linux inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux10-ks.cfg console=ttyS0,115200n8<enter>"
  ]
  boot_wait = "5s"
  format    = "qcow2"

  # Serial console, QEMU error logging, and host-forwarded SSH
  qemuargs = [
    ["-serial",  "mon:stdio"],
    ["-display", "none"],
    ["-d",       "guest_errors"],
    ["-D",       "qemu-errors.log"],
    ["-netdev",  "user,id=net0,hostfwd=tcp::{{ .SSHHostPort }}-:22"],
    ["-device",  "virtio-net-pci,netdev=net0"],
  ]

  # SSH communicator settings
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
