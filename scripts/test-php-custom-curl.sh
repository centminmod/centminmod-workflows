#!/bin/bash
# PHP_CUSTOM_CURL=y checks for 141.00beta01+ installs. Run inside the container:
#   docker exec -i cmm_el89 bash -s < scripts/test-php-custom-curl.sh
# Reads the libcurl version Centmin Mod builds from the installed
# inc/php_configure.inc, mirroring its selection: CURL_VER_OSSL11 on EL8, and on
# EL9 with PHP 7.4/8.0 (compat-openssl11); CURL_VER otherwise.
set -uo pipefail
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
inc="$centmin_dir/inc/php_configure.inc"
el=$(rpm -E '%{rhel}')
phpver=$(/usr/local/bin/php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
var=CURL_VER
if [[ "$el" = 8 ]] || [[ "$el" = 9 && "$phpver" =~ ^(7\.4|8\.0)$ ]]; then
  var=CURL_VER_OSSL11
fi
expected=$(sed -nE "s/^[[:space:]]*local $var=\"([0-9.]+)\".*/\1/p" "$inc" | head -1)
if [[ -z "$expected" ]]; then
  echo "FAIL: could not read $var from $inc"
  exit 1
fi
echo "INFO: EL$el PHP $phpver expects libcurl $expected ($var)"
/usr/local/bin/php --ri curl
echo '---'
/usr/local/bin/php /home/php-curl-test.php "$expected"
