<?php
/**
 * curl_sanity.php  —  verify that PHP really uses the custom libcurl
 * Works on PHP ≥ 7.1 (7.x uses bit-mask, 8.x returns string-list).
 */

echo "PHP ".PHP_VERSION.PHP_EOL;

$cv = curl_version();
echo "libcurl {$cv['version']}  ({$cv['ssl_version']})".PHP_EOL;

/* ---- 1. confirm the desired libcurl version ----------------------- */
/* optional argv[1] = expected libcurl version. Without it, expect the */
/* custom libcurl Centmin Mod built: compile_custom_curl picks the     */
/* version per OpenSSL and installs it, with its libcurl.pc, under     */
/* /opt/curl_php (CURL_PHP_PREFIX env overrides that prefix)           */
$expected = $argv[1] ?? '';
if ($expected === '') {
    $pc = (getenv('CURL_PHP_PREFIX') ?: '/opt/curl_php').'/lib/pkgconfig/libcurl.pc';
    if (!is_readable($pc) || !preg_match('/^Version:\s*(\S+)/m', (string)file_get_contents($pc), $m)) {
        echo "ERROR: no expected libcurl version: pass one as argv[1] or install the custom libcurl (cannot read a Version: line from $pc)".PHP_EOL; exit(1);
    }
    $expected = $m[1];
    echo "Expected libcurl $expected (from $pc)".PHP_EOL;
}
if ($cv['version'] !== $expected) {
    echo "ERROR: PHP linked to the wrong libcurl (expected $expected)".PHP_EOL; exit(1);
}

/* ---- 2. feature detection ----------------------------------------- */
$need = [
    'SSL'   => defined('CURL_VERSION_SSL')   ? CURL_VERSION_SSL   : 0,
    'HTTP2' => defined('CURL_VERSION_HTTP2') ? CURL_VERSION_HTTP2 : 0,
    'IPv6'  => defined('CURL_VERSION_IPV6')  ? CURL_VERSION_IPV6  : 0,
];

$missing = [];
if (is_int($cv['features'])) {          // PHP 7 → uses bit-mask
    foreach ($need as $name => $flag) {
        if (!($cv['features'] & $flag)) $missing[] = $name;
    }
} else {                                // PHP 8.1+ → array of strings
    foreach (array_keys($need) as $name) {
        if (!in_array($name, $cv['features'], true)) $missing[] = $name;
    }
}
if ($missing) {
    echo "ERROR: libcurl lacks ".implode(', ', $missing).PHP_EOL; exit(1);
}

/* helper: map numeric http_version → text */
function httpVer(int $v): string {
    if ($v === CURL_HTTP_VERSION_1_0) return '1.0';
    if ($v === CURL_HTTP_VERSION_1_1) return '1.1';
    if (defined('CURL_HTTP_VERSION_2') && $v === CURL_HTTP_VERSION_2) return '2';
    if (defined('CURL_HTTP_VERSION_3') && $v === CURL_HTTP_VERSION_3) return '3';
    return (string)$v;
}

/* ---- 3. simple online checks -------------------------------------- */
$tests = [
    [ 'url' => 'http://example.com/',          'expect' => 200, 'httpver' => CURL_HTTP_VERSION_1_1 ],
    [ 'url' => 'https://example.com/',         'expect' => 200, 'httpver' => CURL_HTTP_VERSION_1_1 ],
    [ 'url' => 'https://httpbin.org/get',      'expect' => 200,
      'httpver' => defined('CURL_HTTP_VERSION_2TLS') ? CURL_HTTP_VERSION_2TLS
                                                     : (defined('CURL_HTTP_VERSION_2') ? CURL_HTTP_VERSION_2
                                                                                        : CURL_HTTP_VERSION_1_1) ],
];

foreach ($tests as $t) {
    echo PHP_EOL.">>> {$t['url']}".PHP_EOL;
    $ch = curl_init($t['url']);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 10,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_HTTP_VERSION   => $t['httpver'],
        CURLOPT_USERAGENT      => 'curl-sanity/1.0',
    ]);
    $body = curl_exec($ch);
    if ($body === false) {
        echo "cURL error: ".curl_error($ch).PHP_EOL; exit(1);
    }
    $info = curl_getinfo($ch);
    curl_close($ch);

    echo "HTTP {$info['http_code']} over HTTP/".httpVer($info['http_version']).PHP_EOL;
    if ($info['http_code'] !== $t['expect']) {
        echo "ERROR: unexpected status code".PHP_EOL; exit(1);
    }
}

echo PHP_EOL."All cURL tests passed ✓".PHP_EOL;
exit(0);
