#!/usr/bin/expect -f
set timeout -1
spawn /usr/local/src/centminmod/centmin.sh
expect "Enter option"
send -- "5\r"
expect "PHP Upgrade/Downgrade - Would you like to continue?"
send -- "y\r"
expect "Enter PHP Version number you want to upgrade/downgrade to"
send -- "8.1.33\r"
expect "Do you still want to continue?"
send -- "y\r"
expect "Do you want to use Zend OPcache"
send -- "\r"
expect "Enter option"
send -- "24\r"
after 60000
expect eof