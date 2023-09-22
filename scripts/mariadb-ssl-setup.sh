#!/bin/bash

# Script for setting up MariaDB with SSL
# Usage: ./mariadb-ssl-setup.sh ecdsa REMOTEIP

# SSL Method: either 'rsa' or 'ecdsa'
SSL_CERT_METHOD="$1"
REMOTEIP="$2"

# Check if the SSL_CERT_METHOD is provided and valid
if [[ -z "$SSL_CERT_METHOD" || ! "$SSL_CERT_METHOD" =~ ^(rsa|ecdsa)$ ]]; then
    echo "Usage: $0 [rsa|ecdsa]"
    exit 1
fi

# Create necessary directories
mkdir -p /etc/mysql/ssl /usr/local/nginx/conf/ssl-mariadb

# Change to the SSL directory
cd /etc/mysql/ssl

echo "Generate SSL Certificates"
# Generate SSL Certificates based on method
# Generate certificates and keys
if [ "$SSL_CERT_METHOD" == "rsa" ]; then
    # Generate CA key
    openssl genpkey -algorithm RSA -out ca-key.pem
    # Generate CA certificate
    openssl req -new -x509 -key ca-key.pem -out ca-cert.pem -subj "/C=US/ST=State/L=Location/O=Organization/OU=Unit/CN=CA" -nodes
    # Generate Server key
    openssl genpkey -algorithm RSA -out server-key.pem
    # Generate Server certificate request
    openssl req -new -key server-key.pem -out server-csr.pem -subj "/C=US/ST=State/L=Location/O=Organization/OU=Unit/CN=server" -nodes
    # Generate Server certificate using the CA
    openssl x509 -req -in server-csr.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem
else
    # Generate CA key
    openssl ecparam -genkey -name prime256v1 -out ca-key.pem
    # Generate CA certificate
    openssl req -new -x509 -key ca-key.pem -out ca-cert.pem -subj "/C=US/ST=State/L=Location/O=Organization/OU=Unit/CN=CA" -nodes
    # Generate Server key
    openssl ecparam -genkey -name prime256v1 -out server-key.pem
    # Generate Server certificate request
    openssl req -new -key server-key.pem -out server-csr.pem -subj "/C=US/ST=State/L=Location/O=Organization/OU=Unit/CN=server" -nodes
    # Generate Server certificate using the CA
    openssl x509 -req -in server-csr.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem
