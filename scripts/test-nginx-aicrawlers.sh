#!/bin/bash
# tools/nginx-aicrawlers.sh and botlimit.conf AI crawler map checks for
# 141.00beta01+. Run inside the test container after the install copied the
# shipped empty maps from config/nginx (maintenance_confcheck on upgrades):
#   docker exec cmm_el89 bash /opt/ci141/test-nginx-aicrawlers.sh
# Loads the shipped config/nginx/botlimit.conf at http level through a test
# conf.d file next to a 127.0.0.1:8140 test server, then checks the empty maps,
# dry-run, print, update (twice), status and cron-install/cron-remove.
# update downloads ai.robots.txt and the vendor crawler IP lists; checks that
# need a vendor list are reported as INFO when that list did not download.
# Exits 1 if any FAIL line is printed.
set -uo pipefail
centmin_dir=${CENTMIN_MOD_DIR:-/usr/local/src/centminmod}
tool=$centmin_dir/tools/nginx-aicrawlers.sh
conf_dir=/usr/local/nginx/conf
conf_d=$conf_dir/conf.d
aic_dir=$conf_dir/aicrawlers
state=/var/lib/centminmod/aicrawlers
cron_file=/etc/cron.d/centminmod-aicrawlers
site=$conf_dir/ci141-bots
work=$(mktemp -d /root/ci141-aicrawlers.XXXXXX)
failed=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
info() { echo "INFO: $*"; }
cleanup() {
  rm -f "$conf_d"/zz-ci141-botlimit.conf "$conf_d"/zz-ci141-bots.conf "$cron_file"
  nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1
  rm -rf "$site" "$work"
}
trap cleanup EXIT
googlebot='Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
browser='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'
gptbot='Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.1; +https://openai.com/gptbot)'
bot_header() { curl -s -m 10 -o /dev/null -D - -A "$1" http://127.0.0.1:8140/ | tr -d '\r' | sed -n 's/^[Xx]-[Cc][Ii]141-[Bb]ot: //p'; }
# burst <user agent>: 30 quick requests, prints "<200 count> <503 count>"
burst() {
  local c ok=0 limited=0
  for _ in $(seq 1 30); do
    c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -A "$1" http://127.0.0.1:8140/)
    [[ "$c" = 200 ]] && ok=$((ok + 1))
    [[ "$c" = 503 ]] && limited=$((limited + 1))
  done
  echo "$ok $limited"
}
reload() { nginx -t > /dev/null 2>&1 && nginx -s reload && sleep 2; }

if [[ ! -f "$tool" ]]; then
  fail "$tool missing"
  echo "RESULT: FAIL"
  exit 1
fi
command -v jq > /dev/null 2>&1 || dnf -y -q install jq < /dev/null > /dev/null 2>&1
command -v jq > /dev/null 2>&1 && pass "jq installed" || fail "jq not installed"

echo "== shipped empty maps (A2-stubs)"
for f in aicrawlers_ua.conf aicrawlers_ip.conf; do
  [[ -f "$aic_dir/$f" ]] && pass "$aic_dir/$f" || fail "$aic_dir/$f missing (not copied from config/nginx at install or by maintenance_confcheck)"
done
if nginx -T 2>/dev/null | grep -q 'map $http_user_agent $bot_agent_ua'; then
  fail "a botlimit.conf with the AI maps is already loaded, this test adds its own copy"
fi
cp -f "$centmin_dir/config/nginx/botlimit.conf" "$conf_d/zz-ci141-botlimit.conf"
mkdir -p "$site"
echo ok > "$site/ok.txt"
cat > "$conf_d/zz-ci141-bots.conf" <<NGX
server {
  listen 127.0.0.1:8140;
  root $site;
  # nodelay: sequential test requests over the rate get 503 instead of a delay
  limit_req zone=botb_reqlimitip burst=5 nodelay;
  if (\$bot_agent = '3') {
    return 444;
  }
  location / {
    add_header X-CI141-Bot "\$bot_agent \$aicrawler_claim \$aicrawler_verified" always;
    default_type text/plain;
    try_files /ok.txt =404;
  }
}
NGX
if nginx -t > "$work/t.log" 2>&1; then
  pass "nginx -t with botlimit.conf and the empty maps"
else
  fail "nginx -t rejects botlimit.conf with the empty maps:"
  tail -5 "$work/t.log"
  echo "RESULT: FAIL"
  exit 1
fi
reload
read -r ok limited <<< "$(burst "$googlebot")"
[[ "$ok" -eq 30 ]] && pass "Googlebot user agent, 30 requests: none rate limited" || fail "Googlebot user agent: $ok of 30 HTTP 200, $limited rate limited"
hdr=$(bot_header "$googlebot")
[[ "$hdr" = '1  ' ]] && pass "empty maps: Googlebot keeps level 1, no claim ('$hdr')" || fail "empty maps: Googlebot header '$hdr', expected '1  '"
hdr=$(bot_header "$browser")
[[ "$hdr" = '0  ' ]] && pass "browser user agent: level 0, no claim ('$hdr')" || fail "browser user agent header '$hdr', expected '0  '"
# return 444 closes the connection without a response: curl reports exit 52
# (empty reply) or 56 (connection reset), depending on how the close arrives
dropped() { [[ "$1" = 000 && ( "$2" -eq 52 || "$2" -eq 56 ) ]]; }
c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -A 'HTTrack' http://127.0.0.1:8140/)
rc=$?
dropped "$c" "$rc" && pass "HTTrack user agent dropped (444, curl exit $rc)" || fail "HTTrack user agent: HTTP $c, curl exit $rc"

echo "== dry-run and print"
sum_before=$(md5sum "$aic_dir"/*.conf)
bash "$tool" dry-run < /dev/null > "$work/dryrun.log" 2>&1
st=$?
head -40 "$work/dryrun.log"
[[ "$st" -eq 0 ]] && pass "dry-run exit 0" || fail "dry-run exit $st"
grep -q 'nginx -t on the generated files: ok' "$work/dryrun.log" && pass "dry-run: nginx -t on the generated files ok" || fail "dry-run: no 'nginx -t on the generated files: ok'"
grep -q 'dry-run: nothing written' "$work/dryrun.log" && pass "dry-run: nothing written" || fail "dry-run: no 'nothing written' line"
[[ "$(md5sum "$aic_dir"/*.conf)" = "$sum_before" ]] && pass "dry-run left the map files unchanged" || fail "dry-run changed the map files"
[[ ! -d "$state/json" ]] && pass "dry-run wrote no $state/json cache" || fail "dry-run wrote $state/json"
bash "$tool" print < /dev/null > "$work/print.log" 2>&1
st=$?
[[ "$st" -eq 0 ]] && pass "print exit 0" || fail "print exit $st"
grep -q 'map $http_user_agent $aicrawler_category' "$work/print.log" && pass "print shows the category map" || fail "print has no \$aicrawler_category map"

echo "== update"
bash "$tool" update < /dev/null > "$work/update1.log" 2>&1
st=$?
cat "$work/update1.log"
[[ "$st" -eq 0 ]] && pass "update exit 0" || fail "update exit $st"
grep -q 'nginx -t passed' "$work/update1.log" && pass "update installed the maps, nginx -t passed" || fail "update did not report 'nginx -t passed'"
grep -q 'GPTBot' "$aic_dir/aicrawlers_ua.conf" && pass "aicrawlers_ua.conf has GPTBot" || fail "aicrawlers_ua.conf has no GPTBot"
info "$(grep -c ' training;' "$aic_dir/aicrawlers_ua.conf") training, $(grep -c ' search;' "$aic_dir/aicrawlers_ua.conf") search, $(grep -c ' user;' "$aic_dir/aicrawlers_ua.conf") user, $(grep -c ' other;' "$aic_dir/aicrawlers_ua.conf") other user agent entries"
vendors=$(grep -oE '"([a-z]+):\1" 1;' "$aic_dir/aicrawlers_ip.conf" | cut -d: -f1 | tr -d '"' | xargs)
info "vendors with IP lists: ${vendors:-none}"
bash "$tool" update < /dev/null > "$work/update2.log" 2>&1
st=$?
[[ "$st" -eq 0 ]] && grep -q 'no changes in' "$work/update2.log" && pass "second update: no changes" || { fail "second update (exit $st) did not report no changes:"; tail -5 "$work/update2.log"; }
sleep 2
hdr=$(bot_header "$browser")
[[ "$hdr" = '0  ' ]] && pass "browser user agent after update: '$hdr'" || fail "browser user agent after update: '$hdr', expected '0  '"
if [[ " $vendors " = *" google "* ]]; then
  hdr=$(bot_header "$googlebot")
  [[ "$hdr" = '2 google 0' ]] && pass "spoofed Googlebot from 127.0.0.1 marked unverified, level 2 ('$hdr')" || fail "spoofed Googlebot header '$hdr', expected '2 google 0'"
  read -r ok limited <<< "$(burst "$googlebot")"
  [[ "$limited" -gt 0 ]] && pass "spoofed Googlebot rate limited ($limited of 30 HTTP 503)" || fail "spoofed Googlebot not rate limited ($ok of 30 HTTP 200)"
else
  info "Google crawler IP lists did not download, spoofed Googlebot checks skipped"
fi
sed -i -E 's/^([[:space:]]*training[[:space:]]+)0;/\13;/' "$conf_d/zz-ci141-botlimit.conf"
if reload; then
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -A "$gptbot" http://127.0.0.1:8140/)
  rc=$?
  dropped "$c" "$rc" && pass "training category at level 3: GPTBot dropped (444, curl exit $rc)" || fail "training category at level 3: GPTBot HTTP $c, curl exit $rc"
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -A "$browser" http://127.0.0.1:8140/)
  [[ "$c" = 200 ]] && pass "training category at level 3: browser HTTP 200" || fail "training category at level 3: browser HTTP $c"
else
  fail "nginx -t rejects botlimit.conf with training set to 3"
fi

echo "== status and cron"
bash "$tool" status < /dev/null > "$work/status.log" 2>&1
st=$?
cat "$work/status.log"
[[ "$st" -eq 0 ]] && pass "status exit 0" || fail "status exit $st"
grep -q '^last update run: [0-9]' "$work/status.log" && pass "status shows the last update run" || fail "status has no last update time"
bash "$tool" cron-install < /dev/null > "$work/cron.log" 2>&1
st=$?
cat "$work/cron.log"
[[ "$st" -eq 0 ]] && grep -qE '^[0-9]+ 5 \* \* \* root bash .*nginx-aicrawlers\.sh update ' "$cron_file" && pass "cron-install: daily 05:MM root entry" || fail "cron-install exit $st, $cron_file: $(cat "$cron_file" 2>&1)"
bash "$tool" cron-remove < /dev/null > /dev/null 2>&1
[[ ! -f "$cron_file" ]] && pass "cron-remove deleted $cron_file" || fail "cron-remove left $cron_file"

[[ "$failed" -eq 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$failed"
