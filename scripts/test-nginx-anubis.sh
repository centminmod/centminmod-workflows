#!/bin/bash
# addons/anubis.sh checks for 141.00beta01+. Needs nginx built with
# NGINX_AUTHREQ='y'. Run inside the test container:
#   docker exec cmm_el89 bash /opt/ci141/test-nginx-anubis.sh
# Installs Anubis, protects a temporary 127.0.0.1:8130 server with the shipped
# anubis.conf and anubis_check.conf (next to drop.conf and staticfiles.conf, as
# in a Centmin Mod vhost), checks the challenge redirect, the policy and the
# uninstall guard, then uninstalls Anubis. A real browser passing the
# proof-of-work challenge is not tested. Exits 1 if any FAIL line is printed.
set -uo pipefail
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
addon=$centmin_dir/addons/anubis.sh
conf_dir=/usr/local/nginx/conf
vhost=$conf_dir/conf.d/zz-ci141-anubis.conf
site=$conf_dir/ci141-anubis
env_file=/etc/anubis/centminmod.env
policy=/etc/anubis/centminmod.botPolicies.yaml
service=anubis@centminmod
work=$(mktemp -d /root/ci141-anubis.XXXXXX)
failed=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }
cleanup() {
  rm -f "$vhost"
  nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1
  rm -rf "$site" "$work"
}
trap cleanup EXIT
browser='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'
gptbot='Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.1; +https://openai.com/gptbot)'

if [[ ! -f "$addon" ]]; then
  fail "$addon missing"
  echo "RESULT: FAIL"
  exit 1
