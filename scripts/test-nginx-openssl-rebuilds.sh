#!/bin/bash
# Run inside the installed Centmin Mod test container.
set -euo pipefail
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
config=/etc/centminmod/custom_config.inc
logs=/root/centminlogs
mkdir -p "$logs"
backup=$(mktemp)
had_config=n
if [[ -f "$config" ]]; then
  cp -p "$config" "$backup"
  had_config=y
fi
trap '
  if [[ "$had_config" = y ]]; then cp -p "$backup" "$config"; else rm -f "$config"; fi
  rm -f "$backup"
' EXIT
nginx_version=$(nginx -v 2>&1 | awk '{sub(/^nginx\//, "", $3); print $3}')
[[ "$nginx_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $# -gt 0 ]] || set -- 3.5.8 3.6.4 4.0.2
failed=0
for version in "$@"; do
  [[ "$version" =~ ^(3\.(5|6)|4\.0)\.[0-9]+$ ]] || { echo "Invalid OpenSSL test version: $version" >&2; exit 1; }
  cp -p "$backup" "$config"
  prefix="/opt/openssl-ci-$version"
  cat >> "$config" <<CONFIG

OPENSSL_VERSION='$version'
OPENSSL_VERSIONFALLBACK='$version'
OPENSSL_SYSTEM_USE='n'
OPENSSL_CUSTOMPATH='$prefix'
OPENSSL_FORCECOMPILE='y'
PHP_CUSTOMSSL_FORCE='n'
LIBRESSL_SWITCH='n'
BORINGSSL_SWITCH='n'
AWS_LC_SWITCH='n'
NGINX_QUIC_SUPPORT='n'
TIME_NGINX='y'
CONFIG
  log="$logs/nginx-openssl-$version"
  ok=y
  if ! (cd "$centmin_dir" && bash centmin-cli.sh nginx-update "$nginx_version" < /dev/null) > "$log-build.log" 2>&1; then
    ok=n
  fi
  build_info=$(nginx -V 2>&1) || ok=n
  printf '%s\n' "$build_info" > "$log-nginx-version.log"
  [[ "$build_info" = *"built with OpenSSL $version "* && "$build_info" = *'built by gcc 15.'* ]] || ok=n
  if ! "$prefix/bin/openssl" version -a > "$log-openssl-version.log" 2>&1; then
    ok=n
  elif [[ "$(awk 'NR==1 {print $2}' "$log-openssl-version.log")" != "$version" ]]; then
    ok=n
  fi
  nginx -t > "$log-config.log" 2>&1 || ok=n
  systemctl is-active nginx > "$log-service.log" 2>&1 || ok=n
  curl -fsS --max-time 15 -o /dev/null http://127.0.0.1/ > "$log-http.log" 2>&1 || ok=n
  php -v > "$log-php.log" 2>&1 || ok=n
  if [[ "$ok" = y ]]; then
    echo "PASS: Nginx $nginx_version, GCC 15, OpenSSL $version, config/service/HTTP/PHP checks"
  else
    echo "FAIL: Nginx/OpenSSL $version; see nginx-openssl-$version-*.log"
    tail -40 "$log-build.log"
    failed=1
  fi
done
exit "$failed"
