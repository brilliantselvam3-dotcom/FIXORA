# frozen_string_literal: true

require 'securerandom'
require 'time'
require_relative 'auth'
require_relative 'uploads'

class AppError < StandardError
  attr_reader :status

  def initialize(message, status = 400)
    super(message)
    @status = status
  end
end

module Tickets
  CATEGORIES = %w[Hardware Software Network Facility].freeze
  PRIORITIES = %w[Low Medium High Critical].freeze
  STATUSES = ['Open', 'Assigned', 'In Progress', 'Resolved'].freeze
  SLA_HOURS = {
    'Critical' => 2,
    'High' => 8,
    'Medium' => 24,
    'Low' => 72
  }.freeze

  STOPWORDS = %w[the and for with not from that this into near are was is in on at to of a an].freeze

  module_function

  def normalize_enum(value, allowed)
    v = value.to_s.strip.downcase
    return nil if v.empty?

    allowed.find { |item| item.downcase == v }
  end

  def normalize_location(loc)
    loc.to_s.downcase.gsub(/[^a-z0-9\s]/, ' ').gsub(/\s+/, ' ').strip
  end

  def keywords(text)
    text.to_s.downcase.gsub(/[^a-z0-9\s]/, ' ').split.reject { |w| w.length < 3 || STOPWORDS.include?(w) }.uniq
  end

  def find_similar_open_tickets(db, location:, category: nil, title: nil)
    norm_target = normalize_location(location)
    return [] if norm_target.empty?

    open_tickets = db.query(
      <<~SQL
        SELECT t.ticket_id, t.title, t.category, t.priority, t.location, t.department, t.status, t.created_at,
               u.name AS reporter_name
        FROM tickets t
        JOIN users u ON u.user_id = t.reporter_id
        WHERE t.status = 'Open'
        ORDER BY t.created_at DESC
      SQL
    )

    norm_cat = normalize_enum(category, CATEGORIES) if category
    target_kw = keywords(title)

    open_tickets.select do |t|
      norm_existing = normalize_location(t['location'])
      next false if norm_existing.empty?

      if norm_existing == norm_target
        true
      elsif norm_existing.length >= 4 && norm_target.length >= 4 &&
            (norm_existing.include?(norm_target) || norm_target.include?(norm_existing))
        same_cat = norm_cat && t['category'] == norm_cat
        shared_kw = !(target_kw & keywords(t['title'])).empty?
        same_cat || shared_kw
      else
        false
      end
    end
  end

  def duplicate_check(db, location:, category: nil, title: nil)
    loc = location.to_s.strip
    raise AppError.new('Location query parameter is required.', 400) if loc.empty?

    matches = find_similar_open_tickets(db, location: loc, category: category, title: title)
    if matches.empty?
      {
        'duplicate_warning' => false,
        'message' => 'No similar open tickets found at this location.',
        'matches' => [],
        'candidates' => []
      }
    else
      {
        'duplicate_warning' => true,
        'message' => 'A similar open ticket exists at this location.',
        'matches' => matches.map { |m| m['ticket_id'] },
        'candidates' => matches
      }
    end
  end

  def create_ticket(db, user, payload, upload_file: nil, uploads_dir: nil)
    title = payload['title'].to_s.strip
    description = payload['description'].to_s.strip
    raw_category = payload['category'].to_s.strip
    raw_priority = payload['priority'].to_s.strip
    location = payload['location'].to_s.strip
    department = payload['department'].to_s.strip
    department = user['department'] if department.empty?

    missing = []
    missing << 'title' if title.empty?
    missing << 'description' if description.empty?
    missing << 'category' if raw_category.empty?
    missing << 'priority' if raw_priority.empty?
    missing << 'location' if location.empty?
    unless missing.empty?
      raise AppError.new("Missing required fields: #{missing.join(', ')}.", 400)
    end

    category = normalize_enum(raw_category, CATEGORIES)
    unless category
      raise AppError.new("Invalid category '#{raw_category}'. Allowed: #{CATEGORIES.join(', ')}.", 400)
    end

    priority = normalize_enum(raw_priority, PRIORITIES)
    unless priority
      raise AppError.new("Invalid priority '#{raw_priority}'. Allowed: #{PRIORITIES.join(', ')}.", 400)
    end

    saved_attachment = nil
    if upload_file
      saved_attachment = Uploads.validate_and_save(
        uploads_dir: uploads_dir,
        filename: upload_file[:filename],
        content_type: upload_file[:content_type],
        data: upload_file[:data]
      )
    end

    matches = find_similar_open_tickets(db, location: location, category: category, title: title)
    now = Time.now.utc.iso8601
    ticket_id = nil

    begin
      db.synchronize do
        max_row = db.send(:run_sqlite, 'SELECT COALESCE(MAX(seq_num), 100) AS max_seq FROM tickets;', json: true).first
        seq_num = max_row['max_seq'].to_i + 1
        ticket_id = "TKT-#{seq_num}"
        history_id = "HIS-#{SecureRandom.hex(4).upcase}"

        stmts = [
          'PRAGMA foreign_keys = ON;',
          'BEGIN IMMEDIATE;',
          db.bind_params(
            'INSERT INTO tickets (ticket_id, seq_num, title, description, category, priority, location, department, reporter_id, technician_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?);',
            [ticket_id, seq_num, title, description, category, priority, location, department, user['user_id'], 'Open', now, now]
          ),
          db.bind_params(
            'INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) VALUES (?, ?, ?, NULL, ?, ?, ?);',
            [history_id, ticket_id, user['user_id'], 'Open', 'Ticket created by reporter.', now]
          )
        ]

        if saved_attachment
          stmts << db.bind_params(
            'INSERT INTO attachments (attachment_id, ticket_id, file_name, file_type, file_path, file_size, uploaded_by, uploaded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
            [
              saved_attachment['attachment_id'],
              ticket_id,
              saved_attachment['file_name'],
              saved_attachment['file_type'],
              saved_attachment['file_path'],
              saved_attachment['file_size'],
              user['user_id'],
              now
            ]
          )
        end

        stmts << 'COMMIT;'
        db.send(:run_sqlite, stmts.join("\n"), json: false)
      end
    rescue StandardError => e
      if saved_attachment && uploads_dir
        path = File.join(uploads_dir, saved_attachment['file_path'])
        File.delete(path) if File.exist?(path)
      end
      raise e
    end

    ticket = get_ticket(db, user, ticket_id)
    response = {
      'ticket_id' => ticket_id,
      'status' => 'Open',
      'message' => 'Ticket created successfully',
      'duplicate_warning' => !matches.empty?,
      'matches' => matches.map { |m| m['ticket_id'] },
      'ticket' => ticket
    }
    response['duplicate_message'] = 'A similar open ticket exists at this location.' unless matches.empty?
    response
  end

  def list_tickets(db, user, filters = {})
    conditions = []
    params = []

    case user['role']
    when 'reporter'
      conditions << 't.reporter_id = ?'
      params << user['user_id']
    when 'technician'
      conditions << 't.technician_id = ?'
      params << user['user_id']
    when 'admin'
      # Admin sees all tickets
    else
      raise AuthError.new('Unauthorized role.', 403)
    end

    if filters['status'] && !filters['status'].strip.empty?
      st = normalize_enum(filters['status'], STATUSES)
      raise AppError.new("Invalid status filter '#{filters['status']}'.", 400) unless st

      conditions << 't.status = ?'
      params << st
    end

    if filters['priority'] && !filters['priority'].strip.empty?
      pr = normalize_enum(filters['priority'], PRIORITIES)
      raise AppError.new("Invalid priority filter '#{filters['priority']}'.", 400) unless pr

      conditions << 't.priority = ?'
      params << pr
    end

    if filters['category'] && !filters['category'].strip.empty?
      cat = normalize_enum(filters['category'], CATEGORIES)
      raise AppError.new("Invalid category filter '#{filters['category']}'.", 400) unless cat

      conditions << 't.category = ?'
      params << cat
    end

    if filters['department'] && !filters['department'].strip.empty?
      conditions << 'LOWER(t.department) = LOWER(?)'
      params << filters['department'].strip
    end

    if filters['date_from'] && !filters['date_from'].strip.empty?
      conditions << 'substr(t.created_at, 1, 10) >= ?'
      params << filters['date_from'].strip[0, 10]
    end

    if filters['date_to'] && !filters['date_to'].strip.empty?
      conditions << 'substr(t.created_at, 1, 10) <= ?'
      params << filters['date_to'].strip[0, 10]
    end

    if filters['unassigned'].to_s == 'true'
      conditions << 't.technician_id IS NULL'
    end

    if filters['search'] && !filters['search'].strip.empty?
      term = "%#{filters['search'].strip.downcase}%"
      conditions << '(LOWER(t.ticket_id) LIKE ? OR LOWER(t.title) LIKE ? OR LOWER(t.description) LIKE ? OR LOWER(t.location) LIKE ? OR LOWER(t.department) LIKE ?)'
      5.times { params << term }
    end

    where_sql = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"

    sql = <<~SQL
      SELECT
        t.*,
        rep.name AS reporter_name,
        rep.email AS reporter_email,
        tech.name AS technician_name,
        tech.email AS technician_email,
        r.resolution_note,
        r.resolved_at,
        (SELECT COUNT(*) FROM attachments a WHERE a.ticket_id = t.ticket_id) AS attachment_count
      FROM tickets t
      JOIN users rep ON rep.user_id = t.reporter_id
      LEFT JOIN users tech ON tech.user_id = t.technician_id
      LEFT JOIN resolutions r ON r.ticket_id = t.ticket_id
      #{where_sql}
      ORDER BY t.seq_num DESC
    SQL

    rows = db.query(sql, params).map { |row| enrich_ticket(row) }
    if filters['overdue'].to_s == 'true'
      rows = rows.select { |r| r['is_overdue'] }
    end
    rows
  end

  def get_ticket(db, user, ticket_id)
    row = db.query_one(
      <<~SQL,
        SELECT
          t.*,
          rep.name AS reporter_name,
          rep.email AS reporter_email,
          tech.name AS technician_name,
          tech.email AS technician_email,
          r.resolution_id,
          r.resolution_note,
          r.resolved_at
        FROM tickets t
        JOIN users rep ON rep.user_id = t.reporter_id
        LEFT JOIN users tech ON tech.user_id = t.technician_id
        LEFT JOIN resolutions r ON r.ticket_id = t.ticket_id
        WHERE t.ticket_id = ?
      SQL
      [ticket_id]
    )
    raise AppError.new("Ticket '#{ticket_id}' not found.", 404) unless row

    authorize_ticket_view!(user, row)

    history = db.query(
      <<~SQL,
        SELECT h.history_id, h.ticket_id, h.changed_by, h.old_status, h.new_status, h.note, h.changed_at,
               u.name AS changed_by_name, u.role AS changed_by_role
        FROM ticket_history h
        JOIN users u ON u.user_id = h.changed_by
        WHERE h.ticket_id = ?
        ORDER BY h.changed_at ASC, h.rowid ASC
      SQL
      [ticket_id]
    )

    attachments = db.query(
      <<~SQL,
        SELECT attachment_id, ticket_id, file_name, file_type, file_size, uploaded_by, uploaded_at
        FROM attachments
        WHERE ticket_id = ?
        ORDER BY uploaded_at ASC
      SQL
      [ticket_id]
    ).map do |a|
      a.merge('url' => "/attachments/#{a['attachment_id']}")
    end

    resolution = if row['resolution_id']
                   {
                     'resolution_id' => row['resolution_id'],
                     'technician_id' => row['technician_id'],
                     'technician_name' => row['technician_name'],
                     'resolution_note' => row['resolution_note'],
                     'resolved_at' => row['resolved_at']
                   }
                 end

    enrich_ticket(row).merge(
      'history' => history,
      'attachments' => attachments,
      'resolution' => resolution
    )
  end

  def assign_ticket(db, user, ticket_id, payload)
    Auth.require_role!(user, 'admin')

    technician_id = payload['technician_id'].to_s.strip
    raise AppError.new('technician_id is required.', 400) if technician_id.empty?

    tech = db.query_one('SELECT user_id, name, role, department, active FROM users WHERE user_id = ?', [technician_id])
    raise AppError.new("Technician '#{technician_id}' not found.", 400) unless tech
    unless tech['role'] == 'technician'
      raise AppError.new("User '#{tech['name']}' has role '#{tech['role']}', not 'technician'.", 400)
    end
    raise AppError.new("Technician '#{tech['name']}' is inactive.", 400) unless tech['active'].to_i == 1

    reassign = payload['reassign'] == true || payload['reassign'].to_s == 'true'
    reason = payload['reason'].to_s.strip
    note = payload['note'].to_s.strip

    existing = db.query_one('SELECT ticket_id, status, technician_id FROM tickets WHERE ticket_id = ?', [ticket_id])
    raise AppError.new("Ticket '#{ticket_id}' not found.", 404) unless existing

    now = Time.now.utc.iso8601

    if existing['status'] == 'Resolved'
      raise AppError.new('Cannot assign or reassign a Resolved ticket.', 409)
    end

    if reassign && %w[Assigned In\ Progress].include?(existing['status'])
      raise AppError.new('Reassignment reason is required when reassigning an active ticket.', 400) if reason.empty?

      old_status = existing['status']
      his_return_id = "HIS-#{SecureRandom.hex(4).upcase}"
      his_assign_id = "HIS-#{SecureRandom.hex(4).upcase}"
      result = db.atomic_script_with_result([
        [
          "UPDATE tickets SET technician_id = ?, status = 'Assigned', updated_at = ? WHERE ticket_id = ? AND status IN ('Assigned', 'In Progress')",
          technician_id, now, ticket_id
        ],
        [
          "INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) SELECT ?, ?, ?, ?, 'Open', ?, ? WHERE changes() = 1",
          his_return_id, ticket_id, user['user_id'], old_status, "Returned for reassignment: #{reason}", now
        ],
        [
          "INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) SELECT ?, ?, ?, 'Open', 'Assigned', ?, ? WHERE (SELECT status FROM tickets WHERE ticket_id = ?) = 'Assigned' AND (SELECT updated_at FROM tickets WHERE ticket_id = ?) = ?",
          his_assign_id, ticket_id, user['user_id'], "Reassigned to #{tech['name']} (#{tech['department']}).", now, ticket_id, ticket_id, now
        ],
        'SELECT changes() AS changed_rows'
      ])

      changed = result.first ? result.first['changed_rows'].to_i : 0
      raise AppError.new('Ticket state changed concurrently; please refresh and retry.', 409) if changed.zero?

      return get_ticket(db, user, ticket_id)
    end

    # Normal Open -> Assigned atomic transition (race-safe for T14)
    his_id = "HIS-#{SecureRandom.hex(4).upcase}"
    assign_note = note.empty? ? "Assigned to #{tech['name']} (#{tech['department']})." : note

    result = db.atomic_script_with_result([
      [
        "UPDATE tickets SET technician_id = ?, status = 'Assigned', updated_at = ? WHERE ticket_id = ? AND status = 'Open'",
        technician_id, now, ticket_id
      ],
      [
        "INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) SELECT ?, ?, ?, 'Open', 'Assigned', ?, ? WHERE changes() = 1",
        his_id, ticket_id, user['user_id'], assign_note, now
      ],
      'SELECT changes() AS changed_rows'
    ])

    changed = result.first ? result.first['changed_rows'].to_i : 0
    if changed.zero?
      raise AppError.new("Ticket '#{ticket_id}' is not Open (current status: #{existing['status']}) or was assigned concurrently.", 409)
    end

    get_ticket(db, user, ticket_id)
  end

  def update_status(db, user, ticket_id, payload)
    target_raw = payload['status'].to_s.strip
    raise AppError.new('Target status is required.', 400) if target_raw.empty?

    target_status = normalize_enum(target_raw, STATUSES)
    raise AppError.new("Invalid status '#{target_raw}'. Allowed: #{STATUSES.join(', ')}.", 400) unless target_status

    ticket = db.query_one('SELECT * FROM tickets WHERE ticket_id = ?', [ticket_id])
    raise AppError.new("Ticket '#{ticket_id}' not found.", 404) unless ticket

    current_status = ticket['status']
    note = payload['note'].to_s.strip
    reason = payload['reason'].to_s.strip
    resolution_note = (payload['resolution_note'] || payload['note']).to_s.strip
    now = Time.now.utc.iso8601

    if user['role'] == 'reporter'
      raise AuthError.new('Forbidden: Reporters cannot change ticket status.', 403)
    end

    case [current_status, target_status]
    when ['Assigned', 'In Progress']
      unless user['role'] == 'technician' && ticket['technician_id'] == user['user_id']
        raise AuthError.new('Forbidden: Only the assigned technician can start work on this ticket.', 403)
      end

      his_id = "HIS-#{SecureRandom.hex(4).upcase}"
      entry_note = note.empty? ? 'Technician started work on ticket.' : note
      result = db.atomic_script_with_result([
        [
          "UPDATE tickets SET status = 'In Progress', updated_at = ? WHERE ticket_id = ? AND status = 'Assigned' AND technician_id = ?",
          now, ticket_id, user['user_id']
        ],
        [
          "INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) SELECT ?, ?, ?, 'Assigned', 'In Progress', ?, ? WHERE changes() = 1",
          his_id, ticket_id, user['user_id'], entry_note, now
        ],
        'SELECT changes() AS changed_rows'
      ])
      changed = result.first ? result.first['changed_rows'].to_i : 0
      raise AppError.new('Could not transition ticket to In Progress.', 409) if changed.zero?

    when ['In Progress', 'Resolved']
      unless user['role'] == 'technician' && ticket['technician_id'] == user['user_id']
        raise AuthError.new('Forbidden: Only the assigned technician can resolve this ticket.', 403)
      end

      if resolution_note.empty?
        raise AppError.new('Resolution note is required before marking a ticket Resolved.', 400)
      end

      res_id = "RES-#{SecureRandom.hex(4).upcase}"
      his_id = "HIS-#{SecureRandom.hex(4).upcase}"
      result = db.atomic_script_with_result([
        [
          "UPDATE tickets SET status = 'Resolved', updated_at = ? WHERE ticket_id = ? AND status = 'In Progress' AND technician_id = ?",
          now, ticket_id, user['user_id']
        ],
        [
          "INSERT INTO resolutions (resolution_id, ticket_id, technician_id, resolution_note, resolved_at) SELECT ?, ?, ?, ?, ? WHERE changes() = 1",
          res_id, ticket_id, user['user_id'], resolution_note, now
        ],
        [
          "INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) SELECT ?, ?, ?, 'In Progress', 'Resolved', ?, ? WHERE (SELECT status FROM tickets WHERE ticket_id = ?) = 'Resolved' AND (SELECT updated_at FROM tickets WHERE ticket_id = ?) = ?",
          his_id, ticket_id, user['user_id'], resolution_note, now, ticket_id, ticket_id, now
        ],
        'SELECT changes() AS changed_rows'
      ])
      changed = result.first ? result.first['changed_rows'].to_i : 0
      raise AppError.new('Could not resolve ticket; state may have changed concurrently.', 409) if changed.zero?

    when ['Assigned', 'Open'], ['In Progress', 'Open']
      Auth.require_role!(user, 'admin')
      return_reason = reason.empty? ? note : reason
      if return_reason.empty?
        raise AppError.new('A reason is required when returning a ticket to Open.', 400)
      end

      his_id = "HIS-#{SecureRandom.hex(4).upcase}"
      result = db.atomic_script_with_result([
        [
          "UPDATE tickets SET status = 'Open', technician_id = NULL, updated_at = ? WHERE ticket_id = ? AND status = ?",
          now, ticket_id, current_status
        ],
        [
          "INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) SELECT ?, ?, ?, ?, 'Open', ?, ? WHERE changes() = 1",
          his_id, ticket_id, user['user_id'], current_status, "Returned to Open: #{return_reason}", now
        ],
        'SELECT changes() AS changed_rows'
      ])
      changed = result.first ? result.first['changed_rows'].to_i : 0
      raise AppError.new('Could not return ticket to Open.', 409) if changed.zero?

    else
      if user['role'] == 'technician' && ticket['technician_id'] != user['user_id']
        raise AuthError.new('Forbidden: You are not assigned to this ticket.', 403)
      end

      raise AppError.new(
        "Invalid status transition from '#{current_status}' to '#{target_status}'. Allowed pipeline: Open -> Assigned -> In Progress -> Resolved.",
        409
      )
    end

    get_ticket(db, user, ticket_id)
  end

  def add_note(db, user, ticket_id, payload)
    note = payload['note'].to_s.strip
    raise AppError.new('Note text is required.', 400) if note.empty?

    ticket = db.query_one('SELECT * FROM tickets WHERE ticket_id = ?', [ticket_id])
    raise AppError.new("Ticket '#{ticket_id}' not found.", 404) unless ticket

    authorize_ticket_view!(user, ticket)
    if user['role'] == 'technician' && ticket['technician_id'] != user['user_id']
      raise AuthError.new('Forbidden: Only assigned technician can add progress notes.', 403)
    end
    if user['role'] == 'reporter' && ticket['reporter_id'] != user['user_id']
      raise AuthError.new('Forbidden: Cannot comment on another reporter ticket.', 403)
    end

    now = Time.now.utc.iso8601
    his_id = "HIS-#{SecureRandom.hex(4).upcase}"
    prefix = user['role'] == 'reporter' ? 'Reporter comment' : 'Progress note'

    db.transaction_script([
      ['UPDATE tickets SET updated_at = ? WHERE ticket_id = ?', now, ticket_id],
      [
        'INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        his_id, ticket_id, user['user_id'], ticket['status'], ticket['status'], "#{prefix}: #{note}", now
      ]
    ])

    get_ticket(db, user, ticket_id)
  end

  def add_attachment(db, user, ticket_id, upload_file:, uploads_dir:)
    ticket = db.query_one('SELECT * FROM tickets WHERE ticket_id = ?', [ticket_id])
    raise AppError.new("Ticket '#{ticket_id}' not found.", 404) unless ticket

    case user['role']
    when 'admin'
      # allowed
    when 'reporter'
      raise AuthError.new('Forbidden: Cannot upload evidence to another user ticket.', 403) unless ticket['reporter_id'] == user['user_id']
    when 'technician'
      raise AuthError.new('Forbidden: Only assigned technician can upload evidence.', 403) unless ticket['technician_id'] == user['user_id']
    end

    saved = Uploads.validate_and_save(
      uploads_dir: uploads_dir,
      filename: upload_file[:filename],
      content_type: upload_file[:content_type],
      data: upload_file[:data]
    )

    now = Time.now.utc.iso8601
    his_id = "HIS-#{SecureRandom.hex(4).upcase}"

    begin
      db.transaction_script([
        [
          'INSERT INTO attachments (attachment_id, ticket_id, file_name, file_type, file_path, file_size, uploaded_by, uploaded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          saved['attachment_id'], ticket_id, saved['file_name'], saved['file_type'], saved['file_path'], saved['file_size'], user['user_id'], now
        ],
        [
          'INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
          his_id, ticket_id, user['user_id'], ticket['status'], ticket['status'], "Uploaded photo evidence: #{saved['file_name']}", now
        ]
      ])
    rescue StandardError => e
      path = File.join(uploads_dir, saved['file_path'])
      File.delete(path) if File.exist?(path)
      raise e
    end

    saved.merge('ticket_id' => ticket_id, 'uploaded_at' => now, 'url' => "/attachments/#{saved['attachment_id']}")
  end

  def get_attachment(db, user, attachment_id)
    row = db.query_one(
      <<~SQL,
        SELECT a.*, t.reporter_id, t.technician_id
        FROM attachments a
        JOIN tickets t ON t.ticket_id = a.ticket_id
        WHERE a.attachment_id = ?
      SQL
      [attachment_id]
    )
    raise AppError.new("Attachment '#{attachment_id}' not found.", 404) unless row

    authorize_ticket_view!(user, row)
    row
  end

  def dashboard_metrics(db, user)
    Auth.require_role!(user, 'admin')

    counts = db.query_one(
      <<~SQL
        SELECT
          COUNT(*) AS total_count,
          COALESCE(SUM(CASE WHEN status = 'Open' THEN 1 ELSE 0 END), 0) AS open_count,
          COALESCE(SUM(CASE WHEN status = 'Assigned' THEN 1 ELSE 0 END), 0) AS assigned_count,
          COALESCE(SUM(CASE WHEN status = 'In Progress' THEN 1 ELSE 0 END), 0) AS in_progress_count,
          COALESCE(SUM(CASE WHEN status = 'Resolved' THEN 1 ELSE 0 END), 0) AS resolved_count,
          COALESCE(SUM(CASE WHEN status != 'Resolved' THEN 1 ELSE 0 END), 0) AS active_count
        FROM tickets
      SQL
    )

    avg_row = db.query_one(
      <<~SQL
        SELECT
          COUNT(*) AS resolved_sample_count,
          AVG((julianday(r.resolved_at) - julianday(t.created_at)) * 1440.0) AS avg_minutes
        FROM tickets t
        JOIN resolutions r ON r.ticket_id = t.ticket_id
        WHERE t.status = 'Resolved'
      SQL
    )

    sample_count = avg_row ? avg_row['resolved_sample_count'].to_i : 0
    avg_minutes = sample_count.positive? && avg_row['avg_minutes'] ? avg_row['avg_minutes'].to_f.round(2) : 0.0
    avg_hours = (avg_minutes / 60.0).round(2)

    by_category = db.query('SELECT category AS label, COUNT(*) AS count FROM tickets GROUP BY category ORDER BY count DESC')
    by_department = db.query('SELECT department AS label, COUNT(*) AS count FROM tickets GROUP BY department ORDER BY count DESC')
    by_priority = db.query('SELECT priority AS label, COUNT(*) AS count FROM tickets GROUP BY priority ORDER BY count DESC')
    by_status = db.query('SELECT status AS label, COUNT(*) AS count FROM tickets GROUP BY status')

    tech_workload = db.query(
      <<~SQL
        SELECT
          u.user_id, u.name, u.department,
          COALESCE(SUM(CASE WHEN t.status = 'Assigned' THEN 1 ELSE 0 END), 0) AS assigned_count,
          COALESCE(SUM(CASE WHEN t.status = 'In Progress' THEN 1 ELSE 0 END), 0) AS in_progress_count,
          COALESCE(SUM(CASE WHEN t.status = 'Resolved' THEN 1 ELSE 0 END), 0) AS resolved_count
        FROM users u
        LEFT JOIN tickets t ON t.technician_id = u.user_id
        WHERE u.role = 'technician' AND u.active = 1
        GROUP BY u.user_id
        ORDER BY u.name
      SQL
    )

    active_tickets = db.query("SELECT ticket_id, priority, status, created_at FROM tickets WHERE status != 'Resolved'")
    overdue_ids = []
    now = Time.now.utc
    active_tickets.each do |t|
      sla_hrs = SLA_HOURS[t['priority']] || 24
      deadline = Time.parse(t['created_at']) + (sla_hrs * 3600)
      overdue_ids << t['ticket_id'] if now > deadline
    end

    {
      'total_count' => counts['total_count'].to_i,
      'open_count' => counts['open_count'].to_i,
      'assigned_count' => counts['assigned_count'].to_i,
      'in_progress_count' => counts['in_progress_count'].to_i,
      'resolved_count' => counts['resolved_count'].to_i,
      'active_count' => counts['active_count'].to_i,
      'overdue_count' => overdue_ids.length,
      'overdue_ticket_ids' => overdue_ids,
      'resolved_sample_count' => sample_count,
      'average_resolution_time_minutes' => avg_minutes,
      'average_resolution_time_hours' => avg_hours,
      'average_resolution_time_display' => format_duration(avg_minutes, sample_count),
      'by_category' => by_category,
      'by_department' => by_department,
      'by_priority' => by_priority,
      'by_status' => by_status,
      'technician_workload' => tech_workload
    }
  end

  def authorize_ticket_view!(user, ticket)
    case user['role']
    when 'admin'
      true
    when 'reporter'
      unless ticket['reporter_id'] == user['user_id']
        raise AuthError.new('Forbidden: Reporters can only access their own tickets.', 403)
      end
    when 'technician'
      unless ticket['technician_id'] == user['user_id']
        raise AuthError.new('Forbidden: Technicians can only access tickets assigned to them.', 403)
      end
    else
      raise AuthError.new('Forbidden.', 403)
    end
  end

  def enrich_ticket(row)
    created = Time.parse(row['created_at'])
    sla_hours = SLA_HOURS[row['priority']] || 24
    deadline = created + (sla_hours * 3600)
    now = Time.now.utc

    if row['status'] == 'Resolved' && row['resolved_at']
      resolved = Time.parse(row['resolved_at'])
      res_mins = ((resolved - created) / 60.0).round(2)
      is_overdue = resolved > deadline
      remaining_mins = 0
    else
      res_mins = nil
      is_overdue = now > deadline
      remaining_mins = ((deadline - now) / 60.0).round(0).to_i
    end

    row.merge(
      'sla_hours' => sla_hours,
      'sla_deadline' => deadline.utc.iso8601,
      'is_overdue' => is_overdue,
      'sla_remaining_minutes' => remaining_mins,
      'resolution_duration_minutes' => res_mins
    )
  end

  def format_duration(minutes, sample_count)
    return 'N/A (0 resolved)' if sample_count.zero?
    return "#{minutes.round(1)} min" if minutes < 60

    hrs = (minutes / 60).floor
    rem = (minutes % 60).round(0)
    "#{hrs}h #{rem}m"
  end
end
