#!/bin/bash
# config/nginx/mcp_proxy.conf and mcp_proxy_http.conf checks for 141.00beta01+.
# Run inside the test container after the install copied config/nginx to
# /usr/local/nginx/conf (maintenance_confcheck adds missing ones on upgrades):
#   docker exec cmm_el89 bash /opt/ci141/test-nginx-mcp-proxy.sh
# Phase 1 includes the shipped templates unchanged in a 127.0.0.1:8120 test
# server proxying to a loopback SSE backend. Phase 2 uses edited copies: one
# allowed browser origin and, on nginx built with the json module, the
# commented json_set Mcp-Method/Mcp-Name header check. The installed templates
# are never edited. Exits 1 if any FAIL line is printed.
set -uo pipefail
ci_dir=$(dirname "$(readlink -f "$0")")
conf_dir=/usr/local/nginx/conf
vhost=$conf_dir/conf.d/zz-ci141-mcp.conf
copies=$conf_dir/ci141-mcp
tmpl_http=$conf_dir/mcp_proxy_http.conf
tmpl_loc=$conf_dir/mcp_proxy.conf
work=$(mktemp -d /root/ci141-mcp.XXXXXX)
failed=0
backend_pid=''
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
info() { echo "INFO: $*"; }
cleanup() {
  rm -f "$vhost"
  [[ -n "$backend_pid" ]] && kill "$backend_pid" 2>/dev/null
  nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1
  rm -rf "$copies" "$work"
}
trap cleanup EXIT
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }
expect_code() {
  local what=$1 want=$2 got
  shift 2
  got=$(code "$@")
  [[ "$got" = "$want" ]] && pass "$what: HTTP $got" || fail "$what: HTTP $got, expected $want"
}
# write_vhost <http template> <location template> [extra server lines]
write_vhost() {
  cat > "$vhost" <<NGX
include $1;
upstream ci141_mcp_backend {
  server 127.0.0.1:18000;
}
server {
  listen 127.0.0.1:8120;
  $3
  location /mcp {
    include $2;
    proxy_pass http://ci141_mcp_backend;
  }
}
NGX
  if nginx -t > "$work/t.log" 2>&1; then
    nginx -s reload
    sleep 2
    return 0
  fi
  tail -5 "$work/t.log"
  return 1
}
body='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_weather"}}'
post() { curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data "$body" "$@" http://127.0.0.1:8120/mcp; }

for f in "$tmpl_http" "$tmpl_loc"; do
  [[ -f "$f" ]] && pass "$f" || fail "$f missing (not copied from config/nginx at install or by maintenance_confcheck)"
done
if [[ "$failed" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
python3 "$ci_dir/test-nginx-141-backend.py" 18000 sse < /dev/null > /dev/null 2>&1 &
backend_pid=$!
sleep 1

echo "== phase 1: shipped templates"
if write_vhost "$tmpl_http" "$tmpl_loc"; then
  pass "nginx -t with the shipped mcp_proxy_http.conf and mcp_proxy.conf"
  first=$(timeout 2 curl -sN http://127.0.0.1:8120/mcp)
  grep -q 'data: first' <<< "$first" && pass "SSE: first event arrives before the stream ends (unbuffered)" || fail "SSE: no event within 2s, output '$first'"
  full=$(curl -sN -m 10 http://127.0.0.1:8120/mcp)
  grep -q 'data: second' <<< "$full" && pass "SSE: whole stream proxied" || fail "SSE: stream output '$full'"
  expect_code "PUT" 405 -X PUT http://127.0.0.1:8120/mcp
  expect_code "POST from a disallowed Origin" 403 -X POST -H 'Origin: https://evil.example' --data "$body" http://127.0.0.1:8120/mcp
  got=$(post)
  [[ "$got" = 200 ]] && pass "POST without Origin: HTTP 200" || fail "POST without Origin: HTTP $got"
else
  fail "nginx -t rejects the shipped MCP templates"
fi

echo "== phase 2: allowed origin and optional json_set header check"
mkdir -p "$copies"
sed -E 's|^([[:space:]]*)#("https://app\.example\.com")|\1\2|' "$tmpl_http" > "$copies/mcp_proxy_http.conf"
json=n
nginx -V 2>&1 | grep -q -- '--with-http_json_module' && json=y
extra=''
if [[ "$json" = y ]]; then
  sed -i -E '/^#map "\$request_method:\$uri" \$mcp_body_early_read/,$ s/^#//' "$copies/mcp_proxy_http.conf"
  sed -E '/^# Optional header check/,/^$/{/^# Optional header check/!s/^#//;}' "$tmpl_loc" > "$copies/mcp_proxy.conf"
  extra='client_body_early_read $mcp_body_early_read; client_body_buffer_size 1m;'
else
  cp "$tmpl_loc" "$copies/mcp_proxy.conf"
  info "nginx built without --with-http_json_module, json_set header check skipped"
fi
if write_vhost "$copies/mcp_proxy_http.conf" "$copies/mcp_proxy.conf" "$extra"; then
  pass "nginx -t with the edited copies (json check: $json)"
  got=$(post -H 'Origin: https://app.example.com')
  [[ "$got" = 200 ]] && pass "POST from the allowed Origin: HTTP 200" || fail "POST from the allowed Origin: HTTP $got"
  if [[ "$json" = y ]]; then
    got=$(post -H 'Mcp-Method: tools/call' -H 'Mcp-Name: get_weather')
    [[ "$got" = 200 ]] && pass "matching Mcp-Method and Mcp-Name: HTTP 200" || fail "matching Mcp-Method and Mcp-Name: HTTP $got"
    got=$(post -H 'Mcp-Method: tools/call' -H 'Mcp-Name: other')
    [[ "$got" = 400 ]] && pass "Mcp-Name differing from the body: HTTP 400" || fail "Mcp-Name differing from the body: HTTP $got, expected 400"
    got=$(post -H 'Mcp-Method: tools/list' -H 'Mcp-Name: get_weather')
    [[ "$got" = 400 ]] && pass "Mcp-Method differing from the body: HTTP 400" || fail "Mcp-Method differing from the body: HTTP $got, expected 400"
    got=$(post -H 'Mcp-Method: tools/call' -H 'Mcp-Name: =?base64?Zm9v?=')
    [[ "$got" = 200 ]] && pass "Base64 Mcp-Name left to the MCP server: HTTP 200" || fail "Base64 Mcp-Name: HTTP $got, expected 200"
    got=$(post)
    [[ "$got" = 200 ]] && pass "no Mcp headers: HTTP 200" || fail "no Mcp headers: HTTP $got"
  fi
else
  fail "nginx -t rejects the edited MCP template copies"
fi

[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
