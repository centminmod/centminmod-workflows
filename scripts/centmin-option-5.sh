#!/usr/bin/expect -f
set timeout -1
spawn /usr/local/src/centminmod/centmin.sh
expect "Enter option"
send -- "5\r"
expect "PHP Upgrade/Downgrade - Would you like to continue?"
send -- "y\r"
expect "Enter PHP Version number you want to upgrade/downgrade to"
send -- "8.0.30\r"
expect "Do you still want to continue?"
send -- "y\r"
expect "Do you want to use Zend OPcache"
send -- "\r"
expect "Enter option"
send -- "24\r"
after 30000
expect eof