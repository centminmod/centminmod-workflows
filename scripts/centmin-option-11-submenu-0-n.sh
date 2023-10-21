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
send -- "n\r"
expect "Enter option"
send -- "11\r"
expect "Enter option"
send -- "24\r"
after 30000
expect eof