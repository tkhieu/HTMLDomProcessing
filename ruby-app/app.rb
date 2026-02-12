require 'sinatra'
require 'sinatra/json'
require 'nokogiri'
require 'oga'
require 'httparty'
require 'json'
require 'logger'

# === Cấu hình ===
set :bind, '0.0.0.0'
set :port, 4567
set :server, :puma

# URL của PHP service (lấy từ ENV, mặc định là docker service name)
PHP_SERVICE_URL = ENV.fetch('PHP_SERVICE_URL', 'http://php-app:8080')

# Giới hạn kích thước input (100KB)
MAX_INPUT_SIZE = 100 * 1024

# Logger cho parser errors
PARSER_LOGGER = Logger.new(STDOUT)
PARSER_LOGGER.level = Logger::INFO

# === Struct cho kết quả parser ===
# Mỗi parser trả về ParseResult thay vì String (tránh nil crash)
ParseResult = Struct.new(:success, :output, :error, keyword_init: true)

# === Security headers ===
before do
  headers['Content-Security-Policy'] = "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline' 'self'"
  headers['X-Content-Type-Options'] = 'nosniff'
  headers['X-Frame-Options'] = 'DENY'
end

# === Test cases mặc định ===
TEST_CASES = [
  # === Nhóm 1: Thiếu bracket / closing tag (cơ bản) ===
  { html: '<div>test</div',                          desc: 'Thiếu bracket >' },
  { html: '<div>test',                               desc: 'Thiếu closing tag' },
  { html: '<script>alert("test")',                   desc: 'Thiếu closing script' },
  { html: '<div><span>test</div>',                   desc: 'Thiếu closing span' },
  { html: '<p>paragraph',                            desc: 'Thiếu closing p' },
  { html: '<iframe src="test.html">',                desc: 'Thiếu closing iframe' },
  { html: '<img src="test.png">',                    desc: 'Self-closing element' },
  { html: '<br>',                                    desc: 'Void element' },
  { html: '<div class="a">hello<div>world',         desc: 'Nested unclosed divs' },
  { html: '<b><i>text</b></i>',                      desc: 'Overlapping tags' },

  # === Nhóm 2: Tag lồng nhau sai / chồng chéo ===
  { html: '<table><tr><td>A<td>B<tr><td>C',         desc: 'Table không có closing tags' },
  { html: '<ul><li>one<li>two<li>three',             desc: 'List items không close' },
  { html: '<p>first<p>second<p>third',               desc: 'P liên tiếp (auto-close?)' },
  { html: '<div><p>text</div></p>',                  desc: 'Closing tag sai thứ tự' },
  { html: '<a href="#"><div>block in inline</div></a>', desc: 'Block element trong inline' },
  { html: '<b><div>bold div</b></div>',              desc: 'Inline bọc block, close sai' },

  # === Nhóm 3: Attributes oái ăm ===
  { html: '<div class="a" class="b">dup attr</div>', desc: 'Duplicate attributes' },
  { html: '<div class=>empty value</div>',           desc: 'Attribute có = nhưng không có value' },
  { html: '<div class>no equals</div>',              desc: 'Attribute không có =' },
  { html: '<div data-x="he said \\"hi\\"">quote</div>', desc: 'Escaped quotes trong attr' },
  { html: "<div class='single'>mixed</div>",        desc: 'Single quotes attr' },
  { html: '<div class=unquoted>no quotes</div>',    desc: 'Attribute không có quotes' },
  { html: '<div style="color:red;font-size:">bad css</div>', desc: 'CSS value bị cắt' },

  # === Nhóm 4: Comment và CDATA ===
  { html: '<!-- comment -->visible',                 desc: 'Comment trước text' },
  { html: '<!-- unterminated comment',               desc: 'Comment không đóng' },
  { html: '<!---->empty comment',                    desc: 'Comment rỗng' },
  { html: '<!-- <div>hidden</div> -->shown',         desc: 'HTML bên trong comment' },
  { html: '<![CDATA[raw text]]>after',               desc: 'CDATA section' },
  { html: '<!DOCTYPE html><div>after doctype</div>', desc: 'DOCTYPE trước HTML' },

  # === Nhóm 5: Special / edge cases ===
  { html: '',                                        desc: 'Chuỗi rỗng' },
  { html: 'plain text no tags',                      desc: 'Chỉ có text, không có tag' },
  { html: '   ',                                     desc: 'Chỉ có whitespace' },
  { html: '<>empty tag</>',                          desc: 'Tag không có tên' },
  { html: '< div>space trước tên tag</div>',         desc: 'Space sau dấu <' },
  { html: '<div >space trước ></div >',              desc: 'Space trước dấu >' },
  { html: '<DIV>UPPERCASE</DIV>',                    desc: 'Tag viết hoa' },
  { html: '<DiV>MiXeD CaSe</dIv>',                  desc: 'Tag mixed case' },

  # === Nhóm 6: Encoding và ký tự đặc biệt ===
  { html: '<div>Tom &amp; Jerry</div>',              desc: 'HTML entity &amp;' },
  { html: '<div>5 &lt; 10 &gt; 3</div>',            desc: 'Entity &lt; và &gt;' },
  { html: '<div>Price: 100&yen;</div>',              desc: 'Entity &yen; (named)' },
  { html: '<div>&#x1F600; emoji</div>',              desc: 'Hex entity (emoji)' },
  { html: '<div>caf&eacute;</div>',                  desc: 'Entity &eacute; (accent)' },
  { html: '<div>&notanentity;</div>',                desc: 'Entity không tồn tại' },

  # === Nhóm 7: Script / style injection ===
  { html: '<script>alert("xss")</script>',           desc: 'Script tag đầy đủ' },
  { html: '<img src=x onerror="alert(1)">',         desc: 'Event handler trong attr' },
  { html: '<style>body{display:none}</style>hi',     desc: 'Style tag' },
  { html: '<svg onload="alert(1)">',                desc: 'SVG với event handler' },
  { html: '<math><mi>x</mi></math>',                desc: 'MathML element' },
  { html: '<div onclick="alert(1)">click</div>',    desc: 'Inline event handler' },

  # === Nhóm 8: Nested cực sâu / lỗi lầm ===
  { html: '<div>' * 10 + 'deep' + '</div>' * 5,     desc: '10 div mở, 5 div đóng' },
  { html: '</div>text<div>',                         desc: 'Closing tag trước opening' },
  { html: '</span></div></p>orphan closings',        desc: 'Chỉ có closing tags' },
  { html: '<div/><span/>self close non-void',        desc: 'XHTML self-close non-void' },
  { html: '<br/><hr/><img src="x"/>',               desc: 'XHTML self-close void' },
  { html: '<div><!-- comment <span> -->text</div>',  desc: 'Tag mở trong comment' },
  { html: "line1\nline2\n<div>\nline3\n</div>",     desc: 'Newlines trong HTML' },
  { html: "tab\there\t<div>\ttab</div>",            desc: 'Tabs trong HTML' },

  # === Nhóm 9: Template syntax và non-HTML ===
  { html: '<div>{{name}}</div>',                     desc: 'Mustache template syntax' },
  { html: '<div><%= user.name %></div>',             desc: 'ERB template syntax' },
  { html: '<div><?php echo "hi"; ?></div>',          desc: 'PHP tag trong HTML' },
  { html: '<div ng-if="show">angular</div>',        desc: 'Angular directive' },
  { html: '<div v-if="show">vue</div>',             desc: 'Vue directive' },
  { html: '<custom-element>web component</custom-element>', desc: 'Custom element / Web Component' },

  # === Nhóm 10: Các lỗi "kinh điển" của devs ===
  { html: '<div><img src="photo.jpg"></div',         desc: 'Img + div thiếu >' },
  { html: '<a href="page1"><a href="page2">nested links</a></a>', desc: 'Link lồng trong link' },
  { html: '<form><form>nested</form></form>',       desc: 'Form lồng trong form' },
  { html: '<select><div>invalid child</div></select>', desc: 'Div trong select' },
  { html: '<tr><div>div trong tr</div></tr>',       desc: 'Div trong table row' },
  { html: '<option>opt1<option>opt2<option>opt3',   desc: 'Options không close' },
  { html: '<head><div>div trong head</div></head>', desc: 'Div trong head' },
  { html: '<p>text<table><tr><td>cell</td></tr></table>more</p>', desc: 'Table trong p tag' },
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

# --- Parser 3: PHP simple_html_dom (gọi API) ---
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

# --- Parser 5: Peraichi simple_html_dom (gọi API — str_get_html) ---
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

# --- Parser 6: Peraichi RSHD (Ruby port of simple_html_dom.php) ---
require_relative 'peraichi_simple_html_dom'

def parse_peraichi_ruby(html)
  dom = PeraichiSimpleHtmlDom.str_get_html(html)
  ParseResult.new(success: true, output: dom.to_s)
rescue StandardError => e
  PARSER_LOGGER.error("Peraichi RSHD error: #{e.class} - #{e.message}")
  ParseResult.new(success: false, error: "Error: #{e.message}")
end

# --- Batch: gọi Peraichi 1 lần cho tất cả test cases ---
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

# --- Batch: gọi PHP 1 lần cho tất cả test cases ---
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

# So sánh output vs input để hiển thị badge
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

# Trang chính — hiển thị textarea và kết quả
get '/' do
  @results = nil
  @error = nil
  @test_cases = nil
  erb :index
end

# So sánh 1 HTML input
post '/compare' do
  html = params[:html].to_s

  # Validate input
  if html.strip.empty?
    @error = "Vui lòng nhập HTML input"
    @results = nil
    @test_cases = nil
    return erb :index
  end

  if html.bytesize > MAX_INPUT_SIZE
    @error = "Input quá lớn (tối đa 100KB)"
    @results = nil
    @test_cases = nil
    return erb :index
  end

  @results = [{
    input: html,
    desc: 'Custom input',
    nokogiri: parse_nokogiri(html),
    oga: parse_oga(html),
    php: parse_php(html),
    peraichi: parse_peraichi(html),
    peraichi_ruby: parse_peraichi_ruby(html),
  }]
  @error = nil
  @test_cases = nil
  erb :index
end

# Load tất cả test cases — dùng batch endpoint cho PHP
post '/compare_batch' do
  html_array = TEST_CASES.map { |tc| tc[:html] }

  # Chạy Ruby parsers cho mỗi test case, PHP batch 1 lần duy nhất
  php_results = parse_php_batch(html_array)
  peraichi_results = parse_peraichi_batch(html_array)

  @results = TEST_CASES.each_with_index.map do |tc, i|
    {
      input: tc[:html],
      desc: tc[:desc],
      nokogiri: parse_nokogiri(tc[:html]),
      oga: parse_oga(tc[:html]),
      php: php_results[i],
      peraichi: peraichi_results[i],
      peraichi_ruby: parse_peraichi_ruby(tc[:html]),
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
    <h1>HTML Parser Comparison — POC <small>Nokogiri &middot; Oga &middot; PHP &middot; Peraichi SHD &middot; Peraichi RSHD</small></h1>

    <div class="input-section">
      <form method="post" action="/compare" id="compareForm">
        <textarea name="html" id="htmlInput" placeholder="Nhập HTML input tại đây..."><%= @results && @results.length == 1 && !@test_cases ? Rack::Utils.escape_html(@results[0][:input]) : '' %></textarea>
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
              <th>simple_html_dom <span class="lang-badge lang-php">PHP</span></th>
              <th>Peraichi SHD <span class="lang-badge lang-php">PHP</span></th>
              <th>Peraichi RSHD <span class="lang-badge lang-ruby">Ruby</span></th>
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

                <%# Peraichi RSHD (Ruby) %>
                <td>
                  <% badge = compute_badge(row[:peraichi_ruby], row[:input]) %>
                  <div class="code-output"><%= row[:peraichi_ruby].success ? Rack::Utils.escape_html(row[:peraichi_ruby].output) : Rack::Utils.escape_html(row[:peraichi_ruby].error) %></div>
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
      // Disable buttons khi đang xử lý
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
      // Disable buttons khi đang xử lý
      document.getElementById('compareBtn').disabled = true;
      document.getElementById('compareBtn').textContent = 'Processing...';
    });
  </script>
</body>
</html>