fi
ver=$(sed -nE "s/^ANUBIS_VER_DEFAULT='([^']+)'.*/\1/p" "$addon")
port=$(sed -nE "s/^ANUBIS_PORT='([0-9]+)'.*/\1/p" "$addon")
mport=$(sed -nE "s/^ANUBIS_METRICS_PORT='([0-9]+)'.*/\1/p" "$addon")
# anubis.sh sources /etc/centminmod/custom_config.inc after these defaults, so
# ANUBIS_VER, ANUBIS_PORT and ANUBIS_METRICS_PORT set there win. tail: the
# values are the last line, whatever the sourced file prints
read -r ver port mport < <(ANUBIS_VER=$ver ANUBIS_PORT=$port ANUBIS_METRICS_PORT=$mport bash -c '
  [[ -f /etc/centminmod/custom_config.inc ]] && source /etc/centminmod/custom_config.inc
  echo "$ANUBIS_VER $ANUBIS_PORT $ANUBIS_METRICS_PORT"' | tail -n 1)
echo "== anubis.sh install (Anubis $ver, 127.0.0.1:$port, metrics :$mport)"
nginx -V 2>&1 | grep -q -- '--with-http_auth_request_module' && pass "nginx has auth_request" || fail "nginx lacks auth_request (NGINX_AUTHREQ='y' expected)"
bash "$addon" install < /dev/null > "$work/install.log" 2>&1
st=$?
tail -15 "$work/install.log"
[[ "$st" -eq 0 ]] && pass "anubis.sh install exit 0" || fail "anubis.sh install exit $st"
grep -q 'nginx has the auth_request module' "$work/install.log" && pass "install reports nginx auth_request" || fail "install did not report nginx auth_request"
rpm -q anubis 2>/dev/null | grep -q "^anubis-${ver}-" && pass "$(rpm -q anubis)" || fail "anubis-$ver RPM not installed: $(rpm -q anubis 2>&1)"
systemctl is-active --quiet "$service" && pass "$service active" || fail "$service not active"
[[ "$(stat -c %a "$env_file" 2>/dev/null)" = 600 ]] && pass "$env_file mode 600" || fail "$env_file mode $(stat -c %a "$env_file" 2>&1)"
for want in "BIND=127.0.0.1:$port" "METRICS_BIND=127.0.0.1:$mport" 'TARGET=" "' "POLICY_FNAME=$policy"; do
  grep -qxF -- "$want" "$env_file" && pass "env: $want" || fail "env: no '$want' line"
done
grep -qE '^ED25519_PRIVATE_KEY_HEX=[0-9a-f]{64}$' "$env_file" && pass "env: persistent ED25519 signing key" || fail "env: no ED25519_PRIVATE_KEY_HEX"
grep -A2 '^status_codes:' "$policy" 2>/dev/null | grep -qE '^[[:space:]]*DENY: 403' && pass "policy: status_codes DENY: 403" || fail "policy: no DENY: 403 under status_codes"
listen=$(ss -Hlntp 2>/dev/null | grep -i anubis | awk '{print $4}')
if [[ -n "$listen" ]] && ! grep -qv '^127\.0\.0\.1:' <<< "$listen"; then
  pass "listeners on loopback only: $(echo $listen)"
else
  fail "anubis listeners: '$(echo $listen)'"
fi
for f in anubis.conf anubis_check.conf; do
  [[ -f "$conf_dir/$f" ]] && pass "$conf_dir/$f" || fail "$conf_dir/$f missing"
done

echo "== protected test server"
mkdir -p "$site"
echo "protected page" > "$site/index.txt"
printf 'User-agent: *\nDisallow:\n' > "$site/robots.txt"
{
  echo 'server {'
  echo '  listen 127.0.0.1:8130;'
  echo '  server_name ci141-anubis.test;'
  echo "  root $site;"
  for f in drop.conf staticfiles.conf; do
    [[ -f "$conf_dir/$f" ]] && echo "  include $conf_dir/$f;"
  done
  echo "  include $conf_dir/anubis.conf;"
  echo "  include $conf_dir/anubis_check.conf;"
  echo '  location = / { default_type text/plain; try_files /index.txt =404; }'
  echo '}'
} > "$vhost"
if nginx -t > "$work/t.log" 2>&1; then
  pass "nginx -t with anubis.conf and anubis_check.conf"
  nginx -s reload
  sleep 2
  out=$(curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' -A "$browser" http://127.0.0.1:8130/)
  [[ "$out" == "307 "*"/.within.website/?redir="* ]] && pass "browser user agent redirected to the challenge: $out" || fail "browser user agent: '$out', expected 307 to /.within.website/?redir="
  got=$(code -A "$browser" http://127.0.0.1:8130/.within.website/x/cmd/anubis/static/js/main.mjs)
  [[ "$got" = 200 ]] && pass "Anubis static asset HTTP 200 (not taken by drop.conf or staticfiles.conf)" || fail "Anubis static asset HTTP $got"
  got=$(code -A "$browser" http://127.0.0.1:8130/robots.txt)
  [[ "$got" = 200 ]] && pass "robots.txt HTTP 200 (policy allow via X-Original-URI)" || fail "robots.txt HTTP $got"
  got=$(code -A "$gptbot" http://127.0.0.1:8130/)
  [[ "$got" = 403 ]] && pass "GPTBot HTTP 403 (policy DENY)" || fail "GPTBot HTTP $got, expected 403"
else
  fail "nginx -t rejects the anubis test server:"
  tail -5 "$work/t.log"
fi

echo "== anubis.sh status"
bash "$addon" status < /dev/null > "$work/status.log" 2>&1
cat "$work/status.log"
grep -q "service: $service active" "$work/status.log" && pass "status: service active" || fail "status: service not reported active"
grep -qF "$vhost" "$work/status.log" && pass "status lists $vhost" || fail "status does not list $vhost"

echo "== anubis.sh uninstall"
bash "$addon" uninstall < /dev/null > "$work/uninstall1.log" 2>&1
st=$?
[[ "$st" -ne 0 ]] && pass "uninstall refused while a vhost includes anubis*.conf (exit $st)" || fail "uninstall ran while $vhost includes anubis*.conf"
systemctl is-active --quiet "$service" && pass "$service still active after the refusal" || fail "$service stopped by a refused uninstall"
rm -f "$vhost"
nginx -t > /dev/null 2>&1 && nginx -s reload
bash "$addon" uninstall < /dev/null > "$work/uninstall2.log" 2>&1
st=$?
tail -6 "$work/uninstall2.log"
[[ "$st" -eq 0 ]] && pass "uninstall exit 0 once no vhost includes anubis*.conf" || fail "uninstall exit $st"
rpm -q anubis > /dev/null 2>&1 && fail "anubis RPM still installed" || pass "anubis RPM removed"
for f in "$env_file" "$policy" "$conf_dir/anubis.conf" "$conf_dir/anubis_check.conf"; do
  [[ -f "$f" ]] && pass "kept $f" || fail "$f removed by uninstall"
done

[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
