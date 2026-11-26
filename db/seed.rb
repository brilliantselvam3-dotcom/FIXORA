# frozen_string_literal: true

require 'time'
require_relative '../lib/auth'

module Seed
  module_function

  def run(db)
    existing = db.query_one('SELECT COUNT(*) AS cnt FROM users')
    return if existing && existing['cnt'].to_i > 0

    now = Time.now.utc
    t_minus = ->(mins) { (now - (mins * 60)).utc.iso8601 }

    users = [
      ['USR-REP-01', 'Ananya Sharma', 'ananya@campus.edu', 'reporter123', 'reporter', 'CSE (AI&ML)'],
      ['USR-REP-02', 'Rohan Nair', 'rohan@campus.edu', 'reporter123', 'reporter', 'ECE'],
      ['USR-TECH-01', 'Karthik Raj', 'karthik@campus.edu', 'tech123', 'technician', 'IT Infrastructure'],
      ['USR-TECH-02', 'Meera Menon', 'meera@campus.edu', 'tech123', 'technician', 'Lab Operations'],
      ['USR-ADM-01', 'Dr. Priya Kumar', 'admin@campus.edu', 'admin123', 'admin', 'Campus Operations'],
      ['USR-ADM-02', 'Vikram Rao', 'admin2@campus.edu', 'admin123', 'admin', 'IT Operations']
    ]

    stmts = []
    users.each do |uid, name, email, pwd, role, dept|
      hash = Auth.hash_password(pwd)
      stmts << [
        'INSERT INTO users (user_id, name, email, password_hash, role, department, active, created_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?)',
        uid, name, email, hash, role, dept, t_minus.call(600)
      ]
    end

    tickets = [
      {
        ticket_id: 'TKT-101', seq_num: 101,
        title: 'Lab PC not starting',
        description: 'Workstation does not power on; PSU LED blinks amber.',
        category: 'Hardware', priority: 'High',
        location: 'CSE AI Lab - PC-12', department: 'CSE (AI&ML)',
        reporter_id: 'USR-REP-01', technician_id: nil, status: 'Open',
        created_at: t_minus.call(45), updated_at: t_minus.call(45)
      },
      {
        ticket_id: 'TKT-102', seq_num: 102,
        title: 'MATLAB license server timeout',
        description: 'Workstations in row 2 show license checkout error -15 on launch.',
        category: 'Software', priority: 'Medium',
        location: 'ECE CAD Lab - WS-04', department: 'ECE',
        reporter_id: 'USR-REP-02', technician_id: 'USR-TECH-01', status: 'Assigned',
        created_at: t_minus.call(180), updated_at: t_minus.call(160)
      },
      {
        ticket_id: 'TKT-103', seq_num: 103,
        title: 'Projector HDMI port damaged',
        description: 'Podium HDMI cable does not lock and flickers during lectures.',
        category: 'Facility', priority: 'High',
        location: 'Seminar Hall B - Podium', department: 'CSE (AI&ML)',
        reporter_id: 'USR-REP-01', technician_id: 'USR-TECH-02', status: 'In Progress',
        created_at: t_minus.call(300), updated_at: t_minus.call(210)
      },
      {
        ticket_id: 'TKT-104', seq_num: 104,
        title: 'Wi-Fi access point offline',
        description: 'No 5GHz SSID broadcast in North Wing reading bay.',
        category: 'Network', priority: 'Critical',
        location: 'Central Library - Floor 2', department: 'IT Infrastructure',
        reporter_id: 'USR-REP-02', technician_id: 'USR-TECH-01', status: 'Resolved',
        created_at: t_minus.call(420), updated_at: t_minus.call(330)
      },
      {
        ticket_id: 'TKT-105', seq_num: 105,
        title: 'AC unit leaking near server rack',
        description: 'Condensation dripping from split AC unit above rack B2.',
        category: 'Facility', priority: 'Critical',
        location: 'Data Center - Block A', department: 'IT Infrastructure',
        reporter_id: 'USR-REP-01', technician_id: 'USR-TECH-02', status: 'Resolved',
        created_at: t_minus.call(540), updated_at: t_minus.call(390)
      }
    ]

    tickets.each do |t|
      stmts << [
        'INSERT INTO tickets (ticket_id, seq_num, title, description, category, priority, location, department, reporter_id, technician_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        t[:ticket_id], t[:seq_num], t[:title], t[:description], t[:category], t[:priority],
        t[:location], t[:department], t[:reporter_id], t[:technician_id], t[:status],
        t[:created_at], t[:updated_at]
      ]
    end

    histories = [
      ['HIS-1001', 'TKT-101', 'USR-REP-01', nil, 'Open', 'Ticket created by reporter.', t_minus.call(45)],

      ['HIS-1002', 'TKT-102', 'USR-REP-02', nil, 'Open', 'Ticket created by reporter.', t_minus.call(180)],
      ['HIS-1003', 'TKT-102', 'USR-ADM-01', 'Open', 'Assigned', 'Assigned to Karthik Raj (IT Infrastructure).', t_minus.call(160)],

      ['HIS-1004', 'TKT-103', 'USR-REP-01', nil, 'Open', 'Ticket created by reporter.', t_minus.call(300)],
      ['HIS-1005', 'TKT-103', 'USR-ADM-01', 'Open', 'Assigned', 'Assigned to Meera Menon (Lab Operations).', t_minus.call(260)],
      ['HIS-1006', 'TKT-103', 'USR-TECH-02', 'Assigned', 'In Progress', 'Inspecting podium HDMI coupler and wall plate.', t_minus.call(210)],

      ['HIS-1007', 'TKT-104', 'USR-REP-02', nil, 'Open', 'Ticket created by reporter.', t_minus.call(420)],
      ['HIS-1008', 'TKT-104', 'USR-ADM-01', 'Open', 'Assigned', 'Assigned to Karthik Raj (IT Infrastructure).', t_minus.call(405)],
      ['HIS-1009', 'TKT-104', 'USR-TECH-01', 'Assigned', 'In Progress', 'Checking PoE switch port and AP uptime.', t_minus.call(380)],
      ['HIS-1010', 'TKT-104', 'USR-TECH-01', 'In Progress', 'Resolved', 'Replaced faulty PoE injector and verified 5GHz signal coverage.', t_minus.call(330)],

      ['HIS-1011', 'TKT-105', 'USR-REP-01', nil, 'Open', 'Ticket created by reporter.', t_minus.call(540)],
      ['HIS-1012', 'TKT-105', 'USR-ADM-02', 'Open', 'Assigned', 'Assigned to Meera Menon (Lab Operations).', t_minus.call(520)],
      ['HIS-1013', 'TKT-105', 'USR-TECH-02', 'Assigned', 'In Progress', 'Placed drip tray and cleared blocked drain line.', t_minus.call(470)],
      ['HIS-1014', 'TKT-105', 'USR-TECH-02', 'In Progress', 'Resolved', 'Flushed condensate drain line and sealed elbow joint; zero leakage.', t_minus.call(390)]
    ]

    histories.each do |hid, tid, by, old_s, new_s, note, at|
      stmts << [
        'INSERT INTO ticket_history (history_id, ticket_id, changed_by, old_status, new_status, note, changed_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        hid, tid, by, old_s, new_s, note, at
      ]
    end

    stmts << [
      'INSERT INTO resolutions (resolution_id, ticket_id, technician_id, resolution_note, resolved_at) VALUES (?, ?, ?, ?, ?)',
      'RES-104', 'TKT-104', 'USR-TECH-01',
      'Replaced faulty PoE injector and verified 5GHz signal coverage.', t_minus.call(330)
    ]
    stmts << [
      'INSERT INTO resolutions (resolution_id, ticket_id, technician_id, resolution_note, resolved_at) VALUES (?, ?, ?, ?, ?)',
      'RES-105', 'TKT-105', 'USR-TECH-02',
      'Flushed condensate drain line and sealed elbow joint; zero leakage.', t_minus.call(390)
    ]

    db.transaction_script(stmts, return_json: false)
  end
end
