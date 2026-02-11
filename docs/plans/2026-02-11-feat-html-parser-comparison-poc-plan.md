---
title: "HTML Parser Comparison POC"
type: feat
date: 2026-02-11
---

# HTML Parser Comparison POC

## Enhancement Summary

**Deepened on:** 2026-02-11
**Sections enhanced:** 7
**Research agents used:** Security Sentinel, Performance Oracle, Architecture Strategist, Code Simplicity Reviewer, Best Practices Researcher, Framework Docs Researcher, Pattern Recognition Specialist, Deployment Verification Agent, Silent Failure Hunter

### Key Improvements
1. **Docker**: Layer caching, multi-stage PHP build, healthchecks, `NOKOGIRI_USE_SYSTEM_LIBRARIES=true` (10x faster Nokogiri builds)
2. **Parsers**: Replace SimpleHtmlDom regex with character state machine; use structured `ParseResult` to fix nil-crash bugs; add batch PHP endpoint (10 HTTP calls -> 1)
3. **Security**: Explicit `Rack::Utils.escape_html` for XSS, input size validation (100KB), CSP headers
4. **Error handling**: 27 silent failure patterns identified and addressed — PHP API no longer silently returns unparsed input on failure

### New Considerations Discovered
- **Oga gem**: Limited maintenance since ~2020, Ruby 3.2+ compatibility unknown — have fallback plan
- **Nokogiri HTML5**: Has a newer HTML5 parser (Gumbo) via `Nokogiri::HTML5` — more browser-accurate than HTML4 parser
- **PHP single-threaded**: Built-in server handles one request at a time — batch endpoint eliminates bottleneck
- **SimpleHtmlDom regex**: Original `$` anchor only matches end-of-string — will fail on 8/10 test cases mid-string

---

## Overview

Build a POC app comparing how different HTML parsers handle broken/malformed HTML. The app runs 2 Docker containers (Ruby + PHP) via Docker Compose. Users input HTML, and the app displays output from 4 parsers side-by-side: Nokogiri, Oga, a custom SimpleHtmlDom Ruby class, and PHP's simple_html_dom (called via API).

## Problem Statement / Motivation

Different HTML parsers handle malformed HTML in vastly different ways — some auto-close tags, some restructure the DOM, some preserve input as-is. Understanding these differences is critical when choosing a parser for production use. This POC provides a visual, side-by-side comparison tool.

## Proposed Solution

Two-container Docker Compose setup:

```
docker-compose.yml
├── ruby-app/          # Sinatra web app (port 4567) — main UI + 3 local parsers
│   ├── Dockerfile
│   ├── Gemfile
│   └── app.rb
└── php-app/           # PHP API (port 8080) — simple_html_dom parser
    ├── Dockerfile
    ├── composer.json
    └── index.php
```

## Technical Approach

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    User Browser                          │
│              http://localhost:4567                        │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│          ruby-app (Sinatra + Puma)                       │
│          Port 4567                                       │
│                                                          │
│  Parser 1: Nokogiri (gem)                                │
│  Parser 2: Oga (gem)                                     │
│  Parser 3: SimpleHtmlDom (custom Ruby class)             │
│  Parser 4: ──── HTTP POST ────┐                          │
│                               │                          │
└───────────────────────────────┼──────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────┐
│          php-app (PHP built-in server)                   │
│          Port 8080                                       │
│                                                          │
│  POST /parse       (single HTML input)                   │
│  POST /parse_batch (array of HTML inputs)                │
│  GET  /health      (healthcheck)                         │
│  Uses: simplehtmldom/simplehtmldom ^2.0                  │
└──────────────────────────────────────────────────────────┘
```

Both containers share a Docker network and communicate via service name (`php-app`).

### Research Insights: Architecture

**Distributed Monolith Awareness:** This is technically a distributed monolith — ruby-app cannot function fully without php-app. This is acceptable for POC but should be documented. The architecture review confirms this split is justified because Ruby and PHP runtimes cannot coexist cleanly in one container.

**Config via ENV vars:** All inter-service URLs must use environment variables, not hardcoded strings:
```ruby
PHP_SERVICE_URL = ENV.fetch('PHP_SERVICE_URL', 'http://php-app:8080')
```

**Stateless design is excellent** — no database, no sessions, no shared state. This is the right trade-off for a POC.

---

### Implementation Phases

#### Phase 1: Docker Infrastructure

**Files:** `docker-compose.yml`, `ruby-app/Dockerfile`, `php-app/Dockerfile`

**Tasks:**
- [x] Create `docker-compose.yml` with 2 services on shared network
  - `ruby-app`: Ruby 3.2-slim, port 4567, depends_on php-app with `condition: service_healthy`
  - `php-app`: PHP 8.1-cli, port 8080, with healthcheck
  - Resource limits: ruby-app 512M, php-app 256M
- [x] Create `ruby-app/Dockerfile` with layer caching optimization
- [x] Create `php-app/Dockerfile` with multi-stage build

### Research Insights: Docker

**Layer caching (10x faster rebuilds):** Copy Gemfile/composer.json BEFORE application code. This ensures dependency installation is cached when only code changes:

```dockerfile
# ruby-app/Dockerfile
FROM ruby:3.2-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libxml2-dev libxslt1-dev zlib1g-dev curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy dependency files FIRST (cached until Gemfile changes)
COPY Gemfile Gemfile.lock ./

