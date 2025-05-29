# Adapted from AlmaLinux's official kickstart for GitHub Actions
# Simplified partitioning and adapted for TCG

url --url https://repo.almalinux.org/almalinux/10/BaseOS/x86_64/os
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --disabled
services --enabled=sshd

# Simplified partitioning for faster install
zerombr
clearpart --all --initlabel
autopart --type=plain --nohome --noboot --noswap

# Network configuration
network --bootproto=dhcp --device=link --activate --onboot=on

# Root password for Packer SSH access
rootpw --plaintext almalinux

# Bootloader - simplified
bootloader --timeout=0 --location=mbr --append="console=tty0 console=ttyS0,115200n8 no_timer_check net.ifnames=0"

reboot --eject

%packages --exclude-weakdeps --inst-langs=en
@core
dracut-config-generic
grub2-pc
tar
NetworkManager
# Exclude firmware to save space and time
-*firmware
-dracut-config-rescue
-firewalld
-plymouth*
-*-firmware
%end

# Disable kdump service
%addon com_redhat_kdump --disable
%end

%post --erroronfail
# Allow root SSH login for Packer
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/01-permitrootlogin.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/01-permitrootlogin.conf

# Generate SSH host keys
/usr/bin/ssh-keygen -A

# Ensure network comes up
systemctl enable NetworkManager

# Add console to kernel args
grubby --update-kernel=ALL --args="console=ttyS0,115200n8"

# Log for debugging
echo "Kickstart post-install completed at $(date)" > /root/ks-post-complete.log
%end