# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'securerandom'

class UploadError < StandardError
  attr_reader :status

  def initialize(message, status = 400)
    super(message)
    @status = status
  end
end

module Uploads
  MAX_FILE_SIZE = 5 * 1024 * 1024 # 5 MB
  ALLOWED_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp].freeze
  ALLOWED_MIME_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp].freeze

  module_function

  # Parses multipart/form-data cleanly preserving binary payloads.
  # Returns { fields: { key => value }, files: { key => { filename:, content_type:, data: } } }
  def parse_multipart(content_type, raw_body)
    raise UploadError, 'Empty multipart request body.' if raw_body.nil? || raw_body.empty?

    match = content_type.to_s.match(/boundary=(?:"([^"]+)"|([^;\s]+))/i)
    raise UploadError, 'Missing multipart boundary.' unless match

    boundary = match[1] || match[2]
    delimiter = "--#{boundary}".b
    body = raw_body.b

    parts = body.split(delimiter)
    fields = {}
    files = {}

    parts.each do |part|
      next if part.empty? || part == "--\r\n".b || part == "--".b

      part = part.sub(/\A\r\n/, '')
      part = part.sub(/\r\n--\z/, '')
      part = part.sub(/\r\n\z/, '')
      next if part.empty? || part == '--'.b

      header_end = part.index("\r\n\r\n".b)
      next unless header_end

      raw_headers = part[0...header_end].force_encoding('UTF-8')
      payload = part[(header_end + 4)..-1] || ''.b

      disposition = nil
      part_content_type = nil
      raw_headers.split("\r\n").each do |line|
        if line =~ /\AContent-Disposition:\s*(.+)\z/i
          disposition = Regexp.last_match(1)
        elsif line =~ /\AContent-Type:\s*(.+)\z/i
          part_content_type = Regexp.last_match(1).strip
        end
      end
      next unless disposition

      name_match = disposition.match(/\bname="([^"]+)"/)
      next unless name_match

      field_name = name_match[1]
      filename_match = disposition.match(/\bfilename="([^"]*)"/)

      if filename_match && !filename_match[1].empty?
        files[field_name] = {
          filename: File.basename(filename_match[1]),
          content_type: part_content_type || 'application/octet-stream',
          data: payload
        }
      elsif !filename_match
        fields[field_name] = payload.force_encoding('UTF-8')
      end
    end

    { fields: fields, files: files }
  end

  def validate_and_save(uploads_dir:, filename:, content_type:, data:)
    clean_name = File.basename(filename.to_s.strip)
    raise UploadError, 'Attachment filename is required.' if clean_name.empty?

    ext = File.extname(clean_name).downcase
    unless ALLOWED_EXTENSIONS.include?(ext)
      raise UploadError, "Unsupported file extension '#{ext}'. Allowed: #{ALLOWED_EXTENSIONS.join(', ')}."
    end

    mime = content_type.to_s.split(';').first.to_s.strip.downcase
    unless ALLOWED_MIME_TYPES.include?(mime)
      raise UploadError, "Unsupported file MIME type '#{mime}'. Allowed: PNG, JPEG, GIF, WEBP."
    end

    bytes = data.to_s.b
    if bytes.bytesize.zero?
      raise UploadError, 'Uploaded photo file is empty.'
    end
    if bytes.bytesize > MAX_FILE_SIZE
      raise UploadError, "File size (#{(bytes.bytesize / 1024.0 / 1024.0).round(2)} MB) exceeds the 5 MB limit."
    end

    detected = detect_image_format(bytes)
    unless detected
      raise UploadError, 'File contents do not match a valid image signature (PNG, JPEG, GIF, or WEBP).'
    end

    expected_family = ext == '.jpg' ? :jpeg : ext.delete('.').to_sym
    unless detected == expected_family
      raise UploadError, "File signature (#{detected}) does not match extension (#{ext})."
    end

    FileUtils.mkdir_p(uploads_dir)
    attachment_id = "ATT-#{SecureRandom.hex(4).upcase}"
    stored_name = "#{attachment_id}#{ext}"
    full_path = File.join(uploads_dir, stored_name)
    File.binwrite(full_path, bytes)

    canonical_mime = detected == :jpeg ? 'image/jpeg' : "image/#{detected}"

    {
      'attachment_id' => attachment_id,
      'file_name' => clean_name,
      'file_type' => canonical_mime,
      'file_path' => stored_name,
      'file_size' => bytes.bytesize
    }
  end

  def decode_base64_attachment(payload)
    filename = payload['file_name'] || payload['filename']
    mime = payload['file_type'] || payload['content_type']
    raw_b64 = payload['content_base64'].to_s

    if raw_b64.start_with?('data:')
      header, encoded = raw_b64.split(',', 2)
      if header && header =~ /\Adata:([^;]+);base64\z/i
        mime ||= Regexp.last_match(1)
      end
      raw_b64 = encoded.to_s
    end

    raise UploadError, 'Missing base64 file content.' if raw_b64.strip.empty?

    begin
      decoded = Base64.strict_decode64(raw_b64.gsub(/\s+/, ''))
    rescue ArgumentError
      raise UploadError, 'Invalid base64 image payload.'
    end

    {
      filename: filename,
      content_type: mime || 'application/octet-stream',
      data: decoded
    }
  end

  def detect_image_format(bytes)
    return :png if bytes.bytesize >= 8 && bytes[0, 8] == "\x89PNG\r\n\x1a\n".b
    return :jpeg if bytes.bytesize >= 3 && bytes[0, 3] == "\xFF\xD8\xFF".b
    return :gif if bytes.bytesize >= 6 && (bytes[0, 6] == 'GIF87a'.b || bytes[0, 6] == 'GIF89a'.b)
    return :webp if bytes.bytesize >= 12 && bytes[0, 4] == 'RIFF'.b && bytes[8, 4] == 'WEBP'.b

    nil
  end
end
