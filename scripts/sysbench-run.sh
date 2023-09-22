#!/bin/bash

mkdir -p /root/tools/sysbench
cd /root/tools/sysbench
wget -O /root/tools/sysbench/sysbench.sh https://github.com/centminmod/centminmod-sysbench/raw/master/sysbench.sh
chmod +x sysbench.sh
echo
./sysbench.sh install
echo
./sysbench.sh cpu
echo
./sysbench.sh mem
echo
./sysbench.sh file
echo
./sysbench.sh file-16k
echo
./sysbench.sh file-64k
echo
./sysbench.sh file-512k
echo
./sysbench.sh file-1m
echo
echo "SSL MariaDB MySQL sysbench test"
./sysbench.sh mysqloltpnew y local_username password database_name
echo
echo "non-SSL MariaDB MySQL sysbench test"
./sysbench.sh mysqloltpnew n localnossl_username password databasenossl_name