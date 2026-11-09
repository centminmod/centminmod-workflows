#!/bin/bash
# Centmin Mod 141.00beta01 nginx feature checks, driven by the toggles in
# effect: the last value in /etc/centminmod/custom_config.inc, else the
# centmin.sh default. A module whose toggle is 'y' must be built, loaded and
# answer requests; one whose toggle is 'n' must be absent. Copied into the test
# container by .github/workflows/almalinux10-nginx-features.yml and run after
# the install and after each nginx rebuild:
#   docker exec cmm_el89 bash /opt/ci141/test-nginx-141-features.sh <label>
# /root/ci-nginx-build.log holds the output of the build being checked.
# Exits 1 if any FAIL line is printed.
set -uo pipefail
label=${1:-checks}
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
ci_dir=$(dirname "$(readlink -f "$0")")
build_log=/root/ci-nginx-build.log
conf_dir=/usr/local/nginx/conf
conf_d=$conf_dir/conf.d
ci_conf=$conf_dir/ci141
mod_dir=/usr/local/nginx/modules
errlog=/usr/local/nginx/logs/error.log
lualib=/usr/local/nginx-dep/lib/lua/5.1
work=$(mktemp -d /root/ci141-features.XXXXXX)
failed=0
backend_pids=()
nginx_conf_backup=''
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
info() { echo "INFO: $*"; }
cfg() {
  local v
  v=$(sed -nE "s/^$1=['\"]?([^'\" ]*).*/\1/p" /etc/centminmod/custom_config.inc 2>/dev/null | tail -1)
  [[ -n "$v" ]] || v=$(sed -nE "s/^$1=['\"]?([^'\" ]*).*/\1/p" "$centmin_dir/centmin.sh" | head -1)
  echo "$v"
}
on() { [[ "$(cfg "$1")" = [yY] ]]; }
verno() { awk -F. '{printf "%d", $1*1000000 + $2*1000 + $3}' <<< "$1"; }
re() { sed 's/[\\.*^$()+?{|[]/\\&/g' <<< "$1"; }
modopt() { grep -oE -- "--add-(dynamic-)?module=[^ ]*$1[^ ]*" <<< "$V" | head -1; }
load_count() { grep -cE "^[[:space:]]*load_module[^#]*/$(re "$1")\"?;" <<< "$T"; }
code() { curl -s -m "${CURL_MAX:-10}" -o /dev/null -w '%{http_code}' "$@"; }
expect_code() {
  local what=$1 want=$2 got
  shift 2
  got=$(code "$@")
  [[ "$got" = "$want" ]] && pass "$what: HTTP $got" || fail "$what: HTTP $got, expected $want"
}
in_log() { grep -qE -- "$1" "$work/build.log"; }

cleanup() {
  rm -f "$conf_d"/zz-ci141-*.conf
  [[ -n "$nginx_conf_backup" ]] && cp -p "$nginx_conf_backup" "$conf_dir/nginx.conf"
  local p
  for p in "${backend_pids[@]}"; do kill "$p" 2>/dev/null; done
  nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1
  rm -rf "$work" "$ci_conf" /usr/local/nginx/ci141-cache
}
trap cleanup EXIT

# add_conf <name>: test config from stdin to conf.d (http level), @CI@ is
# replaced by $ci_conf. Kept when nginx -t accepts it, else removed with a FAIL
add_conf() {
  local f="$conf_d/zz-ci141-$1.conf"
  sed "s|@CI@|$ci_conf|g" > "$f"
  if nginx -t > "$work/t.log" 2>&1; then
    return 0
  fi
  fail "$1: nginx -t rejects the test config:"
  tail -5 "$work/t.log" | sed 's/^/  /'
  rm -f "$f"
  return 1
}
start_backend() {
  python3 "$ci_dir/test-nginx-141-backend.py" "$1" "${2:-ok}" < /dev/null > /dev/null 2>&1 &
  backend_pids+=("$!")
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.1
  done
  fail "test backend on 127.0.0.1:$1 did not start"
  return 1
}
# module_present <label> <dir pattern> <version string> <y|n|any dynamic> [module.so...]
module_present() {
  local what=$1 pat=$2 want=$3 dyn=$4 opt so n
  shift 4
  opt=$(modopt "$pat")
  if [[ -z "$opt" ]]; then
    fail "$what: no --add-module or --add-dynamic-module for $pat in nginx -V"
    return 1
  fi
  [[ "$opt" == *"$want"* ]] && pass "$what: $opt" || fail "$what: $opt is not $want"
  if [[ "$dyn" = n ]]; then
    [[ "$opt" == --add-module=* ]] || fail "$what: expected a static module, got $opt"
    return 0
  fi
  if [[ "$dyn" = y && "$opt" != --add-dynamic-module=* ]]; then
    fail "$what: expected a dynamic module, got $opt"
  fi
  for so in "$@"; do
    if [[ -f "$mod_dir/$so" ]]; then
      pass "$what: $so installed ($(du -h "$mod_dir/$so" | cut -f1))"
      if ldd "$mod_dir/$so" 2>/dev/null | grep -q 'not found'; then
        fail "$what: $so has unresolved libraries:"
        ldd "$mod_dir/$so" | grep 'not found' | sed 's/^/  /'
      fi
    else
      fail "$what: $mod_dir/$so missing"
    fi
    n=$(load_count "$so")
    [[ "$n" -eq 1 ]] && pass "$what: load_module $so active once" || fail "$what: load_module $so active $n times"
  done
}
# module_absent <label> <dir pattern> [module.so...]
module_absent() {
  local what=$1 pat=$2 so n
  shift 2
  [[ -z "$(modopt "$pat")" ]] && pass "$what off: not in nginx -V" || fail "$what off: $(modopt "$pat") in nginx -V"
  if on NGXDYNAMIC_MANUALOVERRIDE; then
    info "$what off: NGXDYNAMIC_MANUALOVERRIDE='y', module files not checked"
    return 0
  fi
  for so in "$@"; do
    [[ ! -e "$mod_dir/$so" && ! -e "$mod_dir/$so.old" ]] && pass "$what off: no $so or $so.old" || fail "$what off: $mod_dir/$so or .old left behind"
    n=$(load_count "$so")
    [[ "$n" -eq 0 ]] && pass "$what off: no load_module $so" || fail "$what off: load_module $so active $n times"
  done
}

V=$(nginx -V 2>&1)
T=$(nginx -T 2>/dev/null)
ngx_v=$(nginx -v 2>&1)
if grep -qi 'angie' <<< "$ngx_v"; then
  core=angie
elif grep -qi 'freenginx' <<< "$ngx_v"; then
  core=freenginx
else
  core=nginx
fi
core_ver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$ngx_v" | head -1)
cv=$(verno "$core_ver")
mkdir -p "$ci_conf"
echo "== $label: $ngx_v (core $core)"

