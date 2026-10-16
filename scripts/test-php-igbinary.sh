#!/bin/bash
# Run inside the disposable AlmaLinux 10 CI container after install and rebuild.
set -euo pipefail
trap 'printf "FAIL: line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
stage=${1:?before or after}
expected=${2:?y or n}
source_sha=${3:?expected source SHA}
redis_source=${4:?stable or git}
[[ "$stage" = before || "$stage" = after ]]
[[ "$expected" = y || "$expected" = n ]]
[[ "$redis_source" = stable || "$redis_source" = git ]]
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" = almalinux && "$VERSION_ID" = 10* ]]
centmin_dir=/usr/local/src/centminmod
[[ "$(git -C "$centmin_dir" rev-parse HEAD)" = "$source_sha" ]]
[[ "$(/usr/local/bin/php-config --version)" = 8.4.26 ]]
output=/root/centminlogs/php-igbinary
mkdir -p "$output"
{
    cat /etc/os-release
    lscpu
    git -C "$centmin_dir" rev-parse HEAD
    git -C "$centmin_dir" diff -- centmin.sh
    /usr/local/bin/php-config --configure-options
    if [[ -f /svr-setup/php-8.4.26/fpm-build/Makefile ]]; then
        sed -n -E '/^(CC|CXX|CFLAGS|CFLAGS_CLEAN|CXXFLAGS|LDFLAGS) = /p' \
            /svr-setup/php-8.4.26/fpm-build/Makefile
    else
        echo 'Build tree cleaned; compiler commands are retained in the workflow install/rebuild logs.'
    fi
    /usr/local/bin/php --ini
    /usr/local/bin/php --ri igbinary
    /usr/local/bin/php --ri redis
    rpm -q libzstd libzstd-devel lz4 lz4-devel
} > "$output/$stage-environment.txt"
/usr/local/sbin/php-fpm -t
for cmm_service in php-fpm nginx redis; do
    systemctl is-active --quiet "$cmm_service" || { echo "$cmm_service is not active" >&2; exit 1; }
done
fpm_pid=$(systemctl show --property MainPID --value php-fpm)
cmp -s "/proc/$fpm_pid/exe" /usr/local/sbin/php-fpm
endpoint=/usr/local/nginx/html/cmm-igbinary-benchmark.php
trap 'rm -f "$endpoint"' EXIT
install -m 0644 /opt/php-igbinary-benchmark.php "$endpoint"
/usr/local/bin/php /opt/php-igbinary-benchmark.php "$expected" > "$output/$stage-cli.json"
curl --fail --silent --show-error --max-time 120 -H 'Host: localhost' \
    "http://127.0.0.1/cmm-igbinary-benchmark.php?igbinary=$expected" > "$output/$stage-fpm.json"
python3 - "$output" "$stage" "$expected" "$redis_source" <<'PY'
import json
import pathlib
import sys

root, stage, expected = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == 'y'
redis_source = sys.argv[4]
summary = [f'\n{stage}, PhpRedis={redis_source}, PHPREDIS_IGBINARY={"y" if expected else "n"}\n',
           '| SAPI | Posts serializer/compression | Stored bytes | Redis allocation bytes | SET us | GET us |',
           '|---|---|---:|---:|---:|---:|']
for mode, sapi in [('cli', 'cli'), ('fpm', 'fpm-fcgi')]:
    result = json.loads((root / f'{stage}-{mode}.json').read_text())
    assert result['metadata']['sapi'] == sapi, result
    assert result['metadata']['redis_igbinary'] == expected, result
    if redis_source == 'stable':
        assert result['metadata']['redis'] == '6.3.0', result['metadata']
    assert len(result['serialization']) == 4 and len(result['redis']) == 4, result
    assert all(len(cases) == (6 if expected else 3) for cases in result['redis'].values()), result
    if stage == 'after':
        before = json.loads((root / f'before-{mode}.json').read_text())
        for field in ['php', 'igbinary', 'redis', 'session_serializer', 'compact_strings', 'fixture_sha256']:
            assert result['metadata'][field] == before['metadata'][field], field
    print(f'PASS: {stage} {mode}, igbinary={expected}, serialization and Redis benchmarks completed')
    for case, measurements in result['redis']['posts'].items():
        summary.append(f'| {mode} | {case} | {measurements["stored_bytes"]} | '
                       f'{measurements["memory_usage_bytes"]} | '
                       f'{measurements["set"]["median_ns_op"] / 1000:.2f} | '
                       f'{measurements["get"]["median_ns_op"] / 1000:.2f} |')
(root / f'{stage}-summary.txt').write_text('\n'.join(summary) + '\n')
PY
