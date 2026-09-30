#!/bin/bash
# Nginx ModSecurity feature checks. Run inside the installed Centmin Mod test container:
#   docker exec -i cmm_el89 bash -s < scripts/test-nginx-modsecurity.sh
# Temporarily switches SecRuleEngine to On to prove requests are blocked, then
# restores the original setting. Exits 1 if any FAIL line is printed.
set -uo pipefail
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
modsec_conf=/usr/local/nginx/modsec/modsecurity.conf
main_conf=/usr/local/nginx/modsec/main.conf
errlog=/usr/local/nginx/logs/error.log
vhost_log=/var/log/nginx/localhost.error.log
libmodsec=/usr/local/nginx-dep/lib/libmodsecurity.so
module=/usr/local/nginx/modules/ngx_http_modsecurity_module.so
failed=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
info() { echo "INFO: $*"; }
cfg() {
  local v
  v=$(sed -nE "s/^$1=['\"]?([^'\" ]*).*/\1/p" /etc/centminmod/custom_config.inc 2>/dev/null | tail -1)
  [[ -n "$v" ]] || v=$(sed -nE "s/^$1=['\"]?([^'\" ]*).*/\1/p" "$centmin_dir/centmin.sh" | head -1)
  echo "$v"
}
backup=$(mktemp)
[[ -f "$modsec_conf" ]] && cp -p "$modsec_conf" "$backup"
cleanup() {
  if [[ -s "$backup" ]]; then cp -p "$backup" "$modsec_conf"; nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; fi
  rm -f "$backup"
}
trap cleanup EXIT

crs_ver=$(cfg MODSECURITY_OWASPVER)
info "$(nginx -v 2>&1); expecting OWASP CRS $crs_ver"

# build checks
V=$(nginx -V 2>&1)
modopt=$(grep -oE -- '--add-(dynamic-)?module=[^ ]*ModSecurity-nginx[^ ]*' <<< "$V" | head -1)
[[ -n "$modopt" ]] && pass "nginx built with ModSecurity-nginx ($modopt)" || fail "ModSecurity-nginx not in nginx -V"
if [[ -f "$libmodsec" ]]; then
  pass "libmodsecurity installed ($(readlink -f "$libmodsec"))"
else
  fail "$libmodsec missing"
fi
if [[ "$modopt" == --add-dynamic-module=* ]]; then
  [[ -f "$module" ]] && pass "ngx_http_modsecurity_module.so installed" || fail "$module missing"
  if nginx -T 2>/dev/null | grep -qE '^[[:space:]]*load_module[^#]*ngx_http_modsecurity_module\.so'; then
    pass "load_module ngx_http_modsecurity_module.so active"
  else
    fail "no active load_module line for ngx_http_modsecurity_module.so"
  fi
fi
for f in "$module" /usr/local/sbin/nginx; do
  [[ -f "$f" ]] || continue
  if ldd "$f" 2>/dev/null | grep -q 'not found'; then
    fail "$f has unresolved libraries:"; ldd "$f" | grep 'not found'
  fi
done
T=$(nginx -T 2>/dev/null)
grep -qE '^[[:space:]]*modsecurity on;' <<< "$T" && pass "'modsecurity on;' active" || fail "'modsecurity on;' not active in nginx -T"
grep -qE "^[[:space:]]*modsecurity_rules_file[[:space:]]+$main_conf;" <<< "$T" && pass "modsecurity_rules_file $main_conf active" || fail "modsecurity_rules_file not active in nginx -T"
crs_dir=/usr/local/nginx/coreruleset-$crs_ver
[[ -f "$crs_dir/crs-setup.conf" ]] && pass "OWASP CRS $crs_ver installed" || fail "$crs_dir/crs-setup.conf missing"
grep -q "^Include $crs_dir/rules/\*\.conf" "$main_conf" 2>/dev/null && pass "main.conf includes CRS $crs_ver rules" || fail "main.conf does not include $crs_dir/rules/*.conf"
engine=$(awk '/^SecRuleEngine/ {print $2; exit}' "$modsec_conf" 2>/dev/null)
info "default SecRuleEngine: ${engine:-unset}"
nginx -t >/dev/null 2>&1 && pass "nginx -t" || { nginx -t; fail "nginx -t"; }
systemctl is-active --quiet nginx && pass "nginx service active" || fail "nginx service not active"

# runtime checks with the rule engine switched on
if [[ -f "$modsec_conf" ]]; then
  el0=$(wc -l < "$errlog" 2>/dev/null || echo 0)
  vl0=$(wc -l < "$vhost_log" 2>/dev/null || echo 0)
  sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' "$modsec_conf"
  if nginx -t >/dev/null 2>&1; then
    nginx -s reload; sleep 2
    normal=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://localhost/)
    xss=$(curl -s -m 10 -o /dev/null -w '%{http_code}' 'http://localhost/?q=%3Cscript%3Ealert(1)%3C/script%3E')
    sqli=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://localhost/?id=1%27%20OR%20%271%27=%271")
    [[ "$normal" = 200 ]] && pass "normal request HTTP 200" || fail "normal request HTTP $normal"
    [[ "$xss" = 403 ]] && pass "XSS request blocked (HTTP 403)" || fail "XSS request HTTP $xss (expected 403)"
    [[ "$sqli" = 403 ]] && pass "SQLi request blocked (HTTP 403)" || fail "SQLi request HTTP $sqli (expected 403)"
    denied=$(tail -n +$((vl0 + 1)) "$vhost_log" 2>/dev/null | grep -c 'ModSecurity: Access denied')
    [[ "$denied" -gt 0 ]] && pass "$vhost_log has $denied 'ModSecurity: Access denied' entries" || fail "no 'ModSecurity: Access denied' entries in $vhost_log"
    new_errors=$( { tail -n +$((el0 + 1)) "$errlog"; tail -n +$((vl0 + 1)) "$vhost_log"; } 2>/dev/null | grep -E '\[(crit|alert|emerg)\]')
    [[ -z "$new_errors" ]] && pass "no new crit/alert/emerg error.log entries" || { fail "new error.log entries:"; echo "$new_errors" | tail -5; }
  else
    nginx -t
    fail "nginx -t with SecRuleEngine On"
  fi
else
  fail "$modsec_conf missing; skipped blocking checks"
fi
[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