echo "== toggles: each one this script reads must exist in centmin.sh"
known=(NGINX_JSON NGINX_ANGIE_ACME NGINX_ANGIE_VERSION FREENGINX_INSTALL FREENGINX_VERSION
  NGINX_NJS NGINX_NJS_VER NGINX_NJS_QUICKJS NGINX_NJS_QUICKJS_VER NGXDYNAMIC_NJS
  NGINX_CACHEPURGE NGINX_CACHEPURGEVER ORESTY_HEADERSMORE ORESTY_HEADERSMOREGIT NGINX_HEADERSMORE
  NGINX_OPENRESTY ORESTY_ECHOGIT ORESTY_ECHOVER NGINX_HTTPREDIS NGINX_HTTPREDISVER
  ORESTY_LUANGINX ORESTY_LUALIMITTRAFFIC ORESTY_LUALIMITTRAFFICVER ORESTY_LUAHTTP ORESTY_LUAHTTPVER
  ORESTY_LUAOPENSSL ORESTY_LUAOPENSSLVER ORESTY_LUAPROMETHEUS ORESTY_LUAPROMETHEUSVER ORESTY_LUAJA4 ORESTY_LUAJA4VER
  NGINX_AUTHJWT NGINX_AUTHJWTVER NGXDYNAMIC_AUTHJWT NGINX_KEYVAL NGINX_KEYVALVER NGINX_KEYVAL_REDIS NGXDYNAMIC_KEYVAL
  NGINX_RATELIMIT NGINX_RATELIMITCOMMIT NGXDYNAMIC_RATELIMIT NGINX_OTEL NGINX_OTELVER
  NGINX_RTMP NGINX_VIDEO NGINX_RTMP_HTTPFLV NGINX_RTMP_HTTPFLVVER NGINX_UPSTREAMCHECK NGINX_UPSTREAMCHECKCOMMIT
  NGINX_STICKY NGINX_TLS_FINGERPRINT NGXDYNAMIC_MANUALOVERRIDE)
missing=0
for t in "${known[@]}"; do
  grep -q "^${t}=" "$centmin_dir/centmin.sh" || { fail "toggle $t is not defined in $centmin_dir/centmin.sh (renamed, or this Centmin Mod predates it)"; missing=1; }
done
[[ "$missing" -eq 0 ]] && pass "all ${#known[@]} toggles defined in centmin.sh"
enabled=()
for t in "${known[@]}"; do
  [[ "$t" = *VER || "$t" = *VERSION || "$t" = *COMMIT ]] && continue
  on "$t" && enabled+=("$t")
done
info "toggles on: ${enabled[*]}"

echo "== nginx service and build log"
nginx -t > /dev/null 2>&1 && pass "nginx -t" || { nginx -t; fail "nginx -t"; }
systemctl is-active --quiet nginx && pass "nginx service active" || fail "nginx service not active"
expect_code "default site" 200 http://127.0.0.1/
if [[ -s "$build_log" ]]; then
  # ANSI colours from cecho would hide the start of a line from the patterns
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\(B//g; s/\\E\[[0-9;]*m//g; s/\r$//' "$build_log" > "$work/build.log"
  markers=$(grep -nE 'Patching failed|Aborting script|Hunk #[0-9]+ FAILED|saving rejects to file|Nginx configure failed|Nginx make failed|(^|[^A-Za-z])ERROR: ' "$work/build.log" | head -20)
  if [[ -z "$markers" ]]; then
    pass "no abort, patch failure or ERROR: markers in the build log"
  else
    fail "abort, patch failure or ERROR: markers in the build log:"
    echo "$markers" | sed 's/^/  /'
  fi
  info "$(grep -cE '(^|[^A-Za-z])Error: ' "$work/build.log") 'Error:' lines in the build log (dnf 'Unable to find a match' lines are normal)"
else
  fail "$build_log missing or empty"
  : > "$work/build.log"
fi

echo "== core version"
if [[ "$core" = angie ]]; then
  want=$(cfg NGINX_ANGIE_VERSION)
  grep -qiF "Angie/${want#Angie-}" <<< "$ngx_v" && pass "Angie ${want#Angie-}" || fail "nginx -v '$ngx_v' is not $want"
elif on FREENGINX_INSTALL; then
  want=$(cfg FREENGINX_VERSION)
  [[ "$core" = freenginx && "$core_ver" = "$want" ]] && pass "freenginx $want" || fail "FREENGINX_INSTALL='y' but nginx -v is '$ngx_v', expected freenginx/$want"
else
  info "nginx $core_ver"
fi

echo "== pinned module versions"
if on NGINX_CACHEPURGE; then
  module_present ngx_cache_purge ngx_cache_purge "ngx_cache_purge-$(cfg NGINX_CACHEPURGEVER)" any
  src="/svr-setup/ngx_cache_purge-$(cfg NGINX_CACHEPURGEVER)/ngx_cache_purge_module.c"
  if [[ "$core" = freenginx ]]; then
    if [[ ! -f "$src" ]]; then
      fail "ngx_cache_purge: $src missing, freenginx struct guard not checked"
    elif grep -q '^#  if (nginx_version >= 1029004)' "$src"; then
      grep -qF '#  if (nginx_version >= 1029004) && !defined(freenginx)' "$src" && pass "ngx_cache_purge: freenginx struct guard applied" || fail "ngx_cache_purge: freenginx struct guard missing in $src"
    else
      info "ngx_cache_purge: no nginx_version >= 1029004 guard in $src"
    fi
  fi
fi
if on ORESTY_HEADERSMORE && ! on ORESTY_HEADERSMOREGIT; then
  module_present headers-more headers-more-nginx-module "headers-more-nginx-module-$(cfg NGINX_HEADERSMORE)" any
fi
if on NGINX_OPENRESTY && ! on ORESTY_ECHOGIT; then
  module_present echo echo-nginx-module "echo-nginx-module-$(cfg ORESTY_ECHOVER)" any
fi
if on NGINX_HTTPREDIS; then
  module_present ngx_http_redis ngx_http_redis "ngx_http_redis-$(cfg NGINX_HTTPREDISVER)" any
fi

echo "== NGINX_JSON and NGINX_ANGIE_ACME"
json_expected=n
if on NGINX_JSON && [[ "$core" = nginx ]] && (( cv >= 1031005 )); then
  json_expected=y
fi
if [[ "$json_expected" = y ]]; then
  grep -q -- '--with-http_json_module' <<< "$V" && pass "--with-http_json_module" || fail "NGINX_JSON='y' on nginx $core_ver but no --with-http_json_module"
else
  grep -q -- '--with-http_json_module' <<< "$V" && fail "--with-http_json_module on $core $core_ver (NGINX_JSON='$(cfg NGINX_JSON)')" || pass "no --with-http_json_module ($core $core_ver, NGINX_JSON='$(cfg NGINX_JSON)')"
fi
if [[ "$core" = angie ]] && on NGINX_ANGIE_ACME; then
  grep -q -- '--with-http_acme_module' <<< "$V" && pass "Angie --with-http_acme_module" || fail "NGINX_ANGIE_ACME='y' Angie build without --with-http_acme_module"
else
  grep -q -- '--with-http_acme_module' <<< "$V" && fail "--with-http_acme_module on $core (NGINX_ANGIE_ACME='$(cfg NGINX_ANGIE_ACME)')" || pass "no --with-http_acme_module ($core)"
fi
if ss -Hlunp 'sport = :53' 2>/dev/null | grep -qE '"(nginx|angie)"'; then
  fail "nginx listens on UDP port 53 without an acme_client"
else
  pass "no nginx UDP :53 listener"
fi

echo "== NGINX_NJS and NGINX_NJS_QUICKJS"
rt_njs=n rt_qjs=n
if on NGINX_NJS; then
  if on NGXDYNAMIC_NJS; then
    module_present njs 'njs/nginx' njs y ngx_http_js_module.so
  else
    module_present njs 'njs/nginx' njs n
  fi
  cat > "$ci_conf/ci141.js" <<'JS'
function hi(r) {
  r.return(200, 'version=' + njs.version + ' map=' + (typeof Map) + '\n');
}
export default { hi };
JS
  add_conf njs <<'NGX' && rt_njs=y
server {
  listen 127.0.0.1:8107;
  location = /njs { js_import ci141n from @CI@/ci141.js; js_content ci141n.hi; }
}
NGX
  qjs_conf='server {
  listen 127.0.0.1:8108;
  location = /qjs { js_engine qjs; js_import ci141q from @CI@/ci141.js; js_content ci141q.hi; }
}'
  if on NGINX_NJS_QUICKJS; then
    qver=$(cfg NGINX_NJS_QUICKJS_VER)
    in_log "QuickJS $(re "$qver") libquickjs\.a ready" && pass "QuickJS $qver libquickjs.a built" || fail "build log has no 'QuickJS $qver libquickjs.a ready'"
    in_log "njs QuickJS engine enabled" && pass "build log: njs QuickJS engine enabled" || fail "build log has no 'njs QuickJS engine enabled'"
    got=$(ls -A /svr-setup/njs-quickjs 2>/dev/null | sort | xargs)
    if [[ -f /root/ci141-expected-fail ]]; then
      # an expected-fail rebuild (nginx-141-rebuild.sh) removed the QuickJS
      # build dir before aborting; the running nginx is still the earlier build
      info "/svr-setup/njs-quickjs holds '$got' after an expected-fail rebuild ($(cat /root/ci141-expected-fail)), not checked"
    elif [[ "$label" = install ]]; then
      # the install ends with disk_cleanups (inc/centminfinish.inc), which
      # deletes every folder in /svr-setup; menu 4 rebuilds keep it
      info "/svr-setup/njs-quickjs holds '$got' after the install's /svr-setup cleanup, not checked"
    else
      [[ "$got" = 'libquickjs.a quickjs.h' ]] && pass "/svr-setup/njs-quickjs holds only quickjs.h and libquickjs.a" || fail "/svr-setup/njs-quickjs holds '$got'"
    fi
    if [[ -f "$mod_dir/ngx_http_js_module.so" ]] && on NGXDYNAMIC_NJS; then
      ldd "$mod_dir/ngx_http_js_module.so" | grep -qi quickjs && fail "ngx_http_js_module.so links a shared QuickJS" || pass "ngx_http_js_module.so has QuickJS linked in statically"
    fi
    add_conf qjs <<< "$qjs_conf" && rt_qjs=y
  else
    sed "s|@CI@|$ci_conf|g" <<< "$qjs_conf" > "$conf_d/zz-ci141-qjs-off.conf"
    nginx -t > /dev/null 2>&1 && fail "NGINX_NJS_QUICKJS='n' but 'js_engine qjs;' passes nginx -t" || pass "NGINX_NJS_QUICKJS='n': 'js_engine qjs;' fails nginx -t"
    rm -f "$conf_d/zz-ci141-qjs-off.conf"
  fi
