#!/usr/bin/expect -f
set timeout -1
spawn /usr/local/src/centminmod/centmin.sh
expect "Enter option"
send -- "4\r"
expect "Nginx Upgrade - Would you like to continue?"
send -- "y\r"
expect "Install which version of Nginx"
send -- "1.27.0\r"
expect "Do you still want to continue?"
send -- "y\r"
expect "Enter option"
send -- "24\r"
after 30000
expect eof