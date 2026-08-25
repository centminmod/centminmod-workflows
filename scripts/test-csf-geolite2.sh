#!/usr/bin/env bash

set -uo pipefail

failures=0

summary() {
  printf '%s\n' "$1"
}

pass() {
  summary "PASS: $1"
}

fail() {
  summary "FAIL: $1"
  failures=$((failures + 1))
}

check() {
  local description=$1
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

run_shell() {
  bash -c "$1"
}

summary '## CSF and GeoLite2 assertions'

version=$(run_shell 'csf -v' 2>&1) || version='unable to determine'
summary "CSF version: ${version}"

check 'CSF reload succeeds' run_shell 'csf -ra >/tmp/csf-geolite2-reload.log 2>&1'
check 'CSF temporary-rule listing succeeds' run_shell 'csf -t >/dev/null 2>&1'
check 'csf service is active' systemctl is-active --quiet csf
check 'lfd service is active' systemctl is-active --quiet lfd

# The Centmin Mod mirror routing was introduced in CSF 16.33. Keep this test
# useful on stable/pre-promotion jobs without imposing 16.33 expectations on
# older packages.
if ! grep -q 'mxmind\.centminmod\.com' /usr/local/csf/lib/ConfigServer/Config.pm; then
  summary 'INFO: pre-16.33 CSF detected; GeoLite2 mirror assertions skipped'
  exit "$failures"
fi

cc_src=$(sed -n 's/^CC_SRC = "\([^"]*\)".*/\1/p' /etc/csf/csf.conf)
cc_lookups=$(sed -n 's/^CC_LOOKUPS = "\([^"]*\)".*/\1/p' /etc/csf/csf.conf)
summary "CC_SRC=${cc_src:-missing}; CC_LOOKUPS=${cc_lookups:-missing}; MM_LICENSE_KEY value intentionally hidden"

if [[ $cc_src == 1 ]]; then
  pass 'fresh install uses CC_SRC=1'
else
  fail "expected CC_SRC=1, got ${cc_src:-missing}"
fi
if [[ $cc_lookups == 1 ]]; then
  pass 'fresh install uses CC_LOOKUPS=1'
else
  fail "expected CC_LOOKUPS=1, got ${cc_lookups:-missing}"
fi
# This Perl program is intentionally single-quoted for execution in the container.
# shellcheck disable=SC2016
check 'fresh install has no injected/shared MaxMind key' \
  perl -ne 'BEGIN {$status=1} if (/^MM_LICENSE_KEY = "([^"]*)"/) {$status=length($1) ? 1 : 0} END {exit $status}' \
  /etc/csf/csf.conf

# This Perl program is intentionally single-quoted for execution in the container.
# shellcheck disable=SC2016
check 'empty key resolves all GeoLite2 archives to the Centmin Mod mirror' \
  perl -I/usr/local/csf/lib -MConfigServer::Config -e \
  'my $o=ConfigServer::Config->loadconfig(); my %c=$o->config(); exit !(($c{cc_src} || "") eq "Centmin Mod GeoLite2 mirror" && ($c{cc_country} || "") eq "https://mxmind.centminmod.com/GeoLite2-Country-CSV.zip" && ($c{cc_city} || "") eq "https://mxmind.centminmod.com/GeoLite2-City-CSV.zip" && ($c{cc_asn} || "") eq "https://mxmind.centminmod.com/GeoLite2-ASN-CSV.zip" && $c{cc_country} !~ /license_key=/ && $c{cc_city} !~ /license_key=/ && $c{cc_asn} !~ /license_key=/);'

geo_ready=0
for _attempt in {1..24}; do
  if [[ -s /var/lib/csf/Geo/GeoLite2-Country-Blocks-IPv4.csv &&
        -s /var/lib/csf/Geo/GeoLite2-Country-Blocks-IPv6.csv &&
        -s /var/lib/csf/Geo/GeoLite2-Country-Locations-en.csv ]]; then
    geo_ready=1
    break
  fi
  sleep 5
done

if ((geo_ready)); then
  pass 'required Country IPv4, IPv6 and location CSV files are non-empty'
else
  fail 'required Country IPv4, IPv6 and location CSV files were not ready within 120 seconds'
  tail -n 100 /var/log/lfd.log || true
fi

check 'lfd logged a successful Centmin Mod GeoLite2 mirror retrieval' \
  grep -Eq 'CCL: Retrieved Centmin Mod GeoLite2 mirror.*IP database' /var/log/lfd.log
# The array expression is intentionally single-quoted for the container shell.
# shellcheck disable=SC2016
check 'download archives and temporary files were cleaned up' run_shell \
  'shopt -s nullglob; files=(/var/lib/csf/Geo/*.zip /var/lib/csf/Geo/*.tmp); ((${#files[@]} == 0))'

if ((geo_ready)); then
  check 'known public IP country lookup resolves to US' run_shell \
    "csf -i 8.8.8.8 2>/dev/null | grep -Eq '(^|[/ (])US([/ )]|$)'"

  before="$(sha256sum /var/lib/csf/Geo/GeoLite2-Country-Blocks-IPv4.csv | awk '{print $1}') $(stat -c %Y /var/lib/csf/Geo/GeoLite2-Country-Blocks-IPv4.csv)"
  if run_shell 'csf -ra >/tmp/csf-geolite2-second-reload.log 2>&1'; then
    sleep 2
    after="$(sha256sum /var/lib/csf/Geo/GeoLite2-Country-Blocks-IPv4.csv | awk '{print $1}') $(stat -c %Y /var/lib/csf/Geo/GeoLite2-Country-Blocks-IPv4.csv)"
    if [[ $before == "$after" ]]; then
      pass 'second CSF reload preserves the fresh GeoLite2 database'
    else
      fail 'second CSF reload unexpectedly changed the fresh GeoLite2 database'
    fi
  else
    fail 'second CSF reload succeeds'
  fi
fi

redacted=$(perl -I/usr/local/csf/lib -MConfigServer::Logger -e \
  '$x=q{https://download.maxmind.com/app/x?license_key=ABCD1234567890 https://example.test/x?license_key=WXYZ987654321&api_secret=Secret123 hockey=score}; print ConfigServer::Logger::_redact_log_credentials($x)' \
  2>/dev/null) || redacted=''
if [[ $redacted == *'license_key=ABCD...REDACTED'* &&
      $redacted == *'https://example.test/x?license_key=REDACTED&api_secret=REDACTED'* &&
      $redacted == *'hockey=score'* &&
      $redacted != *'ABCD1234567890'* &&
      $redacted != *'WXYZ987654321'* &&
      $redacted != *'Secret123'* ]]; then
  pass 'logger exposes only the four-character MaxMind hint and redacts other secrets'
else
  fail 'logger credential-redaction behavior is incorrect'
fi

exit "$failures"