else
  module_absent njs 'njs/nginx'
fi

echo "== NGINX_CACHEPURGE, headers-more and echo runtime"
rt_purge=n rt_hm=n rt_echo=n
if [[ -n "$(modopt ngx_cache_purge)" ]]; then
  add_conf cachepurge <<'NGX' && rt_purge=y
proxy_cache_path /usr/local/nginx/ci141-cache levels=1 keys_zone=ci141_purge:1m inactive=10m;
server {
  listen 127.0.0.1:8102;
  location / { default_type text/plain; return 200 "cache backend\n"; }
}
server {
  listen 127.0.0.1:8101;
  location /c/ {
    proxy_pass http://127.0.0.1:8102;
    proxy_cache ci141_purge;
    proxy_cache_key $uri;
    proxy_cache_valid 200 10m;
    proxy_ignore_headers Cache-Control Expires Set-Cookie;
    add_header X-CI141-Cache $upstream_cache_status always;
  }
  location ~ ^/purge(/.*)$ {
    proxy_cache_purge ci141_purge $1;
  }
}
NGX
fi
if [[ -n "$(modopt headers-more-nginx-module)" ]]; then
  add_conf headersmore <<'NGX' && rt_hm=y
server {
  listen 127.0.0.1:8104;
  location = /ct { default_type 'Text/HTML; charset=utf-8'; return 200 "content type test\n"; }
}
server {
  listen 127.0.0.1:8103;
  location = /hm {
    proxy_pass http://127.0.0.1:8104/ct;
    more_set_headers -t 'text/html' 'X-CI141-HM: matched';
  }
}
NGX
fi
if [[ -n "$(modopt echo-nginx-module)" ]]; then
  add_conf echo <<'NGX' && rt_echo=y
server {
  listen 127.0.0.1:8105;
  location = /echo { echo "echo-ok"; }
}
NGX
fi
rt_json=n
if [[ "$json_expected" = y ]]; then
  add_conf json <<'NGX' && rt_json=y
map $request_method $ci141_json_early {
  default 0;
  POST    1;
}
json_set $ci141_j_method $request_body method;
server {
  listen 127.0.0.1:8106;
  client_body_early_read $ci141_json_early;
  location = /j { return 200 "$ci141_j_method\n"; }
}
NGX
fi

echo "== ORESTY_LUANGINX optional Lua libraries"
rt_lua=n rt_ja4=n
declare -A lua_name=([ORESTY_LUALIMITTRAFFIC]=lua-resty-limit-traffic [ORESTY_LUAHTTP]=lua-resty-http
  [ORESTY_LUAOPENSSL]=lua-resty-openssl [ORESTY_LUAPROMETHEUS]=nginx-lua-prometheus [ORESTY_LUAJA4]=lua-resty-ja4)
declare -A lua_files=([ORESTY_LUALIMITTRAFFIC]='resty/limit/req.lua resty/limit/conn.lua resty/limit/count.lua resty/limit/traffic.lua'
  [ORESTY_LUAHTTP]='resty/http.lua resty/http_headers.lua resty/http_connect.lua'
  [ORESTY_LUAOPENSSL]='resty/openssl.lua resty/openssl'
  [ORESTY_LUAPROMETHEUS]='prometheus.lua prometheus_keys.lua prometheus_resty_counter.lua'
  [ORESTY_LUAJA4]='resty/ja4.lua resty/ja4h.lua resty/ja4')
