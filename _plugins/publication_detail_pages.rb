module PublicationDetails
  module_function

  DEFAULT_DIR = 'bibliography'.freeze

  def details_dir(site)
    site.config.dig('scholar', 'details_dir') || DEFAULT_DIR
  end

  def title_slug(title)
    slug = title.to_s
                .unicode_normalize(:nfkd)
                .encode('ASCII', invalid: :replace, undef: :replace, replace: '')
                .gsub(/[^0-9A-Za-z]+/, '_')
                .gsub(/\A_+|_+\z/, '')
    slug = 'paper' if slug.empty?
    "#{slug}.html"
  end

  def details_path(site, title)
    "/#{details_dir(site)}/#{title_slug(title)}"
  end

  class BibliographyParser
    def initialize(path)
      @source = File.read(path).sub(/\A---\s*\n.*?\n---\s*\n/m, '')
    end

    def entries
      @entries ||= parse_entries
    end

    private

    def parse_entries
      entries = []
      index = 0

      while (at_index = @source.index('@', index))
        index = at_index + 1
        type = read_until(index, '{').strip.downcase
        next unless valid_entry_type?(type)

        block_start = @source.index('{', at_index)
        break unless block_start

        block_end = find_matching_brace(block_start)
        break unless block_end

        raw_entry = @source[at_index..block_end]
        body = @source[(block_start + 1)...block_end]
        parsed = parse_entry_body(type, body, raw_entry)
        entries << parsed if parsed
        index = block_end + 1
      end

      entries
    end

    def valid_entry_type?(type)
      !type.empty? && type != 'string' && type != 'comment' && type != 'preamble'
    end

    def read_until(index, char)
      @source[index...@source.index(char, index)] || ''
    end

    def find_matching_brace(open_index)
      depth = 0
      in_quotes = false
      escape = false

      @source.chars.each_with_index do |char, idx|
        next if idx < open_index

        if in_quotes
          if escape
            escape = false
          elsif char == '\\'
            escape = true
          elsif char == '"'
            in_quotes = false
          end
          next
        end

        case char
        when '"'
          in_quotes = true
        when '{'
          depth += 1
        when '}'
          depth -= 1
          return idx if depth.zero?
        end
      end

      nil
    end

    def parse_entry_body(type, body, raw_entry)
      key, fields_blob = split_key_and_fields(body)
      return if key.to_s.strip.empty?

      fields = parse_fields(fields_blob)
      fields['key'] = key.strip
      fields['type'] = type
      fields['bibtex'] = raw_entry.strip
      fields['author_array'] = parse_authors(fields['author'])
      fields
    end

    def split_key_and_fields(body)
      comma_index = find_top_level_comma(body)
      return [body.strip, ''] unless comma_index

      [body[0...comma_index], body[(comma_index + 1)..]]
    end

    def find_top_level_comma(text)
      depth = 0
      in_quotes = false
      escape = false

      text.chars.each_with_index do |char, idx|
        if in_quotes
          if escape
            escape = false
          elsif char == '\\'
            escape = true
          elsif char == '"'
            in_quotes = false
          end
          next
        end

        case char
        when '"'
          in_quotes = true
        when '{'
          depth += 1
        when '}'
          depth -= 1 if depth.positive?
        when ','
          return idx if depth.zero?
        end
      end

      nil
    end

    def parse_fields(text)
      fields = {}
      index = 0

      while index < text.length
        index += 1 while index < text.length && [',', "\n", "\r", ' ', "\t"].include?(text[index])
        break if index >= text.length

        name_start = index
        index += 1 while index < text.length && text[index] != '='
        break if index >= text.length

        field_name = text[name_start...index].strip.downcase
        index += 1
        index += 1 while index < text.length && text[index] =~ /\s/

        value, index = parse_value(text, index)
        fields[field_name] = clean_value(value)
      end

      fields
    end

    def parse_value(text, index)
      case text[index]
      when '{'
        start = index
        depth = 0
        index.upto(text.length - 1) do |i|
          depth += 1 if text[i] == '{'
          depth -= 1 if text[i] == '}'
          if depth.zero?
            return [text[start..i], i + 1]
          end
        end
      when '"'
        start = index
        escaped = false
        (index + 1).upto(text.length - 1) do |i|
          char = text[i]
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            return [text[start..i], i + 1]
          end
        end
      else
        start = index
        index += 1 while index < text.length && text[index] != ','
        return [text[start...index], index]
      end

      [text[index..], text.length]
    end

    def clean_value(value)
      cleaned = value.to_s.strip
      loop do
        break unless (cleaned.start_with?('{') && cleaned.end_with?('}')) || (cleaned.start_with?('"') && cleaned.end_with?('"'))

        candidate = cleaned[1...-1].strip
        break unless balanced_wrapping?(cleaned)

        cleaned = candidate
      end
      cleaned.gsub(/\s+/, ' ').strip
    end

    def balanced_wrapping?(value)
      return true if value.start_with?('"') && value.end_with?('"')
      return false unless value.start_with?('{') && value.end_with?('}')

      depth = 0
      value.chars.each_with_index do |char, idx|
        depth += 1 if char == '{'
        depth -= 1 if char == '}'
        return false if depth.zero? && idx < value.length - 1
      end

      depth.zero?
    end

    def parse_authors(author_field)
      author_field.to_s.split(/\s+and\s+/).filter_map do |author|
        name = author.strip
        next if name.empty?

        if name.include?(',')
          last, first = name.split(',', 2).map(&:strip)
        else
          parts = name.split
          first = parts[0...-1].join(' ')
          last = parts[-1]
        end

        { 'first' => first.to_s, 'last' => last.to_s }
      end
    end
  end
end

module Jekyll
  class PublicationDetailsPage < Page
    def initialize(site, entry)
      @site = site
      @base = site.source
      @dir = PublicationDetails.details_dir(site)
      @name = PublicationDetails.title_slug(entry['title'])

      process(@name)
      read_yaml(File.join(@base, '_layouts'), 'bibtex.html')

      data['layout'] = 'bibtex'
      data['title'] = entry['title']
      data['reference'] = entry
      data['permalink'] = PublicationDetails.details_path(site, entry['title'])
      data['wiki_key'] = File.basename(@name, '.html')
    end
  end

  class PublicationDetailsPageGenerator < Generator
    safe true
    priority :low

    def generate(site)
      bibliography = File.join(site.source, '_bibliography', site.config.dig('scholar', 'bibliography') || 'papers.bib')
      return unless File.exist?(bibliography)

      PublicationDetails::BibliographyParser.new(bibliography).entries.each do |entry|
        site.pages << PublicationDetailsPage.new(site, entry)
      end
    end
  end
end

module Jekyll
  module PublicationDetailsFilters
    def publication_details_path(title)
      site = @context.registers[:site]
      PublicationDetails.details_path(site, title)
    end
  end
end

Liquid::Template.register_filter(Jekyll::PublicationDetailsFilters)
