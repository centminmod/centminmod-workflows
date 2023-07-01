FROM almalinux/8-init

ENV TERM=xterm-256color
ENV container=docker

RUN dnf -y update && \
    dnf -y install initscripts systemd-sysv sudo curl python3 && \
    dnf clean all

VOLUME [ "/sys/fs/cgroup", "/run" ]
CMD ["/usr/sbin/init"]