lua_extras=(ORESTY_LUALIMITTRAFFIC ORESTY_LUAHTTP ORESTY_LUAOPENSSL ORESTY_LUAPROMETHEUS ORESTY_LUAJA4)
if on ORESTY_LUANGINX && [[ -n "$(modopt lua-nginx-module)" ]]; then
  for t in "${lua_extras[@]}"; do
    name=${lua_name[$t]}
    ver=$(cfg "${t}VER")
    if on "$t"; then
      in_log "$(re "$name $ver") installed" && pass "$t: $name $ver installed" || fail "$t: build log has no '$name $ver installed'"
      for f in ${lua_files[$t]}; do
        [[ -e "$lualib/$f" ]] && pass "$t: $lualib/$f" || fail "$t: $lualib/$f missing"
      done
    else
      f=${lua_files[$t]%% *}
      [[ ! -e "$lualib/$f" ]] && pass "$t off: no $f" || fail "$t off: $lualib/$f installed"
    fi
  done
  in_log "ORESTY_LUAJA4='y' skipped" && fail "lua-resty-ja4 skipped: lua-resty-core older than 0.1.32"
  {
    on ORESTY_LUALIMITTRAFFIC && echo 'lua_shared_dict ci141_limit 1m;'
    if on ORESTY_LUAPROMETHEUS; then
      echo 'lua_shared_dict prometheus_metrics 10m;'
      echo 'init_worker_by_lua_block {'
      echo '  ci141_prometheus = require("prometheus").init("prometheus_metrics")'
      echo '  ci141_requests = ci141_prometheus:counter("nginx_http_requests_total", "Number of HTTP requests", {"host"})'
      echo '}'
    fi
    echo 'server {'
    echo '  listen 127.0.0.1:8109;'
    echo '  server_name ci141-lua;'
    on ORESTY_LUAPROMETHEUS && echo '  log_by_lua_block { ci141_requests:inc(1, {ngx.var.server_name}) }'
    on ORESTY_LUALIMITTRAFFIC && echo '  location = /lim { content_by_lua_block { local lim = require "resty.limit.req"; local l, err = lim.new("ci141_limit", 10, 5); ngx.say(type(lim.new), " ", l and "ok" or err) } }'
    on ORESTY_LUAHTTP && echo '  location = /http { content_by_lua_block { local http = require "resty.http"; local res, err = http.new():request_uri("http://127.0.0.1/"); ngx.say(type(http.new), " ", res and res.status or err) } }'
    on ORESTY_LUAOPENSSL && echo '  location = /ossl { content_by_lua_block { local pkey = require "resty.openssl.pkey"; local k, err = pkey.new({type = "Ed25519"}); ngx.say(k and k:get_key_type().sn or ("ERR " .. tostring(err))) } }'
    on ORESTY_LUAPROMETHEUS && echo '  location = /metrics { content_by_lua_block { ci141_prometheus:collect() } }'
    echo '}'
  } > "$work/lua.conf"
  add_conf lua < "$work/lua.conf" && rt_lua=y
  if on ORESTY_LUAJA4; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=ci141-ja4.test' \
      -keyout "$ci_conf/ja4.key" -out "$ci_conf/ja4.crt" > /dev/null 2>&1
    add_conf ja4 <<'NGX' && rt_ja4=y
server {
  listen 127.0.0.1:8444 ssl;
  server_name ci141-ja4.test;
  ssl_certificate @CI@/ja4.crt;
  ssl_certificate_key @CI@/ja4.key;
  ssl_client_hello_by_lua_block { require("resty.ja4").compute() }
  location / {
    header_filter_by_lua_block {
      ngx.header["X-JA4"] = require("resty.ja4").get()
      ngx.header["X-JA4H"] = require("resty.ja4h").compute()
    }
    content_by_lua_block { ngx.say("ja4") }
  }
}
NGX
  fi
elif on ORESTY_LUANGINX; then
  fail "ORESTY_LUANGINX='y' but no lua-nginx-module in nginx -V"
else
  for t in "${lua_extras[@]}"; do
    if on "$t"; then
      in_log "ORESTY_LUA\* optional Lua libraries skipped" && pass "$t='y' without ORESTY_LUANGINX: skip message printed" || fail "$t='y' without ORESTY_LUANGINX: no skip message"
    fi
  done
fi

echo "== NGINX_AUTHJWT"
rt_jwt=n
if on NGINX_AUTHJWT; then
  if on NGXDYNAMIC_AUTHJWT; then
    module_present auth_jwt nginx-auth-jwt "nginx-auth-jwt-$(cfg NGINX_AUTHJWTVER)" y ngx_http_auth_jwt_module.so
    ldd "$mod_dir/ngx_http_auth_jwt_module.so" 2>/dev/null | grep -q libjansson && pass "auth_jwt: links libjansson" || fail "auth_jwt: ngx_http_auth_jwt_module.so does not link libjansson"
  else
    module_present auth_jwt nginx-auth-jwt "nginx-auth-jwt-$(cfg NGINX_AUTHJWTVER)" n
  fi
  rpm -q jansson-devel > /dev/null 2>&1 && pass "auth_jwt: $(rpm -q jansson-devel)" || fail "auth_jwt: jansson-devel not installed"
  python3 - "$ci_conf" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
d = sys.argv[1]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
secret = os.urandom(32)
with open(d + "/jwks.json", "w") as f:
    json.dump({"keys": [{"kty": "oct", "kid": "ci141", "alg": "HS256", "k": b64(secret)}]}, f)
def token(header, key):
    h = b64(json.dumps(header).encode())
    p = b64(json.dumps({"sub": "ci141", "exp": int(time.time()) + 3600}).encode())
    sig = b64(hmac.new(key, (h + "." + p).encode(), hashlib.sha256).digest()) if key else ""
    return h + "." + p + "." + sig
hs = {"alg": "HS256", "typ": "JWT", "kid": "ci141"}
for name, header, key in (("good", hs, secret), ("badsig", hs, os.urandom(32)), ("none", {"alg": "none", "typ": "JWT"}, None)):
    with open(d + "/jwt." + name, "w") as f:
        f.write(token(header, key))
PY
  echo "jwt ok" > "$ci_conf/ok.txt"
  add_conf authjwt <<'NGX' && rt_jwt=y
server {
  listen 127.0.0.1:8110;
  location = /jwt {
    auth_jwt "ci141";
    auth_jwt_key_file @CI@/jwks.json;
    default_type text/plain;
    alias @CI@/ok.txt;
  }
}
NGX
else
  module_absent auth_jwt nginx-auth-jwt ngx_http_auth_jwt_module.so
fi

