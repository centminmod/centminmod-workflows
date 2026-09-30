#!/bin/bash
# Nginx Lua feature checks. Run inside the installed Centmin Mod test container:
#   docker exec -i cmm_el89 bash -s < scripts/test-nginx-lua.sh
# Expected versions come from the installed centmin.sh, with custom_config.inc
# overrides taking precedence. Exits 1 if any FAIL line is printed.
set -uo pipefail
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
conf=/usr/local/nginx/conf/conf.d/zz-ci-luatest.conf
errlog=/usr/local/nginx/logs/error.log
lualib=/usr/local/nginx-dep/lib/lua/5.1
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
cleanup() { rm -f "$conf"; nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; }
trap cleanup EXIT

luangx_ver=$(cfg ORESTY_LUANGINXVER)
core_ver=$(cfg ORESTY_LUARESTYCOREVER)
info "$(nginx -v 2>&1); expecting lua-nginx-module $luangx_ver, lua-resty-core $core_ver"

# build checks
V=$(nginx -V 2>&1)
luaopt=$(grep -oE -- '--add-(dynamic-)?module=[^ ]*lua-nginx-module[^ ]*' <<< "$V" | head -1)
if [[ "$luaopt" == *"lua-nginx-module-${luangx_ver}" ]]; then
  pass "nginx built with lua-nginx-module $luangx_ver ($luaopt)"
else
  fail "lua-nginx-module $luangx_ver not in nginx -V (found: ${luaopt:-none})"
fi
[[ "$V" == *ngx_devel_kit* ]] && pass "ngx_devel_kit in nginx -V" || fail "ngx_devel_kit missing from nginx -V"
if [[ "$luaopt" == --add-dynamic-module=* ]]; then
  [[ -f /usr/local/nginx/modules/ngx_http_lua_module.so ]] && pass "ngx_http_lua_module.so installed" || fail "ngx_http_lua_module.so missing"
  if nginx -T 2>/dev/null | grep -qE '^[[:space:]]*load_module[^#]*ngx_http_lua_module\.so'; then
    pass "load_module ngx_http_lua_module.so active"
  else
    fail "no active load_module line for ngx_http_lua_module.so"
  fi
fi
for m in stream-lua-nginx-module lua-upstream-nginx-module; do
  grep -qE -- "--add-(dynamic-)?module=[^ ]*${m}" <<< "$V" && info "$m built" || info "$m not built (off by default)"
done
nginx -T 2>/dev/null | grep -qE '^[[:space:]]*lua_package_path' && pass "lua_package_path configured" || fail "lua_package_path not in nginx -T"
nginx -t >/dev/null 2>&1 && pass "nginx -t" || { nginx -t; fail "nginx -t"; }
systemctl is-active --quiet nginx && pass "nginx service active" || fail "nginx service not active"

# C modules must be built against LuaJIT (Lua 5.1 API), not system Lua 5.3/5.4
if command -v nm >/dev/null 2>&1; then
  for so in "$lualib/cjson.so" "$lualib/redis/parser.so"; do
    if [[ ! -f "$so" ]]; then fail "$so missing"; continue; fi
    n=$(nm -D "$so" 2>/dev/null | grep -cE ' U (lua_rawlen|lua_isinteger|lua_geti|luaL_len|lua_newuserdatauv|lua_pcallk|lua_callk|lua_rotate)$')
    [[ "$n" -eq 0 ]] && pass "$(basename "$so") has no Lua 5.2+ symbols" || fail "$so references $n Lua 5.2+ symbols (built against system Lua)"
  done
else
  info "nm not installed; skipped Lua ABI symbol check"
fi