fi
chmod 600 *.pem
chown -Rv mysql:root /etc/mysql/ssl/
\cp -af /etc/mysql/ssl/* /usr/local/nginx/conf/ssl-mariadb
chown -Rv nginx:nginx /usr/local/nginx/conf/ssl-mariadb

mkdir -p /home/sysbench/mysql
cp /etc/mysql/ssl/server-key.pem /home/sysbench/mysql/client-key.pem
cp /etc/mysql/ssl/server-cert.pem /home/sysbench/mysql/client-cert.pem
cp /etc/mysql/ssl/ca-cert.pem /home/sysbench/mysql/cacert.pem
chmod 644 /home/sysbench/mysql/*.pem

echo
echo "Verify SSL Certificates"
openssl x509 -in server-cert.pem -text -noout

# Backup /etc/my.cnf
\cp -a /etc/my.cnf /etc/my.cnf.backup-b4-ssl-setup

# Output example MariaDB server and client configuration
echo
echo "Add the following lines to your MariaDB server's /etc/my.cnf file under [mysqld] section:"
echo "ssl-key = /etc/mysql/ssl/server-key.pem"
echo "ssl-cert = /etc/mysql/ssl/server-cert.pem"
echo "ssl-ca = /etc/mysql/ssl/ca-cert.pem"
# echo "tls_version = TLSv1.2,TLSv1.3"

# insert into /etc/my.cnf
# sed -i '/\[mysqld\]/a ssl-key = \/etc\/mysql\/ssl\/server-key.pem\nssl-cert = \/etc\/mysql\/ssl\/server-cert.pem\nssl-ca = \/etc\/mysql\/ssl\/ca-cert.pem\ntls_version = TLSv1.2,TLSv1.3' /etc/my.cnf
sed -i '/\[mysqld\]/a ssl-key = \/etc\/mysql\/ssl\/server-key.pem\nssl-cert = \/etc\/mysql\/ssl\/server-cert.pem\nssl-ca = \/etc\/mysql\/ssl\/ca-cert.pem' /etc/my.cnf

echo
echo "Restart MariaDB MySQL server"
systemctl restart mariadb
echo
journalctl -u mariadb --no-pager
echo
systemctl status mariadb --no-pager

echo
echo "Check SSL setup in /etc/my.cnf"
egrep 'ssl|tls' /etc/my.cnf
mysqladmin var | egrep 'tls|ssl' | tr -s ' '

echo
echo "Add the following lines to your MariaDB client's /etc/my.cnf file under [mysql] section:"
echo "ssl-key = /etc/mysql/ssl/server-key.pem"
echo "ssl-cert = /etc/mysql/ssl/server-cert.pem"
echo "ssl-ca = /etc/mysql/ssl/ca-cert.pem"
sed -i '/\[mysql\]/a ssl-key = \/etc\/mysql\/ssl\/server-key.pem\nssl-cert = \/etc\/mysql\/ssl\/server-cert.pem\nssl-ca = \/etc\/mysql\/ssl\/ca-cert.pem' /etc/my.cnf

echo
echo "Add the following lines to your MariaDB client's /etc/my.cnf file under [client] section:"
echo "ssl-key = /etc/mysql/ssl/server-key.pem"
echo "ssl-cert = /etc/mysql/ssl/server-cert.pem"
echo "ssl-ca = /etc/mysql/ssl/ca-cert.pem"
sed -i '/\[client\]/a ssl-key = \/etc\/mysql\/ssl\/server-key.pem\nssl-cert = \/etc\/mysql\/ssl\/server-cert.pem\nssl-ca = \/etc\/mysql\/ssl\/ca-cert.pem' /etc/my.cnf

# Output example CSF Firewall setup
echo
echo "Add the following line to your /etc/csf/csf.allow for allowing MySQL port 3306:"
echo "tcp|in|d=3306|s=$REMOTEIP"

# MySQL grants for remote user
echo
echo "Run the following SQL commands to grant remote access to your MariaDB:"
echo "GRANT ALL PRIVILEGES ON database_name.* TO 'remote_username'@'remote_ip' IDENTIFIED BY 'password' REQUIRE SSL;"
echo "GRANT ALL PRIVILEGES ON database_name.* TO 'local_username'@'127.0.0.1' IDENTIFIED BY 'password' REQUIRE SSL;"
echo "FLUSH PRIVILEGES;"
echo
if [ -f /usr/local/src/centminmod/addons/mysqladmin_shell.sh ]; then
    echo "/usr/local/src/centminmod/addons/mysqladmin_shell.sh createuserdb database_name local_username password"
    /usr/local/src/centminmod/addons/mysqladmin_shell.sh createuserdb database_name local_username password
    echo "/usr/local/src/centminmod/addons/mysqladmin_shell.sh createuserdb databasenossl_name localnossl_username password"
    /usr/local/src/centminmod/addons/mysqladmin_shell.sh createuserdb databasenossl_name localnossl_username password
fi
mysql -e "GRANT ALL PRIVILEGES ON database_name.* TO 'local_username'@'127.0.0.1' IDENTIFIED BY 'password' REQUIRE SSL; FLUSH PRIVILEGES;"
echo

# Generate PHP MySQL SSL test script
cat <<EOL > /etc/mysql/ssl/mysql_ssl_test.php
<?php
\$host = '127.0.0.1';

// SSL connection variables
\$ssl_username = 'local_username';
\$ssl_password = 'password';
\$ssl_dbname = 'database_name';

// Non-SSL connection variables
\$nossl_username = 'localnossl_username';
\$nossl_password = 'password';
\$nossl_dbname = 'databasenossl_name';

// Initialize MySQLi object for SSL and non-SSL
\$mysqli_ssl = mysqli_init();
\$mysqli_nossl = mysqli_init();

// Set SSL options for MySQLi
mysqli_ssl_set(\$mysqli_ssl, '/usr/local/nginx/conf/ssl-mariadb/server-key.pem', '/usr/local/nginx/conf/ssl-mariadb/server-cert.pem', '/usr/local/nginx/conf/ssl-mariadb/ca-cert.pem', NULL, NULL);

// Connect to MySQL database using SSL, without verifying the server certificate
if (!mysqli_real_connect(\$mysqli_ssl, \$host, \$ssl_username, \$ssl_password, \$ssl_dbname, 3306, NULL, MYSQLI_CLIENT_SSL_DONT_VERIFY_SERVER_CERT)) {
    echo 'Failed to connect using SSL: ' . mysqli_connect_error() . PHP_EOL;
} else {
    echo 'Successfully connected using SSL!' . PHP_EOL;
    mysqli_close(\$mysqli_ssl);
}

// Connect to MySQL database without using SSL
if (!mysqli_real_connect(\$mysqli_nossl, \$host, \$nossl_username, \$nossl_password, \$nossl_dbname, 3306)) {
    echo 'Failed to connect without SSL: ' . mysqli_connect_error() . PHP_EOL;
} else {
    echo 'Successfully connected without using SSL!' . PHP_EOL;
    mysqli_close(\$mysqli_nossl);
}
?>
EOL

chown nginx:nginx /etc/mysql/ssl/mysql_ssl_test.php

echo "PHP MySQL SSL test script has been generated at /etc/mysql/ssl/mysql_ssl_test.php"
echo
echo "Test /etc/mysql/ssl/mysql_ssl_test.php"
echo "/usr/local/bin/php /etc/mysql/ssl/mysql_ssl_test.php"
/usr/local/bin/php /etc/mysql/ssl/mysql_ssl_test.php

