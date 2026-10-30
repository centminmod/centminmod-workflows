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
# Back to Main menu is 11 on 132.00stable, 14 on 140.00beta01, 20 on 141.00beta01
expect -re {([0-9]+)\)\. Back to Main menu}
set backopt $expect_out(1,string)
expect "Enter option"
send -- "$backopt\r"
expect "Enter option"
send -- "24\r"
after 60000
expect eof