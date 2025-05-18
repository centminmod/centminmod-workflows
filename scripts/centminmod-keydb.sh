#!/bin/bash
# ==========================================================================
# Centmin Mod EL8+ system keydb server install
# ==========================================================================
# for genkeydb function
DEBUG_KEYDBGEN=n
FORCE_DELETE='n'
STARTPORT=7479

# clang version
CLANG='n'
CLANG_BIN='/usr/bin/clang'
CLANG_DETECT_VER=$(clang --version | head -n1 | awk '{print $3}' | cut -d . -f1)

# Function to get the lower value of TX and RX queues
get_queue_count() {
    local interface=$1
    local tx_count=$(ls -d /sys/class/net/"$interface"/queues/tx-* | wc -l)
    local rx_count=$(ls -d /sys/class/net/"$interface"/queues/rx-* | wc -l)
    if [ $tx_count -lt $rx_count ]; then
        echo $tx_count
    else
        echo $rx_count
    fi
}

keydb_install() {
  # Choose the primary network interface
  primary_interface=$(ip route | grep default | awk '{print $5}' | head -n 1)

  # Get queue count
  queue_count=$(get_queue_count "$primary_interface")
  queue_count=${queue_count:-2}
  if [ "$queue_count" -eq '1' ]; then
    # optimal value
    queue_count=2
  elif [ "$queue_count" -ge '4' ]; then
    # max keydb recommended value for server-threads
    queue_count=4
  fi

  yum install -y libuuid-devel which libatomic tcltls libzstd rpm-build
  
  if [[ "$CLANG" = [yY] && "$CLANG_DETECT_VER" -ge '15' ]]; then
    # LLVMLTO_OPT=' -flto'
    # CCTOOLSET=' --gcc-toolchain=/opt/rh/gcc-toolset-11/root/usr'
    CLANG_CCOPT=' -Wno-sign-compare -Wno-string-plus-int -Wno-deprecated-declarations -Wno-unused-parameter -Wno-unused-const-variable -Wno-conditional-uninitialized -Wno-mismatched-tags -Wno-sometimes-uninitialized -Wno-parentheses-equality -Wno-tautological-compare -Wno-self-assign -Wno-deprecated-register -Wno-deprecated -Wno-invalid-source-encoding -Wno-pointer-sign -Wno-parentheses -Wno-enum-conversion -Wno-c++11-compat-deprecated-writable-strings -Wno-write-strings -Wno-unused-command-line-argument -Wno-strict-prototypes'
    export CC="ccache ${CLANG_BIN}${LLVMLTO_OPT} -ferror-limit=0${CCTOOLSET}${CLANG_CCOPT}"
    export CXX="ccache ${CLANG_BIN}++${LLVMLTO_OPT} -ferror-limit=0${CLANG_CCOPT}"
    export CCACHE_CPP2=yes
  elif [[ -f /opt/rh/gcc-toolset-11/root/usr/bin/gcc && -f /opt/rh/gcc-toolset-11/root/usr/bin/g++ ]]; then
    source /opt/rh/gcc-toolset-11/enable
    export CC="ccache gcc"
    export CXX="ccache g++"
  elif [[ -f /opt/rh/gcc-toolset-10/root/usr/bin/gcc && -f /opt/rh/gcc-toolset-10/root/usr/bin/g++ ]]; then
    source /opt/rh/gcc-toolset-10/enable
    export CC="ccache gcc"
    export CXX="ccache g++"
  fi
  
  # install KeyDB via source compile to allow KeyDB to run
  # beside existing Redis YUM packages
  mkdir -p /svr-setup
  cd /svr-setup
  rm -rf KeyDB
  git clone https://github.com/Snapchat/KeyDB
  cd KeyDB
  git fetch --all
  git checkout RELEASE_6_3_4
  git pull
  make distclean
  export KEYDB_CFLAGS="-fPIC -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
  export KEYDB_LDFLAGS="-Wl,-z,relro,-z,now -pie"
  export CFLAGS="-fPIC -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
  export LDFLAGS="-Wl,-z,relro,-z,now -pie"
  export CPPFLAGS="-D_FORTIFY_SOURCE=2"
  export CXXFLAGS="-fPIC -O2"
  time make -j$(nproc) BUILD_TLS=yes USE_SYSTEMD=yes MALLOC=jemalloc
  #time make test
  time make install
  \cp -af ./src/keydb-diagnostic-tool /usr/local/bin/keydb-diagnostic-tool

  if [ -f /usr/local/bin/checksec ]; then
    echo
    echo "checksec --file=$(which keydb-server) --format=json | jq -r"
    checksec --file=$(which keydb-server) --format=json | jq -r
    echo
  fi
 
  # add keydb linux user
  getent group keydb &> /dev/null || groupadd -r keydb &> /dev/null
  getent passwd keydb &> /dev/null || useradd -r -g keydb -d /var/lib/keydb -s /sbin/nologin -c 'KeyDB Database Server' keydb &> /dev/null
  
  # setup /etc/keydb directory
  KEYDB_DIR=/etc/keydb
  mkdir -p $KEYDB_DIR
  \cp -af keydb.conf $KEYDB_DIR
  
  # setup directories and permissions
  mkdir -p /var/run/keydb /var/log/keydb /var/lib/keydb
  chown -R keydb:keydb /var/run/keydb /var/log/keydb /etc/keydb /var/lib/keydb
  chmod 755 /var/run/keydb
  echo "d      /var/run/keydb/         0755 keydb keydb -" > /etc/tmpfiles.d/keydb.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/keydb.conf

  # copy sentinel.conf template to /etc/keydb/sentinel.conf
  \cp -af ./sentinel.conf $KEYDB_DIR

  # Update log and pid file paths in custom config
  sed -i "s|logfile \"\"|logfile /var/log/keydb/sentinel.log|" "${KEYDB_DIR}/sentinel.conf"
  sed -i "s|pidfile /var/run/keydb-sentinel.pid|pidfile /var/run/keydb/keydb-sentinel.pid|" "${KEYDB_DIR}/sentinel.conf"
  # Modify original or custom sentinel config file
  sed -i "s/^sentinel monitor mymaster 127.0.0.1 6379 2/sentinel monitor mymaster 127.0.0.1 7379 2/" "${KEYDB_DIR}/sentinel.conf"
  # sed -i "s/^# sentinel auth-pass <master-name> <password>/sentinel auth-pass mymaster $master_password/" "${KEYDB_DIR}/sentinel.conf"
  # fix noexec /tmp
  mkdir -p /home/keydbtmp
  chown keydb:keydb /home/keydbtmp
  chmod 1777 /home/keydbtmp
  sed -i 's|dir /tmp|dir /home/keydbtmp|' "${KEYDB_DIR}/sentinel.conf"
  # reduce failover time
  sed -i 's|sentinel down-after-milliseconds mymaster 30000|sentinel down-after-milliseconds mymaster 5000|' "${KEYDB_DIR}/sentinel.conf"
  sed -i 's|sentinel failover-timeout mymaster 180000|sentinel failover-timeout mymaster 60000|' "${KEYDB_DIR}/sentinel.conf"
  # setup limit.conf
  mkdir -p "/etc/systemd/system/keydb-sentinel.service.d"
  if [ -f /etc/systemd/system/keydb-sentinel.service.d/limit.conf ]; then
    \cp -af /etc/systemd/system/keydb-sentinel.service.d/limit.conf "/etc/systemd/system/keydb-sentinel.service.d/limit.conf"
    sed -i "s|LimitNOFILE=.*|LimitNOFILE=5242880|" "/etc/systemd/system/keydb-sentinel.service.d/limit.conf"
  fi
  
  # adjust default keydb server to run on TCP port 7379 to not conflict
  # with redis default 6379 port and setup keydb.conf defaults
  sed -i 's|^port 6379|port 7379|' ${KEYDB_DIR}/keydb.conf
  sed -i 's|^tcp-backlog 511|tcp-backlog 524288|' ${KEYDB_DIR}/keydb.conf
  sed -i 's|dir ./|dir /var/lib/keydb|' ${KEYDB_DIR}/keydb.conf
  sed -i 's|^pidfile /var/run/keydb_6379.pid|pidfile /var/run/keydb/keydb_7379.pid|' ${KEYDB_DIR}/keydb.conf
  sed -i 's|^logfile ""|logfile /var/log/keydb/keydb.log|' ${KEYDB_DIR}/keydb.conf
  sed -i 's|^# min-clients-per-thread 50|min-clients-per-thread 50|' ${KEYDB_DIR}/keydb.conf
  sed -i 's|^min-clients-per-thread .*|min-clients-per-thread 40|' ${KEYDB_DIR}/keydb.conf
  if [ "$(nproc)" -ge '4' ]; then
    sed -i 's|^# server-thread-affinity|server-thread-affinity|' ${KEYDB_DIR}/keydb.conf
  fi
  if [ "$queue_count" -ge '1' ]; then
    # set to lower of NIC TX or RX queue sizes
    sed -i "s|^server-threads .*|server-threads $queue_count|" ${KEYDB_DIR}/keydb.conf
  fi
  cat ${KEYDB_DIR}/keydb.conf | grep -E '^pid|^port|^log|^dir|^tcp-backlog|^server-threads|server-thread|replica-ignore-maxmemory|min-clients'
  
  # setup logrotate and systemd service files and dependencies
  \cp -af ./pkg/rpm/keydb_build/keydb_rpm/etc/logrotate.d/keydb /etc/logrotate.d/keydb
  \cp -af ./pkg/rpm/keydb_build/keydb_rpm/usr/lib/systemd/system/keydb.service /usr/lib/systemd/system/keydb.service
  \cp -af ./pkg/rpm/keydb_build/keydb_rpm/usr/lib/systemd/system/keydb-sentinel.service /usr/lib/systemd/system/keydb-sentinel.service
  \cp -af ./pkg/rpm/keydb_build/keydb_rpm/usr/libexec/keydb-shutdown /usr/libexec/keydb-shutdown
  chown -R keydb:keydb /usr/libexec/keydb-shutdown
  
  # adjust systemd service files
  sed -i 's|Type=forking|Type=notify|' /usr/lib/systemd/system/keydb.service
  sed -i 's|\/usr\/bin\/keydb-|\/usr\/local\/bin\/keydb-|g' /usr/lib/systemd/system/keydb.service
  sed -i 's|\/usr\/bin\/keydb-|\/usr\/local\/bin\/keydb-|g' /usr/lib/systemd/system/keydb-sentinel.service
  sed -i 's|\/usr\/local\/bin\/keydb-server \/etc\/keydb\/keydb.conf|\/usr\/local\/bin\/keydb-server \/etc\/keydb\/keydb.conf --daemonize no --supervised systemd|' /usr/lib/systemd/system/keydb.service
  
  # modify keydb service limits
  mkdir -p /etc/systemd/system/keydb.service.d /etc/systemd/system/keydb-sentinel.service.d
  \cp -af ./pkg/rpm/keydb_build/keydb_rpm/etc/systemd/system/keydb.service.d/limit.conf /etc/systemd/system/keydb.service.d/limit.conf
  \cp -af ./pkg/rpm/keydb_build/keydb_rpm/etc/systemd/system/keydb-sentinel.service.d/limit.conf /etc/systemd/system/keydb-sentinel.service.d/limit.conf
  sed -i 's|10240|5242880|' /etc/systemd/system/keydb.service.d/limit.conf
  sed -i 's|10240|5242880|' /etc/systemd/system/keydb-sentinel.service.d/limit.conf
  
  # only enable keydb-server
  echo "systemctl daemon-reload"
  systemctl daemon-reload
  echo "systemctl enable keydb"
  systemctl enable keydb
  echo "systemctl start keydb"
  systemctl start keydb
  echo "systemctl status keydb --no-pager -l"
  systemctl status keydb --no-pager -l

  echo
  echo "keydb server installed"
  echo
  prlimit -p $(pidof keydb-server)
  echo
  keydb-server -v
  echo
}

