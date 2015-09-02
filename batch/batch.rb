class BlankSlate
  class << self

    def hide(name)
      warn_level = $VERBOSE
      $VERBOSE = nil
      if instance_methods.include?(name.to_sym) &&
          name !~ /^(__|instance_eval$)/
        @hidden_methods ||= {}
        @hidden_methods[name.to_sym] = instance_method(name)
        undef_method name
      end
    ensure
      $VERBOSE = warn_level
    end

    def find_hidden_method(name)
      @hidden_methods ||= {}
      @hidden_methods[name] || superclass.find_hidden_method(name)
    end

    def reveal(name)
      hidden_method = find_hidden_method(name)
      fail "Don't know how to reveal method '#{name}'" unless hidden_method
      define_method(name, hidden_method)
    end
  end

  instance_methods.each { |m| hide(m) }
end

module Kernel
  class << self
    alias_method :blank_slate_method_added, :method_added
    def method_added(name)
      result = blank_slate_method_added(name)
      return result if self != Kernel
      BlankSlate.hide(name)
      result
    end
  end
end

class Object
  class << self
    alias_method :blank_slate_method_added, :method_added
    def method_added(name)
      result = blank_slate_method_added(name)
      return result if self != Object
      BlankSlate.hide(name)
      result
    end

    def find_hidden_method(name)
      nil
    end
  end
end

class Module
  alias blankslate_original_append_features append_features
  def append_features(mod)
    result = blankslate_original_append_features(mod)
    return result if mod != Object
    instance_methods.each do |name|
      BlankSlate.hide(name)
    end
    result
  end
end

