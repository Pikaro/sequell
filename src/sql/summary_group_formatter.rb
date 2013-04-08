module Sql
  class SummaryGroupFormatter
    DEFAULT_FORMAT = '${n_x}${.} ${%} [${n_ratio};${x}]'
    DEFAULT_PARENT_FORMAT = '${n_x}${.} ${%} (${child})'

    def self.parent_format(format=nil)
      self.new(format || DEFAULT_PARENT_FORMAT)
    end

    def initialize(format=nil)
      @format = format || DEFAULT_FORMAT
    end

    def format(row)
      @format.gsub(/\$\{([^}]+)\}/) { |m|
        format_key_value($1, row)
      }.gsub(/ +/, ' ').gsub(/([\[(])[;,]/, '\1').strip
    end

    def format_key_value(key, row)
      case key
      when 'n_x'
        row.count_prefix
      when '.'
        row.key_display_value
      when '%'
        row.percentage_string
      when 'n_ratio'
        row.count_ratio_percentage
      when 'x'
        row.extra_field_value_string
      when 'child'
        row.subrows_string
      else
        "\${#{key}}"
      end
    end
  end
end
