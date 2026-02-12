# frozen_string_literal: true

# Ruby port of simple_html_dom v1.9.1 (291)
# Original PHP: http://sourceforge.net/projects/simplehtmldom/
# Authors: S.C. Chen, John Schlick, Rus Carroll, logmanoriginal
# Ported to Ruby for Peraichi comparison POC.

module PeraichiSimpleHtmlDom
  # Node type constants
  HDOM_TYPE_ELEMENT = 1
  HDOM_TYPE_COMMENT = 2
  HDOM_TYPE_TEXT    = 3
  HDOM_TYPE_ENDTAG  = 4
  HDOM_TYPE_ROOT    = 5
  HDOM_TYPE_UNKNOWN = 6

  # Quote type constants
  HDOM_QUOTE_DOUBLE = 0
  HDOM_QUOTE_SINGLE = 1
  HDOM_QUOTE_NO     = 3

  # Info index constants
  HDOM_INFO_BEGIN    = 0
  HDOM_INFO_END      = 1
  HDOM_INFO_QUOTE    = 2
  HDOM_INFO_SPACE    = 3
  HDOM_INFO_TEXT     = 4
  HDOM_INFO_INNER    = 5
  HDOM_INFO_OUTER    = 6
  HDOM_INFO_ENDSPACE = 7

  HDOM_SMARTY_AS_TEXT = 1

  DEFAULT_TARGET_CHARSET = 'UTF-8'
  DEFAULT_BR_TEXT        = "\r\n"
  DEFAULT_SPAN_TEXT      = ' '
  MAX_FILE_SIZE          = 1_500_000

  # -------------------------------------------------------------------------
  # Node  (equivalent to simple_html_dom_node)
  # -------------------------------------------------------------------------
  class Node
    attr_accessor :nodetype, :tag, :attr, :children, :nodes,
                  :parent, :_, :tag_start

    # @param dom [Dom]
    def initialize(dom)
      @nodetype  = HDOM_TYPE_TEXT
      @tag       = 'text'
      @attr      = {}
      @children  = []
      @nodes     = []
      @parent    = nil
      @_         = {}   # metadata hash (keyed by HDOM_INFO_* constants)
      @tag_start = 0
      @dom       = dom
      dom.nodes << self
    end

    # ------- to_s / clear --------------------------------------------------

    def to_s
      outertext
    end

    def clear
      @dom      = nil
      @nodes    = nil
      @parent   = nil
      @children = nil
    end

    # ------- dump helpers --------------------------------------------------

    def dump(show_attr = true, depth = 0)
      out = "\t" * depth + @tag

      if show_attr && @attr.is_a?(Hash) && !@attr.empty?
        out << '('
        @attr.each { |k, v| out << "[#{k}]=>\"#{v}\", " }
        out << ')'
      end
      out << "\n"
      $stdout.print out

      @nodes&.each { |n| n.dump(show_attr, depth + 1) }
    end

    def dump_node(echo = true)
      string = @tag.dup

      if @attr.is_a?(Hash) && !@attr.empty?
        string << '('
        @attr.each { |k, v| string << "[#{k}]=>\"#{v}\", " }
        string << ')'
      end

      if @_.is_a?(Hash) && !@_.empty?
        string << ' $_ ('
        @_.each do |k, v|
          if v.is_a?(Array) || v.is_a?(Hash)
            string << "[#{k}]=>(" 
            (v.is_a?(Hash) ? v : v.each_with_index.to_h { |val, i| [i, val] }).each do |k2, v2|
              string << "[#{k2}]=>\"#{v2}\", "
            end
            string << ')'
          else
            string << "[#{k}]=>\"#{v}\", "
          end
        end
        string << ')'
      end

      string << ' HDOM_INNER_INFO: '
      if @_.is_a?(Hash) && @_.key?(HDOM_INFO_INNER)
        string << "'#{@_[HDOM_INFO_INNER]}'"
      else
        string << ' NULL '
      end

      string << " children: #{@children ? @children.size : 0}"
      string << " nodes: #{@nodes ? @nodes.size : 0}"
      string << " tag_start: #{@tag_start}"
      string << "\n"

      if echo
        $stdout.print string
        nil
      else
        string
      end
    end

    # ------- tree navigation -----------------------------------------------

    def parent(new_parent = nil)
      if new_parent
        @parent = new_parent
        @parent.nodes << self
        @parent.children << self
      end
      @parent
    end

    def has_child
      !@children.nil? && !@children.empty?
    end

    def children(idx = -1)
      return @children if idx == -1
      return nil unless @children
      @children[idx]
    end

    def first_child
      (@children && !@children.empty?) ? @children[0] : nil
    end

    def last_child
      (@children && !@children.empty?) ? @children[-1] : nil
    end

    def next_sibling
      return nil if @parent.nil?
      idx = @parent.children.index { |c| c.equal?(self) }
      return nil if idx.nil?
      @parent.children[idx + 1]
    end

    def prev_sibling
      return nil if @parent.nil?
      idx = @parent.children.index { |c| c.equal?(self) }
      return nil if idx.nil? || idx == 0
      @parent.children[idx - 1]
    end

    def find_ancestor_tag(tag)
      return nil if @parent.nil?
      ancestor = @parent
      while ancestor
        break if ancestor.tag == tag
        ancestor = ancestor.parent
      end
      ancestor
    end

    # ------- text accessors ------------------------------------------------

    def innertext
      return @_[HDOM_INFO_INNER] if @_.key?(HDOM_INFO_INNER)

      if @_.key?(HDOM_INFO_TEXT)
        return @dom.restore_noise(@_[HDOM_INFO_TEXT])
      end

      ret = +''
      @nodes.each { |n| ret << n.outertext }
      ret
    end

    def outertext
      return innertext if @tag == 'root'

      if @dom && @dom.callback
        @dom.callback.call(self)
      end

      return @_[HDOM_INFO_OUTER] if @_.key?(HDOM_INFO_OUTER)

      if @_.key?(HDOM_INFO_TEXT)
        return @dom.restore_noise(@_[HDOM_INFO_TEXT])
      end

      ret = +''

      if @dom && @_.key?(HDOM_INFO_BEGIN) && @dom.nodes[@_[HDOM_INFO_BEGIN]]
        ret << @dom.nodes[@_[HDOM_INFO_BEGIN]].makeup
      end

      if @_.key?(HDOM_INFO_INNER)
        ret << @_[HDOM_INFO_INNER] if @tag != 'br'
      elsif @nodes
        @nodes.each { |n| ret << convert_text(n.outertext) }
      end

      if @_.key?(HDOM_INFO_END) && @_[HDOM_INFO_END] != 0
        ret << "</#{@tag}>"
      end

      ret
    end

    def text
      return @_[HDOM_INFO_INNER] if @_.key?(HDOM_INFO_INNER)

      case @nodetype
      when HDOM_TYPE_TEXT
        return @dom.restore_noise(@_[HDOM_INFO_TEXT])
      when HDOM_TYPE_COMMENT
        return ''
      when HDOM_TYPE_UNKNOWN
        return ''
      end

      return '' if @tag.casecmp('script') == 0
      return '' if @tag.casecmp('style') == 0

      ret = +''

      if @nodes
        @nodes.each do |n|
          if n.tag == 'p'
            ret = ret.rstrip + "\n\n"
          end
          ret << convert_text(n.text)
          ret << @dom.default_span_text if n.tag == 'span'
        end
      end
      ret
    end

    def xmltext
      ret = innertext
      ret = ret.gsub(/<!\[CDATA\[/i, '')
      ret = ret.gsub(']]>', '')
      ret
    end

    # ------- makeup --------------------------------------------------------

    def makeup
      return @dom.restore_noise(@_[HDOM_INFO_TEXT]) if @_.key?(HDOM_INFO_TEXT)

      ret = +"<#{@tag}"
      i = -1

      @attr.each do |key, val|
        i += 1
        next if val.nil? || val == false

        ret << @_[HDOM_INFO_SPACE][i][0]

        if val == true
          ret << key.to_s
        else
          quote = case @_[HDOM_INFO_QUOTE][i]
                  when HDOM_QUOTE_DOUBLE then '"'
                  when HDOM_QUOTE_SINGLE then "'"
                  else ''
                  end
          ret << key.to_s
          ret << @_[HDOM_INFO_SPACE][i][1]
          ret << '='
          ret << @_[HDOM_INFO_SPACE][i][2]
          ret << quote
          ret << val.to_s
          ret << quote
        end
      end

      ret = @dom.restore_noise(ret)
      ret << (@_[HDOM_INFO_ENDSPACE] || '') << '>'
      ret
    end

    # ------- CSS selector engine -------------------------------------------

    def find(selector, idx = nil, lowercase = false)
      selectors = parse_selector(selector)
      count = selectors.size
      return [] if count == 0

      found_keys = {}

      (0...count).each do |c|
        levle = selectors[c].size
        return [] if levle == 0
        return [] unless @_.key?(HDOM_INFO_BEGIN)

        head = { @_[HDOM_INFO_BEGIN] => 1 }
        cmd = ' ' # Combinator

        (0...levle).each do |l|
          ret = {}
          head.each_key do |k|
            n = (k == -1) ? @dom.root : @dom.nodes[k]
            n.seek(selectors[c][l], ret, cmd, lowercase)
          end
          head = ret
          cmd = selectors[c][l][4] # Next Combinator
        end

        head.each_key do |k|
          found_keys[k] = 1 unless found_keys.key?(k)
        end
      end

      sorted_keys = found_keys.keys.sort
      found = sorted_keys.map { |k| @dom.nodes[k] }

      if idx.nil?
        found
      else
        idx += found.size if idx < 0
        found[idx]
      end
    end

    # protected
    def seek(selector, ret, parent_cmd, lowercase = false)
      tag_sel, id, klass, attributes, _cmb = selector
      nodes_list = []

      if parent_cmd == ' ' # Descendant Combinator
        end_pos = (!@_[HDOM_INFO_END].nil? && @_[HDOM_INFO_END] != 0) ? @_[HDOM_INFO_END] : 0
        if end_pos == 0
          p = @parent
          while p && !p._.key?(HDOM_INFO_END)
            end_pos -= 1
            p = p.parent
          end
          end_pos += p._[HDOM_INFO_END] if p && p._.key?(HDOM_INFO_END)
        end

        nodes_start = @_[HDOM_INFO_BEGIN] + 1
        nodes_count = end_pos - nodes_start
        if nodes_count > 0 && nodes_start < @dom.nodes.size
          # Replicate PHP array_slice with preserved keys
          actual_end = [nodes_start + nodes_count, @dom.nodes.size].min
          (nodes_start...actual_end).each do |idx|
            nodes_list << [idx, @dom.nodes[idx]] if @dom.nodes[idx]
          end
        end
      elsif parent_cmd == '>' # Child Combinator
        nodes_list = @children.map { |c| [c._[HDOM_INFO_BEGIN], c] } if @children
      elsif parent_cmd == '+' && @parent && @parent.children.any? { |c| c.equal?(self) }
        index = @parent.children.index { |c| c.equal?(self) }
        if index && (index + 1) < @parent.children.size
          child = @parent.children[index + 1]
          nodes_list << [child._[HDOM_INFO_BEGIN], child]
        end
      elsif parent_cmd == '~' && @parent && @parent.children.any? { |c| c.equal?(self) }
        index = @parent.children.index { |c| c.equal?(self) }
        if index
          @parent.children[index..].each do |child|
            nodes_list << [child._[HDOM_INFO_BEGIN], child]
          end
        end
      end

      nodes_list.each do |_node_key, node|
        next unless node
        pass = true

        pass = false unless node.parent

        if pass && tag_sel == 'text' && node.tag == 'text'
          dom_idx = @dom.nodes.index { |n| n.equal?(node) }
          ret[dom_idx] = 1 if dom_idx
          next
        end

        if pass && !node.parent.children.any? { |c| c.equal?(node) }
          pass = false
        end

        if pass && tag_sel != '' && tag_sel != node.tag && tag_sel != '*'
          pass = false
        end

        if pass && id != '' && !node.attr.key?('id')
          pass = false
        end

        if pass && id != '' && node.attr.key?('id')
          node_id = node.attr['id'].to_s.strip.split(' ')[0]
          pass = false if id != node_id
        end

        if pass && klass != '' && klass.is_a?(Array) && !klass.empty?
          if node.attr.key?('class')
            node_classes = node.attr['class'].to_s.split(' ')
            node_classes = node_classes.map(&:downcase) if lowercase
            klass.each do |c_item|
              unless node_classes.include?(c_item)
                pass = false
                break
              end
            end
          else
            pass = false
          end
        end

        if pass && attributes != '' && attributes.is_a?(Array) && !attributes.empty?
          attributes.each do |a|
            att_name, att_expr, att_val, att_inv, att_case_sensitivity = a

            # Handle indexing attributes (i.e. "[2]")
            if att_name.is_a?(String) && att_name.match?(/\A\d+\z/) && att_expr == '' && att_val == ''
              count_idx = 0
              node.parent.children.each do |c_item|
                count_idx += 1 if c_item.tag == node.tag
                break if c_item.equal?(node)
              end
              next if count_idx == att_name.to_i
            end

            if att_inv
              if node.attr.key?(att_name)
                pass = false
                break
              end
            else
              if att_name != 'plaintext' && !node.attr.key?(att_name)
                pass = false
                break
              end
            end

            next if att_expr == ''

            node_key_value = if att_name == 'plaintext'
                               node.text
                             else
                               node.attr[att_name]
                             end

            if lowercase
              check = match_expr(att_expr, att_val.to_s.downcase, node_key_value.to_s.downcase, att_case_sensitivity)
            else
              check = match_expr(att_expr, att_val.to_s, node_key_value.to_s, att_case_sensitivity)
            end

            unless check
              pass = false
              break
            end
          end
        end

        ret[node._[HDOM_INFO_BEGIN]] = 1 if pass
      end
    end

    # protected
    def match_expr(exp, pattern, value, case_sensitivity)
      if case_sensitivity == 'i'
        pattern = pattern.downcase
        value   = value.downcase
      end

      case exp
      when '='  then value == pattern
      when '!=' then value != pattern
      when '^=' then value.match?(/\A#{Regexp.escape(pattern)}/)
      when '$=' then value.match?(/#{Regexp.escape(pattern)}\z/)
      when '*=' then value.include?(pattern)
      when '|=' then value.start_with?(pattern)
      when '~=' then value.strip.split(' ').include?(pattern)
      else false
      end
    end

    # protected
    def parse_selector(selector_string)
      pattern = /([\w:*-]*)(?:#([\w-]+))?(?:|\.([.\w-]+))?((?:\[@?(?:!?[\w:-]+)(?:(?:[!*^$|~]?=)["']?(?:.*?)["']?)?(?:\s*?(?:[iIsS])?)?\])+)?([\/, >+~]+)/i

      trimmed = selector_string.strip + ' '
      matches = trimmed.scan(pattern)
      # scan returns array of capture groups, we need to simulate PREG_SET_ORDER
      # Each match is [m1, m2, m3, m4, m5, m6] corresponding to captures

      selectors = []
      result = []

      matches.each do |m|
        # Reconstruct full match for trimming check
        full = m.join('')
        full = full.strip
        next if full == '' || full == '/' || full == '//'

        # m[0] = tag, m[1] = id, m[2] = class, m[3] = attributes, m[4] = separator
        m = m.map { |v| v || '' }

        # Convert tag to lowercase if needed
        m[0] = m[0].downcase if @dom && @dom.lowercase

        # Extract classes
        if m[2] != ''
          m[2] = m[2].split('.')
        end

        # Extract attributes
        if m[3] != ''
          attr_pattern = /\[@?(!?[\w:-]+)(?:([!*^$|~]?=)["']?(.*?)["']?)?(?:\s+?([iIsS])?)?\]/i
          attr_matches = m[3].strip.scan(attr_pattern)

          m[3] = []
          attr_matches.each do |att|
            att_full = att.join('')
            next if att_full.strip == ''

            inverted = att[0] && att[0][0] == '!'
            m[3] << [
              inverted ? att[0][1..] : (att[0] || ''), # Name
              att[1] || '',                              # Expression
              att[2] || '',                              # Value
              inverted,                                  # Inverted Flag
              att[3] ? att[3].downcase : ''              # Case-Sensitivity
            ]
          end
        end

        # Sanitize separator
        if m[4] != '' && m[4].strip == ''
          m[4] = ' ' # Descendant separator
        else
          m[4] = m[4].strip
        end

        is_list = (m[4] == ',')
        m[4] = '' if is_list

        result << m

        if is_list
          selectors << result
          result = []
        end
      end

      selectors << result if result.size > 0
      selectors
    end

    # ------- property access (__get/__set equivalents) ---------------------

    def get_attribute(name)
      _php_get(name)
    end

    def set_attribute(name, value)
      _php_set(name, value)
    end

    def has_attribute(name)
      _php_isset(name)
    end

    def remove_attribute(name)
      _php_set(name, nil)
    end

    def get_all_attributes
      @attr
    end

    # PHP __get equivalent
    def _php_get(name)
      name = name.to_s
      if @attr.key?(name)
        return convert_text(@attr[name])
      end
      case name
      when 'outertext'  then outertext
      when 'innertext'  then innertext
      when 'plaintext'  then text
      when 'xmltext'    then xmltext
      else
        @attr.key?(name)
      end
    end

    # PHP __set equivalent
    def _php_set(name, value)
      name = name.to_s
      case name
      when 'outertext'
        @_[HDOM_INFO_OUTER] = value
        return value
      when 'innertext'
        if @_.key?(HDOM_INFO_TEXT)
          @_[HDOM_INFO_TEXT] = value
          return value
        end
        @_[HDOM_INFO_INNER] = value
        return value
      end

      unless @attr.key?(name)
        @_[HDOM_INFO_SPACE] ||= []
        @_[HDOM_INFO_SPACE] << [' ', '', '']
        @_[HDOM_INFO_QUOTE] ||= []
        @_[HDOM_INFO_QUOTE] << HDOM_QUOTE_DOUBLE
      end

      @attr[name] = value
    end

    # PHP __isset equivalent
    def _php_isset(name)
      name = name.to_s
      case name
      when 'outertext', 'innertext', 'plaintext'
        return true
      end
      @attr.key?(name)
    end

    # PHP __unset equivalent
    def _php_unset(name)
      name = name.to_s
      @attr.delete(name) if @attr.key?(name)
    end

    # method_missing for dynamic attribute access (like PHP __get/__set)
    def method_missing(name, *args)
      name_str = name.to_s
      if name_str.end_with?('=')
        attr_name = name_str.chomp('=')
        _php_set(attr_name, args[0])
      else
        _php_get(name_str)
      end
    end

    def respond_to_missing?(name, include_private = false)
      true
    end

    # ------- convert_text --------------------------------------------------

    def convert_text(text_val)
      converted_text = text_val.to_s

      source_charset = ''
      target_charset = ''

      if @dom
        source_charset = @dom._charset.to_s.upcase
        target_charset = @dom._target_charset.to_s.upcase
      end

      if !source_charset.empty? && !target_charset.empty? &&
         source_charset.casecmp(target_charset) != 0
        if target_charset == 'UTF-8' && self.class.is_utf8(converted_text)
          # already UTF-8
        else
          begin
            converted_text = converted_text.encode(target_charset, source_charset, invalid: :replace, undef: :replace)
          rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, Encoding::ConverterNotFoundError
            # leave as is
          end
        end
      end

      if target_charset == 'UTF-8'
        bom = "\xEF\xBB\xBF".b
        if converted_text.b.start_with?(bom)
          converted_text = converted_text.b[3..].force_encoding(converted_text.encoding)
        end
        if converted_text.b.end_with?(bom)
          converted_text = converted_text.b[0..-4].force_encoding(converted_text.encoding)
        end
      end

      converted_text
    end

    def self.is_utf8(str)
      c = 0
      b = 0
      bits = 0
      bytes = str.bytes
      len = bytes.size
      i = 0
      while i < len
        c = bytes[i]
        if c > 128
          if c >= 254
            return false
          elsif c >= 252
            bits = 6
          elsif c >= 248
            bits = 5
          elsif c >= 240
            bits = 4
          elsif c >= 224
            bits = 3
          elsif c >= 192
            bits = 2
          else
            return false
          end
          return false if (i + bits) > len
          while bits > 1
            i += 1
            b = bytes[i]
            return false if b < 128 || b > 191
            bits -= 1
          end
        end
        i += 1
      end
      true
    end

    # ------- get_display_size (for img tags) --------------------------------

    def get_display_size
      return false unless @tag == 'img'

      width = -1
      height = -1

      width = @attr['width'] if @attr.key?('width')
      height = @attr['height'] if @attr.key?('height')

      if @attr.key?('style')
        attributes = {}
        @attr['style'].to_s.scan(/([\w-]+)\s*:\s*([^;]+)\s*;?/) do |m|
          attributes[m[0]] = m[1]
        end

        if attributes.key?('width') && width == -1
          if attributes['width'].to_s.downcase.end_with?('px')
            proposed = attributes['width'][0..-3]
            width = proposed.to_i if proposed.match?(/\A-?\d+\z/)
          end
        end

        if attributes.key?('height') && height == -1
          if attributes['height'].to_s.downcase.end_with?('px')
            proposed = attributes['height'][0..-3]
            height = proposed.to_i if proposed.match?(/\A-?\d+\z/)
          end
        end
      end

      { 'height' => height, 'width' => width }
    end

    # ------- save ----------------------------------------------------------

    def save(filepath = '')
      ret = outertext
      File.write(filepath, ret) if filepath != ''
      ret
    end

    # ------- class manipulation --------------------------------------------

    def add_class(klass)
      klass = klass.split(' ') if klass.is_a?(String)

      if klass.is_a?(Array)
        klass.each do |c|
          current = _php_get('class')
          if current && current != false
            unless has_class(c)
              _php_set('class', current.to_s + ' ' + c)
            end
          else
            _php_set('class', c)
          end
        end
      end
    end

    # PHP uses addClass
    alias addClass add_class

    def has_class(klass)
      if klass.is_a?(String)
        current = @attr['class']
        if current
          return current.to_s.split(' ').include?(klass)
        end
      end
      false
    end

    alias hasClass has_class

    def remove_class(klass = nil)
      return unless @attr.key?('class')

      if klass.nil?
        remove_attribute('class')
        return
      end

      klass = klass.split(' ') if klass.is_a?(String)

      if klass.is_a?(Array)
        remaining = @attr['class'].to_s.split(' ') - klass
        if remaining.empty?
          remove_attribute('class')
        else
          _php_set('class', remaining.join(' '))
        end
      end
    end

    alias removeClass remove_class

    def remove
      @parent.remove_child(self) if @parent
    end

    def remove_child(node)
      return unless @nodes && @children && @dom

      nidx = @nodes.index { |n| n.equal?(node) }
      cidx = @children.index { |c| c.equal?(node) }
      didx = @dom.nodes.index { |d| d.equal?(node) }

      if nidx && cidx && didx
        node.children&.dup&.each { |child| node.remove_child(child) }

        node.nodes&.dup&.each do |entity|
          enidx = node.nodes.index { |n| n.equal?(entity) }
          edidx = node._dom_ref&.nodes&.index { |d| d.equal?(entity) }
          if enidx
            node.nodes.delete_at(enidx)
          end
          if edidx
            node._dom_ref.nodes.delete_at(edidx)
          end
        end

        @nodes.delete_at(nidx)
        @children.delete_at(cidx)
        @dom.nodes.delete_at(didx)

        node.clear
      end
    end

    alias removeChild remove_child

    def append_child(node)
      node.parent(self)
      node
    end

    alias appendChild append_child

    # expose @dom for removeChild
    def _dom_ref
      @dom
    end

    # ------- DOM compatibility methods -------------------------------------

    def get_element_by_id(id)
      find("##{id}", 0)
    end
    alias getElementById get_element_by_id

    def get_elements_by_id(id, idx = nil)
      find("##{id}", idx)
    end
    alias getElementsById get_elements_by_id

    def get_element_by_tag_name(name)
      find(name, 0)
    end
    alias getElementByTagName get_element_by_tag_name

    def get_elements_by_tag_name(name, idx = nil)
      find(name, idx)
    end
    alias getElementsByTagName get_elements_by_tag_name

    def parent_node
      parent()
    end
    alias parentNode parent_node

    def child_nodes(idx = -1)
      children(idx)
    end
    alias childNodes child_nodes

    def first_child_node
      first_child
    end
    alias firstChild first_child

    def last_child_node
      last_child
    end
    alias lastChild last_child

    def next_sibling_node
      next_sibling
    end
    alias nextSibling next_sibling

    def previous_sibling
      prev_sibling
    end
    alias previousSibling previous_sibling

    def has_child_nodes
      has_child
    end
    alias hasChildNodes has_child_nodes

    def node_name
      @tag
    end
    alias nodeName node_name

    # Aliases using PHP-style naming
    alias getAllAttributes get_all_attributes
    alias getAttribute get_attribute
    alias setAttribute set_attribute
    alias hasAttribute has_attribute
    alias removeAttribute remove_attribute
  end # class Node

  # -------------------------------------------------------------------------
  # Dom  (equivalent to simple_html_dom)
  # -------------------------------------------------------------------------
  class Dom
    attr_accessor :root, :nodes, :callback, :lowercase, :original_size, :size,
                  :_charset, :_target_charset, :default_span_text

    attr_reader :noise

    SELF_CLOSING_TAGS = {
      'area' => 1, 'base' => 1, 'br' => 1, 'col' => 1,
      'embed' => 1, 'hr' => 1, 'img' => 1, 'input' => 1,
      'link' => 1, 'meta' => 1, 'param' => 1, 'source' => 1,
      'track' => 1, 'wbr' => 1
    }.freeze

    BLOCK_TAGS = {
      'body' => 1, 'div' => 1, 'form' => 1,
      'root' => 1, 'span' => 1, 'table' => 1
    }.freeze

    OPTIONAL_CLOSING_TAGS = {
      'b'        => { 'b' => 1 },
      'dd'       => { 'dd' => 1, 'dt' => 1 },
      'dl'       => { 'dd' => 1, 'dt' => 1 },
      'dt'       => { 'dd' => 1, 'dt' => 1 },
      'li'       => { 'li' => 1 },
      'optgroup' => { 'optgroup' => 1, 'option' => 1 },
      'option'   => { 'optgroup' => 1, 'option' => 1 },
      'p'        => { 'p' => 1 },
      'rp'       => { 'rp' => 1, 'rt' => 1 },
      'rt'       => { 'rp' => 1, 'rt' => 1 },
      'td'       => { 'td' => 1, 'th' => 1 },
      'th'       => { 'td' => 1, 'th' => 1 },
      'tr'       => { 'td' => 1, 'th' => 1, 'tr' => 1 }
    }.freeze

    TOKEN_BLANK = " \t\r\n"
    TOKEN_EQUAL = " =/>"
    TOKEN_SLASH = " />\r\n\t"
    TOKEN_ATTR  = ' >'

    def initialize(
      str = nil,
      lowercase: true,
      force_tags_closed: true,
      target_charset: DEFAULT_TARGET_CHARSET,
      strip_rn: true,
      default_br_text: DEFAULT_BR_TEXT,
      default_span_text: DEFAULT_SPAN_TEXT,
      options: 0
    )
      @root           = nil
      @nodes          = []
      @callback       = nil
      @lowercase      = lowercase
      @original_size  = 0
      @size           = 0
      @pos            = 0
      @doc            = ''
      @char           = nil
      @cursor         = 0
      @parent         = nil
      @noise          = {}
      @_charset       = ''
      @_target_charset = target_charset
      @default_br_text = default_br_text
      @default_span_text = default_span_text
      @optional_closing_tags = force_tags_closed ? OPTIONAL_CLOSING_TAGS.dup : {}

      if str
        if str.match?(/\Ahttp:\/\//i) || File.file?(str)
          load_file(str)
        else
          load(str, lowercase, strip_rn, default_br_text, default_span_text, options)
        end
      end
    end

    # ------- load ----------------------------------------------------------

    def load(
      str,
      lowercase = true,
      strip_rn = true,
      default_br_text = DEFAULT_BR_TEXT,
      default_span_text = DEFAULT_SPAN_TEXT,
      options = 0
    )
      # prepare
      prepare(str, lowercase, default_br_text, default_span_text)

      # Strip out <script> tags
      remove_noise('<\s*script[^>]*[^/]>(.*?)<\s*/\s*script\s*>', true, false)
      remove_noise('<\s*script\s*>(.*?)<\s*/\s*script\s*>', true, false)

      # strip out \r \n if told to
      if strip_rn
        @doc = @doc.gsub("\r", ' ')
        @doc = @doc.gsub("\n", ' ')
        @size = @doc.size
      end

      # strip out cdata
      remove_noise('<!\[CDATA\[(.*?)\]\]>', true, true)
      # strip out comments
      remove_noise('<!--(.*?)-->', true, false)
      # strip out <style> tags
      remove_noise('<\s*style[^>]*[^/]>(.*?)<\s*/\s*style\s*>', true, false)
      remove_noise('<\s*style\s*>(.*?)<\s*/\s*style\s*>', true, false)
      # strip out preformatted tags
      remove_noise('<\s*(?:code)[^>]*>(.*?)<\s*/\s*(?:code)\s*>', true, false)
      # strip out server side scripts
      remove_noise('(<\?)(.*?)(\?>)', false, true)

      if (options & HDOM_SMARTY_AS_TEXT) != 0
        remove_noise('(\{\w)(.*?)(\})', false, true)
      end

      # parsing
      parse
      # end
      @root._[HDOM_INFO_END] = @cursor
      parse_charset

      self
    end

    def load_file(filepath)
      doc = File.read(filepath)
      load(doc, true)
    rescue
      false
    end

    # ------- prepare -------------------------------------------------------

    def prepare(str, lowercase = true, default_br_text = DEFAULT_BR_TEXT, default_span_text = DEFAULT_SPAN_TEXT)
      clear

      @doc           = str.strip
      @size          = @doc.size
      @original_size = @size
      @pos           = 0
      @cursor        = 1
      @noise         = {}
      @nodes         = []
      @lowercase     = lowercase
      @default_br_text   = default_br_text
      @default_span_text = default_span_text
      @root          = Node.new(self)
      @root.tag      = 'root'
      @root._[HDOM_INFO_BEGIN] = -1
      @root.nodetype = HDOM_TYPE_ROOT
      @parent        = @root
      @char          = @size > 0 ? @doc[0] : nil
    end

    # ------- parse (main tokenizer loop) -----------------------------------

    def parse
      loop do
        s = copy_until_char('<')
        if s == ''
          if read_tag
            next
          else
            return true
          end
        end

        # Add a text node for text between tags
        node = Node.new(self)
        @cursor += 1
        node._[HDOM_INFO_TEXT] = s
        link_nodes(node, false)
      end
    end

    # ------- parse_charset -------------------------------------------------

    def parse_charset
      charset = nil

      if charset.nil? || charset.to_s.empty?
        el = @root.find('meta[http-equiv=Content-Type]', 0, true)
        if el
          fullvalue = el._php_get('content')
          if fullvalue && fullvalue != false && !fullvalue.to_s.empty?
            if fullvalue.to_s.match?(/charset=(.+)/i)
              charset = fullvalue.to_s.match(/charset=(.+)/i)[1]
            else
              charset = 'ISO-8859-1'
            end
          end
        end
      end

      if charset.nil? || charset.to_s.empty?
        meta = @root.find('meta[charset]', 0)
        if meta
          charset = meta._php_get('charset')
        end
      end

      if charset.nil? || charset.to_s.empty?
        charset = 'UTF-8'
      end

      cl = charset.to_s.downcase
      if cl == 'iso-8859-1' || cl == 'latin1' || cl == 'latin-1'
        charset = 'CP1252'
      end

      @_charset = charset
    end

    # ------- read_tag ------------------------------------------------------

    def read_tag
      if @char != '<'
        @root._[HDOM_INFO_END] = @cursor
        return false
      end

      begin_tag_pos = @pos
      @pos += 1
      @char = @pos < @size ? @doc[@pos] : nil

      # end tag
      if @char == '/'
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil

        skip(TOKEN_BLANK)
        tag = copy_until_char('>')

        # Skip attributes in end tags
        space_pos = tag.index(' ')
        tag = tag[0...space_pos] if space_pos

        parent_lower = @parent.tag.downcase
        tag_lower    = tag.downcase

        if parent_lower != tag_lower
          if @optional_closing_tags.key?(parent_lower) && BLOCK_TAGS.key?(tag_lower)
            @parent._[HDOM_INFO_END] = 0
            org_parent = @parent

            while @parent.parent && @parent.tag.downcase != tag_lower
              @parent = @parent.parent
            end

            if @parent.tag.downcase != tag_lower
              @parent = org_parent

              if @parent.parent
                @parent = @parent.parent
              end

              @parent._[HDOM_INFO_END] = @cursor
              return as_text_node(tag)
            end
          elsif @parent.parent && BLOCK_TAGS.key?(tag_lower)
            @parent._[HDOM_INFO_END] = 0
            org_parent = @parent

            while @parent.parent && @parent.tag.downcase != tag_lower
              @parent = @parent.parent
            end

            if @parent.tag.downcase != tag_lower
              @parent = org_parent
              @parent._[HDOM_INFO_END] = @cursor
              return as_text_node(tag)
            end
          elsif @parent.parent && @parent.parent.tag.downcase == tag_lower
            @parent._[HDOM_INFO_END] = 0
            @parent = @parent.parent
          else
            return as_text_node(tag)
          end
        end

        @parent._[HDOM_INFO_END] = @cursor

        if @parent.parent
          @parent = @parent.parent
        end

        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
        return true
      end

      # start tag
      node = Node.new(self)
      node._[HDOM_INFO_BEGIN] = @cursor
      @cursor += 1
      tag = copy_until(TOKEN_SLASH)
      node.tag_start = begin_tag_pos

      # doctype, cdata & comments...
      if tag.length > 0 && tag[0] == '!'
        node._[HDOM_INFO_TEXT] = '<' + tag + copy_until_char('>')

        if tag.length > 2 && tag[1] == '-' && tag[2] == '-'
          node.nodetype = HDOM_TYPE_COMMENT
          node.tag = 'comment'
        else
          node.nodetype = HDOM_TYPE_UNKNOWN
          node.tag = 'unknown'
        end

        node._[HDOM_INFO_TEXT] += '>' if @char == '>'

        link_nodes(node, true)
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
        return true
      end

      # The start tag cannot contain another start tag
      if tag.include?('<')
        tag = '<' + tag[0..-2]
        node._[HDOM_INFO_TEXT] = tag
        link_nodes(node, false)
        @pos -= 1
        @char = @doc[@pos]
        return true
      end

      # Handle invalid tag names
      unless tag.match?(/\A\w[\w:-]*\z/)
        node._[HDOM_INFO_TEXT] = '<' + tag + copy_until_chars('<>')

        if @char == '<'
          link_nodes(node, false)
          return true
        end

        node._[HDOM_INFO_TEXT] += '>' if @char == '>'
        link_nodes(node, false)
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
        return true
      end

      # begin tag, add new node
      node.nodetype = HDOM_TYPE_ELEMENT
      tag_lower = tag.downcase
      node.tag = @lowercase ? tag_lower : tag

      # handle optional closing tags
      if @optional_closing_tags.key?(tag_lower)
        while @optional_closing_tags[tag_lower]&.key?(@parent.tag.downcase)
          @parent._[HDOM_INFO_END] = 0
          @parent = @parent.parent
        end
        node.parent = @parent
      end

      guard = 0

      # [0] Space between tag and first attribute
      space = [copy_skip(TOKEN_BLANK), '', '']

      # attributes
      loop do
        name = copy_until(TOKEN_EQUAL)

        if name == '' && @char != nil && space[0] == ''
          break
        end

        if guard == @pos
          @pos += 1
          @char = @pos < @size ? @doc[@pos] : nil
          next
        end

        guard = @pos

        # handle endless '<'
        if @pos >= @size - 1 && @char != '>'
          node.nodetype = HDOM_TYPE_TEXT
          node._[HDOM_INFO_END] = 0
          node._[HDOM_INFO_TEXT] = '<' + tag + space[0] + name
          node.tag = 'text'
          link_nodes(node, false)
          return true
        end

        # handle mismatch '<'
        if @pos > 0 && @doc[@pos - 1] == '<'
          node.nodetype = HDOM_TYPE_TEXT
          node.tag = 'text'
          node.attr = {}
          node._[HDOM_INFO_END] = 0
          node._[HDOM_INFO_TEXT] = @doc[begin_tag_pos...(@pos - 1)]
          @pos -= 2
          @pos += 1
          @char = @pos < @size ? @doc[@pos] : nil
          link_nodes(node, false)
          return true
        end

        if name != '/' && name != '' # attribute name
          # [1] Whitespace after attribute name
          space[1] = copy_skip(TOKEN_BLANK)

          name = restore_noise(name) # might be a noisy name

          name = name.downcase if @lowercase

          if @char == '=' # attribute with value
            @pos += 1
            @char = @pos < @size ? @doc[@pos] : nil
            parse_attr(node, name, space)
          else
            # no value attr: nowrap, checked, selected...
            node._[HDOM_INFO_QUOTE] ||= []
            node._[HDOM_INFO_QUOTE] << HDOM_QUOTE_NO
            node.attr[name] = true
            if @char != '>'
              @pos -= 1
              @char = @doc[@pos]
            end
          end

          node._[HDOM_INFO_SPACE] ||= []
          node._[HDOM_INFO_SPACE] << space

          # prepare for next attribute
          space = [copy_skip(TOKEN_BLANK), '', '']
        else
          break
        end

        break if @char == '>' || @char == '/'
      end

      link_nodes(node, true)
      node._[HDOM_INFO_ENDSPACE] = space[0]

      # handle empty tags (i.e. "<div/>")
      if copy_until_char('>') == '/'
        node._[HDOM_INFO_ENDSPACE] = (node._[HDOM_INFO_ENDSPACE] || '') + '/'
        node._[HDOM_INFO_END] = 0
      else
        unless SELF_CLOSING_TAGS.key?(node.tag.downcase)
          @parent = node
        end
      end

      @pos += 1
      @char = @pos < @size ? @doc[@pos] : nil

      if node.tag == 'br'
        node._[HDOM_INFO_INNER] = @default_br_text
      end

      true
    end

    # ------- parse_attr ----------------------------------------------------

    def parse_attr(node, name, space)
      is_duplicate = node.attr.key?(name)

      unless is_duplicate
        space[2] = copy_skip(TOKEN_BLANK)
      end

      case @char
      when '"'
        quote_type = HDOM_QUOTE_DOUBLE
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
        value = copy_until_char('"')
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
      when "'"
        quote_type = HDOM_QUOTE_SINGLE
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
        value = copy_until_char("'")
        @pos += 1
        @char = @pos < @size ? @doc[@pos] : nil
      else
        quote_type = HDOM_QUOTE_NO
        value = copy_until(TOKEN_ATTR)
      end

      value = restore_noise(value)

      value = value.gsub("\r", '')
      value = value.gsub("\n", '')

      value = value.strip if name == 'class'

      unless is_duplicate
        node._[HDOM_INFO_QUOTE] ||= []
        node._[HDOM_INFO_QUOTE] << quote_type
        node.attr[name] = value
      end
    end

    # ------- link_nodes ----------------------------------------------------

    def link_nodes(node, is_child)
      node.parent = @parent
      @parent.nodes << node
      @parent.children << node if is_child
    end

    # ------- as_text_node --------------------------------------------------

    def as_text_node(tag)
      node = Node.new(self)
      @cursor += 1
      node._[HDOM_INFO_TEXT] = '</' + tag + '>'
      link_nodes(node, false)
      @pos += 1
      @char = @pos < @size ? @doc[@pos] : nil
      true
    end

    # ------- string scanner helpers ----------------------------------------

    def skip(chars)
      @pos += strspn(@doc, chars, @pos)
      @char = @pos < @size ? @doc[@pos] : nil
    end

    def copy_skip(chars)
      pos = @pos
      len = strspn(@doc, chars, pos)
      @pos += len
      @char = @pos < @size ? @doc[@pos] : nil
      return '' if len == 0
      @doc[pos, len]
    end

    def copy_until(chars)
      pos = @pos
      len = strcspn(@doc, chars, pos)
      @pos += len
      @char = @pos < @size ? @doc[@pos] : nil
      @doc[pos, len] || ''
    end

    def copy_until_char(char)
      return '' if @char.nil?

      found_pos = @doc.index(char, @pos)
      if found_pos.nil?
        ret = @doc[@pos, @size - @pos]
        @char = nil
        @pos = @size
        return ret || ''
      end

      if found_pos == @pos
        return ''
      end

      pos_old = @pos
      @char = @doc[found_pos]
      @pos = found_pos
      @doc[pos_old, found_pos - pos_old] || ''
    end

    # copy_until for multiple chars (used for '<>' in invalid tag handling)
    def copy_until_chars(chars)
      copy_until(chars)
    end

    # ------- strspn / strcspn (PHP equivalents) ----------------------------

    def strspn(str, chars, offset = 0)
      count = 0
      i = offset
      while i < str.size
        break unless chars.include?(str[i])
        count += 1
        i += 1
      end
      count
    end

    def strcspn(str, chars, offset = 0)
      count = 0
      i = offset
      while i < str.size
        break if chars.include?(str[i])
        count += 1
        i += 1
      end
      count
    end

    # ------- noise system --------------------------------------------------

    def remove_noise(pattern_str, case_insensitive = true, remove_tag = false)
      flags = Regexp::MULTILINE
      flags |= Regexp::IGNORECASE if case_insensitive
      pattern = Regexp.new(pattern_str, flags)

      matches = []
      @doc.scan(pattern) do
        m = Regexp.last_match
        matches << m
      end

      # Process from last to first (reverse) to maintain correct offsets
      matches.reverse_each do |m|
        key = '___noise___' + format('% 5d', @noise.size + 1000)

        idx = remove_tag ? 0 : 1
        # For patterns without a capture group at idx, fall back to full match
        matched_text = m[idx] || m[0]
        match_offset = m.begin(idx) || m.begin(0)
        match_len    = matched_text.size

        @noise[key] = matched_text
        @doc = @doc[0...match_offset] + key + @doc[(match_offset + match_len)..]
      end

      @size = @doc.size
      @char = @size > 0 ? @doc[0] : nil
    end

    def restore_noise(text)
      text = text.dup if text.frozen?

      while (pos = text.index('___noise___'))
        if text.size > pos + 15
          key = '___noise___' +
                text[pos + 11].to_s +
                text[pos + 12].to_s +
                text[pos + 13].to_s +
                text[pos + 14].to_s +
                text[pos + 15].to_s

          if @noise.key?(key)
            text = text[0...pos] + @noise[key] + text[(pos + 16)..]
          else
            text = text[0...pos] +
                   'UNDEFINED NOISE FOR KEY: ' + key +
                   text[(pos + 16)..]
          end
        else
          text = text[0...pos] +
                 'NO NUMERIC NOISE KEY' +
                 text[(pos + 11)..]
        end
      end
      text
    end

    def search_noise(text)
      @noise.each_value do |element|
        return element if element.include?(text)
      end
      nil
    end

    # ------- to_s / save / dump -------------------------------------------

    def to_s
      @root.innertext
    end

    def save(filepath = '')
      ret = @root.innertext
      File.write(filepath, ret) if filepath != ''
      ret
    end

    def dump(show_attr = true)
      @root.dump(show_attr)
    end

    # ------- clear ---------------------------------------------------------

    def clear
      if @nodes
        @nodes.each do |n|
          n&.clear
        end
      end

      @root&.clear
      @root  = nil
      @doc   = nil
      @noise = {}
    end

    # ------- find / callback -----------------------------------------------

    def find(selector, idx = nil, lowercase = false)
      @root.find(selector, idx, lowercase)
    end

    def set_callback(function)
      @callback = function
    end

    def remove_callback
      @callback = nil
    end

    # ------- __get equivalent (method_missing) ----------------------------

    def _php_get(name)
      case name.to_s
      when 'outertext'       then @root.innertext
      when 'innertext'       then @root.innertext
      when 'plaintext'       then @root.text
      when 'charset'         then @_charset
      when 'target_charset'  then @_target_charset
      end
    end

    # ------- DOM-compatible methods ----------------------------------------

    def child_nodes(idx = -1)
      @root.child_nodes(idx)
    end
    alias childNodes child_nodes

    def first_child
      @root.first_child
    end
    alias firstChild first_child

    def last_child
      @root.last_child
    end
    alias lastChild last_child

    def create_element(name, value = nil)
      PeraichiSimpleHtmlDom.str_get_html("<#{name}>#{value}</#{name}>")&.first_child
    end
    alias createElement create_element

    def create_text_node(value)
      dom = PeraichiSimpleHtmlDom.str_get_html(value)
      dom&.nodes&.last
    end
    alias createTextNode create_text_node

    def get_element_by_id(id)
      find("##{id}", 0)
    end
    alias getElementById get_element_by_id

    def get_elements_by_id(id, idx = nil)
      find("##{id}", idx)
    end
    alias getElementsById get_elements_by_id

    def get_element_by_tag_name(name)
      find(name, 0)
    end
    alias getElementByTagName get_element_by_tag_name

    def get_elements_by_tag_name(name, idx = -1)
      find(name, idx)
    end
    alias getElementsByTagName get_elements_by_tag_name

    def load_file_method(*args)
      load_file(*args)
    end
    alias loadFile load_file_method

  end # class Dom

  # -------------------------------------------------------------------------
  # Module-level methods
  # -------------------------------------------------------------------------

  def self.str_get_html(
    str,
    lowercase: true,
    force_tags_closed: true,
    target_charset: DEFAULT_TARGET_CHARSET,
    strip_rn: false,
    default_br_text: DEFAULT_BR_TEXT,
    default_span_text: DEFAULT_SPAN_TEXT
  )
    dom = Dom.new(
      nil,
      lowercase: lowercase,
      force_tags_closed: force_tags_closed,
      target_charset: target_charset,
      strip_rn: strip_rn,
      default_br_text: default_br_text,
      default_span_text: default_span_text
    )

    return false if str.nil? || str.empty? || str.size > MAX_FILE_SIZE

    dom.load(str, lowercase, strip_rn)
  end

  def self.file_get_html(
    url,
    lowercase: true,
    force_tags_closed: true,
    target_charset: DEFAULT_TARGET_CHARSET,
    strip_rn: false,
    default_br_text: DEFAULT_BR_TEXT,
    default_span_text: DEFAULT_SPAN_TEXT
  )
    dom = Dom.new(
      nil,
      lowercase: lowercase,
      force_tags_closed: force_tags_closed,
      target_charset: target_charset,
      strip_rn: strip_rn,
      default_br_text: default_br_text,
      default_span_text: default_span_text
    )

    contents = File.read(url)

    max_len = MAX_FILE_SIZE
    if contents.nil? || contents.empty? || contents.size > max_len
      dom.clear
      return false
    end

    dom.load(contents, lowercase, strip_rn)
  end

  def self.dump_html_tree(node, show_attr = true, _deep = 0)
    node.dump(show_attr)
  end

end # module PeraichiSimpleHtmlDom
