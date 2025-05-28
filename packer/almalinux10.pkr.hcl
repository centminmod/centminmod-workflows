packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.2"
    }
  }
}

# ───── Variables ─────
variable "iso_url" {
  type = string
}

variable "iso_checksum" {
  type = string   # bare 64-char SHA-256 digest
}

variable "disk_size" {
  type    = number
  default = 20480   # MiB
}

variable "memory" {
  type    = number
  default = 4096    # MiB
}

variable "cpus" {
  type    = number
  default = 2
}

# ───── QEMU builder ─────
source "qemu" "almalinux10" {
  iso_url           = var.iso_url
  iso_checksum_type = "sha256"
  iso_checksum      = var.iso_checksum

  output_directory  = "build/almalinux10"
  vm_name           = "almalinux10"

  disk_size   = var.disk_size
  memory      = var.memory
  cpus        = var.cpus
  accelerator = "tcg"

  http_directory = "packer/http"
  http_port_min  = 8000
  http_port_max  = 9000

  boot_command = [
    "<tab><wait>",
    " inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux10-ks.cfg",
    " ip=dhcp console=ttyS0,115200n8<enter>"
  ]
  boot_wait = "10s"
  format    = "qcow2"

  headless          = true
  vnc_bind_address  = "127.0.0.1"
  vnc_port_min      = 5900
  vnc_port_max      = 6000

  disk_interface = "virtio"
  net_device     = "virtio-net"
  host_port_min  = 2222
  host_port_max  = 2222

  qemuargs = [
    ["-serial", "file:serial.log"],
    ["-d",      "guest_errors,cpu_reset"],
    ["-D",      "qemu-errors.log"]
  ]

  communicator = "ssh"
  ssh_username = "root"
  ssh_password = "changeme"
  ssh_timeout  = "15m"
  ssh_pty      = true

  shutdown_command = "shutdown -P now"
}

# ───── Simple smoke test ─────
build {
  sources = ["source.qemu.almalinux10"]

  provisioner "shell" {
    inline = [
      "echo '=== VM up; post-install check ==='",
      "hostname",
      "date",
      "cat /root/install-complete.txt"
    ]
  }
}
