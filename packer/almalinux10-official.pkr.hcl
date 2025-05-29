# packer/almalinux10.pkr.hcl
packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.2"
    }
  }
}

variable "iso_url" {
  type = string
}

variable "iso_checksum" {
  type = string
}

variable "headless" {
  type    = bool
  default = true
}

source "qemu" "almalinux10" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  
  output_directory = "build/almalinux10"
  vm_name         = "AlmaLinux-10-GenericCloud.x86_64.qcow2"
  
  # Adapted from AlmaLinux's config
  accelerator        = "tcg"  # Changed from kvm for GitHub Actions
  disk_interface     = "virtio-scsi"
  disk_size          = "10G"
  disk_cache         = "unsafe"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true
  format             = "qcow2"
  
  # Hardware config - reduced for TCG
  machine_type = "q35"
  memory       = 2048  # Reduced from their default
  cpus         = 1     # Reduced for TCG performance
  cpu_model    = "max" # Changed from "host" for TCG
  net_device   = "virtio-net"
  
  # HTTP server for kickstart
  http_directory = "packer/http"
  http_port_min  = 8000
  http_port_max  = 9000
  
  # Boot configuration - adapted from their boot_command
  boot_command = [
    "<wait5>",
    "<up>",
    "e",
    "<down><down><end>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux-10-gencloud.ks",
    "<leftCtrlOn>x<leftCtrlOff>"
  ]
  boot_wait = "10s"
  
  # SSH configuration
  ssh_username = "root"
  ssh_password = "almalinux"
  ssh_timeout  = "60m"
  ssh_pty      = true
  
  shutdown_command = "shutdown -P now"
  headless         = var.headless
  
  # QEMU args for debugging
  qemuargs = [
    ["-serial", "file:/tmp/serial.log"],
    ["-display", "none"],
    ["-device", "virtio-rng-pci,rng=rng0"],
    ["-object", "rng-random,id=rng0,filename=/dev/urandom"]
  ]
}

build {
  sources = ["source.qemu.almalinux10"]
  
  # Simple shell provisioner instead of Ansible
  provisioner "shell" {
    inline = [
      "# Install cloud-init and required packages",
      "dnf install -y cloud-init cloud-utils-growpart",
      
      "# Configure cloud-init",
      "systemctl enable cloud-init-local.service",
      "systemctl enable cloud-init.service",
      "systemctl enable cloud-config.service",
      "systemctl enable cloud-final.service",
      
      "# Clean up",
      "dnf clean all",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/systemd/random-seed",
      "rm -f /etc/ssh/ssh_host_*",
      "rm -f /etc/udev/rules.d/70-persistent-*",
      "rm -f /var/lib/dhclient/*",
      
      "# Ensure cloud-init will regenerate SSH keys",
      "rm -f /etc/ssh/sshd_config.d/01-permitrootlogin.conf"
    ]
  }
}