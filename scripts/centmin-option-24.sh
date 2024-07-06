#!/usr/bin/expect -f
set timeout -1

# Function to handle selecting option 24
proc select_option_24 {} {
    expect "Enter option"
    send -- "24\r"
}

# Start the centmin.sh script
spawn /usr/local/src/centminmod/centmin.sh

# Select option 24 the first time
select_option_24

# Wait for the menu to return
expect {
    "Enter option" { 
        # If the menu appears again, select option 24 again
        select_option_24
    }
    eof {
        # If the end of file is encountered, end the script
        exit
    }
}

# Wait for the end of file (EOF) from the spawned process
expect eof
