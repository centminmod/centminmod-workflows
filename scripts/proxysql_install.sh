#!/bin/bash

# ProxySQL Source Installation Script for AlmaLinux 10
# Version: 1.0
# Purpose: Compile and install ProxySQL from source (no official EL10 packages yet)
# Usage: ./proxysql_install.sh

set -e  # Exit on error

# Configuration Variables
PROXYSQL_VERSION="3.0.2"
PROXYSQL_GIT_REPO="https://github.com/sysown/proxysql.git"
PROXYSQL_BUILD_DIR="/tmp/proxysql"
PROXYSQL_USER="proxysql"
PROXYSQL_GROUP="proxysql"
PROXYSQL_DATA_DIR="/var/lib/proxysql"
PROXYSQL_CONFIG_FILE="/etc/proxysql.cnf"
PROXYSQL_LOG_DIR="/var/log/proxysql"
INSTALL_LOG="/root/centminlogs/proxysql-install-$(date +%Y%m%d-%H%M%S).log"

# Color Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging Function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$INSTALL_LOG"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$INSTALL_LOG"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$INSTALL_LOG"
}

# Create log directory
mkdir -p /root/centminlogs

log "==============================================="
log "ProxySQL Source Installation for AlmaLinux 10"
log "Version: $PROXYSQL_VERSION"
log "==============================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

# Detect OS version
if [ -f /etc/almalinux-release ]; then
    OS_VERSION=$(awk '{print $3}' /etc/almalinux-release | cut -d'.' -f1)
    log "Detected AlmaLinux $OS_VERSION"
else
    error "This script is designed for AlmaLinux. OS not recognized."
fi

# Step 1: Install Build Dependencies
log "Step 1/10: Installing build dependencies..."

dnf install -y \
    automake \
    bzip2 \
    cmake \
    make \
    gcc-c++ \
    gcc \
    git \
    openssl \
    openssl-devel \
    gnutls \
    gnutls-devel \
    libtool \
    patch \
    libuuid-devel \
    python3 \
    python3-pip 2>&1 | tee -a "$INSTALL_LOG"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log "✓ Build dependencies installed successfully"
else
    error "Failed to install build dependencies"
fi

# Step 2: Download ProxySQL Source Code
log "Step 2/10: Downloading ProxySQL v$PROXYSQL_VERSION source code..."

# Clean up any existing build directory
if [ -d "$PROXYSQL_BUILD_DIR" ]; then
    warn "Removing existing build directory: $PROXYSQL_BUILD_DIR"
    rm -rf "$PROXYSQL_BUILD_DIR"
fi

git clone --branch "v$PROXYSQL_VERSION" "$PROXYSQL_GIT_REPO" "$PROXYSQL_BUILD_DIR" 2>&1 | tee -a "$INSTALL_LOG"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log "✓ ProxySQL source code downloaded successfully"
else
    error "Failed to download ProxySQL source code"
fi

cd "$PROXYSQL_BUILD_DIR" || error "Failed to change to build directory"

# Fix execute permissions on dependency configure scripts
log "Fixing execute permissions on dependency configure scripts..."
chmod +x deps/libdaemon/libdaemon/configure 2>/dev/null || true
chmod +x deps/libconfig/libconfig/configure 2>/dev/null || true
chmod +x deps/jemalloc/jemalloc/configure 2>/dev/null || true
log "✓ Configure script permissions fixed"

# Step 3: Compile ProxySQL
log "Step 3/10: Compiling ProxySQL (this may take 2-3 minutes)..."

CPU_CORES=$(nproc)
log "Using $CPU_CORES CPU cores for compilation"

# Disable problematic GCC warnings
export CFLAGS="-Wno-maybe-uninitialized -Wno-declaration-after-statement"
export CXXFLAGS="-Wno-maybe-uninitialized -Wno-declaration-after-statement"

make -j"$CPU_CORES" 2>&1 | tee -a "$INSTALL_LOG"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log "✓ ProxySQL compiled successfully"
else
    error "Failed to compile ProxySQL"
