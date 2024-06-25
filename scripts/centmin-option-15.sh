#!/usr/bin/expect -f
set timeout -1
spawn /usr/local/src/centminmod/centmin.sh
expect "Enter option"
send -- "15\r"
expect "Enter option"
send -- "24\r"
after 30000
expect eof