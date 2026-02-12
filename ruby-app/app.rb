require 'sinatra'
require 'sinatra/json'
require 'nokogiri'
require 'oga'
require 'httparty'
require 'json'
require 'logger'

# === Cau hinh ===
set :bind, '0.0.0.0'
set :port, 4567
set :server, :puma

# URL cua PHP service (lay tu ENV, mac dinh la docker service name)
PHP_SERVICE_URL = ENV.fetch('PHP_SERVICE_URL', 'http://php-app:8080')

# Gioi han kich thuoc input (100KB)
MAX_INPUT_SIZE = 100 * 1024

# Logger cho parser errors
PARSER_LOGGER = Logger.new(STDOUT)
PARSER_LOGGER.level = Logger::INFO

# === Struct cho ket qua parser ===
# Moi parser tra ve ParseResult thay vi String (tranh nil crash)
ParseResult = Struct.new(:success, :output, :error, keyword_init: true)

# === Security headers ===
before do
  headers['Content-Security-Policy'] = "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline' 'self'"
  headers['X-Content-Type-Options'] = 'nosniff'
  headers['X-Frame-Options'] = 'DENY'
end

# === Test cases mac dinh ===
TEST_CASES = [
  { html: '<div>test</div',                   desc: 'Thieu bracket >' },
  { html: '<div>test',                        desc: 'Thieu closing tag' },
  { html: '<script>alert("test")',            desc: 'Thieu closing script' },
  { html: '<div><span>test</div>',            desc: 'Thieu closing span' },
  { html: '<p>paragraph',                     desc: 'Thieu closing p' },
  { html: '<iframe src="test.html">',         desc: 'Thieu closing iframe' },
  { html: '<img src="test.png">',             desc: 'Self-closing element' },
  { html: '<br>',                             desc: 'Void element' },
  { html: '<div class="a">hello<div>world',  desc: 'Nested unclosed divs' },
  { html: '<b><i>text</b></i>',              desc: 'Overlapping tags' },
].freeze

# ============================================================
# PARSERS
# ============================================================

# --- Parser 1: Nokogiri (HTML4/libxml2) ---
# Auto-close missing tags, restructure overlapping tags
def parse_nokogiri(html)
  doc = Nokogiri::HTML::DocumentFragment.parse(html)
  ParseResult.new(success: true, output: doc.to_html)