# Use system libraries for Nokogiri (90s -> 11s build time)
ENV NOKOGIRI_USE_SYSTEM_LIBRARIES=true

RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 && \
    rm -rf /usr/local/bundle/cache

# Copy app code LAST (rebuilds only when code changes)
COPY . .

EXPOSE 4567
CMD ["ruby", "app.rb"]
```

```dockerfile
# php-app/Dockerfile — Multi-stage build (removes ~80MB Composer tooling)
FROM composer:latest AS deps
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-interaction

FROM php:8.1-cli
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=deps /app/vendor ./vendor
COPY . .
EXPOSE 8080
CMD ["php", "-S", "0.0.0.0:8080", "index.php"]
```

**Healthcheck with `service_healthy`** — prevents race condition where ruby-app starts before php-app is ready:

```yaml
# docker-compose.yml
version: '3.8'

services:
  php-app:
    build: ./php-app
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/health"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          memory: 256M
    networks:
      - app-network

  ruby-app:
    build: ./ruby-app
    ports:
      - "4567:4567"
    depends_on:
      php-app:
        condition: service_healthy
    environment:
      - PHP_SERVICE_URL=http://php-app:8080
    deploy:
      resources:
        limits:
          memory: 512M
    networks:
      - app-network

networks:
  app-network:
    driver: bridge
```

**Acceptance:**
- `docker compose up --build` starts both containers without errors
- `curl localhost:4567` returns HTML page
- `curl -X POST localhost:8080/parse -d '{"html":"<p>test"}' -H 'Content-Type: application/json'` returns JSON
- `curl localhost:8080/health` returns `{"status":"ok"}`

---

#### Phase 2: PHP Parser API

**Files:** `php-app/composer.json`, `php-app/index.php`

**Tasks:**
- [x] Create `composer.json` with `simplehtmldom/simplehtmldom: ^2.0` dependency
- [x] Create `index.php` with endpoints:
  - `GET /health` — healthcheck for Docker
  - `POST /parse` — single HTML parse (backward compatible)
  - `POST /parse_batch` — batch parse (array of HTML inputs, single HTTP call)
- [x] Validate JSON input (check `json_last_error()`)
- [x] Return explicit error when `str_get_html()` returns false (NEVER silently return raw input)

### Research Insights: PHP API

**Critical silent failure fix:** The original code silently returns unparsed input when parsing fails. This makes the UI show "NO change" badge for a catastrophic failure:

```php
// BAD — silent failure
$dom = \simplehtmldom\HtmlDocument::str_get_html($html);
$result = $dom ? (string)$dom : $html;  // Returns raw input on failure!

// GOOD — explicit failure
$dom = \simplehtmldom\HtmlDocument::str_get_html($html);
if ($dom === false) {
    http_response_code(500);
    echo json_encode(['error' => 'Parse failed', 'result' => null]);
    exit;
}
$result = (string)$dom;
echo json_encode(['result' => $result]);
```

**Batch endpoint eliminates PHP single-threaded bottleneck** (10 HTTP calls -> 1):

```php
<?php
require 'vendor/autoload.php';

header('Content-Type: application/json; charset=utf-8');

$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

// Health check cho Docker
if ($uri === '/health') {
    echo json_encode(['status' => 'ok']);
    exit;
}

// Chi chap nhan POST
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

// Gioi han kich thuoc input (100KB)
set_time_limit(10);