version_to_int() {
    local ver="$1"
    IFS='.' read -r -a ver_parts <<< "$ver"
    printf -v ver_num "%03d%03d%03d" "${ver_parts[0]}" "${ver_parts[1]}" "${ver_parts[2]}"
    echo $ver_num
}

keydb_upgrade() {
  if [[ -f /opt/rh/gcc-toolset-11/root/usr/bin/gcc && -f /opt/rh/gcc-toolset-11/root/usr/bin/g++ ]]; then
    source /opt/rh/gcc-toolset-11/enable
  elif [[ -f /opt/rh/gcc-toolset-10/root/usr/bin/gcc && -f /opt/rh/gcc-toolset-10/root/usr/bin/g++ ]]; then
    source /opt/rh/gcc-toolset-10/enable
  fi

  # install KeyDB via source compile to allow KeyDB to run
  # beside existing Redis YUM packages
  mkdir -p /svr-setup
  cd /svr-setup
  rm -rf KeyDB
  git clone https://github.com/Snapchat/KeyDB
  cd KeyDB
  git fetch --all
  latest_branch=$(git branch -r | grep 'RELEASE_' | sort -r | head -n 1 | awk '{print $NF}' | sed 's/origin\///')

  # Get the currently installed KeyDB version
  current_version=$(keydb-server -v | awk '{print $3}' | cut -d'=' -f2)
  
  # Assuming latest_branch contains the latest version branch name like "RELEASE_6_3_4"
  # Extract the version number from the latest_branch variable
  latest_version=$(echo $latest_branch | tr '_' '.' | cut -d'.' -f2-)
  
  # Convert versions to integers
  current_version_int=$(version_to_int $current_version)
  latest_version_int=$(version_to_int $latest_version)
  
  # Compare the versions
  if [ "$current_version_int" -lt "$latest_version_int" ]; then
      echo "KeyDB update available: current version $current_version, latest version $latest_version."
      echo
      git checkout "$latest_branch"
      git pull
      make distclean
      time make -j$(nproc) BUILD_TLS=yes USE_SYSTEMD=yes MALLOC=jemalloc
      #time make test
      time make install
      \cp -af ./src/keydb-diagnostic-tool /usr/local/bin/keydb-diagnostic-tool
      
      cat ${KEYDB_DIR}/keydb.conf | grep -E '   ^pid|^port|^log|^dir|^tcp-backlog|^server-threads|server-thread|replica-ignore-maxmemory|min-clients'
    
      # only enable keydb-server
      echo "systemctl daemon-reload"
      systemctl daemon-reload
      echo "systemctl enable keydb"
      systemctl enable keydb
      echo "systemctl start keydb"
      systemctl start keydb
      echo "systemctl status keydb --no-pager -l"
      systemctl status keydb --no-pager -l
    
      echo
      echo "keydb server upgraded"
      echo
      prlimit -p $(pidof keydb-server)
      echo
      keydb-server -v
      echo
  else
      echo "KeyDB is up-to-date (version $current_version)."
  fi
}

