#!/bin/bash
# Checks a centmin.sh menu 5 upgrade to PHP 8.6 inside the Centmin Mod container:
#   docker exec -i cmm_el89 bash -s -- 8.6.0 /root/centminlogs/php86-menu5-upgrade.log < scripts/php86-menu5-check.sh
# PHP 8.6 differences it expects: memcache and mcrypt are skipped
# (PHPMEMCACHE_MAXVERNUM / PHPMCRYPT_MAXVERNUM = 80600), phpredis builds from
# its develop branch, and there is no swoole for PHP 8.6.
# Prints a markdown table and exits 1 if any check fails.

want_ver=${1:-8.6.0}
log=${2:-/root/centminlogs/php86-menu5-upgrade.log}
scandir=/etc/centminmod/php.d
IFS=. read -r v_major v_minor v_patch <<< "$want_ver"
want_vernum=$(printf '%d%02d%02d' "$v_major" "$v_minor" "$v_patch")
fails=0

# check <name> <detail> <test command...>: one table row per check
check() {
  local name=$1 detail=$2
  shift 2
  if "$@"; then
    printf '| %s | pass | %s |\n' "$name" "$detail"
  else
    printf '| %s | FAIL | %s |\n' "$name" "$detail"
    fails=$((fails + 1))
  fi
}
has_module() { php -m 2>/dev/null | grep -qix "$1"; }
lacks_module() { ! has_module "$1"; }
starts_with() { [[ $1 == "$2"* ]]; }

clean=$(mktemp)
sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\(B//g; s/\r$//' "$log" > "$clean" 2>/dev/null

echo '| Check | Result | Detail |'
echo '|---|---|---|'

check 'menu 5 output log' "$log" test -s "$log"

ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
check 'php version' "got ${ver:-none}, want $want_ver" test "$ver" = "$want_ver"

vernum=$(php-config --vernum 2>/dev/null)
check 'php-config --vernum' "got ${vernum:-none}, want $want_vernum" test "$vernum" = "$want_vernum"

fpm=$(/usr/local/sbin/php-fpm -v 2>/dev/null | head -n1)
check 'php-fpm -v' "${fpm:-none}" starts_with "$fpm" "PHP $want_ver (fpm-fcgi)"

startup=$(php -v 2>&1 | grep -ciE 'warning|deprecated|unable to load|fatal')
check 'no PHP startup messages' "$startup warning/deprecated/fatal lines in php -v" test "$startup" -eq 0

for svc in php-fpm nginx; do
  state=$(systemctl is-active "$svc" 2>/dev/null)
  check "$svc service" "${state:-unknown}" test "$state" = active
done

printf '<?php echo "menu5test ", PHP_VERSION, " ", PHP_SAPI, "\\n";\n' > /usr/local/nginx/html/php-menu5-test.php
resp=$(curl -s --max-time 60 -w 'http=%{http_code}' http://localhost/php-menu5-test.php)
curl_rc=$?
rm -f /usr/local/nginx/html/php-menu5-test.php
# a timed-out or truncated transfer can still print the expected text, so curl must exit 0
page_ok() { [ "$curl_rc" -eq 0 ] && starts_with "$resp" "menu5test $want_ver fpm-fcgi"$'\n'"http=200"; }
check 'PHP page via nginx' "curl exit $curl_rc, ${resp//$'\n'/ }" page_ok

check 'redis loaded' 'php -m' has_module redis
for ext in memcache mcrypt swoole; do
  check "$ext not loaded" 'php -m (no PHP 8.6 support upstream)' lacks_module "$ext"
  check "no $ext.ini" "$scandir" test ! -e "$scandir/$ext.ini"
done

check 'phpredis from develop' 'menu 5 output' \
  grep -qF 'Compiling PHP redis extension from phpredis develop branch' "$clean"
check 'memcache skipped' 'menu 5 output (PHPMEMCACHE_MAXVERNUM)' \
  grep -qF 'skipping memcache PHP extension' "$clean"
check 'mcrypt skipped' 'menu 5 output (PHPMCRYPT_MAXVERNUM)' \
  grep -qF 'skipping mcrypt PECL extension' "$clean"

fatal=$(grep -cE 'PHP configure failed|PHP make failed|\[FATAL\]|Aborting script' "$clean")
check 'no fatal markers' "$fatal lines: PHP configure/make failed, [FATAL], Aborting script" test "$fatal" -eq 0

echo
echo "Patching failed lines (not gated; the imagick PHP 8.4 patch failure is known and harmless):"
grep -n 'Patching failed' "$clean" || echo none
rm -f "$clean"

echo
echo "failed checks: $fails"
[ "$fails" -eq 0 ]
