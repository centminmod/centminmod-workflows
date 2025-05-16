<?php
/**
 * curl_sanity.php  —  verify that PHP really uses the custom libcurl
 * Works on PHP ≥ 7.1 (7.x uses bit-mask, 8.x returns string-list).
 */

echo "PHP ".PHP_VERSION.PHP_EOL;

$cv = curl_version();
echo "libcurl {$cv['version']}  ({$cv['ssl_version']})".PHP_EOL;

/* ---- 1. confirm the desired libcurl version ----------------------- */
if ($cv['version'] !== '8.13.0') {
    echo "ERROR: PHP linked to the wrong libcurl".PHP_EOL; exit(1);
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
