# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'securerandom'
require_relative '../server'

ROOT = File.expand_path('..', __dir__)
TEST_TMP = File.join(__dir__, 'tmp_run')
TEST_DB = File.join(TEST_TMP, 'test_tracker.db')
TEST_UPLOADS = File.join(TEST_TMP, 'uploads')
EVIDENCE_PATH = File.join(__dir__, 'test_evidence.json')
TEST_PORT = 4599

FileUtils.rm_rf(TEST_TMP)
FileUtils.mkdir_p(TEST_UPLOADS)

app = IssueTrackerServer.new(port: TEST_PORT, db_path: TEST_DB, uploads_dir: TEST_UPLOADS, seed: true)
server = app.build_webrick_server(bind_address: '127.0.0.1', quiet: true)
server_thread = Thread.new { server.start }

# Wait for /health
20.times do
  begin
    res = Net::HTTP.get_response(URI("http://127.0.0.1:#{TEST_PORT}/health"))
    break if res.code == '200'
  rescue StandardError
    sleep 0.1
  end
end

def http_req(method, path, token: nil, json: nil, headers: {}, body: nil)
  uri = URI("http://127.0.0.1:#{TEST_PORT}#{path}")
  klass = case method.to_s.upcase
          when 'GET' then Net::HTTP::Get
          when 'POST' then Net::HTTP::Post
          when 'PATCH' then Net::HTTP::Patch
          when 'DELETE' then Net::HTTP::Delete
          else raise "Unsupported method #{method}"
          end

  req = klass.new(uri)
  req['Authorization'] = "Bearer #{token}" if token
  headers.each { |k, v| req[k] = v }

  if json
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(json)
  elsif body
    req.body = body
  end

  res = Net::HTTP.start(uri.host, uri.port, read_timeout: 10) { |http| http.request(req) }
  parsed = begin
    JSON.parse(res.body)
  rescue StandardError
    { 'raw' => res.body }
  end
  { status: res.code.to_i, body: parsed }
end

def multipart_req(path, token:, fields: {}, file: nil)
  boundary = "----RubyTestBoundary#{SecureRandom.hex(8)}"
  chunks = []

  fields.each do |k, v|
    chunks << "--#{boundary}\r\n".b
    chunks << "Content-Disposition: form-data; name=\"#{k}\"\r\n\r\n".b
    chunks << "#{v}\r\n".b
  end

  if file
    chunks << "--#{boundary}\r\n".b
    chunks << "Content-Disposition: form-data; name=\"#{file[:field] || 'photo'}\"; filename=\"#{file[:filename]}\"\r\n".b
    chunks << "Content-Type: #{file[:content_type]}\r\n\r\n".b
    chunks << file[:data].b
    chunks << "\r\n".b
  end

  chunks << "--#{boundary}--\r\n".b
  http_req(
    'POST',
    path,
    token: token,
    headers: { 'Content-Type' => "multipart/form-data; boundary=#{boundary}" },
    body: chunks.join
  )
end

results = []
def record(results, id, name, input, expected, passed, observed)
  results << {
    id: id,
    name: name,
    input: input,
    expected: expected,
    observed: observed,
    status: passed ? 'PASS' : 'FAIL'
  }
  puts format('[%s] %-4s %s -> %s', passed ? 'PASS' : 'FAIL', id, name, observed)
end

