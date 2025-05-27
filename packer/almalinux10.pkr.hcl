// Packer template for AlmaLinux 10 Generic Cloud QCOW2

// Variables
variable "iso_url" {
  type        = string
  description = "URL to AlmaLinux 10 minimal ISO"
}

variable "iso_checksum" {
  type        = string
  description = "SHA256 checksum of the ISO"
}

// QEMU builder definition
target "source.qemu.almalinux10" {
  type               = "qemu"
  iso_url            = var.iso_url
  iso_checksum       = var.iso_checksum
  iso_checksum_type  = "sha256"
  output_directory   = "build/almalinux10"
  format             = "qcow2"
  accelerator        = "kvm"
  headless           = true

  disk_size          = 40960      // 40 GB
  memory             = 4096       // 4 GB for build VM
  cpus               = 2          // 2 vCPUs

  communicator       = "ssh"
  ssh_username       = "almalinux"
  ssh_timeout        = "10m"
  shutdown_command   = "shutdown -P now"

  // Serve Kickstart from local HTTP
  http_directory     = "http"
  boot_command       = [
    "inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/almalinux10-ks.cfg inst.ks_delay=5<enter>"
  ]
  boot_wait          = "10s"
}

// Build block
build {
  name    = "almalinux10-qcow2"
  sources = ["source.qemu.almalinux10"]
  // No additional provisioning; Kickstart handles package installation
}
