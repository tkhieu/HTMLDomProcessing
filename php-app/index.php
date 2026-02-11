<?php
/**
 * PHP simple_html_dom Parser API
 *
 * Endpoints:
 *   GET  /health       — healthcheck cho Docker
 *   POST /parse        — parse 1 HTML input
 *   POST /parse_batch  — parse nhiều HTML cùng lúc (1 HTTP call)
 */

// Tắt deprecation notices (simplehtmldom 2.0-RC2 có trim(null) warning trên PHP 8.1)
error_reporting(E_ALL & ~E_DEPRECATED);

require 'vendor/autoload.php';

use simplehtmldom\HtmlDocument;

header('Content-Type: application/json; charset=utf-8');

$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

// --- Health check cho Docker ---
if ($uri === '/health') {
    echo json_encode(['status' => 'ok']);
    exit;
}

// Chỉ chấp nhận POST cho /parse và /parse_batch
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'Method not allowed']);
    exit;
}

// Đọc và validate JSON input
$raw = file_get_contents('php://input');
if ($raw === false || $raw === '') {
    http_response_code(400);
    echo json_encode(['error' => 'Empty request body']);
    exit;
}

$input = json_decode($raw, true);
if (json_last_error() !== JSON_ERROR_NONE) {
    http_response_code(400);
    echo json_encode(['error' => 'Invalid JSON: ' . json_last_error_msg()]);
    exit;
}

// Giới hạn thời gian xử lý (10s)
set_time_limit(10);

// --- Batch endpoint: parse nhiều HTML cùng lúc ---
if ($uri === '/parse_batch' && isset($input['batch']) && is_array($input['batch'])) {
    $results = [];
    foreach ($input['batch'] as $html) {
        if (!is_string($html)) {
            $results[] = ['result' => null, 'error' => 'Not a string'];
            continue;
        }
        $results[] = parseSingleHtml($html);
    }
    echo json_encode(['results' => $results]);
    exit;
}

// --- Single endpoint: parse 1 HTML ---
if ($uri === '/parse') {
    $html = $input['html'] ?? '';
    if (!is_string($html)) {
        http_response_code(400);
        echo json_encode(['error' => 'html field must be a string']);
        exit;
    }
    if ($html === '') {
        echo json_encode(['result' => '']);
        exit;
    }
    $result = parseSingleHtml($html);
    if (isset($result['error'])) {
        http_response_code(500);
    }
    echo json_encode($result);
    exit;
}

// --- 404 cho các route khác ---
http_response_code(404);
echo json_encode(['error' => 'Not found']);

/**
 * Parse 1 HTML string bằng simple_html_dom
 * Trả về ['result' => string] hoặc ['result' => null, 'error' => string]
 */
function parseSingleHtml(string $html): array
{
    $dom = new HtmlDocument();
    $dom->load($html);

    // load() luôn thành công (trả về $this), chỉ fail khi root null
    if ($dom->root === null) {
        return ['result' => null, 'error' => 'Parse failed'];
    }

    $result = (string) $dom;
    return ['result' => $result];
}