fi

# Step 4: Install ProxySQL Binaries
log "Step 4/10: Installing ProxySQL binaries..."

make install 2>&1 | tee -a "$INSTALL_LOG"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log "✓ ProxySQL binaries installed successfully"
else
    error "Failed to install ProxySQL binaries"
fi

# Step 5: Create ProxySQL User and Group
log "Step 5/10: Creating ProxySQL user and group..."

if ! getent group "$PROXYSQL_GROUP" >/dev/null 2>&1; then
    groupadd -r "$PROXYSQL_GROUP"
    log "✓ Created group: $PROXYSQL_GROUP"
else
    warn "Group $PROXYSQL_GROUP already exists"
fi

if ! getent passwd "$PROXYSQL_USER" >/dev/null 2>&1; then
    useradd -r -g "$PROXYSQL_GROUP" -s /sbin/nologin -c "ProxySQL Server" "$PROXYSQL_USER"
    log "✓ Created user: $PROXYSQL_USER"
else
    warn "User $PROXYSQL_USER already exists"
fi

# Step 6: Create Directories and Set Permissions
log "Step 6/10: Creating directories and setting permissions..."

mkdir -p "$PROXYSQL_DATA_DIR"
mkdir -p "$PROXYSQL_LOG_DIR"

chown -R "$PROXYSQL_USER:$PROXYSQL_GROUP" "$PROXYSQL_DATA_DIR"
chown -R "$PROXYSQL_USER:$PROXYSQL_GROUP" "$PROXYSQL_LOG_DIR"

chmod 750 "$PROXYSQL_DATA_DIR"
chmod 750 "$PROXYSQL_LOG_DIR"

log "✓ Directories created and permissions set"

# Step 7: Create ProxySQL Configuration File
log "Step 7/10: Creating ProxySQL configuration file..."

cat > "$PROXYSQL_CONFIG_FILE" <<'EOF'
# ProxySQL Configuration File
# Generated by proxysql_install.sh

datadir="/var/lib/proxysql"

admin_variables=
{
    admin_credentials="admin:admin;radmin:radmin"
    mysql_ifaces="0.0.0.0:6032"
    refresh_interval=2000

    # Web interface disabled by default for security
    # web_enabled=false
    # web_port=6080
}

mysql_variables=
{
    threads=4
    max_connections=2048
    default_query_delay=0
    default_query_timeout=36000000
    have_compress=true
    poll_timeout=2000
    interfaces="0.0.0.0:6033"
    default_schema="information_schema"
    stacksize=1048576
    server_version="5.5.30"
    connect_timeout_server=3000
    monitor_username="monitor"
    monitor_password="monitor"
    monitor_history=600000
    monitor_connect_interval=60000
    monitor_ping_interval=10000
    monitor_read_only_interval=1500
    monitor_read_only_timeout=500
    ping_interval_server_msec=120000
    ping_timeout_server=500
    commands_stats=true
    sessions_sort=true
    connect_retries_on_failure=10
}

# MySQL Servers Configuration
# Add backend servers via admin interface:
# mysql -u admin -padmin -h 127.0.0.1 -P6032
# INSERT INTO mysql_servers(hostgroup_id, hostname, port) VALUES (10, '127.0.0.1', 3306);

# MySQL Users Configuration
# Add users via admin interface:
# INSERT INTO mysql_users(username, password, default_hostgroup) VALUES ('user', 'pass', 10);

# MySQL Query Rules
# Define routing rules via admin interface if needed
EOF

chmod 644 "$PROXYSQL_CONFIG_FILE"
log "✓ Configuration file created: $PROXYSQL_CONFIG_FILE"

# Step 8: Create Systemd Service File
log "Step 8/10: Creating systemd service file..."

cat > /etc/systemd/system/proxysql.service <<'EOF'
[Unit]
Description=High Performance Advanced Proxy for MySQL
After=network.target

[Service]
Type=forking
User=proxysql
Group=proxysql

