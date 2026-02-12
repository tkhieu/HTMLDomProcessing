<?php
/**
 * PHP simple_html_dom Parser API
 *
 * Endpoints:
 *   GET  /health       — healthcheck cho Docker
 *   POST /parse        — parse 1 HTML input
 *   POST /parse_batch  — parse nhieu HTML cung luc (1 HTTP call)
 */

// Tat deprecation notices (simplehtmldom 2.0-RC2 co trim(null) warning tren PHP 8.1)
error_reporting(E_ALL & ~E_DEPRECATED);

require 'vendor/autoload.php';
require 'simple_html_dom.php';

use simplehtmldom\HtmlDocument;

header('Content-Type: application/json; charset=utf-8');

$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

// --- Health check cho Docker ---
if ($uri === '/health') {
    echo json_encode(['status' => 'ok']);
    exit;
}

// Chi chap nhan POST cho /parse va /parse_batch
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'Method not allowed']);
    exit;
}

// Doc va validate JSON input
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

// Gioi han thoi gian xu ly (10s)
set_time_limit(10);

// --- Batch endpoint: parse nhieu HTML cung luc ---
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

// --- Peraichi SHD: parse 1 HTML bang str_get_html ---
if ($uri === '/parse_peraichi') {
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
    $result = parsePeraichiHtml($html);
    if (isset($result['error'])) {
        http_response_code(500);
    }
    echo json_encode($result);
    exit;
}

// --- Peraichi SHD batch: parse nhieu HTML bang str_get_html ---
if ($uri === '/parse_peraichi_batch' && isset($input['batch']) && is_array($input['batch'])) {
    $results = [];
    foreach ($input['batch'] as $html) {
        if (!is_string($html)) {
            $results[] = ['result' => null, 'error' => 'Not a string'];
            continue;
        }
        $results[] = parsePeraichiHtml($html);
    }
    echo json_encode(['results' => $results]);
    exit;
}

// --- 404 cho cac route khac ---
http_response_code(404);
echo json_encode(['error' => 'Not found']);

/**
 * Parse 1 HTML string bang Peraichi simple_html_dom (str_get_html)
 * Tra ve ['result' => string] hoac ['result' => null, 'error' => string]
 */
function parsePeraichiHtml(string $html): array
{
    $dom = str_get_html($html);

    if ($dom === false) {
        return ['result' => null, 'error' => 'Parse failed'];
    }

    $result = (string) $dom;

    // Giai phong bo nho
    $dom->clear();
    unset($dom);

    return ['result' => $result];
}

/**
 * Parse 1 HTML string bang simple_html_dom
 * Tra ve ['result' => string] hoac ['result' => null, 'error' => string]
 */
function parseSingleHtml(string $html): array
{
    $dom = new HtmlDocument();
    $dom->load($html);

    // Kiem tra xem co parse duoc khong
    if ($dom->root === null || $dom->root->childNodes() === []) {
        // Neu input khong rong nhung parse ra rong => co the loi
        if (trim($html) !== '') {
            return ['result' => null, 'error' => 'Parse failed'];
        }
    }

    $result = (string) $dom;
    return ['result' => $result];
}
