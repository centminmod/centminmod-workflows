<?php
declare(strict_types=1);

// Run with PHP 8.4: php php-igbinary-benchmark.php y|n, or --self-test.
function requireCheck(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function fixtures(): array
{
    $posts = $unique = [];
    for ($i = 0; $i < 200; $i++) {
        $posts[] = (object) ['ID' => $i, 'post_title' => "Post $i", 'post_status' => 'publish',
            'meta' => ['template' => 'default', 'views' => $i * 17, 'tags' => ['php', 'cache']]];
        $unique[hash('sha256', "key-$i")] = hash('sha256', "value-$i");
    }
    return [
        'session' => ['user_id' => 123, 'roles' => ['editor'], 'cart' => [12 => 2, 35 => 1], 'logged_in' => true],
        'posts' => $posts,
        'numeric' => range(0, 1999),
        'unique_strings' => $unique,
    ];
}

function sameValue(mixed $expected, mixed $actual): void
{
    requireCheck(serialize($expected) === serialize($actual), 'Round trip changed values, types or object references');
}

function sample(callable $operation, int $iterations): array
{
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $last = $operation($i);
        requireCheck($last !== false, 'Timed operation failed');
    }
    return [(hrtime(true) - $start) / $iterations, $last];
}

function summary(array $samples): array
{
    sort($samples, SORT_NUMERIC);
    return ['median_ns_op' => $samples[intdiv(count($samples), 2)],
        'min_ns_op' => $samples[0], 'max_ns_op' => $samples[count($samples) - 1], 'samples_ns_op' => $samples];
}