begin
  # Sign in demo users
  rep1 = http_req('POST', '/auth/login', json: { email: 'ananya@campus.edu', password: 'reporter123' })[:body]
  rep2 = http_req('POST', '/auth/login', json: { email: 'rohan@campus.edu', password: 'reporter123' })[:body]
  tech1 = http_req('POST', '/auth/login', json: { email: 'karthik@campus.edu', password: 'tech123' })[:body]
  tech2 = http_req('POST', '/auth/login', json: { email: 'meera@campus.edu', password: 'tech123' })[:body]
  adm1 = http_req('POST', '/auth/login', json: { email: 'admin@campus.edu', password: 'admin123' })[:body]
  adm2 = http_req('POST', '/auth/login', json: { email: 'admin2@campus.edu', password: 'admin123' })[:body]

  rep1_tok = rep1['token']
  rep2_tok = rep2['token']
  tech1_tok = tech1['token']
  tech2_tok = tech2['token']
  adm1_tok = adm1['token']
  adm2_tok = adm2['token']

  # Minimal valid 1x1 PNG bytes
  valid_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xDE\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0\x00\x00\x03\x01\x01\x00\x18\xdd\x8d\xb0\x00\x00\x00\x00IEND\xAEB`\x82".b

  # T1 — Valid ticket (with valid PNG photo)
  r1 = multipart_req(
    '/tickets',
    token: rep1_tok,
    fields: {
      'title' => 'GPU workstation fan rattling',
      'description' => 'Loud bearing noise on startup in deep learning rack.',
      'category' => 'Hardware',
      'priority' => 'High',
      'location' => 'CSE AI Lab - PC-19',
      'department' => 'CSE (AI&ML)'
    },
    file: { filename: 'rack_issue.png', content_type: 'image/png', data: valid_png }
  )
  t1_id = r1[:body]['ticket_id']
  t1_pass = r1[:status] == 201 && t1_id =~ /\ATKT-\d+\z/ && r1[:body]['status'] == 'Open' &&
            r1[:body].dig('ticket', 'attachments')&.length == 1
  record(results, 'T1', 'Valid ticket with photo',
         'POST /tickets (Hardware, High, CSE AI Lab - PC-19 + PNG)',
         '201 Created, unique TKT-ID, status=Open, 1 attachment saved',
         t1_pass,
         "HTTP #{r1[:status]}, ticket_id=#{t1_id}, status=#{r1[:body]['status']}, attachments=#{r1[:body].dig('ticket', 'attachments')&.length}")

  # T2 — Missing fields
  r2 = http_req('POST', '/tickets', token: rep1_tok, json: {
    title: '', description: 'Missing title and location', category: 'Hardware', priority: 'Medium', location: ''
  })
  t2_pass = r2[:status] == 400 && r2[:body]['error'].to_s.include?('Missing required fields')
  record(results, 'T2', 'Missing fields',
         'POST /tickets with empty title and location',
         '400 Bad Request with clear validation message',
         t2_pass,
         "HTTP #{r2[:status]}, error=#{r2[:body]['error']}")

  # T3 — Invalid category
  r3 = http_req('POST', '/tickets', token: rep1_tok, json: {
    title: 'Cafeteria coffee machine', description: 'Out of beans', category: 'Catering', priority: 'Low', location: 'Main Canteen'
  })
  t3_pass = r3[:status] == 400 && r3[:body]['error'].to_s.include?('Invalid category')
  record(results, 'T3', 'Invalid category',
         'POST /tickets with category=Catering',
         '400 Bad Request; no ticket created',
         t3_pass,
         "HTTP #{r3[:status]}, error=#{r3[:body]['error']}")

  # T4 — Photo validation (spoofed executable/text as .png + oversized > 5MB)
  r4a = multipart_req(
    '/tickets',
    token: rep1_tok,
    fields: {
      'title' => 'Bad file upload test',
      'description' => 'Trying spoofed png',
      'category' => 'Software',
      'priority' => 'Low',
      'location' => 'Lab 2'
    },
    file: { filename: 'fake.png', content_type: 'image/png', data: 'NOT_A_REAL_PNG_FILE' }
  )
  r4b = multipart_req(
    "/tickets/#{t1_id}/attachments",
    token: rep1_tok,
    file: { filename: 'huge.png', content_type: 'image/png', data: valid_png + ("\x00".b * (5 * 1024 * 1024)) }
  )
  t4_pass = r4a[:status] == 400 && r4b[:status] == 400
  record(results, 'T4', 'Photo validation (magic bytes & size)',
         'Spoofed fake.png + >5MB huge.png',
         'Both rejected with 400; no invalid attachment stored',
         t4_pass,
         "spoofed=HTTP #{r4a[:status]} (#{r4a[:body]['error']}); oversized=HTTP #{r4b[:status]} (#{r4b[:body]['error']})")

  # T5 — Duplicate warning (similar Open ticket at CSE AI Lab - PC-12 which is seeded as TKT-101)
  r5_check = http_req('GET', '/tickets/duplicate-check?location=CSE+AI+Lab+-+PC-12&category=Hardware', token: rep1_tok)
  r5_create = http_req('POST', '/tickets', token: rep2_tok, json: {
    title: 'Monitor black on PC-12',
    description: 'Screen stays dark even after reboot.',
    category: 'Hardware',
    priority: 'Medium',
    location: 'CSE AI Lab - PC-12',
    department: 'CSE (AI&ML)'
  })
  t5_pass = r5_check[:status] == 200 && r5_check[:body]['duplicate_warning'] == true &&
            r5_check[:body]['matches'].include?('TKT-101') &&
            r5_create[:status] == 201 && r5_create[:body]['duplicate_warning'] == true
  record(results, 'T5', 'Duplicate warning',
         'GET /tickets/duplicate-check & POST /tickets at CSE AI Lab - PC-12',
         'Warning=true with matching ticket ID TKT-101 without silently merging',
         t5_pass,
         "check=#{r5_check[:body]['duplicate_warning']} matches=#{r5_check[:body]['matches']}; new_ticket=#{r5_create[:body]['ticket_id']} warn=#{r5_create[:body]['duplicate_warning']}")

  # T6 — Role access (Reporter calls Admin assignment endpoint)
  r6 = http_req('PATCH', "/tickets/#{t1_id}/assign", token: rep1_tok, json: { technician_id: 'USR-TECH-01' })
  t6_check = http_req('GET', "/tickets/#{t1_id}", token: adm1_tok)
  t6_pass = r6[:status] == 403 && t6_check[:body].dig('ticket', 'status') == 'Open'
  record(results, 'T6', 'Role access enforcement',
         "Reporter calls PATCH /tickets/#{t1_id}/assign",
         '403 Forbidden; ticket remains Open',
         t6_pass,
         "HTTP #{r6[:status]} (#{r6[:body]['error']}); ticket status=#{t6_check[:body].dig('ticket', 'status')}")

  # T7 — Valid assignment
  r7 = http_req('PATCH', "/tickets/#{t1_id}/assign", token: adm1_tok, json: { technician_id: 'USR-TECH-01' })
  t7_pass = r7[:status] == 200 && r7[:body].dig('ticket', 'status') == 'Assigned' &&
            r7[:body].dig('ticket', 'technician_id') == 'USR-TECH-01'
  record(results, 'T7', 'Valid assignment',
         "Admin assigns #{t1_id} to USR-TECH-01",
         '200 OK; technician linked; status=Assigned',
         t7_pass,
         "HTTP #{r7[:status]}, status=#{r7[:body].dig('ticket', 'status')}, tech=#{r7[:body].dig('ticket', 'technician_id')}")

  # T8 — Invalid technician (assign Open ticket to Reporter account)
  dup_tkt_id = r5_create[:body]['ticket_id']
  r8 = http_req('PATCH', "/tickets/#{dup_tkt_id}/assign", token: adm1_tok, json: { technician_id: 'USR-REP-01' })
  t8_pass = r8[:status] == 400 && r8[:body]['error'].to_s.include?("not 'technician'")
  record(results, 'T8', 'Invalid technician role check',
         "Admin tries assigning #{dup_tkt_id} to USR-REP-01 (reporter)",
         '400 Rejected; role requirement enforced',
         t8_pass,
         "HTTP #{r8[:status]} (#{r8[:body]['error']})")

  # T9 — Status transition (Assigned -> In Progress by assigned technician)
  r9 = http_req('PATCH', "/tickets/#{t1_id}/status", token: tech1_tok, json: {
    status: 'In Progress',
    note: 'Testing PSU fan bearing on workbench.'
  })
  t9_hist = r9[:body].dig('ticket', 'history') || []
  t9_pass = r9[:status] == 200 && r9[:body].dig('ticket', 'status') == 'In Progress' &&
            t9_hist.any? { |h| h['old_status'] == 'Assigned' && h['new_status'] == 'In Progress' }
  record(results, 'T9', 'Status transition (Assigned -> In Progress)',
         "Assigned Technician moves #{t1_id} to In Progress",
         '200 OK; status=In Progress; history updated',
         t9_pass,
         "HTTP #{r9[:status]}, status=#{r9[:body].dig('ticket', 'status')}, history_entries=#{t9_hist.length}")

  # T10 — Invalid transition (Open directly to Resolved)
  r10 = http_req('PATCH', "/tickets/#{dup_tkt_id}/status", token: tech1_tok, json: {
    status: 'Resolved',
    resolution_note: 'Trying to skip workflow'
  })
  t10_pass = [403, 409].include?(r10[:status])
  record(results, 'T10', 'Invalid transition (Open -> Resolved)',
         "Technician tries moving Open #{dup_tkt_id} directly to Resolved",
         'Rejected (403/409); ticket stays Open',
         t10_pass,
         "HTTP #{r10[:status]} (#{r10[:body]['error']})")

  # T11 — Resolution note required
  r11 = http_req('PATCH', "/tickets/#{t1_id}/status", token: tech1_tok, json: {
    status: 'Resolved',
    resolution_note: '   '
  })
  r11_check = http_req('GET', "/tickets/#{t1_id}", token: tech1_tok)
  t11_pass = r11[:status] == 400 && r11_check[:body].dig('ticket', 'status') == 'In Progress'
  record(results, 'T11', 'Resolution requires non-empty note',
         "Technician resolves #{t1_id} with blank resolution_note",
         '400 Rejected; ticket remains In Progress',
         t11_pass,
         "HTTP #{r11[:status]} (#{r11[:body]['error']}); status=#{r11_check[:body].dig('ticket', 'status')}")

  # T12 — Metrics after resolving ticket
  r12_resolve = http_req('PATCH', "/tickets/#{t1_id}/status", token: tech1_tok, json: {
    status: 'Resolved',
    resolution_note: 'Replaced chassis cooling fan and verified thermal idle at 41C.'
  })
  r12_metrics = http_req('GET', '/dashboard/metrics', token: adm1_tok)
  all_tickets = http_req('GET', '/tickets', token: adm1_tok)[:body]['tickets']
  expected_open = all_tickets.count { |t| t['status'] == 'Open' }
  resolved_durations = all_tickets.select { |t| t['status'] == 'Resolved' }.map { |t| t['resolution_duration_minutes'].to_f }
  expected_avg = (resolved_durations.sum / resolved_durations.length).round(2)
  observed_open = r12_metrics[:body]['open_count']
  observed_avg = r12_metrics[:body]['average_resolution_time_minutes'].to_f
  t12_pass = r12_resolve[:status] == 200 && r12_metrics[:status] == 200 &&
             observed_open == expected_open && (observed_avg - expected_avg).abs < 0.2
  record(results, 'T12', 'Dashboard metrics accuracy',
         "Resolve #{t1_id} and fetch GET /dashboard/metrics",
         "open_count=#{expected_open}, avg_resolution_minutes~#{expected_avg}",
         t12_pass,
         "HTTP #{r12_metrics[:status]}, open_count=#{observed_open}, avg_min=#{observed_avg} (sample=#{r12_metrics[:body]['resolved_sample_count']})")

  # T13 — Unknown ID
  r13 = http_req('GET', '/tickets/TKT-99999', token: adm1_tok)
  t13_pass = r13[:status] == 404 && r13[:body]['error'].to_s.include?('not found')
  record(results, 'T13', 'Unknown ticket ID',
         'GET /tickets/TKT-99999',
         '404 Not Found without server crash',
         t13_pass,
         "HTTP #{r13[:status]} (#{r13[:body]['error']})")

  # T14 — Concurrent update (two admins assign same Open ticket simultaneously)
  r14_create = http_req('POST', '/tickets', token: rep1_tok, json: {
    title: 'Concurrent assignment race test',
    description: 'Testing atomic Open -> Assigned transition.',
    category: 'Network',
    priority: 'High',
    location: 'Network Closet B2',
    department: 'IT Infrastructure'
  })
  race_id = r14_create[:body]['ticket_id']
  barrier = Queue.new
  th1 = Thread.new do
    barrier.pop
    http_req('PATCH', "/tickets/#{race_id}/assign", token: adm1_tok, json: { technician_id: 'USR-TECH-01' })
  end
  th2 = Thread.new do
    barrier.pop
    http_req('PATCH', "/tickets/#{race_id}/assign", token: adm2_tok, json: { technician_id: 'USR-TECH-02' })
  end
  2.times { barrier << true }
  res_a = th1.value
  res_b = th2.value
  race_after = http_req('GET', "/tickets/#{race_id}", token: adm1_tok)[:body]['ticket']
  assign_history_count = race_after['history'].count { |h| h['new_status'] == 'Assigned' }
  statuses_sorted = [res_a[:status], res_b[:status]].sort
  t14_pass = statuses_sorted == [200, 409] && assign_history_count == 1 && race_after['status'] == 'Assigned'
  record(results, 'T14', 'Concurrent admin assignment',
         "2 simultaneous PATCH /tickets/#{race_id}/assign calls",
         'One 200 OK, one 409 Conflict; exactly 1 Assigned history entry',
         t14_pass,
         "statuses=#{statuses_sorted.inspect}, assign_history_count=#{assign_history_count}, winner_tech=#{race_after['technician_id']}")

  # T15 — Private ticket isolation & Admin return-to-open with reason
  r15_priv = http_req('GET', "/tickets/#{t1_id}", token: rep2_tok)
  r15_unassigned_tech = http_req('PATCH', "/tickets/#{race_id}/status", token: (race_after['technician_id'] == 'USR-TECH-01' ? tech2_tok : tech1_tok), json: { status: 'In Progress' })
  r15_return = http_req('PATCH', "/tickets/#{race_id}/status", token: adm1_tok, json: {
    status: 'Open',
    reason: 'Re-routing to evening shift technician.'
  })
  t15_pass = r15_priv[:status] == 403 && r15_unassigned_tech[:status] == 403 &&
             r15_return[:status] == 200 && r15_return[:body].dig('ticket', 'status') == 'Open' &&
             r15_return[:body].dig('ticket', 'technician_id').nil?
  record(results, 'T15', 'Privacy isolation & Admin return-to-Open',
         'Other reporter GET + unassigned tech PATCH + Admin return to Open with reason',
         '403 on private/unassigned access; 200 on Admin return to Open',
         t15_pass,
         "other_rep=#{r15_priv[:status]}, other_tech=#{r15_unassigned_tech[:status]}, admin_return=#{r15_return[:status]} (status=#{r15_return[:body].dig('ticket', 'status')})")

  passed_count = results.count { |r| r[:status] == 'PASS' }
  total_count = results.length
  summary = {
    executed_at: Time.now.utc.iso8601,
    total: total_count,
    passed: passed_count,
    failed: total_count - passed_count,
    tests: results
  }
  File.write(EVIDENCE_PATH, JSON.pretty_generate(summary))

  puts "\nSummary: #{passed_count}/#{total_count} tests passed. Evidence written to #{EVIDENCE_PATH}"
  exit(passed_count == total_count ? 0 : 1)
ensure
  server.shutdown
  server_thread.join(2)
end