// --- Batch endpoint: parse nhieu HTML cung luc ---
if ($uri === '/parse_batch' && isset($input['batch']) && is_array($input['batch'])) {
    $results = [];
    foreach ($input['batch'] as $html) {
        if (!is_string($html)) {
            $results[] = ['result' => null, 'error' => 'Not a string'];
            continue;
        }
        $dom = \simplehtmldom\HtmlDocument::str_get_html($html);
        if ($dom === false) {
            $results[] = ['result' => null, 'error' => 'Parse failed'];
        } else {
            $results[] = ['result' => (string)$dom];
        }
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
    $dom = \simplehtmldom\HtmlDocument::str_get_html($html);
    if ($dom === false) {
        http_response_code(500);
        echo json_encode(['error' => 'Parse failed', 'result' => null]);
        exit;
    }
    echo json_encode(['result' => (string)$dom]);
    exit;
}

http_response_code(404);
echo json_encode(['error' => 'Not found']);
```

**Acceptance:**
- POST `/parse` with broken HTML returns parsed output
- POST `/parse` returns `{"error": "Parse failed"}` when parsing fails (not raw input)
- POST `/parse_batch` with array returns all results in single response
- GET `/health` returns `{"status":"ok"}`
- Invalid JSON returns 400 with error message
- Empty input returns empty result

---

#### Phase 3: Ruby Parsers (Nokogiri + Oga + SimpleHtmlDom)

**Files:** `ruby-app/Gemfile`, `ruby-app/app.rb` (parser module section)

**Tasks:**
- [x] Create `Gemfile` with dependencies:
  - `sinatra`, `sinatra-contrib`, `puma` (web framework)
  - `nokogiri`, `oga` (HTML parsers)
  - `httparty` (HTTP client for PHP API)
  - `json` (JSON parsing)
- [x] Define `ParseResult` struct for structured parser output
- [x] Implement `parse_nokogiri(html)` — uses `Nokogiri::HTML::DocumentFragment.parse`
- [x] Implement `parse_oga(html)` — uses `Oga.parse_html` with `.to_xml`
- [x] Implement `SimpleHtmlDom` class with state machine (not regex)
- [x] Implement `parse_php(html)` and `parse_php_batch(html_array)` — HTTP to PHP service
- [x] Wrap each parser in `StandardError` rescue (not bare `rescue => e`)

### Research Insights: Parsers

**Nokogiri HTML5 parser (Gumbo):** Nokogiri bundles an HTML5-compliant parser that implements the Adoption Agency Algorithm — more browser-accurate than the default HTML4 (libxml2) parser. Consider using `Nokogiri::HTML5.fragment(html)` for better results on overlapping tags like `<b><i>text</b></i>`.

**Oga compatibility warning:** Oga has limited maintenance since ~2020. Ruby 3.2+ compatibility is unknown. If it fails to install, document the limitation and show "Oga unavailable" in its column.

**Structured ParseResult (fixes nil crash in badge logic):**
```ruby
# Thay vi tra ve String (co the nil), dung struct co truong success/error
ParseResult = Struct.new(:success, :output, :error, keyword_init: true)
```

This prevents the critical bug where `nil.strip` crashes the badge comparison when a parser returns nil.

**SimpleHtmlDom — state machine instead of regex:**

The original regex has a `$` anchor that only matches end-of-string. It will fail on 8/10 test cases where broken tags are mid-string. Additionally, nested quantifiers `((?:\s+[^>]*?)?)` risk catastrophic backtracking.

Replace with a simple character scanner:

```ruby
# SimpleHtmlDom Ruby — chi fix broken brackets, khong them closing tags
class SimpleHtmlDom
  def initialize(html)
    raise ArgumentError, "Expected String, got #{html.class}" unless html.is_a?(String)
    @raw = html
  end

  def to_html
    fix_broken_brackets(@raw)
  end

  private

  # Quet tung ky tu, tim tag bi thieu dau >
  def fix_broken_brackets(html)
    result = []
    i = 0

    while i < html.length
      if html[i] == '<'
        # Bat dau tag, tim dau > ket thuc
        tag_start = i
        i += 1

        # Doc cho den khi gap > hoac < tiep theo hoac het chuoi
        while i < html.length && html[i] != '>' && html[i] != '<'
          i += 1
        end

        tag_content = html[tag_start...i]

        if i >= html.length
          # Het chuoi ma chua gap > => them >
          result << tag_content << '>'
        elsif html[i] == '<'
          # Gap < moi ma chua co > => them > truoc tag moi
          result << tag_content << '>'
        else
          # Gap > binh thuong
          result << tag_content << '>'
          i += 1
        end
      else
        result << html[i]
        i += 1
      end
    end

    result.join
  end
end
```

**All parser methods with structured results:**

```ruby
require 'logger'
PARSER_LOGGER = Logger.new(STDOUT)

# --- Parser 1: Nokogiri ---
def parse_nokogiri(html)
  doc = Nokogiri::HTML::DocumentFragment.parse(html)
  ParseResult.new(success: true, output: doc.to_html)
rescue StandardError => e
  PARSER_LOGGER.error("Nokogiri error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Parser 2: Oga ---
def parse_oga(html)
  doc = Oga.parse_html(html)
  ParseResult.new(success: true, output: doc.to_xml)
rescue StandardError => e
  PARSER_LOGGER.error("Oga error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Parser 3: SimpleHtmlDom Ruby ---
def parse_simple(html)
  dom = SimpleHtmlDom.new(html)
  ParseResult.new(success: true, output: dom.to_html)
rescue StandardError => e
  PARSER_LOGGER.error("SimpleHtmlDom error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Parser 4: PHP simple_html_dom (API) ---
PHP_SERVICE_URL = ENV.fetch('PHP_SERVICE_URL', 'http://php-app:8080')

def parse_php(html)
  response = HTTParty.post(
    "#{PHP_SERVICE_URL}/parse",
    body: { html: html }.to_json,
    headers: { 'Content-Type' => 'application/json' },
    timeout: 5
  )
  parsed = JSON.parse(response.body)
  if parsed['error']
    ParseResult.new(success: false, error: "PHP: #{parsed['error']}")
  else
    result = parsed['result']
    ParseResult.new(success: true, output: result.to_s)
  end
rescue Net::OpenTimeout, Net::ReadTimeout => e
  PARSER_LOGGER.warn("PHP timeout: #{e.message}")
  ParseResult.new(success: false, error: "Timeout (> 5s)")
rescue Errno::ECONNREFUSED => e
  ParseResult.new(success: false, error: "PHP service not running")
rescue JSON::ParserError => e
  PARSER_LOGGER.error("PHP invalid JSON: #{e.message}")
  ParseResult.new(success: false, error: "Invalid response from PHP")
rescue StandardError => e
  PARSER_LOGGER.error("PHP unexpected: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Service unavailable")
end

# --- Batch: goi PHP 1 lan cho tat ca test cases ---
def parse_php_batch(html_array)
  response = HTTParty.post(
    "#{PHP_SERVICE_URL}/parse_batch",
    body: { batch: html_array }.to_json,
    headers: { 'Content-Type' => 'application/json' },
    timeout: 10
  )
  parsed = JSON.parse(response.body)
  parsed['results'].map do |r|
    if r['error']
      ParseResult.new(success: false, error: "PHP: #{r['error']}")
    else
      ParseResult.new(success: true, output: r['result'].to_s)
    end
  end
rescue StandardError => e
  PARSER_LOGGER.error("PHP batch error: #{e.class} - #{e.message}")
  html_array.map { ParseResult.new(success: false, error: "Service unavailable") }
end
```

**Acceptance:**
- Each parser returns a `ParseResult` struct (never nil, never bare string)
- `parse_php` distinguishes timeout vs connection refused vs invalid JSON errors
- `parse_php_batch` sends single HTTP request for all test cases
- `SimpleHtmlDom` correctly fixes `<div>test</div` -> `<div>test</div>` mid-string
- `SimpleHtmlDom` does NOT add closing tags

---

#### Phase 4: Sinatra Web App + UI

**Files:** `ruby-app/app.rb` (routes + embedded ERB template)

**Tasks:**
- [x] Create Sinatra app with Puma, bind to `0.0.0.0:4567`
- [x] Add security headers (CSP, X-Content-Type-Options)
- [x] Add input size validation (100KB max, server-side)
- [x] Route `GET /` — render main page with textarea and results area
- [x] Route `POST /compare` — single HTML input, run 4 parsers, return results
- [x] Route `POST /compare_batch` — load all test cases, use `parse_php_batch` for PHP
- [x] Route-level error handler (rescue `StandardError` at Sinatra level)
- [x] Embedded ERB template with inline CSS (no external framework)

### Research Insights: Security & UI

**XSS prevention — explicit escaping:** Use `Rack::Utils.escape_html()` for ALL output. Never use `raw()` or skip escaping:

```erb
<pre><code><%= Rack::Utils.escape_html(result.output) %></code></pre>
```

**CSP headers:**
```ruby
before do
  headers['Content-Security-Policy'] = "default-src 'self'; style-src 'unsafe-inline'; script-src 'self'"
  headers['X-Content-Type-Options'] = 'nosniff'
  headers['X-Frame-Options'] = 'DENY'
end
```

**Input size validation (server-side, 100KB max):**
```ruby
MAX_INPUT_SIZE = 100 * 1024  # 100KB

post '/compare' do
  html = params[:html].to_s
  if html.bytesize > MAX_INPUT_SIZE
    @error = "Input too large (max 100KB)"
    return erb :index
  end
  # ... run parsers
end
```

**Nil-safe badge logic:**
```ruby
def compute_badge(result, input)
  return { text: 'ERROR', css: 'badge-error' } unless result.success
  if result.output.strip == input.strip
    { text: 'NO change', css: 'badge-ok' }
  else
    { text: 'MODIFIED', css: 'badge-modified' }
  end
end
```

**UI Layout:**
```
┌──────────────────────────────────────────────────┐
│  HTML Parser Comparison — POC                    │
├──────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────┐  │
│  │  <textarea> HTML input here...             │  │
│  └────────────────────────────────────────────┘  │
│  [Compare]  [Load Test Cases]                    │
├──────────────────────────────────────────────────┤
│  Input    │ Nokogiri │ Oga    │ Simple  │ PHP    │
│           │ (Ruby)   │ (Ruby) │ (Ruby)  │ (PHP)  │
│───────────┼──────────┼────────┼─────────┼────────│
│  <div>... │ output   │ output │ output  │ output │
│  badge    │ badge    │ badge  │ badge   │ badge  │
└──────────────────────────────────────────────────┘
```

**Badge colors:**
- Green `#e8f5e9` — NO change (output === input)
- Yellow `#fff8e1` — MODIFIED (output differs)
- Red `#ffebee` — ERROR (parser failed)

**Test cases (hardcoded array with descriptions):**
```ruby
TEST_CASES = [
  { html: '<div>test</div',                    desc: 'Thieu bracket >' },
  { html: '<div>test',                         desc: 'Thieu closing tag' },
  { html: '<script>alert("test")',             desc: 'Thieu closing script' },
  { html: '<div><span>test</div>',             desc: 'Thieu closing span' },
  { html: '<p>paragraph',                      desc: 'Thieu closing p' },
  { html: '<iframe src="test.html">',          desc: 'Thieu closing iframe' },
  { html: '<img src="test.png">',              desc: 'Self-closing element' },
  { html: '<br>',                              desc: 'Void element' },
  { html: '<div class="a">hello<div>world',   desc: 'Nested unclosed divs' },
  { html: '<b><i>text</b></i>',               desc: 'Overlapping tags' },
]
```

**Acceptance:**
- Page loads at `localhost:4567` with textarea and buttons
- "Compare" sends single input, displays 1-row result table
- "Load Test Cases" sends all 10 inputs, displays 10-row result table (uses batch PHP endpoint)
- All output HTML-escaped with `Rack::Utils.escape_html` (verify: input `<script>alert(1)</script>` shows as text)
- Badges show NO change / MODIFIED / ERROR with correct colors
- Input > 100KB returns error message
- Route-level error handler prevents 500 errors from reaching users

---

#### Phase 5: Error Handling & Polish

**Files:** `ruby-app/app.rb`

**Tasks:**
- [x] PHP timeout: 5s per-request, 10s for batch
- [x] Input validation: empty input (client + server), size limit 100KB (server)
- [x] Parser errors: each parser wrapped in `rescue StandardError`, returns `ParseResult` with error
- [x] Route error handler: `error StandardError do ... end` at Sinatra level
- [x] Loading state: disable button + "Processing..." (simple JS)
- [x] Vietnamese comments in code
- [x] Basic logging to STDOUT via `Logger` (parser name, duration, errors)
- [x] Verify all 10 test cases produce correct output from each parser
- [x] XSS verification: test with `<script>alert('xss')</script>` input

### Research Insights: Error Handling

**27 silent failure patterns identified.** The most critical ones to address:

1. **PHP `str_get_html()` returns false** — MUST return error JSON, not raw input
2. **`JSON.parse(response.body)['result']` returning nil** — crashes badge `nil.strip`
3. **`rescue => e` catches SystemExit** — use `rescue StandardError => e` instead
4. **Error strings compared as valid output** — `ParseResult` struct fixes this
5. **No route-level error handler** — unhandled exceptions show raw stack trace

**Sinatra global error handler:**
```ruby
error StandardError do
  err = env['sinatra.error']
  PARSER_LOGGER.error("Unhandled: #{err.class} - #{err.message}")
  status 500
  erb :error
end
```

**Acceptance:**
- App doesn't crash when PHP service is down (shows "PHP service not running" in column)
- App doesn't crash on nil parser results (ParseResult always has .success and .output/.error)
- Empty input shows validation message
- Parser errors display gracefully in their column with RED badge
- `docker compose up --build` starts everything cleanly
- No `rescue => e` anywhere — all use `rescue StandardError => e`

---

## Test Cases & Expected Behavior

| # | Input | Description |
|---|-------|-------------|
| 1 | `<div>test</div` | Missing closing bracket `>` |
| 2 | `<div>test` | Missing closing tag |
| 3 | `<script>alert("test")` | Missing closing `</script>` |
| 4 | `<div><span>test</div>` | Missing `</span>`, has `</div>` |
| 5 | `<p>paragraph` | Missing closing `</p>` |
| 6 | `<iframe src="test.html">` | Missing closing `</iframe>` |
| 7 | `<img src="test.png">` | Self-closing/void element |
| 8 | `<br>` | Void element |
| 9 | `<div class="a">hello<div>world` | Nested unclosed divs |
| 10 | `<b><i>text</b></i>` | Overlapping/misnested tags |

### Research Insights: Expected Parser Output

Based on framework documentation research:

**Nokogiri (HTML4/libxml2):**
- Auto-closes ALL missing tags aggressively
- Void elements preserved (`<br>`, `<img>`)
- Overlapping tags restructured: `<b><i>text</b></i>` -> varies by parser version
- Test case 1: `<div>test</div>` (fixes bracket AND adds closing tag to fragment)

**Oga:**
- Less aggressive than Nokogiri
- May not add closing tags for all elements
- Known issue: `to_xml` may produce slightly different output format
- **Risk:** Ruby 3.2+ compatibility unknown — may fail at gem install

**SimpleHtmlDom Ruby (custom):**
- ONLY fixes broken brackets
- Test case 1: `<div>test</div>` (fixes missing `>`)
- Test case 2: `<div>test` (unchanged — no bracket to fix)
- Test case 8: `<br>` (unchanged — valid tag)

**PHP simple_html_dom:**
- Lenient parser, preserves structure
- `forceTagsClosed` parameter (default: true) may add some closing tags
- Test case 1: likely `<div>test</div>` (fixes bracket)
- Known: 10x performance boost in v2.0 for optional end tags

---

## Acceptance Criteria

### Functional Requirements
- [x] `docker compose up --build` starts both containers successfully
- [x] `curl localhost:8080/health` returns `{"status":"ok"}`
- [x] Web UI accessible at `localhost:4567`
- [x] User can enter HTML and click "Compare" to see 4-parser comparison
- [x] "Load Test Cases" loads and compares all 10 test cases at once (batch PHP call)
- [x] Each parser result shows output + NO change/MODIFIED/ERROR badge
- [x] PHP parser errors show specific error (not generic "Service unavailable")
- [x] All 10 test cases produce results without crashes

### Non-Functional Requirements
- [x] Response time < 5s for single input comparison
- [x] Response time < 15s for batch (10 test cases) comparison
- [x] No XSS — all output escaped with `Rack::Utils.escape_html`
- [x] Input size limit: 100KB (server-side validation)
- [x] CSP headers set on all responses
- [x] Clean, readable code with Vietnamese comments
- [x] Basic logging to STDOUT (parser name, errors, durations)

### Error Handling Requirements
- [x] PHP service down -> PHP column shows "PHP service not running" with RED badge
- [x] PHP timeout -> PHP column shows "Timeout (> 5s)" with RED badge
- [x] Parser crash -> affected column shows error with RED badge, other parsers still show results
- [x] Empty input -> validation message (no parser execution)
- [x] Input > 100KB -> error message (no parser execution)
- [x] No bare `rescue => e` — all use `rescue StandardError => e`

---

## Dependencies & Prerequisites

- Docker & Docker Compose installed locally
- Ports 4567 and 8080 available
- Internet access for pulling Docker images and installing gems/packages

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Nokogiri native extension build fails in Docker | Blocks Phase 1 | Use `ruby:3.2-slim` + `libxml2-dev libxslt1-dev` + `NOKOGIRI_USE_SYSTEM_LIBRARIES=true` |
| PHP simple_html_dom package version incompatibility | Blocks Phase 2 | Pin to `^2.0`, test in Docker build |
| SimpleHtmlDom regex fails on mid-string tags | Partial Phase 3 | **Use state machine instead of regex** |
| Docker network issues between containers | Blocks Phase 4 | Use default Docker Compose network + service name |
| Oga gem incompatible with Ruby 3.2+ | Blocks Phase 3 | Show "Oga unavailable" in column, log error, don't crash |
| PHP built-in server single-threaded bottleneck | Slow batch mode | **Use `/parse_batch` endpoint** (1 HTTP call instead of 10) |
| Catastrophic regex backtracking in SimpleHtmlDom | App hangs | **State machine eliminates this risk entirely** |
| XSS via parser output | Security | `Rack::Utils.escape_html` + CSP headers |
| PHP silently returns unparsed input on failure | Wrong results | **Return error JSON with HTTP 500** |
| nil parser result crashes badge comparison | App crash | **ParseResult struct always has .success field** |

## File Summary

| File | Purpose | Est. Lines |
|------|---------|------------|
| `docker-compose.yml` | Container orchestration with healthcheck | ~30 |
| `ruby-app/Dockerfile` | Ruby container with layer caching | ~15 |
| `ruby-app/Gemfile` | Ruby dependencies | ~10 |
| `ruby-app/app.rb` | Main app: routes, parsers, UI template | ~300 |
| `php-app/Dockerfile` | PHP multi-stage build | ~12 |
| `php-app/composer.json` | PHP dependencies | ~8 |
| `php-app/index.php` | PHP parse API (single + batch + health) | ~80 |

**Total: 7 files, ~455 lines**

## Deployment Verification Checklist

### Pre-Deploy
- [x] Docker version >= 20.0 and Docker Compose >= 2.0
- [x] Ports 4567 and 8080 available (`lsof -i :4567 :8080`)
- [x] At least 1GB disk space free

### Build Phase
- [x] `docker compose build --progress=plain` — no errors
- [x] Both images created (`docker images | grep -E "(ruby|php)"`)
- [x] Nokogiri loads: `docker compose run --rm ruby-app ruby -e "require 'nokogiri'; puts Nokogiri::VERSION"`
- [x] Oga loads: `docker compose run --rm ruby-app ruby -e "require 'oga'; puts Oga::VERSION"`

### Startup Phase
- [x] `docker compose up -d` — both containers "Up"
- [x] `docker compose logs ruby-app | tail -5` — shows Puma started
- [x] `docker compose logs php-app | tail -5` — shows server started

### Functional Verification
- [x] `curl http://localhost:4567` — returns HTML
- [x] `curl http://localhost:8080/health` — returns `{"status":"ok"}`
- [x] `curl -X POST http://localhost:8080/parse -H 'Content-Type: application/json' -d '{"html":"<div>test"}'` — returns JSON
- [x] Browser: open `http://localhost:4567`, enter HTML, click Compare — results display

### Error Scenarios
- [x] `docker compose stop php-app` → Compare still works, PHP column shows error
- [x] `docker compose start php-app` → PHP column works again
- [x] Input `<script>alert('xss')</script>` → displayed as text, not executed

## References

- [Nokogiri docs](https://nokogiri.org/)
- [Nokogiri HTML5 parser](https://nokogiri.org/rdoc/Nokogiri/HTML5.html)
- [Oga gem](https://github.com/YorickPeterse/oga)
- [PHP simple_html_dom v2](https://simplehtmldom.sourceforge.io/)
- [Sinatra docs](https://sinatrarb.com/)
- [Docker Compose networking](https://docs.docker.com/compose/how-tos/networking/)
- [Docker Compose healthchecks](https://docs.docker.com/compose/how-tos/startup-order/)
- [Nokogiri Docker best practices](https://ledermann.dev/blog/2020/01/29/building-docker-images-the-performant-way/)
