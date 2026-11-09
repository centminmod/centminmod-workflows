#!/bin/bash
# Rebuild nginx through centmin-cli.sh nginx-update, the centmin.sh menu 4 code
# path without menus, after appending /root/ci141-stage.inc (one setting per
# line, may be empty) to /etc/centminmod/custom_config.inc. Run inside the test
# container by .github/workflows/almalinux10-nginx-features.yml:
#   docker exec cmm_el89 bash /opt/ci141/nginx-141-rebuild.sh <target> <pass|fail> [marker]
# target: same (version of the running nginx or freenginx), freenginx
#   (FREENGINX_VERSION), angie, or an nginx version.
# pass: the build must succeed, replace the nginx binary, print no abort or
#   patch failure markers and leave nginx serving. Its output becomes
#   /root/ci-nginx-build.log for test-nginx-141-features.sh.
# fail: the build must fail, print <marker>, keep the running nginx binary
#   untouched and still serving. /root/ci-nginx-build.log is left as it was.
# custom_config.inc is restored after an expected failure and after a pass
# build that failed, so later checks see the settings of the running nginx.
set -uo pipefail
target=${1:?usage: nginx-141-rebuild.sh <target> <pass|fail> [marker]}
expect=${2:-pass}
marker=${3:-}
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
config=/etc/centminmod/custom_config.inc
stage=/root/ci141-stage.inc
build_log=/root/ci-nginx-build.log
nginx_bin=/usr/local/sbin/nginx
logs=/root/centminlogs
failed=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
cfg() {
  local v
  v=$(sed -nE "s/^$1=['\"]?([^'\" ]*).*/\1/p" "$config" 2>/dev/null | tail -1)
  [[ -n "$v" ]] || v=$(sed -nE "s/^$1=['\"]?([^'\" ]*).*/\1/p" "$centmin_dir/centmin.sh" | head -1)
  echo "$v"
}
mkdir -p "$logs"
backup=$(mktemp /root/ci141-config.XXXXXX)
cp -p "$config" "$backup"
if [[ -s "$stage" ]]; then
  { echo; echo "# CI stage: $target $expect"; cat "$stage"; } >> "$config"
  echo "custom_config.inc lines added for this stage:"
  sed 's/^/  /' "$stage"
fi

case "$target" in
  same) target=$("$nginx_bin" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
  freenginx) target=$(cfg FREENGINX_VERSION) ;;
esac
case "$target" in
  angie) want_v="Angie/$(cfg NGINX_ANGIE_VERSION | sed 's/^Angie-//')" ;;
  *) want_v="/$target" ;;
esac
echo "rebuild: centmin-cli.sh nginx-update $target (expect $expect), running $("$nginx_bin" -v 2>&1)"

mtime_before=$(stat -c %Y "$nginx_bin")
ts=$(date +%Y%m%d-%H%M%S)
run_log="$logs/ci141-nginx-update-${target}-${ts}.log"
start=$(date +%s)
(cd "$centmin_dir" && bash centmin-cli.sh nginx-update "$target") < /dev/null > "$run_log" 2>&1
status=$?
elapsed=$(( $(date +%s) - start ))
mtime_after=$(stat -c %Y "$nginx_bin")
echo "centmin-cli.sh nginx-update exit $status after ${elapsed}s, full output: $run_log"
clean=$(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\(B//g; s/\\E\[[0-9;]*m//g; s/\r$//' "$run_log")
markers=$(grep -nE 'Patching failed|Aborting script|Hunk #[0-9]+ FAILED|saving rejects to file|Nginx configure failed|Nginx make failed|(^|[^A-Za-z])ERROR: ' <<< "$clean" | head -20)

if [[ "$expect" = fail ]]; then
  [[ "$status" -ne 0 ]] && pass "build failed as expected (exit $status)" || fail "build was expected to fail but exited 0"
  if [[ -n "$marker" ]]; then
    grep -qF -- "$marker" <<< "$clean" && pass "build output has '$marker'" || fail "build output has no '$marker'"
  fi
  [[ "$mtime_after" = "$mtime_before" ]] && pass "running nginx binary left untouched" || fail "nginx binary replaced by a build expected to fail"
else
  [[ "$status" -eq 0 ]] && pass "build exit 0" || fail "build exit $status"
  if [[ -z "$markers" ]]; then
    pass "no abort, patch failure or ERROR: markers"
  else
    fail "abort, patch failure or ERROR: markers in the build output:"
    echo "$markers" | sed 's/^/  /'
  fi
  [[ "$mtime_after" -gt "$mtime_before" ]] && pass "nginx binary replaced" || fail "nginx binary not replaced (mtime unchanged)"
  "$nginx_bin" -v 2>&1 | grep -qiF -- "$want_v" && pass "running $("$nginx_bin" -v 2>&1)" || fail "nginx -v '$("$nginx_bin" -v 2>&1)' does not show $want_v"
fi
"$nginx_bin" -t > /dev/null 2>&1 && pass "nginx -t" || { "$nginx_bin" -t; fail "nginx -t"; }
systemctl is-active --quiet nginx && pass "nginx service active" || fail "nginx service not active"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/)
[[ "$code" = 200 ]] && pass "default site HTTP 200" || fail "default site HTTP $code"

if [[ "$expect" = pass && "$failed" -eq 0 ]]; then
  cp -f "$run_log" "$build_log"
  rm -f "$backup" /root/ci141-expected-fail
else
  # an aborted build can remove work dirs of the running build (QuickJS:
  # /svr-setup/njs-quickjs); test-nginx-141-features.sh skips those checks
  [[ "$expect" = fail && "$failed" -eq 0 ]] && echo "$target (marker: ${marker:-none})" > /root/ci141-expected-fail
  echo "--- last 60 lines of the build output"
  tail -60 <<< "$clean"
  echo "--- restoring custom_config.inc from before this stage"
  cp -p "$backup" "$config"
  rm -f "$backup"
fi
[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