try {
    $data = fixtures();
    requireCheck(count(array_unique(array_map('spl_object_id', $data['posts']))) === 200, 'Posts must be independent objects');
    foreach ($data as $value) {
        sameValue($value, unserialize(serialize($value)));
    }
    $shared = (object) ['value' => 1];
    $references = [$shared, $shared];
    if (PHP_SAPI === 'cli' && ($argv[1] ?? '') === '--self-test') {
        sameValue($references, unserialize(serialize($references)));
        requireCheck(summary([3, 1, 2])['median_ns_op'] === 2, 'Median calculation failed');
        echo "PASS: independent fixtures, native round trips, shared references and sample summary\n";
        exit(0);
    }

    $expected = PHP_SAPI === 'cli' ? ($argv[1] ?? '') : ($_GET['igbinary'] ?? '');
    requireCheck(in_array($expected, ['y', 'n'], true), 'Expected igbinary support must be y or n');
    requireCheck(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 4, 'This benchmark targets PHP 8.4');
    requireCheck(PHP_SAPI === 'cli' || PHP_SAPI === 'fpm-fcgi', 'Expected CLI or PHP-FPM');
    requireCheck(extension_loaded('igbinary') && extension_loaded('redis'), 'igbinary and redis extensions must load');
    $client = new Redis();
    requireCheck($client->getOption(Redis::OPT_SERIALIZER) === Redis::SERIALIZER_NONE, 'Default Redis serializer changed');
    $available = defined('Redis::SERIALIZER_IGBINARY') && $client->setOption(Redis::OPT_SERIALIZER, Redis::SERIALIZER_IGBINARY);
    requireCheck($available === ($expected === 'y'), 'PhpRedis igbinary capability differs from the build setting');
    sameValue($references, igbinary_unserialize(igbinary_serialize($references)));

    $report = ['metadata' => [
        'php' => PHP_VERSION, 'sapi' => PHP_SAPI, 'igbinary' => phpversion('igbinary'), 'redis' => phpversion('redis'),
        'redis_igbinary' => $available, 'ini' => php_ini_loaded_file(), 'scanned_ini' => php_ini_scanned_files(),
        'session_serializer' => ini_get('session.serialize_handler'), 'compact_strings' => ini_get('igbinary.compact_strings'),
        'opcache' => ini_get('opcache.enable'), 'opcache_cli' => ini_get('opcache.enable_cli'), 'jit' => ini_get('opcache.jit'),
        'rounds' => 5, 'serialization_iterations' => 200, 'redis_iterations' => 100,
        'compression_levels' => ['lz4' => 0, 'zstd' => 3],
        'fixture_sha256' => hash('sha256', serialize($data)),
        'timing' => 'elapsed nanoseconds per operation, including PHP loop, callback and error-check overhead',
    ], 'serialization' => [], 'redis' => []];

    $originalCompact = ini_get('igbinary.compact_strings');
    foreach ($data as $name => $value) {
        $cases = [
            'php' => ['serialize', 'unserialize', null],
            'igbinary_compact' => ['igbinary_serialize', 'igbinary_unserialize', '1'],
            'igbinary_no_compact' => ['igbinary_serialize', 'igbinary_unserialize', '0'],
        ];
        $encodeSamples = $decodeSamples = [];
        for ($round = 0; $round < 5; $round++) {
            foreach (($round % 2 ? array_reverse($cases, true) : $cases) as $case => [$encode, $decode, $compact]) {
                if ($compact !== null) {
                    ini_set('igbinary.compact_strings', $compact);
                }
                $encoded = $encode($value);
                sameValue($value, $decode($encoded));
                sample(fn() => $encode($value), 20);
                sample(fn() => $decode($encoded), 20);
                [$elapsed, $last] = sample(fn() => $encode($value), 200);
                requireCheck($last === $encoded, 'Non-deterministic serialization');
                $encodeSamples[$case][] = $elapsed;
                [$elapsed, $last] = sample(fn() => $decode($encoded), 200);
                sameValue($value, $last);
                $decodeSamples[$case][] = $elapsed;
                $report['serialization'][$name][$case] = ['bytes' => strlen($encoded),
                    'encode' => summary($encodeSamples[$case]), 'decode' => summary($decodeSamples[$case])];
            }
        }
    }
    ini_set('igbinary.compact_strings', $originalCompact);

    requireCheck($client->connect('127.0.0.1', 6379, 2.0), 'Redis connection failed');
    $raw = new Redis();
    requireCheck($raw->connect('127.0.0.1', 6379, 2.0), 'Raw Redis connection failed');
    $report['metadata']['redis_server'] = $raw->info('server')['redis_version'];
    $prefix = 'cmm:igbinary:' . bin2hex(random_bytes(12)) . ':';
    $keys = [];
    try {
        $serializers = ['php' => Redis::SERIALIZER_PHP];
        if ($available) {
            $serializers['igbinary'] = Redis::SERIALIZER_IGBINARY;
        }
        foreach (['COMPRESSION_LZ4', 'COMPRESSION_ZSTD'] as $constant) {
            requireCheck(defined("Redis::$constant"), "Redis $constant support is missing");
        }
        $compressors = ['none' => Redis::COMPRESSION_NONE, 'lz4' => Redis::COMPRESSION_LZ4, 'zstd' => Redis::COMPRESSION_ZSTD];
        $cases = [];
        foreach ($serializers as $serializerName => $serializer) {
            foreach ($compressors as $compressionName => $compression) {
                $cases["$serializerName+$compressionName"] = [$serializer, $compression];
            }
        }
        foreach ($data as $name => $value) {
            $samples = [];
            for ($round = 0; $round < 5; $round++) {
                foreach (($round % 2 ? array_reverse($cases, true) : $cases) as $case => [$serializer, $compression]) {
                    requireCheck($client->setOption(Redis::OPT_SERIALIZER, $serializer), 'Cannot select serializer');
                    requireCheck($client->setOption(Redis::OPT_COMPRESSION, $compression), 'Cannot select compression');
                    // Reset the level so a preceding Zstd case cannot select LZ4 HC.
                    requireCheck($client->setOption(Redis::OPT_COMPRESSION_LEVEL,
                        $compression === Redis::COMPRESSION_ZSTD ? 3 : 0), 'Cannot set compression level');
                    $key = "$prefix$name:$case";
                    $keys[$key] = true;
                    requireCheck($client->set($key, $value, 120), 'Redis SET failed');
                    sameValue($value, $client->get($key));
                    sample(fn() => $client->get($key), 20);
                    foreach (['set', 'get', 'read95_write5', 'read50_write50'] as $operation) {
                        $call = match ($operation) {
                            'set' => fn() => $client->set($key, $value, 120),
                            'get' => fn() => $client->get($key),
                            'read95_write5' => fn($i) => $i % 20 === 0 ? $client->set($key, $value, 120) : $client->get($key),
                            'read50_write50' => fn($i) => $i % 2 === 0 ? $client->set($key, $value, 120) : $client->get($key),
                        };
                        [$elapsed, $last] = sample($call, 100);
                        if ($operation === 'set') {
                            requireCheck($last === true, 'Redis SET failed');
                        } else {
                            sameValue($value, $last);
                        }
                        $samples[$case][$operation][] = $elapsed;
                        $report['redis'][$name][$case][$operation] = summary($samples[$case][$operation]);
                    }
                    $report['redis'][$name][$case]['stored_bytes'] = $raw->rawCommand('STRLEN', $key);
                    $report['redis'][$name][$case]['memory_usage_bytes'] = $raw->rawCommand('MEMORY', 'USAGE', $key);
                }
            }
        }
    } finally {
        foreach (array_keys($keys) as $key) {
            $raw->del($key);
        }
    }
    if (PHP_SAPI !== 'cli') {
        header('Content-Type: application/json');
    }
    echo json_encode($report, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
} catch (Throwable $error) {
    if (PHP_SAPI !== 'cli') {
        http_response_code(500);
        header('Content-Type: application/json');
    }
    echo json_encode(['error' => $error->getMessage()], JSON_THROW_ON_ERROR), "\n";
    exit(1);
}