echo "== NGINX_KEYVAL and NGINX_KEYVAL_REDIS"
rt_kv=n rt_kvr=n
if on NGINX_KEYVAL; then
  kv_so=(ngx_http_keyval_module.so)
  grep -qE -- '--with-stream(=dynamic)?( |$)' <<< "$V" && kv_so+=(ngx_stream_keyval_module.so)
  if on NGXDYNAMIC_KEYVAL; then
    module_present keyval nginx-keyval "nginx-keyval-$(cfg NGINX_KEYVALVER)" y "${kv_so[@]}"
  else
    module_present keyval nginx-keyval "nginx-keyval-$(cfg NGINX_KEYVALVER)" n
  fi
  if grep -q -- '--with-stream=dynamic' <<< "$V"; then
    s1=$(grep -nE 'load_module[^#]*/ngx_stream_module\.so' <<< "$T" | head -1 | cut -d: -f1)
    s2=$(grep -nE 'load_module[^#]*/ngx_stream_keyval_module\.so' <<< "$T" | head -1 | cut -d: -f1)
    [[ -n "$s1" && -n "$s2" && "$s1" -lt "$s2" ]] && pass "keyval: ngx_stream_module.so loads before ngx_stream_keyval_module.so" || fail "keyval: load order ngx_stream_module.so line ${s1:-none}, ngx_stream_keyval_module.so line ${s2:-none}"
  fi
  add_conf keyval <<'NGX' && rt_kv=y
keyval_zone zone=ci141_kv:32k;
keyval $arg_key $ci141_kv_value zone=ci141_kv;
server {
  listen 127.0.0.1:8111;
  location = /kvset { set $ci141_kv_value $arg_v; return 200 "set\n"; }
  location = /kv { return 200 "$arg_key=$ci141_kv_value\n"; }
}
NGX
  kv_ldd=$(ldd "$mod_dir/ngx_http_keyval_module.so" 2>/dev/null; ldd /usr/local/sbin/nginx 2>/dev/null)
  if on NGINX_KEYVAL_REDIS; then
    rpm -q hiredis-devel > /dev/null 2>&1 && pass "keyval redis: $(rpm -q hiredis-devel)" || fail "keyval redis: hiredis-devel not installed"
    grep -q libhiredis <<< "$kv_ldd" && pass "keyval redis: links libhiredis" || fail "keyval redis: no libhiredis link"
    [[ "$(redis-cli ping 2>/dev/null)" = PONG ]] && pass "redis-cli ping" || fail "Redis is not answering on 127.0.0.1:6379"
    add_conf keyval-redis <<'NGX' && rt_kvr=y
keyval_zone_redis zone=ci141_kvr hostname=127.0.0.1 port=6379 connect_timeout=2s command_timeout=2s;
keyval $arg_key $ci141_kvr_value zone=ci141_kvr;
server {
  listen 127.0.0.1:8112;
  location = /kvset { set $ci141_kvr_value $arg_v; return 200 "set\n"; }
  location = /kv { return 200 "$arg_key=$ci141_kvr_value\n"; }
}
NGX
  else
    grep -q libhiredis <<< "$kv_ldd" && fail "NGINX_KEYVAL_REDIS='n' but keyval links libhiredis" || pass "keyval: no libhiredis link (NGINX_KEYVAL_REDIS='n')"
  fi
else
  module_absent keyval nginx-keyval ngx_http_keyval_module.so ngx_stream_keyval_module.so
fi

echo "== NGINX_RATELIMIT"
rt_rl=n
if on NGINX_RATELIMIT; then
  if on NGXDYNAMIC_RATELIMIT; then
    module_present rate_limit rate-limit-nginx-module "$(cfg NGINX_RATELIMITCOMMIT)" y ngx_http_rate_limit_module.so
  else
    module_present rate_limit rate-limit-nginx-module "$(cfg NGINX_RATELIMITCOMMIT)" n
  fi
  in_log "rate_limit only works with the redis-rate-limiter module" && pass "rate_limit: build log has the redis-rate-limiter note" || fail "rate_limit: build log has no redis-rate-limiter note"
  echo "rate limit ok" > "$ci_conf/rl.txt"
  add_conf ratelimit <<'NGX' && rt_rl=y
upstream ci141_ratelimit_redis {
  server 127.0.0.1:6379;
  keepalive 16;
}
server {
  listen 127.0.0.1:8113;
  location = /limit {
    rate_limit $remote_addr requests=5 period=1m burst=5;
    rate_limit_pass ci141_ratelimit_redis;
    rate_limit_headers on;
    default_type text/plain;
    alias @CI@/rl.txt;
  }
}
NGX
else
  module_absent rate_limit rate-limit-nginx-module ngx_http_rate_limit_module.so
fi

echo "== NGINX_OTEL"
if on NGINX_OTEL; then
  in_log "NGINX_OTEL='y' skipped" && fail "NGINX_OTEL='y' skipped: $(grep -m1 "NGINX_OTEL='y' skipped" "$work/build.log")"
  module_present otel nginx-otel "nginx-otel-$(cfg NGINX_OTELVER)" y ngx_otel_module.so
  sed "s|@CI@|$ci_conf|g" > "$conf_d/zz-ci141-otel.conf" <<'NGX'
otel_exporter { endpoint 127.0.0.1:4317; }
server {
  listen 127.0.0.1:8114;
  location / { otel_trace on; return 200 "otel\n"; }
}
NGX
  nginx -t > "$work/t.log" 2>&1 && pass "otel: nginx -t with otel_exporter and otel_trace" || { fail "otel: nginx -t rejects otel_exporter/otel_trace:"; tail -5 "$work/t.log"; }
  rm -f "$conf_d/zz-ci141-otel.conf"
else
  module_absent otel nginx-otel ngx_otel_module.so
fi

echo "== NGINX_RTMP_HTTPFLV and NGINX_RTMP"
rt_flv=n
if on NGINX_RTMP_HTTPFLV; then
  module_present http-flv nginx-http-flv-module "nginx-http-flv-module-$(cfg NGINX_RTMP_HTTPFLVVER)" n
  grep -q -- '--add-module=../nginx-rtmp-module' <<< "$V" && fail "http-flv: arut nginx-rtmp-module built as well" || pass "http-flv: no arut nginx-rtmp-module"
  [[ -d /svr-setup/nginx-rtmp-module ]] && fail "http-flv: /svr-setup/nginx-rtmp-module was cloned" || pass "http-flv: no nginx-rtmp-module clone"
  if on NGINX_RTMP || on NGINX_VIDEO; then
    in_log "building nginx-http-flv-module .* instead of arut nginx-rtmp-module" && pass "http-flv: both-set warning printed" || fail "http-flv: NGINX_RTMP and NGINX_RTMP_HTTPFLV both 'y' but no warning"
  fi
  cat > "$ci_conf/rtmp.conf" <<'NGX'