rescue StandardError => e
  PARSER_LOGGER.error("Nokogiri error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Parser 2: Oga ---
# Less aggressive than Nokogiri, pure Ruby parser
def parse_oga(html)
  doc = Oga.parse_html(html)
  ParseResult.new(success: true, output: doc.to_xml)
rescue StandardError => e
  PARSER_LOGGER.error("Oga error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Parser 3: SimpleHtmlDom Ruby (class tu viet) ---
# CHI fix broken brackets, KHONG them closing tags
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

def parse_simple(html)
  dom = SimpleHtmlDom.new(html)
  ParseResult.new(success: true, output: dom.to_html)
rescue StandardError => e
  PARSER_LOGGER.error("SimpleHtmlDom error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Parser 4: PHP simple_html_dom (goi API) ---
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
    ParseResult.new(success: true, output: parsed['result'].to_s)
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

# --- Parser 5: Peraichi simple_html_dom (goi API — str_get_html) ---
def parse_peraichi(html)
  response = HTTParty.post(
    "#{PHP_SERVICE_URL}/parse_peraichi",
    body: { html: html }.to_json,
    headers: { 'Content-Type' => 'application/json' },
    timeout: 5
  )
  parsed = JSON.parse(response.body)
  if parsed['error']
    ParseResult.new(success: false, error: "Peraichi: #{parsed['error']}")
  else
    ParseResult.new(success: true, output: parsed['result'].to_s)
  end
rescue Net::OpenTimeout, Net::ReadTimeout => e
  PARSER_LOGGER.warn("Peraichi timeout: #{e.message}")
  ParseResult.new(success: false, error: "Timeout (> 5s)")
rescue Errno::ECONNREFUSED => e
  ParseResult.new(success: false, error: "PHP service not running")
rescue JSON::ParserError => e
  PARSER_LOGGER.error("Peraichi invalid JSON: #{e.message}")
  ParseResult.new(success: false, error: "Invalid response from PHP")
rescue StandardError => e
  PARSER_LOGGER.error("Peraichi unexpected: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Service unavailable")
end

# --- Batch: goi Peraichi 1 lan cho tat ca test cases ---
def parse_peraichi_batch(html_array)
  response = HTTParty.post(
    "#{PHP_SERVICE_URL}/parse_peraichi_batch",
    body: { batch: html_array }.to_json,
    headers: { 'Content-Type' => 'application/json' },
    timeout: 10
  )
  parsed = JSON.parse(response.body)
  parsed['results'].map do |r|
    if r['error']
      ParseResult.new(success: false, error: "Peraichi: #{r['error']}")
    else
      ParseResult.new(success: true, output: r['result'].to_s)
    end
  end
rescue StandardError => e
  PARSER_LOGGER.error("Peraichi batch error: #{e.class} - #{e.message}")
  html_array.map { ParseResult.new(success: false, error: "Service unavailable") }
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

# ============================================================
# BADGE LOGIC
# ============================================================

# So sanh output vs input de hien thi badge
def compute_badge(result, input)
  return { text: 'ERROR', css: 'badge-error' } unless result.success
  if result.output.strip == input.strip
    { text: 'NO change', css: 'badge-ok' }
  else
    { text: 'MODIFIED', css: 'badge-modified' }
  end
end

# ============================================================
# ROUTES
# ============================================================

# Trang chinh — hien thi textarea va ket qua
get '/' do
  @results = nil
  @error = nil
  @test_cases = nil
  erb :index
end

# So sanh 1 HTML input
post '/compare' do
  html = params[:html].to_s

  # Validate input
  if html.strip.empty?
    @error = "Vui long nhap HTML input"
    @results = nil
    @test_cases = nil
    return erb :index
  end

  if html.bytesize > MAX_INPUT_SIZE
    @error = "Input qua lon (toi da 100KB)"
    @results = nil
    @test_cases = nil
    return erb :index
  end

  @results = [{
    input: html,
    desc: 'Custom input',
    nokogiri: parse_nokogiri(html),
    oga: parse_oga(html),
    simple: parse_simple(html),
    php: parse_php(html),
    peraichi: parse_peraichi(html),
  }]
  @error = nil
  @test_cases = nil
  erb :index
end

# Load tat ca test cases — dung batch endpoint cho PHP
post '/compare_batch' do
  html_array = TEST_CASES.map { |tc| tc[:html] }

  # Chay 3 Ruby parsers cho moi test case
  # Chay PHP batch 1 lan duy nhat
  php_results = parse_php_batch(html_array)
  peraichi_results = parse_peraichi_batch(html_array)

  @results = TEST_CASES.each_with_index.map do |tc, i|
    {
      input: tc[:html],
      desc: tc[:desc],
      nokogiri: parse_nokogiri(tc[:html]),
      oga: parse_oga(tc[:html]),
      simple: parse_simple(tc[:html]),
      php: php_results[i],
      peraichi: peraichi_results[i],
    }
  end
  @error = nil
  @test_cases = true
  erb :index
end

# === Global error handler ===
error StandardError do
  err = env['sinatra.error']
  PARSER_LOGGER.error("Unhandled: #{err.class} - #{err.message}")
  status 500
  @error = "Internal server error: #{err.message}"
  @results = nil
  @test_cases = nil
  erb :index
end

# ============================================================
# TEMPLATE (Embedded ERB)
# ============================================================

__END__

@@ index
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>HTML Parser Comparison — POC</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #f5f5f5;
      color: #333;
      padding: 20px;
    }
    .container { max-width: 1400px; margin: 0 auto; }
    h1 {
      font-size: 1.5rem;
      margin-bottom: 20px;
      color: #1a1a1a;
    }
    h1 small { font-weight: normal; color: #888; font-size: 0.8rem; }

    /* Form */
    .input-section {
      background: #fff;
      border: 1px solid #ddd;
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 20px;
    }
    textarea {
      width: 100%;
      height: 120px;
      font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
      font-size: 14px;
      padding: 12px;
      border: 1px solid #ccc;
      border-radius: 6px;
      resize: vertical;
      margin-bottom: 12px;
    }
    textarea:focus { outline: none; border-color: #4A90D9; box-shadow: 0 0 0 2px rgba(74,144,217,0.2); }
    .btn-group { display: flex; gap: 10px; }
    .btn {
      padding: 10px 20px;
      border: none;
      border-radius: 6px;
      cursor: pointer;
      font-size: 14px;
      font-weight: 600;
      transition: opacity 0.2s;
    }
    .btn:hover { opacity: 0.85; }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-primary { background: #4A90D9; color: #fff; }
    .btn-secondary { background: #6c757d; color: #fff; }

    /* Error */
    .error {
      background: #ffebee;
      color: #c62828;
      padding: 12px 16px;
      border-radius: 6px;
      margin-bottom: 16px;
      border: 1px solid #ef9a9a;
    }

    /* Results table */
    .results-section {
      background: #fff;
      border: 1px solid #ddd;
      border-radius: 8px;
      overflow-x: auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th {
      background: #f8f9fa;
      padding: 12px 10px;
      text-align: left;
      border-bottom: 2px solid #dee2e6;
      font-weight: 600;
      white-space: nowrap;
    }
    th .lang-badge {
      display: inline-block;
      font-size: 10px;
      padding: 2px 6px;
      border-radius: 3px;
      font-weight: 600;
      margin-left: 4px;
    }
    .lang-ruby { background: #cc342d; color: #fff; }
    .lang-php { background: #777bb3; color: #fff; }
    .lang-custom { background: #f0ad4e; color: #fff; }

    td {
      padding: 10px;
      border-bottom: 1px solid #eee;
      vertical-align: top;
      max-width: 300px;
    }
    tr:hover td { background: #fafafa; }

    /* Code output */
    .code-output {
      font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
      font-size: 12px;
      background: #f8f9fa;
      padding: 8px;
      border-radius: 4px;
      white-space: pre-wrap;
      word-break: break-all;
      max-height: 200px;
      overflow-y: auto;
      border: 1px solid #e9ecef;
    }

    /* Badges */
    .badge {
      display: inline-block;
      padding: 3px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 700;
      margin-top: 6px;
    }
    .badge-ok { background: #e8f5e9; color: #2e7d32; }
    .badge-modified { background: #fff8e1; color: #f57f17; }
    .badge-error { background: #ffebee; color: #c62828; }

    /* Description column */
    .desc-text { color: #666; font-size: 11px; margin-top: 4px; }

    /* Input column */
    .input-col { min-width: 180px; }
  </style>
</head>
<body>
  <div class="container">
    <h1>HTML Parser Comparison — POC <small>Nokogiri &middot; Oga &middot; SimpleHtmlDom &middot; PHP &middot; Peraichi SHD</small></h1>

    <div class="input-section">
      <form method="post" action="/compare" id="compareForm">
        <textarea name="html" id="htmlInput" placeholder="Nhap HTML input tai day..."><%= @results && @results.length == 1 && !@test_cases ? Rack::Utils.escape_html(@results[0][:input]) : '' %></textarea>
        <div class="btn-group">
          <button type="submit" class="btn btn-primary" id="compareBtn">Compare</button>
          <button type="button" class="btn btn-secondary" id="loadTestBtn">Load Test Cases</button>
        </div>
      </form>
    </div>

    <% if @error %>
      <div class="error"><%= Rack::Utils.escape_html(@error) %></div>
    <% end %>

    <% if @results && @results.length > 0 %>
      <div class="results-section">
        <table>
          <thead>
            <tr>
              <th class="input-col">Input</th>
              <th>Nokogiri <span class="lang-badge lang-ruby">Ruby</span></th>
              <th>Oga <span class="lang-badge lang-ruby">Ruby</span></th>
              <th>SimpleHtmlDom <span class="lang-badge lang-custom">Custom</span></th>
              <th>simple_html_dom <span class="lang-badge lang-php">PHP</span></th>
              <th>Peraichi SHD <span class="lang-badge lang-php">PHP</span></th>
            </tr>
          </thead>
          <tbody>
            <% @results.each do |row| %>
              <tr>
                <%# Input column %>
                <td class="input-col">
                  <div class="code-output"><%= Rack::Utils.escape_html(row[:input]) %></div>
                  <% if row[:desc] %>
                    <div class="desc-text"><%= Rack::Utils.escape_html(row[:desc]) %></div>
                  <% end %>
                </td>

                <%# Nokogiri %>
                <td>
                  <% badge = compute_badge(row[:nokogiri], row[:input]) %>
                  <div class="code-output"><%= row[:nokogiri].success ? Rack::Utils.escape_html(row[:nokogiri].output) : Rack::Utils.escape_html(row[:nokogiri].error) %></div>
                  <span class="badge <%= badge[:css] %>"><%= badge[:text] %></span>
                </td>

                <%# Oga %>
                <td>
                  <% badge = compute_badge(row[:oga], row[:input]) %>
                  <div class="code-output"><%= row[:oga].success ? Rack::Utils.escape_html(row[:oga].output) : Rack::Utils.escape_html(row[:oga].error) %></div>
                  <span class="badge <%= badge[:css] %>"><%= badge[:text] %></span>
                </td>

                <%# SimpleHtmlDom Ruby %>
                <td>
                  <% badge = compute_badge(row[:simple], row[:input]) %>
                  <div class="code-output"><%= row[:simple].success ? Rack::Utils.escape_html(row[:simple].output) : Rack::Utils.escape_html(row[:simple].error) %></div>
                  <span class="badge <%= badge[:css] %>"><%= badge[:text] %></span>
                </td>

                <%# PHP simple_html_dom %>
                <td>
                  <% badge = compute_badge(row[:php], row[:input]) %>
                  <div class="code-output"><%= row[:php].success ? Rack::Utils.escape_html(row[:php].output) : Rack::Utils.escape_html(row[:php].error) %></div>
                  <span class="badge <%= badge[:css] %>"><%= badge[:text] %></span>
                </td>

                <%# Peraichi SHD %>
                <td>
                  <% badge = compute_badge(row[:peraichi], row[:input]) %>
                  <div class="code-output"><%= row[:peraichi].success ? Rack::Utils.escape_html(row[:peraichi].output) : Rack::Utils.escape_html(row[:peraichi].error) %></div>
                  <span class="badge <%= badge[:css] %>"><%= badge[:text] %></span>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
  </div>

  <script>
    // Load Test Cases — submit POST /compare_batch
    document.getElementById('loadTestBtn').addEventListener('click', function() {
      var form = document.getElementById('compareForm');
      form.action = '/compare_batch';
      // Disable buttons khi dang xu ly
      document.getElementById('compareBtn').disabled = true;
      document.getElementById('loadTestBtn').disabled = true;
      document.getElementById('loadTestBtn').textContent = 'Processing...';
      form.submit();
    });

    // Reset action khi submit Compare
    document.getElementById('compareForm').addEventListener('submit', function(e) {
      if (this.action.indexOf('/compare_batch') === -1) {
        this.action = '/compare';
      }
      // Disable buttons khi dang xu ly
      document.getElementById('compareBtn').disabled = true;
      document.getElementById('compareBtn').textContent = 'Processing...';
    });
  </script>
</body>
</html>
