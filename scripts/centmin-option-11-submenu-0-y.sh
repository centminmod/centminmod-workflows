#!/usr/bin/expect -f
set timeout -1
spawn /usr/local/src/centminmod/centmin.sh
expect "Enter option"
send -- "11\r"
expect "Enter option"
send -- "0\r"
expect "Do you want to continue?"
send -- "y\r"
expect "Do you know the existing MySQL root password set in /root/.my.cnf?"
send -- "y\r"
expect "Enter option"
send -- "14\r"
expect "Enter option"
send -- "24\r"
after 60000
expect eof