rtmp {
  server {
    listen 127.0.0.1:1935;
    application live { live on; }
  }
}
NGX
  nginx_conf_backup="$work/nginx.conf.orig"
  cp -p "$conf_dir/nginx.conf" "$nginx_conf_backup"
  echo "include $ci_conf/rtmp.conf;" >> "$conf_dir/nginx.conf"
  if add_conf flv <<'NGX'
server {
  listen 127.0.0.1:8115;
  location /live { flv_live on; chunked_transfer_encoding on; }
}
NGX
  then
    rt_flv=y
  else
    cp -p "$nginx_conf_backup" "$conf_dir/nginx.conf"
    nginx_conf_backup=''
  fi
elif on NGINX_RTMP; then
  grep -q -- '--add-module=../nginx-rtmp-module' <<< "$V" && pass "NGINX_RTMP='y': arut nginx-rtmp-module built" || fail "NGINX_RTMP='y' but no ../nginx-rtmp-module in nginx -V"
else
  module_absent http-flv nginx-http-flv-module
  grep -q -- '--add-module=../nginx-rtmp-module' <<< "$V" && fail "nginx-rtmp-module built with NGINX_RTMP='n'" || pass "no nginx-rtmp-module"
fi

echo "== NGINX_UPSTREAMCHECK"
rt_check=n
if on NGINX_UPSTREAMCHECK; then
  commit=$(cfg NGINX_UPSTREAMCHECKCOMMIT)
  module_present upstream_check nginx_upstream_check_module "${commit:-nginx_upstream_check_module}" n
  if [[ -n "$commit" ]]; then
    [[ -f "/svr-setup/nginx-upstream-check-${commit}.tar.gz" ]] && pass "upstream_check: commit archive nginx-upstream-check-${commit}.tar.gz" || fail "upstream_check: /svr-setup/nginx-upstream-check-${commit}.tar.gz missing"
  fi
  patchlog=$(ls -t /root/centminlogs/patch_patchnginx_*.log 2>/dev/null | head -1)
  if [[ "$core" != nginx ]]; then
    in_log "NGINX_UPSTREAMCHECK='y' core patch skipped" && pass "upstream_check: core patch skipped on $core" || fail "upstream_check: no 'core patch skipped' warning on $core"
  elif (( cv >= 1020001 )); then
    want='check_1.20.1+.patch'
    (( cv >= 1029006 )) && want='check_1.30.4+.patch'
    if in_log "patch -p1 < .*$(re "$want")" || grep -qF "$want" "${patchlog:-/dev/null}"; then
      pass "upstream_check: $want applied"
    else
      fail "upstream_check: no '$want' in the build or patch log"
    fi
    rej=$(find "/svr-setup/nginx-${core_ver}" -name '*.rej' 2>/dev/null | head -5)
    [[ -z "$rej" ]] && pass "upstream_check: no .rej files in /svr-setup/nginx-${core_ver}" || fail "upstream_check: .rej files: $rej"
    add_conf upstreamcheck <<'NGX' && rt_check=y
upstream ci141_check_hash {
  zone ci141_check_hash 64k;
  hash $request_uri consistent;
  server 127.0.0.1:18081;
  server 127.0.0.1:18082;
  check interval=1000 rise=1 fall=1 timeout=500 type=http;
}
upstream ci141_check_iphash {
  zone ci141_check_iphash 64k;
  ip_hash;
  server 127.0.0.1:18081;
  server 127.0.0.1:18082;
  check interval=1000 rise=1 fall=1 timeout=500 type=http;
}
server {
  listen 127.0.0.1:8116;
  location /h/ { proxy_pass http://ci141_check_hash; }
  location /i/ { proxy_pass http://ci141_check_iphash; }
  location = /status { check_status json; }
}
NGX
  fi
else
  module_absent upstream_check nginx_upstream_check_module
fi

echo "== NGINX_STICKY"
rt_sticky=n
native=''
case "$core" in
  angie) native='--without-http_upstream_sticky_module' ;;
  nginx)
    if (( cv >= 1031000 )); then
      native='--without-http_upstream_sticky_module'
    elif (( cv >= 1029006 )); then
      native='--without-http_upstream_sticky'
    fi
    ;;
esac
if on NGINX_STICKY; then
  # NGINX_STICKYVER='master' builds ../nginx-sticky-module-master, a tagged
  # version builds the bitbucket nginx-goodies-nginx-sticky-module-ng-<hash> folder
  module_present sticky nginx-sticky-module nginx-sticky-module n
  sticky_opt=$(modopt nginx-sticky-module)
  sticky_src="/svr-setup/${sticky_opt#--add-module=../}/ngx_http_sticky_module.c"
  if [[ -f "$sticky_src" ]]; then
    if [[ "$core" != nginx ]] || (( cv >= 1023000 )); then
      grep -q 'r->headers_in.cookie, ' "$sticky_src" && pass "sticky: source patched for the nginx 1.23.0+ cookie API" || fail "sticky: $sticky_src not patched for the nginx 1.23.0+ cookie API"
    fi
    if [[ "$core" = angie ]]; then
      grep -q 'ngx_sticky_peer_recovered' "$sticky_src" && pass "sticky: fail_timeout check patched for Angie" || fail "sticky: $sticky_src not patched for Angie recover_at"
    fi
  else
    # the source is gone after the build: the install's disk_cleanups and the
    # menu 4 "Nginx Cleanup" (inc/nginx_upgrade.inc) delete it so the next build
    # downloads master again. Each build patches the fresh copy and says so
    if [[ "$core" != nginx ]] || (( cv >= 1023000 )); then
      in_log 'nginx-sticky-module-ng: cookie lookup switched to the nginx 1\.23\.0\+ API' && pass "sticky: build log: source patched for the nginx 1.23.0+ cookie API" || fail "sticky: $sticky_src gone and no cookie API patch message in the build log"
    fi
    if [[ "$core" = angie ]]; then
      in_log 'nginx-sticky-module-ng: fail_timeout check made Angie compatible' && pass "sticky: build log: fail_timeout check patched for Angie" || fail "sticky: $sticky_src gone and no Angie recover_at patch message in the build log"
    fi
  fi
  if [[ -n "$native" ]]; then
    grep -qE -- "$native( |$)" <<< "$V" && pass "sticky: native module disabled with $native" || fail "sticky: no $native in nginx -V"
  else
    grep -q -- '--without-http_upstream_sticky' <<< "$V" && fail "sticky: native sticky switch passed on $core $core_ver" || pass "sticky: no native sticky switch on $core $core_ver"
  fi
  in_log "NGINX_STICKY='y' third-party nginx-sticky-module-ng is deprecated" && pass "sticky: deprecation warning printed" || fail "sticky: no deprecation warning"
  add_conf sticky <<'NGX' && rt_sticky=y