# runtime checks through a temporary localhost-only server
el0=$(wc -l < "$errlog" 2>/dev/null || echo 0)
cat > "$conf" <<'NGX'
# temporary CI lua test server, removed by test-nginx-lua.sh
server {
  listen 127.0.0.1:8095;
  location = /lua {
    default_type text/plain;
    content_by_lua_block {
      local function say(k, v) ngx.say(k, "=", tostring(v)) end
      say("ngx_lua_version", ngx.config.ngx_lua_version)
      say("resty_core_loaded", package.loaded["resty.core"] ~= nil)
      local okb, base = pcall(require, "resty.core.base")
      say("resty_core_base", okb and base.version or "FAIL")
      say("jit", jit and jit.version or "none")
      local libs = {"resty.memcached", "resty.mysql", "resty.redis", "resty.dns.resolver",
                    "resty.upload", "resty.websocket.server", "resty.websocket.client",
                    "resty.lock", "resty.string", "resty.sha256", "resty.logger.socket",
                    "resty.cookie", "resty.lrucache", "cjson", "redis.parser"}
      for _, m in ipairs(libs) do
        local ok, mod = pcall(require, m)
        if ok then
          say("lib " .. m, "ok " .. tostring(type(mod) == "table" and mod._VERSION or ""))
        else
          say("lib " .. m, "FAIL " .. (tostring(mod):gsub("%s+", " ")):sub(1, 160))
        end
      end
      local okh = pcall(require, "resty.upstream.healthcheck")
      say("healthcheck", okh and "loaded" or "needs NGX_LUAUPSTREAM")
      local s = require("resty.sha256"):new()
      s:update("abc")
      say("sha256_abc", require("resty.string").to_hex(s:final()))
      local cjson = require "cjson"
      say("cjson_roundtrip", cjson.encode(cjson.decode('{"a":[1,2,3]}')))
      local parser = require "redis.parser"
      local res, typ = parser.parse_reply("+OK\r\n")
      say("redis_parser", tostring(res == "OK" and typ == parser.STATUS_REPLY))
      local lru = require("resty.lrucache").new(10)
      lru:set("k", "v")
      say("lrucache", lru:get("k"))
    }
  }
}
NGX
if ! nginx -t >/dev/null 2>&1; then
  nginx -t
  fail "nginx -t with temporary lua server"
  echo "RESULT: FAIL"; exit 1
fi
nginx -s reload; sleep 2
out=$(curl -s -m 10 http://127.0.0.1:8095/lua)
echo "$out" | sed 's/^/  /'
val() { sed -n "s/^$1=//p" <<< "$out" | head -1; }
expect_num=$(awk -F. '{printf "%d", $1*1000000 + $2*1000 + $3}' <<< "$luangx_ver")
[[ "$(val ngx_lua_version)" = "$expect_num" ]] && pass "ngx_lua_version $expect_num" || fail "ngx_lua_version '$(val ngx_lua_version)' != $expect_num"
[[ "$(val resty_core_loaded)" = true ]] && pass "resty.core loaded" || fail "resty.core not loaded"
[[ "$(val resty_core_base)" = "$core_ver" ]] && pass "lua-resty-core $core_ver" || fail "lua-resty-core '$(val resty_core_base)' != $core_ver"
[[ "$(val jit)" == LuaJIT* ]] && pass "$(val jit)" || fail "LuaJIT not active: '$(val jit)'"
while IFS= read -r line; do
  [[ "$line" == *"=FAIL"* ]] && fail "require ${line#lib }" || pass "require ${line#lib }"
done < <(grep '^lib ' <<< "$out")
[[ "$(grep -c '^lib ' <<< "$out")" -eq 15 ]] || fail "expected 15 library results"
info "resty.upstream.healthcheck: $(val healthcheck)"
[[ "$(val sha256_abc)" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]] && pass "resty.sha256 digest" || fail "resty.sha256 digest '$(val sha256_abc)'"
[[ "$(val cjson_roundtrip)" = '{"a":[1,2,3]}' ]] && pass "cjson encode/decode" || fail "cjson roundtrip '$(val cjson_roundtrip)'"
[[ "$(val redis_parser)" = true ]] && pass "redis.parser parse_reply" || fail "redis.parser parse_reply"
[[ "$(val lrucache)" = v ]] && pass "resty.lrucache set/get" || fail "resty.lrucache set/get"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://localhost/)
[[ "$code" = 200 ]] && pass "default site HTTP 200" || fail "default site HTTP $code"
# container-only nginx alerts (no CAP_SYS_NICE / RLIMIT raise in Docker) are not failures
new_errors=$(tail -n +$((el0 + 1)) "$errlog" 2>/dev/null | grep -E '\[(error|crit|alert|emerg)\]' | grep -vE 'setpriority|setrlimit')
if [[ -z "$new_errors" ]]; then
  pass "no new error.log errors"
else
  fail "new error.log errors:"; echo "$new_errors" | tail -5
fi
[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
