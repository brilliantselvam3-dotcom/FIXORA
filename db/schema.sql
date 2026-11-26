PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS users (
  user_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('reporter', 'technician', 'admin')),
  department TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tickets (
  ticket_id TEXT PRIMARY KEY,
  seq_num INTEGER NOT NULL UNIQUE,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('Hardware', 'Software', 'Network', 'Facility')),
  priority TEXT NOT NULL CHECK (priority IN ('Low', 'Medium', 'High', 'Critical')),
  location TEXT NOT NULL,
  department TEXT NOT NULL,
  reporter_id TEXT NOT NULL REFERENCES users(user_id),
  technician_id TEXT REFERENCES users(user_id),
  status TEXT NOT NULL CHECK (status IN ('Open', 'Assigned', 'In Progress', 'Resolved')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS attachments (
  attachment_id TEXT PRIMARY KEY,
  ticket_id TEXT NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  file_name TEXT NOT NULL,
  file_type TEXT NOT NULL,
  file_path TEXT NOT NULL,
  file_size INTEGER NOT NULL,
  uploaded_by TEXT NOT NULL REFERENCES users(user_id),
  uploaded_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ticket_history (
  history_id TEXT PRIMARY KEY,
  ticket_id TEXT NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  changed_by TEXT NOT NULL REFERENCES users(user_id),
  old_status TEXT,
  new_status TEXT NOT NULL,
  note TEXT NOT NULL,
  changed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS resolutions (
  resolution_id TEXT PRIMARY KEY,
  ticket_id TEXT NOT NULL UNIQUE REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  technician_id TEXT NOT NULL REFERENCES users(user_id),
  resolution_note TEXT NOT NULL,
  resolved_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);
CREATE INDEX IF NOT EXISTS idx_tickets_reporter ON tickets(reporter_id);
CREATE INDEX IF NOT EXISTS idx_tickets_technician ON tickets(technician_id);
CREATE INDEX IF NOT EXISTS idx_tickets_location ON tickets(location);
CREATE INDEX IF NOT EXISTS idx_history_ticket ON ticket_history(ticket_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_attachments_ticket ON attachments(ticket_id);