module Builder
  class IllegalBlockError < RuntimeError; end
  class XmlBase < BlankSlate
    class << self
      attr_accessor :cache_method_calls
    end
    def initialize(indent=0, initial=0, encoding='utf-8')
      @indent = indent
      @level  = initial
      @encoding = encoding.downcase
    end
    def explicit_nil_handling?
      @explicit_nil_handling
    end
    def tag!(sym, *args, &block)
      text = nil
      attrs = nil
      sym = "#{sym}:#{args.shift}" if args.first.kind_of?(::Symbol)
      sym = sym.to_sym unless sym.class == ::Symbol
      args.each do |arg|
        case arg
        when ::Hash
          attrs ||= {}
          attrs.merge!(arg)
        when nil
          attrs ||= {}
          attrs.merge!({:nil => true}) if explicit_nil_handling?
        else
          text ||= ''
          text << arg.to_s
        end
      end
      if block
        unless text.nil?
          ::Kernel::raise ::ArgumentError,
            "XmlMarkup cannot mix a text argument with a block"
        end
        _indent
        _start_tag(sym, attrs)
        _newline
        begin
          _nested_structures(block)
        ensure
          _indent
          _end_tag(sym)
          _newline
        end
      elsif text.nil?
        _indent
        _start_tag(sym, attrs, true)
        _newline
      else
        _indent
        _start_tag(sym, attrs)
        text! text
        _end_tag(sym)
        _newline
      end
      @target
    end
    def method_missing(sym, *args, &block)
      cache_method_call(sym) if ::Builder::XmlBase.cache_method_calls
      tag!(sym, *args, &block)
    end
    def text!(text)
      _text(_escape(text))
    end
    def <<(text)
      _text(text)
    end
    def nil?
      false
    end
    private
    if ::String.method_defined?(:encode)
      def _escape(text)
        result = XChar.encode(text)
        begin
          encoding = ::Encoding::find(@encoding)
          raise Exception if encoding.dummy?
          result.encode(encoding)
        rescue
          result.
            gsub(/[^\u0000-\u007F]/) {|c| "&##{c.ord};"}.
            force_encoding('ascii')
        end
      end
    else
      def _escape(text)
        if (text.method(:to_xs).arity == 0)
          text.to_xs
        else
          text.to_xs((@encoding != 'utf-8' or $KCODE != 'UTF8'))
        end
      end
    end
    def _escape_attribute(text)
      _escape(text).gsub("\n", "&#10;").gsub("\r", "&#13;").
        gsub(%r{"}, '&quot;') 
    end
    def _newline
      return if @indent == 0
      text! "\n"
    end
    def _indent
      return if @indent == 0 || @level == 0
      text!(" " * (@level * @indent))
    end
    def _nested_structures(block)
      @level += 1
      block.call(self)
    ensure
      @level -= 1
    end
    def cache_method_call(sym)
      class << self; self; end.class_eval do
        unless method_defined?(sym)
          define_method(sym) do |*args, &block|
            tag!(sym, *args, &block)
          end
        end
      end
    end
  end
  XmlBase.cache_method_calls = true
  class XmlMarkup < XmlBase
    def initialize(options={})
      indent = options[:indent] || 0
      margin = options[:margin] || 0
      @quote = (options[:quote] == :single) ? "'" : '"'
      @explicit_nil_handling = options[:explicit_nil_handling]
      super(indent, margin)
      @target = options[:target] || ""
    end
    def target!
      @target
    end
    def comment!(comment_text)
      _ensure_no_block ::Kernel::block_given?
      _special("<!-- ", " -->", comment_text, nil)
    end
    def declare!(inst, *args, &block)
      _indent
      @target << "<!#{inst}"
      args.each do |arg|
        case arg
        when ::String
          @target << %{ "#{arg}"} 
        when ::Symbol
          @target << " #{arg}"
        end
      end
      if ::Kernel::block_given?
        @target << " ["
        _newline
        _nested_structures(block)
        @target << "]"
      end
      @target << ">"
      _newline
    end
    def instruct!(directive_tag=:xml, attrs={})
      _ensure_no_block ::Kernel::block_given?
      if directive_tag == :xml
        a = { :version=>"1.0", :encoding=>"UTF-8" }
        attrs = a.merge attrs
	@encoding = attrs[:encoding].downcase
      end
      _special(
        "<?#{directive_tag}",
        "?>",
        nil,
        attrs,
        [:version, :encoding, :standalone])
    end
    def cdata!(text)
      _ensure_no_block ::Kernel::block_given?
      _special("<![CDATA[", "]]>", text.gsub(']]>', ']]]]><![CDATA[>'), nil)
    end
    private
    def _text(text)
      @target << text
    end
    def _special(open, close, data=nil, attrs=nil, order=[])
      _indent
      @target << open
      @target << data if data
      _insert_attributes(attrs, order) if attrs
      @target << close
      _newline
    end
    def _start_tag(sym, attrs, end_too=false)
      @target << "<#{sym}"
      _insert_attributes(attrs)
      @target << "/" if end_too
      @target << ">"
    end
    def _end_tag(sym)
      @target << "</#{sym}>"
    end
    def _insert_attributes(attrs, order=[])
      return if attrs.nil?
      order.each do |k|
        v = attrs[k]
        @target << %{ #{k}=#{@quote}#{_attr_value(v)}#{@quote}} if v
      end
      attrs.each do |k, v|
        @target << %{ #{k}=#{@quote}#{_attr_value(v)}#{@quote}} unless order.member?(k) 
      end
    end
    def _attr_value(value)
      case value
      when ::Symbol
        value.to_s
      else
        _escape_attribute(value.to_s)
      end
    end
    def _ensure_no_block(got_block)
      if got_block
        ::Kernel::raise IllegalBlockError.new(
          "Blocks are not allowed on XML instructions"
        )
      end
    end
  end
  if Object::const_defined?(:BasicObject)
    BlankSlate = ::BasicObject
  else
    BlankSlate = ::BlankSlate
  end
  def self.check_for_name_collision(klass, method_name, defined_constant=nil)
    if klass.method_defined?(method_name.to_s)
      fail RuntimeError,
	"Name Collision: Method '#{method_name}' is already defined in #{klass}"
    end
  end
  module XChar 
    CP1252 = {			
      128 => 8364,		
      130 => 8218,		
      131 =>  402,		
      132 => 8222,		
      133 => 8230,		
      134 => 8224,		
      135 => 8225,		
      136 =>  710,		
      137 => 8240,		
      138 =>  352,		
      139 => 8249,		
      140 =>  338,		
      142 =>  381,		
      145 => 8216,		
      146 => 8217,		
      147 => 8220,		
      148 => 8221,		
      149 => 8226,		
      150 => 8211,		
      151 => 8212,		
      152 =>  732,		
      153 => 8482,		
      154 =>  353,		
      155 => 8250,		
      156 =>  339,		
      158 =>  382,		
      159 =>  376,		
    }
    PREDEFINED = {
      38 => '&amp;',		
      60 => '&lt;',		
      62 => '&gt;',		
    }
    VALID = [
      0x9, 0xA, 0xD,
      (0x20..0xD7FF), 
      (0xE000..0xFFFD),
      (0x10000..0x10FFFF)
    ]
    REPLACEMENT_CHAR =
      if String.method_defined?(:encode)
        "\uFFFD"
      elsif $KCODE == 'UTF8'
        "\xEF\xBF\xBD"
      else
        '*'
      end
  end
  class XmlEvents < XmlMarkup
    def text!(text)
      @target.text(text)
    end
    def _start_tag(sym, attrs, end_too=false)
      @target.start_tag(sym, attrs)
      _end_tag(sym) if end_too
    end
    def _end_tag(sym)
      @target.end_tag(sym)
    end
  end
end

module Builder
  module XChar 
    CP1252_DIFFERENCES, UNICODE_EQUIVALENT = Builder::XChar::CP1252.each.
      inject([[],[]]) {|(domain,range),(key,value)|
        [domain << key,range << value]
      }.map {|seq| seq.pack('U*').force_encoding('utf-8')}
    XML_PREDEFINED = Regexp.new('[' +
      Builder::XChar::PREDEFINED.keys.pack('U*').force_encoding('utf-8') +
    ']')
    INVALID_XML_CHAR = Regexp.new('[^'+
      Builder::XChar::VALID.map { |item|
        case item
        when Fixnum
          [item].pack('U').force_encoding('utf-8')
        when Range
          [item.first, '-'.ord, item.last].pack('UUU').force_encoding('utf-8')
        end
      }.join +
    ']')
    ENCODING_BINARY = nil
    ENCODING_UTF8   = Encoding.find('UTF-8')
    ENCODING_ISO1   = nil
    def XChar.unicode(string)
      if string.encoding == ENCODING_BINARY
        if string.ascii_only?
          string
        else
          string = string.clone.force_encoding(ENCODING_UTF8)
          if string.valid_encoding?
            string
          else
            string.encode(ENCODING_UTF8, ENCODING_ISO1)
          end
        end
      elsif string.encoding == ENCODING_UTF8
        if string.valid_encoding?
          string
        else
          string.encode(ENCODING_UTF8, ENCODING_ISO1)
        end
      else
        string.encode(ENCODING_UTF8)
      end
    end
    def XChar.encode(string)
      unicode(string).
        tr(CP1252_DIFFERENCES, UNICODE_EQUIVALENT).
        gsub(INVALID_XML_CHAR, REPLACEMENT_CHAR).
        gsub(XML_PREDEFINED) {|c| PREDEFINED[c.ord]}
    end
  end
end
