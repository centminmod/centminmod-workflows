FROM almalinux/8-init

ENV TERM=xterm-256color
ENV container=docker

RUN dnf -y update && \
    dnf install -y \
        initscripts \
        systemd-sysv \
        curl \
        python3 \
        iptables   \
        iproute    \
        kmod       \
        procps-ng  \
        sudo       \
        udev &&    \
    # Unmask services
    systemctl unmask                                                  \
        systemd-remount-fs.service                                    \
        dev-hugepages.mount                                           \
        sys-fs-fuse-connections.mount                                 \
        systemd-logind.service                                        \
        getty.target                                                  \
        console-getty.service &&                                      \
    # Prevents journald from reading kernel messages from /dev/kmsg
    echo "ReadKMsg=no" >> /etc/systemd/journald.conf &&               \
                                                                      \
    # Housekeeping
    dnf clean all &&                                                  \
    rm -rf                                                            \
       /var/cache/dnf/*                                               \
       /var/log/*                                                     \
       /tmp/*                                                         \
       /var/tmp/*                                                     \
       /usr/share/doc/*                                               \
       /usr/share/man/*

RUN systemctl mask systemd-journald-audit.socket systemd-udev-trigger.service systemd-firstboot.service systemd-networkd-wait-online.service

VOLUME [ "/sys/fs/cgroup", "/run" ]
CMD ["/sbin/init"]
