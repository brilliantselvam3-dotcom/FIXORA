# frozen_string_literal: true

require 'json'
require 'webrick'
require 'fileutils'
require_relative 'lib/database'
require_relative 'lib/auth'
require_relative 'lib/tickets'
require_relative 'lib/uploads'
require_relative 'db/seed'

class IssueTrackerServer
  def initialize(port: 4567, db_path: nil, uploads_dir: nil, seed: true)
    @root = File.expand_path(__dir__)
    @port = port
    @db_path = db_path || File.join(@root, 'data', 'tracker.db')
    @uploads_dir = uploads_dir || File.join(@root, 'uploads')
    @public_dir = File.join(@root, 'public')
    @schema_path = File.join(@root, 'db', 'schema.sql')

    FileUtils.mkdir_p(File.dirname(@db_path))
    FileUtils.mkdir_p(@uploads_dir)

    @db = Database.new(@db_path, @schema_path)
    Seed.run(@db) if seed
  end

  def build_webrick_server(bind_address: '127.0.0.1', quiet: false)
    logger = quiet ? WEBrick::Log.new('/dev/null') : WEBrick::Log.new($stderr, WEBrick::Log::INFO)
    access_log = quiet ? [] : [[$stderr, WEBrick::AccessLog::COMMON_LOG_FORMAT]]

    server = WEBrick::HTTPServer.new(
      Port: @port,
      BindAddress: bind_address,
      Logger: logger,
      AccessLog: access_log
    )

    db = @db
    uploads_dir = @uploads_dir
    public_dir = @public_dir
    handler = method(:handle_request)

    servlet_class = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
      define_method(:initialize) do |srv, *|
        super(srv)
      end

      %w[GET POST PATCH PUT DELETE OPTIONS].each do |http_method|
        define_method("do_#{http_method}") do |req, res|
          handler.call(req, res, db, uploads_dir, public_dir)
        end
      end
    end

    server.mount('/', servlet_class)

    server
  end

  private

  def handle_request(req, res, db, uploads_dir, public_dir)
    add_cors_headers(res)
    if req.request_method == 'OPTIONS'
      res.status = 204
      return
    end

    path = req.path
    method = req.request_method

    case [method, path]
    when ['GET', '/health']
      json_response(res, 200, { status: 'ok', service: 'fixora', time: Time.now.utc.iso8601 })

    when ['POST', '/auth/login']
      payload = parse_json_body(req)
      result = Auth.login(db, payload['email'], payload['password'])
      json_response(res, 200, result)

    when ['POST', '/auth/logout']
      user = Auth.authenticate!(db, req)
      Auth.logout(db, user['token'])
      json_response(res, 200, { message: 'Signed out successfully.' })

    when ['GET', '/auth/me']
      user = Auth.authenticate!(db, req)
      user_clean = user.reject { |k, _| k == 'token' }
      json_response(res, 200, { user: user_clean })

    when ['GET', '/users']
      user = Auth.authenticate!(db, req)
      users = Auth.list_users(db, user, role_filter: req.query['role'])
      json_response(res, 200, { users: users })

    when ['POST', '/users']
      user = Auth.authenticate!(db, req)
      payload = parse_json_body(req)
      created = Auth.create_user(db, user, payload)
      json_response(res, 201, { user: created, message: 'User created successfully.' })

    when ['GET', '/tickets/duplicate-check']
      Auth.authenticate!(db, req)
      result = Tickets.duplicate_check(
        db,
        location: req.query['location'],
        category: req.query['category'],
        title: req.query['title']
      )
      json_response(res, 200, result)

    when ['GET', '/tickets']
      user = Auth.authenticate!(db, req)
      tickets = Tickets.list_tickets(db, user, req.query || {})
      json_response(res, 200, { tickets: tickets, count: tickets.length })

    when ['POST', '/tickets']
      user = Auth.authenticate!(db, req)
      payload, upload_file = parse_ticket_create_request(req)
      result = Tickets.create_ticket(db, user, payload, upload_file: upload_file, uploads_dir: uploads_dir)
      json_response(res, 201, result)

    when ['GET', '/dashboard/metrics']
      user = Auth.authenticate!(db, req)
      metrics = Tickets.dashboard_metrics(db, user)
      json_response(res, 200, metrics)

    else
      if path =~ %r{\A/tickets/([^/]+)/assign\z} && method == 'PATCH'
        ticket_id = Regexp.last_match(1)
        user = Auth.authenticate!(db, req)
        payload = parse_json_body(req)
        ticket = Tickets.assign_ticket(db, user, ticket_id, payload)
        json_response(res, 200, { ticket: ticket, message: 'Ticket assigned successfully.' })

      elsif path =~ %r{\A/tickets/([^/]+)/status\z} && method == 'PATCH'
        ticket_id = Regexp.last_match(1)
        user = Auth.authenticate!(db, req)
        payload = parse_json_body(req)
        ticket = Tickets.update_status(db, user, ticket_id, payload)
        json_response(res, 200, { ticket: ticket, message: "Ticket status updated to #{ticket['status']}." })

      elsif path =~ %r{\A/tickets/([^/]+)/notes\z} && method == 'POST'
        ticket_id = Regexp.last_match(1)
        user = Auth.authenticate!(db, req)
        payload = parse_json_body(req)
        ticket = Tickets.add_note(db, user, ticket_id, payload)
        json_response(res, 201, { ticket: ticket, message: 'Note recorded.' })

      elsif path =~ %r{\A/tickets/([^/]+)/attachments\z} && method == 'POST'
        ticket_id = Regexp.last_match(1)
        user = Auth.authenticate!(db, req)
        upload_file = parse_attachment_upload(req)
        att = Tickets.add_attachment(db, user, ticket_id, upload_file: upload_file, uploads_dir: uploads_dir)
        json_response(res, 201, { attachment: att, message: 'Attachment uploaded successfully.' })

      elsif path =~ %r{\A/tickets/([^/]+)\z} && method == 'GET'
        ticket_id = Regexp.last_match(1)
        user = Auth.authenticate!(db, req)
        ticket = Tickets.get_ticket(db, user, ticket_id)
        json_response(res, 200, { ticket: ticket })

      elsif path =~ %r{\A/attachments/([^/]+)\z} && method == 'GET'
        attachment_id = Regexp.last_match(1)
        user = Auth.authenticate!(db, req)
        att = Tickets.get_attachment(db, user, attachment_id)
        full_path = File.join(uploads_dir, File.basename(att['file_path']))
        raise AppError.new('Attachment file missing on disk.', 404) unless File.exist?(full_path)

        res.status = 200
        res['Content-Type'] = att['file_type']
        res['X-Content-Type-Options'] = 'nosniff'
        res['Content-Disposition'] = "inline; filename=\"#{att['file_name'].gsub('"', '')}\""
        res.body = File.binread(full_path)

      elsif method == 'GET'
        serve_static(public_dir, path, res)
      else
        json_response(res, 404, { error: "Route not found: #{method} #{path}" })
      end
    end
  rescue AuthError => e
    json_response(res, e.status, { error: e.message })
  rescue UploadError => e
    json_response(res, e.status, { error: e.message })
  rescue AppError => e
    json_response(res, e.status, { error: e.message })
  rescue JSON::ParserError
    json_response(res, 400, { error: 'Invalid JSON request body.' })
  rescue StandardError => e
    warn "[ERROR] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    json_response(res, 500, { error: 'Internal server error.' })
  end

  def parse_json_body(req)
    raw = req.body.to_s
    return {} if raw.strip.empty?

    parsed = JSON.parse(raw)
    raise AppError.new('Request body must be a JSON object.', 400) unless parsed.is_a?(Hash)

    parsed
  end

  def parse_ticket_create_request(req)
    ct = req['Content-Type'].to_s
    if ct.downcase.include?('multipart/form-data')
      parsed = Uploads.parse_multipart(ct, req.body)
      upload_file = parsed[:files]['photo'] || parsed[:files]['attachment'] || parsed[:files]['file']
      [parsed[:fields], upload_file]
    else
      payload = parse_json_body(req)
      upload_file = nil
      if payload['attachment'].is_a?(Hash)
        upload_file = Uploads.decode_base64_attachment(payload['attachment'])
      end
      [payload, upload_file]
    end
  end

  def parse_attachment_upload(req)
    ct = req['Content-Type'].to_s
    if ct.downcase.include?('multipart/form-data')
      parsed = Uploads.parse_multipart(ct, req.body)
      file = parsed[:files]['photo'] || parsed[:files]['attachment'] || parsed[:files]['file'] || parsed[:files].values.first
      raise UploadError, 'No photo file provided in multipart upload.' unless file

      file
    else
      payload = parse_json_body(req)
      Uploads.decode_base64_attachment(payload)
    end
  end

  def serve_static(public_dir, path, res)
    clean_rel = path == '/' ? 'index.html' : path.sub(%r{\A/+}, '')
    return json_response(res, 404, { error: 'Not found.' }) if clean_rel.include?('..')

    file_path = File.join(public_dir, clean_rel)
    unless File.file?(file_path)
      # SPA fallback only for non-API paths without file extensions
      file_path = File.join(public_dir, 'index.html')
    end

    return json_response(res, 404, { error: 'Not found.' }) unless File.file?(file_path)

    ext = File.extname(file_path).downcase
    mime = case ext
           when '.html' then 'text/html; charset=utf-8'
           when '.css' then 'text/css; charset=utf-8'
           when '.js' then 'application/javascript; charset=utf-8'
           when '.svg' then 'image/svg+xml'
           when '.png' then 'image/png'
           when '.json' then 'application/json'
           else 'application/octet-stream'
           end

    res.status = 200
    res['Content-Type'] = mime
    res['Cache-Control'] = 'no-store'
    res.body = File.binread(file_path)
  end

  def json_response(res, status, data)
    res.status = status
    res['Content-Type'] = 'application/json; charset=utf-8'
    res['Cache-Control'] = 'no-store'
    res.body = JSON.generate(data)
  end

  def add_cors_headers(res)
    res['Access-Control-Allow-Origin'] = '*'
    res['Access-Control-Allow-Methods'] = 'GET, POST, PATCH, DELETE, OPTIONS'
    res['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
  end
end

if $PROGRAM_NAME == __FILE__
  port = (ENV['PORT'] || 4567).to_i
  host = ENV['HOST'] || '127.0.0.1'
  app = IssueTrackerServer.new(port: port)
  server = app.build_webrick_server(bind_address: host)

  trap('INT') { server.shutdown }
  trap('TERM') { server.shutdown }

  puts "FIXORA listening on http://#{host}:#{port}"
  server.start
end
