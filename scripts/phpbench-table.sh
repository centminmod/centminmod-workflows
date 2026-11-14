#!/bin/bash
# Tabulate phpbench.sh results as one markdown table.
# Each LOG is the concatenated /home/phpbench_logs/phpbench-summary-*.log
# files of one job; the file name without .log labels that job's rows.
# Rows are sorted by PHP version so the same version from each job sits together.
# usage: phpbench-table.sh LOG...

echo "| PHP Version | Job | bench.php | micro_bench.php | detailed_benchmark.php | Total |"
echo "|-------------|-----|-----------|-----------------|------------------------|-------|"
for log in "$@"; do
  [ -s "$log" ] || continue
  awk -F ' : ' -v job="$(basename "$log" .log)" '
    { sub(/\r$/, "") }
    $2 == "bench.php avg" { php = $1; sub(/ centminmod\.com php-fpm/, "", php); b = $3 }
    $2 == "micro_bench.php avg" { m = $3 }
    $2 == "detailed_benchmark.php total avg" {
      d = $3
      total = (b == "" || m == "" || d == "") ? "n/a" : sprintf("%.4f", b + m + d)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", php, job, b, m, d, total
      php = b = m = d = ""
    }' "$log"
done | sort -s -t $'\t' -k1,1V | awk -F '\t' '{ printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6 }'