# Restart configuration
Restart=on-failure
RestartSec=5s

# Security settings
NoNewPrivileges=true
PrivateTmp=true

# Resource limits
LimitNOFILE=102400
LimitNPROC=102400

# Execution
ExecStart=/usr/bin/proxysql -c /etc/proxysql.cnf
ExecReload=/bin/kill -HUP $MAINPID

# PID file
PIDFile=/var/lib/proxysql/proxysql.pid

# Working directory
WorkingDirectory=/var/lib/proxysql

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/proxysql.service
log "✓ Systemd service file created"

# Step 9: Enable and Start ProxySQL Service
log "Step 9/10: Enabling and starting ProxySQL service..."

systemctl daemon-reload 2>&1 | tee -a "$INSTALL_LOG"

systemctl enable proxysql 2>&1 | tee -a "$INSTALL_LOG"
if [ $? -eq 0 ]; then
    log "✓ ProxySQL service enabled"
else
    error "Failed to enable ProxySQL service"
fi

systemctl start proxysql 2>&1 | tee -a "$INSTALL_LOG"
if [ $? -eq 0 ]; then
    log "✓ ProxySQL service started"
else
    error "Failed to start ProxySQL service"
fi

# Wait for ProxySQL to initialize
log "Waiting for ProxySQL to initialize..."
sleep 5

# Step 10: Verify Installation
log "Step 10/10: Verifying ProxySQL installation..."

# Check if ProxySQL binary exists
if [ -x /usr/bin/proxysql ]; then
    PROXYSQL_BIN_VERSION=$(/usr/bin/proxysql --version 2>&1 | head -n1)
    log "✓ ProxySQL binary installed: $PROXYSQL_BIN_VERSION"
else
    error "ProxySQL binary not found at /usr/bin/proxysql"
fi

# Check if service is running
if systemctl is-active --quiet proxysql; then
    log "✓ ProxySQL service is running"
else
    error "ProxySQL service is not running"
fi

# Check if admin interface is accessible
if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    MYSQL_CMD=$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null)
    if $MYSQL_CMD -u admin -padmin -h 127.0.0.1 -P6032 -e "SELECT @@version;" >/dev/null 2>&1; then
        log "✓ ProxySQL admin interface is accessible"
    else
        warn "ProxySQL admin interface test failed (MariaDB may not be configured yet)"
    fi
else
    warn "MySQL/MariaDB client not found - skipping admin interface test"
fi

# Clean up build directory
log "Cleaning up build directory..."
rm -rf "$PROXYSQL_BUILD_DIR"
log "✓ Build directory removed"

# Installation Summary
log ""
log "==============================================="
log "ProxySQL Installation Complete!"
log "==============================================="
log ""
log "Installation Details:"
log "  - Version: $PROXYSQL_VERSION"
log "  - Binary: /usr/bin/proxysql"
log "  - Config: $PROXYSQL_CONFIG_FILE"
log "  - Data Directory: $PROXYSQL_DATA_DIR"
log "  - Log Directory: $PROXYSQL_LOG_DIR"
log "  - Service: proxysql.service"
log ""
log "Network Ports:"
log "  - Admin Interface: 0.0.0.0:6032"
log "  - MySQL Traffic: 0.0.0.0:6033"
log ""
log "Default Admin Credentials:"
log "  - Username: admin"
log "  - Password: admin"
log "  - Connection: mysql -u admin -padmin -h 127.0.0.1 -P6032"
log ""
log "Service Management:"
log "  - Check Status: systemctl status proxysql"
log "  - View Logs: journalctl -u proxysql -f"
log "  - Restart: systemctl restart proxysql"
log "  - Stop: systemctl stop proxysql"
log ""
log "Next Steps:"
log "  1. Configure backend MariaDB/MySQL servers"
log "  2. Add database users to ProxySQL"
log "  3. Set up query routing rules (if needed)"
log "  4. Test connections on port 6033"
log ""
log "Installation log saved to: $INSTALL_LOG"
log "==============================================="

exit 0
