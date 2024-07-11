#!/bin/bash
OS=$(awk -F ':' '/PLATFORM_ID/ {print $2}' /etc/os-release | sed -e 's|"||g')
yum -y install https://mirror.ghettoforge.org/distributions/gf/gf-release-latest.gf.${OS}.noarch.rpm
yum-config-manager --disable gf gf-plus
\cp -af /etc/postfix /etc/postfix-backup-$(date +%Y%m%d%H%M%S)

# Create a yum shell script
cat <<EOF > /tmp/yum-postfix-update.txt
remove postfix postfix-perl-scripts
install postfix3 postfix3-utils
run
EOF

# Run the yum shell script
yum shell -y /tmp/yum-postfix-update.txt --enablerepo=gf-plus

# Clean up
rm -f /tmp/yum-postfix-update.txt

# Adjustments
postconf compatibility_level=3.9
mkdir -p /usr/lib64
if [ ! -d /usr/lib64/postfix ]; then
    ln -s /usr/lib/postfix /usr/lib64/postfix
fi

if grep -q "^exclude=" /etc/yum.conf; then
    sed -i '/^exclude=/ s/$/ postfix*/' /etc/yum.conf
else
    echo "exclude=postfix*" >> /etc/yum.conf
fi

#yum versionlock postfix postfix-perl-scripts postfix3 postfix3-utils
yum versionlock postfix postfix-perl-scripts postfix* postfix3*

yum -y install perl-Bit-Vector perl-Carp-Clan perl-Date-Calc
echo
postfixlog
echo

systemctl daemon-reload
systemctl restart postfix
echo
systemctl status postfix --no-pager
echo
journalctl -u postfix --no-pager | tail -20
echo
postconf mail_version