genkeydb() {
  CLUSTER=$2
  CLUSTER_CREATE=$3
  STARTPORT=$4
  # increment starts at 0
  NUMBER=$(($1-1))
  if [[ "$NUMBER" -eq '0' ]]; then
    NUMBER=0
  elif [[ "$NUMBER" -eq '1' ]]; then
    NUMBER=1
  fi
  echo
  echo "Creating keydb servers starting at TCP = $STARTPORT..."
  for (( p=0; p <= $NUMBER; p++ ))
    do
      KEYDBPORT=$(($STARTPORT+$p))
      echo "-------------------------------------------------------"
      echo "creating keydb server: keydb${KEYDBPORT}.service [increment value: $p]"
      echo "keydb TCP port: $KEYDBPORT"
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        if [ ! -f "/usr/lib/systemd/system/keydb${KEYDBPORT}.service" ]; then
          echo "create systemd keydb${KEYDBPORT}.service"
          echo "cp -a /usr/lib/systemd/system/keydb.service /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|/etc/keydb/keydb.conf|/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|/var/run/keydb/keydb-server.pid|/var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|/var/lib/keydb|/var/lib/keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|ReadWriteDirectories=-/etc/keydb|ReadWriteDirectories=-/etc/keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|ReadWriteDirectories=-/var/run/keydb|ReadWriteDirectories=-/var/run/keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|RuntimeDirectory=keydb|RuntimeDirectory=keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|Alias=keydb.service$|Alias=keydb${KEYDBPORT}.service|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
        else
          echo "/usr/lib/systemd/system/keydb${KEYDBPORT}.service already exists"
        fi
        if [ ! -f "/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf" ]; then
          echo "create /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf config file"
          echo "mkdir -p /etc/keydb${KEYDBPORT}"
          echo "chown -R keydb:keydb /etc/keydb${KEYDBPORT}"
          echo "cp -a /etc/keydb/keydb.conf /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        else
          echo "/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf already exists"
        fi
        if [ -f /etc/systemd/system/keydb.service.d/limit.conf ]; then
          echo "mkdir -p "/etc/systemd/system/keydb${KEYDBPORT}.service.d/""
          echo "\cp -af /etc/systemd/system/keydb.service.d/limit.conf /etc/systemd/system/keydb${KEYDBPORT}.service.d/limit.conf"
        fi
        if [ ! -d "/var/lib/keydb${KEYDBPORT}" ]; then
          echo "mkdir -p /var/lib/keydb${KEYDBPORT}"
          echo "chown -R keydb:keydb /var/lib/keydb${KEYDBPORT}"
        fi
        echo "sed -i \"s|^port 7379|port ${KEYDBPORT}|\" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        echo "sed -i \"s|dir /var/lib/keydb$|dir /var/lib/keydb${KEYDBPORT}|\" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        echo "sed -i \"s|^pidfile /var/run/keydb/keydb_7379.pid|pidfile /var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid|\" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        echo "sed -i \"s|^logfile /var/log/keydb/keydb.log|logfile /var/log/keydb/keydb${KEYDBPORT}.log|\" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        echo "systemctl daemon-reload"
        echo "systemctl start keydb${KEYDBPORT}"
        echo "systemctl enable keydb${KEYDBPORT}"
        echo
        echo "KeyDB TCP $KEYDBPORT Info:"
        echo
        echo "service file: /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
        echo "service limit file: /etc/systemd/system/keydb${KEYDBPORT}.service.d/limit.conf"
        echo "config directory: /etc/keydb${KEYDBPORT}"
        echo "config file: /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        echo "data directory: /var/lib/keydb${KEYDBPORT}"
        echo "pidfile: /var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid"
        echo "log file: /var/log/keydb/keydb${KEYDBPORT}.log"
        echo
        if [[ "$UNIXSOCKET" = [Yy] ]]; then
          echo "keydb-cli -s /var/run/keydb${KEYDBPORT}/keydb${KEYDBPORT}.sock INFO SERVER | grep -E 'redis_version|redis_mode|process_id|tcp_port|uptime|executable|config_file'"
        else
          echo "keydb-cli -h 127.0.0.1 -p $KEYDBPORT INFO SERVER | grep -E 'redis_version|redis_mode|process_id|tcp_port|uptime|executable|config_file'"
        fi
      else
        if [ ! -f "/usr/lib/systemd/system/keydb${KEYDBPORT}.service" ]; then
          echo "create systemd keydb${KEYDBPORT}.service"
          echo "cp -a /usr/lib/systemd/system/keydb.service /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          cp -a /usr/lib/systemd/system/keydb.service /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          echo "sed -i \"s|/etc/keydb/keydb.conf|/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|/var/run/keydb/keydb-server.pid|/var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          echo "sed -i \"s|/var/lib/keydb|/var/lib/keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          sed -i "s|/etc/keydb/keydb.conf|/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          sed -i "s|/var/run/keydb/keydb-server.pid|/var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          sed -i "s|/var/lib/keydb|/var/lib/keydb${KEYDBPORT}|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          echo "sed -i \"s|ReadWriteDirectories=-/etc/keydb|ReadWriteDirectories=-/etc/keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          sed -i "s|ReadWriteDirectories=-/etc/keydb|ReadWriteDirectories=-/etc/keydb${KEYDBPORT}|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          echo "sed -i \"s|ReadWriteDirectories=-/var/run/keydb|ReadWriteDirectories=-/var/run/keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          sed -i "s|ReadWriteDirectories=-/var/run/keydb|ReadWriteDirectories=-/var/run/keydb${KEYDBPORT}|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          echo "sed -i \"s|RuntimeDirectory=keydb|RuntimeDirectory=keydb${KEYDBPORT}|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          sed -i "s|RuntimeDirectory=keydb|RuntimeDirectory=keydb${KEYDBPORT}|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          echo "sed -i \"s|Alias=keydb.service$|Alias=keydb${KEYDBPORT}.service|\" /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
          sed -i "s|Alias=keydb.service$|Alias=keydb${KEYDBPORT}.service|" /usr/lib/systemd/system/keydb${KEYDBPORT}.service
          # setup directories and permissions
          mkdir -p /var/run/keydb${KEYDBPORT}
          chown -R keydb:keydb /var/run/keydb${KEYDBPORT}
          chmod 755 /var/run/keydb${KEYDBPORT}
          echo "d      /var/run/keydb${KEYDBPORT}/         0755 keydb keydb -" > /etc/tmpfiles.d/keydb${KEYDBPORT}.conf
          echo "systemd-tmpfiles --create /etc/tmpfiles.d/keydb${KEYDBPORT}.conf"
          systemd-tmpfiles --create /etc/tmpfiles.d/keydb${KEYDBPORT}.conf
        else
          echo "/usr/lib/systemd/system/keydb${KEYDBPORT}.service already exists"
        fi
        if [ ! -f "/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf" ]; then
          echo "create /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf config file"
          echo "mkdir -p /etc/keydb${KEYDBPORT}"
          echo "chown -R keydb:keydb /etc/keydb${KEYDBPORT}"
          echo "cp -a /etc/keydb/keydb.conf /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
          mkdir -p /etc/keydb${KEYDBPORT}
          chown -R keydb:keydb /etc/keydb${KEYDBPORT}
          cp -a /etc/keydb/keydb.conf /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf
        else
          echo "/etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf already exists"
        fi
        if [ -f /etc/systemd/system/keydb.service.d/limit.conf ]; then
          echo "mkdir -p /etc/systemd/system/keydb${KEYDBPORT}.service.d/"
          echo "\cp -af /etc/systemd/system/keydb.service.d/limit.conf /etc/systemd/system/keydb${KEYDBPORT}.service.d/limit.conf"
          mkdir -p /etc/systemd/system/keydb${KEYDBPORT}.service.d/
          \cp -af /etc/systemd/system/keydb.service.d/limit.conf /etc/systemd/system/keydb${KEYDBPORT}.service.d/limit.conf
        fi
        if [ ! -d "/var/lib/keydb${KEYDBPORT}" ]; then
          echo "mkdir -p /var/lib/keydb${KEYDBPORT}"
          mkdir -p "/var/lib/keydb${KEYDBPORT}"
          echo "chown -R keydb:keydb /var/lib/keydb${KEYDBPORT}"
          chown -R keydb:keydb /var/lib/keydb${KEYDBPORT}
        fi
        sed -i "s|^port 7379|port ${KEYDBPORT}|" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf
        sed -i "s|dir /var/lib/keydb$|dir /var/lib/keydb${KEYDBPORT}|" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf
        sed -i "s|^pidfile /var/run/keydb/keydb_7379.pid|pidfile /var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid|" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf
        sed -i "s|^logfile /var/log/keydb/keydb.log|logfile /var/log/keydb/keydb${KEYDBPORT}.log|" /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf
        echo "systemctl daemon-reload"
        systemctl daemon-reload
        echo "systemctl start keydb${KEYDBPORT}"
        systemctl start keydb${KEYDBPORT}
        echo "systemctl enable keydb${KEYDBPORT}"
        systemctl enable keydb${KEYDBPORT}
        echo
        echo "KeyDB TCP $KEYDBPORT Info:"
        echo "service file: /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
        echo "service limit file: /etc/systemd/system/keydb${KEYDBPORT}.service.d/limit.conf"
        echo "config directory: /etc/keydb${KEYDBPORT}"
        echo "config file: /etc/keydb${KEYDBPORT}/keydb${KEYDBPORT}.conf"
        echo "data directory: /var/lib/keydb${KEYDBPORT}"
        echo "pidfile: /var/run/keydb${KEYDBPORT}/keydb_${KEYDBPORT}.pid"
        echo "log file: /var/log/keydb/keydb${KEYDBPORT}.log"
        echo
        if [[ "$UNIXSOCKET" = [Yy] ]]; then
          echo "keydb-cli -s /var/run/keydb${KEYDBPORT}/keydb${KEYDBPORT}.sock INFO SERVER | grep -E 'redis_version|redis_mode|process_id|tcp_port|uptime|executable|config_file'"
          keydb-cli -s /var/run/keydb${KEYDBPORT}/keydb${KEYDBPORT}.sock INFO SERVER | grep -E 'redis_version|redis_mode|process_id|tcp_port|uptime|executable|config_file'
        else
          echo "keydb-cli -h 127.0.0.1 -p $KEYDBPORT INFO SERVER | grep -E 'redis_version|redis_mode|process_id|tcp_port|uptime|executable|config_file'"
          keydb-cli -h 127.0.0.1 -p $KEYDBPORT INFO SERVER | grep -E 'redis_version|redis_mode|process_id|tcp_port|uptime|executable|config_file'
        fi
      fi
  done
}

