<?php
/**
 * linux/test/router.php — a tiny stand-in for the MCR Fleet (workstream E)
 * REST API, used only to prove the mcr-agent enroll/heartbeat/command path.
 *
 * Run:  php -S 127.0.0.1:9900 router.php
 *
 * It generates a FRESH Ed25519 keypair on first use (written to keys.json in
 * the same dir) so the test never needs the real fleet secret. The agent under
 * test is pointed at this test public key via MCR_FLEET_PUBKEY. This proves the
 * verification LOGIC (accept fleet-signed, reject anything else) with a test key;
 * production pins the real key XkOx...=.
 *
 * Endpoints (contract-compatible with spec section E):
 *   POST /fleet/v1/enroll          -> {ok, node_id, node_secret}
 *   POST /fleet/v1/heartbeat       -> verify HMAC + replay; return signed commands
 *   POST /fleet/v1/command-result  -> store result
 * Plus test helpers:
 *   GET  /__pubkey                 -> {public_key}  (base64 raw, for the agent)
 *   POST /__queue                  -> queue a command for the next heartbeat
 *                                     body: {type, payload, sign:true|false, badkey:true}
 */

$DIR = __DIR__;
$STATE = $DIR . '/state.json';
$KEYS  = $DIR . '/keys.json';
$REPLAY_WINDOW = 300;

function jexit($arr, $code = 200) {
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($arr, JSON_UNESCAPED_SLASHES);
    exit;
}
function load_json($f, $def) { return is_file($f) ? (json_decode(file_get_contents($f), true) ?: $def) : $def; }
function save_json($f, $v) { file_put_contents($f, json_encode($v)); }

// --- keys: fleet signing keypair (TEST ONLY) + a wrong keypair -------------
$keys = load_json($KEYS, null);
if (!$keys) {
    $kp = sodium_crypto_sign_keypair();
    $wrong = sodium_crypto_sign_keypair();
    $keys = [
        'secret'     => base64_encode(sodium_crypto_sign_secretkey($kp)),
        'public'     => base64_encode(sodium_crypto_sign_publickey($kp)),
        'wrong_secret' => base64_encode(sodium_crypto_sign_secretkey($wrong)),
    ];
    save_json($KEYS, $keys);
}

$state = load_json($STATE, ['nodes' => [], 'queue' => [], 'results' => []]);

$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$method = $_SERVER['REQUEST_METHOD'];
$raw = file_get_contents('php://input');
$body = json_decode($raw, true) ?: [];

// --- test helpers ----------------------------------------------------------
if ($uri === '/__pubkey' && $method === 'GET') {
    jexit(['public_key' => $keys['public']]);
}
if ($uri === '/__queue' && $method === 'POST') {
    $type    = $body['type'] ?? 'restart-service';
    $payload = $body['payload'] ?? ['service' => 'nginx'];
    $sign    = $body['sign'] ?? true;
    $badkey  = $body['badkey'] ?? false;
    $cid = 'cmd_' . bin2hex(random_bytes(4));
    $payload_b64 = base64_encode(json_encode($payload));
    $msg = $cid . '|' . $type . '|' . $payload_b64;   // exact bytes the agent reconstructs
    $sig = '';
    if ($sign) {
        $sk = base64_decode($badkey ? $keys['wrong_secret'] : $keys['secret']);
        $sig = base64_encode(sodium_crypto_sign_detached($msg, $sk));
    } else {
        $sig = base64_encode(random_bytes(64)); // garbage
    }
    $state['queue'][] = ['id' => $cid, 'type' => $type, 'payload_b64' => $payload_b64, 'sig' => $sig];
    save_json($STATE, $state);
    jexit(['ok' => true, 'queued' => $cid]);
}
if ($uri === '/__results' && $method === 'GET') {
    jexit(['results' => $state['results']]);
}
if ($uri === '/__reset' && $method === 'POST') {
    @unlink($STATE);
    jexit(['ok' => true]);
}

// --- enroll ----------------------------------------------------------------
if ($uri === '/fleet/v1/enroll' && $method === 'POST') {
    $token = $body['token'] ?? '';
    if ($token === '') jexit(['ok' => false, 'code' => 'bad_request'], 400);
    // (demo) accept any non-empty token
    $node_id = 'node_' . bin2hex(random_bytes(5));
    $node_secret = base64_encode(random_bytes(32));
    $state['nodes'][$node_id] = [
        'secret' => $node_secret,
        'seen_ts' => [],
        'profile' => $body['node'] ?? null,
    ];
    save_json($STATE, $state);
    jexit(['ok' => true, 'node_id' => $node_id, 'node_secret' => $node_secret]);
}

// --- heartbeat -------------------------------------------------------------
if ($uri === '/fleet/v1/heartbeat' && $method === 'POST') {
    $node_id = $_SERVER['HTTP_X_MCR_NODE'] ?? '';
    $ts      = (int)($_SERVER['HTTP_X_MCR_TIMESTAMP'] ?? 0);
    $sig     = $_SERVER['HTTP_X_MCR_SIGNATURE'] ?? '';
    if (!isset($state['nodes'][$node_id])) jexit(['ok' => false, 'code' => 'unknown_node'], 401);
    $secret = $state['nodes'][$node_id]['secret'];

    // verify HMAC over exact body bytes (constant-time)
    $expect = hash_hmac('sha256', $raw, $secret);
    if (!hash_equals($expect, $sig)) jexit(['ok' => false, 'code' => 'bad_signature'], 401);

    // replay window
    $now = time();
    if (abs($now - $ts) > $GLOBALS['REPLAY_WINDOW']) jexit(['ok' => false, 'code' => 'replay'], 401);
    if (in_array($ts, $state['nodes'][$node_id]['seen_ts'], true)) jexit(['ok' => false, 'code' => 'replay'], 401);
    $state['nodes'][$node_id]['seen_ts'][] = $ts;

    // hand back queued commands, then clear the queue
    $cmds = $state['queue'];
    $state['queue'] = [];
    save_json($STATE, $state);
    jexit(['ok' => true, 'commands' => $cmds]);
}

// --- command-result --------------------------------------------------------
if ($uri === '/fleet/v1/command-result' && $method === 'POST') {
    $node_id = $_SERVER['HTTP_X_MCR_NODE'] ?? '';
    $sig     = $_SERVER['HTTP_X_MCR_SIGNATURE'] ?? '';
    if (!isset($state['nodes'][$node_id])) jexit(['ok' => false], 401);
    $secret = $state['nodes'][$node_id]['secret'];
    if (!hash_equals(hash_hmac('sha256', $raw, $secret), $sig)) jexit(['ok' => false, 'code' => 'bad_signature'], 401);
    $state['results'][] = $body;
    save_json($STATE, $state);
    jexit(['ok' => true]);
}

jexit(['ok' => false, 'code' => 'not_found', 'uri' => $uri], 404);