upstream ci141_sticky {
  sticky name=ci141route hash=md5 httponly;
  server 127.0.0.1:18081;
  server 127.0.0.1:18082;
}
server {
  listen 127.0.0.1:8117;
  location / { proxy_pass http://ci141_sticky; }
}
NGX
else
  module_absent sticky nginx-sticky-module
  grep -q -- '--without-http_upstream_sticky' <<< "$V" && fail "native sticky module disabled with NGINX_STICKY='n'" || pass "native sticky module not disabled"
fi

echo "== NGINX_TLS_FINGERPRINT"
if on NGINX_TLS_FINGERPRINT; then
  in_log "JA3 nginx-ssl-fingerprint module is deprecated" && pass "ja3: deprecation warning printed" || fail "ja3: no deprecation warning"
  if grep -q -- '--with-openssl=' <<< "$V"; then
    info "ja3: nginx compiles in a source OpenSSL, the module may build: $(modopt nginx-ssl-fingerprint)"
  else
    [[ -z "$(modopt nginx-ssl-fingerprint)" ]] && pass "ja3: module not built against system OpenSSL" || fail "ja3: $(modopt nginx-ssl-fingerprint) built against system OpenSSL"
    in_log "NGINX_TLS_FINGERPRINT='y' skipped" && pass "ja3: skip message printed" || fail "ja3: no 'NGINX_TLS_FINGERPRINT='y' skipped' message"
  fi
else
  [[ -z "$(modopt nginx-ssl-fingerprint)" ]] && pass "ja3 off: not in nginx -V" || fail "ja3 off: $(modopt nginx-ssl-fingerprint) in nginx -V"
fi

echo "== runtime checks"
if [[ "$rt_check" = y || "$rt_sticky" = y ]]; then
  start_backend 18081
fi
# error.log baseline after the config tests above, whose nginx -t runs
# (including the expected js_engine qjs failure) log [emerg] lines
el0=$(wc -l < "$errlog" 2>/dev/null || echo 0)
nginx -s reload || fail "nginx -s reload with the test configs"
sleep 3
if [[ "$rt_purge" = y ]]; then
  c1=$(curl -s -m 10 -o /dev/null -D - http://127.0.0.1:8101/c/ci141 | grep -i '^x-ci141-cache:' | tr -d '\r' | awk '{print $2}')
  c2=$(curl -s -m 10 -o /dev/null -D - http://127.0.0.1:8101/c/ci141 | grep -i '^x-ci141-cache:' | tr -d '\r' | awk '{print $2}')
  [[ "$c1" = MISS && "$c2" = HIT ]] && pass "ngx_cache_purge: cache MISS then HIT" || fail "ngx_cache_purge: cache status '$c1' then '$c2', expected MISS then HIT"
  expect_code "ngx_cache_purge: purge a cached key" 200 http://127.0.0.1:8101/purge/c/ci141
  # ngx_cache_purge 3.0.x answers 412 for a key not in the cache while
  # cache_purge_legacy_status is on (the default), 404 only when it is off
  expect_code "ngx_cache_purge: purge a missing key" 412 http://127.0.0.1:8101/purge/c/ci141
fi
if [[ "$rt_hm" = y ]]; then
  h=$(curl -s -m 10 -o /dev/null -D - http://127.0.0.1:8103/hm | tr -d '\r')
  grep -qi '^x-ci141-hm: matched' <<< "$h" && pass "headers-more: -t 'text/html' matches 'Text/HTML; charset=utf-8'" || fail "headers-more: -t 'text/html' did not match $(grep -i '^content-type' <<< "$h")"
fi
if [[ "$rt_echo" = y ]]; then
  body=$(curl -s -m 10 http://127.0.0.1:8105/echo)
  [[ "$body" = echo-ok ]] && pass "echo: echo-ok" || fail "echo: '$body'"
fi
if [[ "$rt_json" = y ]]; then
  body=$(curl -s -m 10 -d '{"method":"tools/call"}' http://127.0.0.1:8106/j)
  [[ "$body" = tools/call ]] && pass "json_set: method from the request body" || fail "json_set: '$body', expected tools/call"
fi
if [[ "$rt_njs" = y ]]; then
  body=$(curl -s -m 10 http://127.0.0.1:8107/njs)
  [[ "$body" = "version=$(cfg NGINX_NJS_VER) map=undefined" ]] && pass "njs: default njs engine, $body" || fail "njs: '$body', expected version=$(cfg NGINX_NJS_VER) map=undefined"
fi
if [[ "$rt_qjs" = y ]]; then
  body=$(curl -s -m 10 http://127.0.0.1:8108/qjs)
  [[ "$body" = "version=$(cfg NGINX_NJS_VER) map=function" ]] && pass "njs: js_engine qjs runs QuickJS, $body" || fail "njs: js_engine qjs gave '$body', expected version=$(cfg NGINX_NJS_VER) map=function"
fi
if [[ "$rt_lua" = y ]]; then
  if on ORESTY_LUALIMITTRAFFIC; then
    body=$(curl -s -m 10 http://127.0.0.1:8109/lim)
    [[ "$body" = 'function ok' ]] && pass "resty.limit.req: $body" || fail "resty.limit.req: '$body'"
  fi
  if on ORESTY_LUAHTTP; then
    body=$(curl -s -m 10 http://127.0.0.1:8109/http)
    [[ "$body" = 'function 200' ]] && pass "resty.http: request_uri to the default site, $body" || fail "resty.http: '$body'"
  fi
  if on ORESTY_LUAOPENSSL; then
    body=$(curl -s -m 10 http://127.0.0.1:8109/ossl)
    [[ "$body" = ED25519 ]] && pass "resty.openssl: Ed25519 key" || fail "resty.openssl: '$body'"
  fi
  if on ORESTY_LUAPROMETHEUS; then
    # this request is counted by log_by_lua; counters sync to the dict every 1s
    curl -s -m 10 -o /dev/null http://127.0.0.1:8109/metrics
    sleep 2
    body=$(curl -s -m 10 http://127.0.0.1:8109/metrics)
    grep -q '^nginx_http_requests_total{host="ci141-lua"} [1-9]' <<< "$body" && pass "prometheus: log_by_lua counted requests, $(grep -m1 '^nginx_http_requests_total{' <<< "$body")" || fail "prometheus: no counted nginx_http_requests_total{host=\"ci141-lua\"} in /metrics: $(head -c 300 <<< "$body")"
  fi
fi
if [[ "$rt_ja4" = y ]]; then
  h=$(curl -sk -m 10 -o /dev/null -D - --resolve ci141-ja4.test:8444:127.0.0.1 https://ci141-ja4.test:8444/ | tr -d '\r')
  ja4=$(sed -n 's/^[Xx]-[Jj][Aa]4: //p' <<< "$h")
  ja4h=$(sed -n 's/^[Xx]-[Jj][Aa]4[Hh]: //p' <<< "$h")
  [[ "$ja4" =~ ^t1[0-3]d ]] && pass "lua-resty-ja4: X-JA4 $ja4" || fail "lua-resty-ja4: X-JA4 '$ja4'"
  [[ -n "$ja4h" ]] && pass "lua-resty-ja4: X-JA4H $ja4h" || fail "lua-resty-ja4: no X-JA4H header"
fi
if [[ "$rt_jwt" = y ]]; then
  expect_code "auth_jwt: no token" 401 http://127.0.0.1:8110/jwt
  expect_code "auth_jwt: bad signature" 401 -H "Authorization: Bearer $(cat "$ci_conf/jwt.badsig")" http://127.0.0.1:8110/jwt
  expect_code "auth_jwt: alg none" 401 -H "Authorization: Bearer $(cat "$ci_conf/jwt.none")" http://127.0.0.1:8110/jwt
  expect_code "auth_jwt: valid HS256 token" 200 -H "Authorization: Bearer $(cat "$ci_conf/jwt.good")" http://127.0.0.1:8110/jwt
fi
if [[ "$rt_kv" = y ]]; then
  curl -s -m 10 -o /dev/null 'http://127.0.0.1:8111/kvset?key=ci141&v=shm-value'
  body=$(curl -s -m 10 'http://127.0.0.1:8111/kv?key=ci141')
  [[ "$body" = 'ci141=shm-value' ]] && pass "keyval: shared memory zone stores and returns a value" || fail "keyval: '$body', expected ci141=shm-value"
fi
if [[ "$rt_kvr" = y ]]; then
  key="ci141-redis-$RANDOM"
  curl -s -m 10 -o /dev/null "http://127.0.0.1:8112/kvset?key=$key&v=redis-value"
  body=$(curl -s -m 10 "http://127.0.0.1:8112/kv?key=$key")
  [[ "$body" = "$key=redis-value" ]] && pass "keyval redis: value stored and returned" || fail "keyval redis: '$body', expected $key=redis-value"
  rkeys=$(redis-cli --scan --pattern "*${key}*" 2>/dev/null)
  [[ -n "$rkeys" ]] && pass "keyval redis: key in Redis ($rkeys)" || fail "keyval redis: no Redis key matching *$key*"
  printf '%s\n' "$rkeys" | xargs -r redis-cli del > /dev/null
  systemctl stop redis
  t0=$(date +%s)
  CURL_MAX=20 code "http://127.0.0.1:8112/kv?key=$key" > /dev/null
  rc=$?
  t1=$(( $(date +%s) - t0 ))
  [[ "$rc" -ne 28 && "$t1" -lt 12 ]] && pass "keyval redis: Redis stopped, request returned in ${t1}s" || fail "keyval redis: Redis stopped, request took ${t1}s (curl exit $rc)"
  systemctl start redis
  sleep 1
  [[ "$(redis-cli ping 2>/dev/null)" = PONG ]] || fail "Redis did not restart"
fi
if [[ "$rt_rl" = y ]]; then
  got=$(code http://127.0.0.1:8113/limit)
  info "rate_limit: one request with Redis lacking the redis-rate-limiter module: HTTP $got"
fi
if [[ "$rt_flv" = y ]]; then
  ss -Hlnt 'sport = :1935' | grep -q '127.0.0.1:1935' && pass "http-flv: rtmp listening on 127.0.0.1:1935" || fail "http-flv: no rtmp listener on 127.0.0.1:1935"
  info "http-flv: flv_live with no publisher: HTTP $(CURL_MAX=5 code 'http://127.0.0.1:8115/live?port=1935&app=live&stream=ci141')"
fi
if [[ "$rt_check" = y ]]; then
  sleep 2
  st=$(curl -s -m 10 'http://127.0.0.1:8116/status?format=json')
  for up in ci141_check_hash ci141_check_iphash; do
    grep -qE "\"upstream\": *\"$up\", *\"name\": *\"127\.0\.0\.1:18082\", *\"status\": *\"down\"" <<< "$st" && pass "upstream_check: $up 127.0.0.1:18082 down" || fail "upstream_check: $up 127.0.0.1:18082 not reported down"
    grep -qE "\"upstream\": *\"$up\", *\"name\": *\"127\.0\.0\.1:18081\", *\"status\": *\"up\"" <<< "$st" && pass "upstream_check: $up 127.0.0.1:18081 up" || fail "upstream_check: $up 127.0.0.1:18081 not reported up"
  done
  for path in h i; do
    ok=0 bad=0 t0=$(date +%s)
    for n in $(seq 1 200); do
      [[ "$(CURL_MAX=5 code "http://127.0.0.1:8116/$path/$n")" = 200 ]] && ok=$((ok + 1)) || bad=$((bad + 1))
      # stop after a few failures so a hung worker cannot stall the job
      [[ "$bad" -gt 5 ]] && break
    done
    t1=$(( $(date +%s) - t0 ))
    [[ "$bad" -eq 0 ]] && pass "upstream_check /$path/: 200 requests all 200 in ${t1}s" || fail "upstream_check /$path/: $bad of 200 requests failed or hung (${t1}s)"
  done
  pgrep -f 'nginx: worker process' > /dev/null && pass "upstream_check: workers alive" || fail "upstream_check: no nginx worker processes"
fi
if [[ "$rt_sticky" = y ]]; then
  start_backend 18082
  h=$(curl -s -m 10 -c "$work/cookies" -D - -o "$work/s1" http://127.0.0.1:8117/ | tr -d '\r')
  grep -qi '^set-cookie: ci141route=' <<< "$h" && pass "sticky: route cookie set" || fail "sticky: no ci141route cookie"
  curl -s -m 10 -b "$work/cookies" -o "$work/s2" http://127.0.0.1:8117/
  curl -s -m 10 -b "$work/cookies" -o "$work/s3" http://127.0.0.1:8117/
  p1=$(awk '{print $2}' "$work/s1") p2=$(awk '{print $2}' "$work/s2") p3=$(awk '{print $2}' "$work/s3")
  [[ -n "$p1" && "$p1" = "$p2" && "$p2" = "$p3" ]] && pass "sticky: cookie keeps backend $p1" || fail "sticky: backends '$p1' '$p2' '$p3'"
fi

echo "== error.log"
new=$(tail -n +$((el0 + 1)) "$errlog" 2>/dev/null)
# the rate_limit request on 127.0.0.1:8113 deliberately uses a Redis without
# the redis-rate-limiter module (HTTP 500), and the module logs an alert for it
crit=$(grep -E '\[(crit|alert|emerg)\]' <<< "$new" | grep -vE 'setpriority|setrlimit' |
  grep -vE 'header already sent while sending to client, .*request: "GET /limit HTTP/1\.1".*host: "127\.0\.0\.1:8113"')
[[ -z "$crit" ]] && pass "no new crit/alert/emerg error.log entries" || { fail "new error.log entries:"; tail -5 <<< "$crit" | sed 's/^/  /'; }
if [[ "$rt_lua" = y || "$rt_ja4" = y ]]; then
  luaerr=$(grep -E '\[error\]' <<< "$new" | grep -i lua)
  [[ -z "$luaerr" ]] && pass "no new Lua errors in error.log" || { fail "Lua errors in error.log:"; tail -5 <<< "$luaerr" | sed 's/^/  /'; }
fi

[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