genkeydb_del() {
  # increment starts at 0
  NUMBER=$(($1-1))
  NUMBER_SENTINELS=2
  if [[ "$NUMBER" -eq '0' ]]; then
    NUMBER=0
  elif [[ "$NUMBER" -eq '1' ]]; then
    NUMBER=1
  fi
  echo
  for (( p=0; p <= $NUMBER; p++ ))
    do
      KEYDBPORT=$(($STARTPORT+$p))
    if [[ "$FORCE_DELETE" = [Yy] || -f "/usr/lib/systemd/system/keydb${KEYDBPORT}.service" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /usr/lib/systemd/system/keydb${KEYDBPORT}.service ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "systemctl stop keydb${KEYDBPORT}.service"
        echo "systemctl disable keydb${KEYDBPORT}.service"
        echo "rm -rf /usr/lib/systemd/system/keydb${KEYDBPORT}.service"
      else
        systemctl stop keydb${KEYDBPORT}.service
        systemctl disable keydb${KEYDBPORT}.service
        rm -rf "/usr/lib/systemd/system/keydb${KEYDBPORT}.service"
      fi
    fi
    if [[ "$FORCE_DELETE" = [Yy] || -d "/etc/systemd/system/keydb${KEYDBPORT}.service.d" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /etc/systemd/system/keydb${KEYDBPORT}.service.d ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "rm -rf /etc/systemd/system/keydb${KEYDBPORT}.service.d"
      else
        rm -rf "/etc/systemd/system/keydb${KEYDBPORT}.service.d"
      fi
    fi
    if [[ "$FORCE_DELETE" = [Yy] || -d "/etc/keydb${KEYDBPORT}" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /etc/keydb${KEYDBPORT} ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "rm -rf /etc/keydb${KEYDBPORT}"
      else
        rm -rf "/etc/keydb${KEYDBPORT}"
      fi
    fi
    if [[ "$FORCE_DELETE" = [Yy] || -d "/var/lib/keydb${KEYDBPORT}" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /var/lib/keydb${KEYDBPORT} ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "rm -rf /var/lib/keydb${KEYDBPORT}"
      else
        rm -rf "/var/lib/keydb${KEYDBPORT}"
      fi
    fi
    if [[ "$FORCE_DELETE" = [Yy] || -f "/var/run/keydb/keydb_${KEYDBPORT}.pid" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /var/run/keydb/keydb_${KEYDBPORT}.pid ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "rm -rf /var/run/keydb/keydb_${KEYDBPORT}.pid"
      else
        rm -rf "/var/run/keydb/keydb_${KEYDBPORT}.pid"
      fi
    fi
    if [[ "$FORCE_DELETE" = [Yy] || -f "/var/log/keydb/keydb${KEYDBPORT}.log" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /var/log/keydb/keydb${KEYDBPORT}.log ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "rm -rf /var/log/keydb/keydb${KEYDBPORT}.log"
      else
        rm -rf "/var/log/keydb/keydb${KEYDBPORT}.log"
      fi
    fi
    if [[ "$FORCE_DELETE" = [Yy] || -f "/etc/tmpfiles.d/keydb${KEYDBPORT}.conf" ]]; then
      echo "-------------------------------------------------------"
      echo "Deleting /etc/tmpfiles.d/keydb${KEYDBPORT}.conf ..."
      if [[ "$DEBUG_KEYDBGEN" = [yY] ]]; then
        echo "rm -rf /etc/tmpfiles.d/keydb${KEYDBPORT}.conf"
      else
        rm -rf "/etc/tmpfiles.d/keydb${KEYDBPORT}.conf"
      fi
    fi
  done
  echo "Deletion completed"
  exit
}

help() {
  echo
  echo "Usage:"
  echo
  echo "* multi X - no. of standalone redis instances to create"
# echo "* multi-cache X - no. of standalone redis instances + disable ondisk persistence"
  echo "* delete X - no. of redis instances to delete"
  echo "* delete X 7479 - no. of redis instances to delete + custom start port 7479"
  echo
  echo "$0 install"
  echo "$0 upgrade"
  echo "$0 multi X"
  # echo "$0 multi-cache X"
  echo "$0 delete X"
}

case "$1" in
  install )
    keydb_install
    ;;
  upgrade )
    keydb_upgrade
    ;;
  multi )
    NUM=$2
    CUSTOM_STARTPORT=$3
    if [[ ! -z "$CUSTOM_STARTPORT" ]]; then
      CHECK_PORT=$(netstat -nt | grep -q $CUSTOM_STARTPORT; echo $?)
      if [[ "$CHECK_PORT" -ne '0' ]]; then
        STARTPORT=$CUSTOM_STARTPORT
      else
        echo
        echo "Error: TCP port $CUSTOM_STARTPORT in use, try another port"
        echo
        exit
      fi
    fi
    genkeydb $NUM na na $STARTPORT
    ;;
  delete )
    NUM=$2
    CUSTOM_STARTPORT=$3
    if [[ ! -z "$CUSTOM_STARTPORT" ]]; then
      STARTPORT=$CUSTOM_STARTPORT
    fi
    genkeydb_del $NUM na na $STARTPORT
    ;;
  * )
    help
    ;;
esac
