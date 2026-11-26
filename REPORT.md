# Project Report — FIXORA

**Event:** IT HAPPENS @ RAALE #15  
**Date:** 26 November 2026  

---

## 1. What We Built
We built **FIXORA**, a multi-role web application and REST API that centralizes campus, IT, and laboratory problem reporting, technician dispatch, strict lifecycle tracking, duplicate detection, photo evidence validation, and service-level metrics.

### Architecture
- **Frontend (`public/index.html`, `public/styles.css`, `public/app.js`)**: Single-page role-aware web UI with dedicated Reporter, Technician, and Admin workflows, live duplicate-ticket warnings, upload progress indicator (`XMLHttpRequest`), lab workstation QR quick-fill presets, SLA badges, SVG/CSS distribution charts, and an append-only ticket timeline modal.
- **API & Business Logic (`server.rb`, `lib/auth.rb`, `lib/tickets.rb`, `lib/uploads.rb`)**: Ruby 2.6 WEBrick HTTP server exposing JSON and multipart endpoints, PBKDF2-HMAC-SHA256 authentication with Bearer session tokens, server-side RBAC, magic-byte photo validation, and atomic ticket transition logic.
- **Persistence (`db/schema.sql`, `db/seed.rb`, `lib/database.rb`)**: SQLite 3.51.0 relational database (`data/tracker.db`) with foreign keys, WAL journal mode, `Mutex` synchronization, and `BEGIN IMMEDIATE` transactions, plus local disk storage (`uploads/`) for validated image attachments.

---

## 2. Roles and Permissions
Every permission check is enforced on the server in `lib/auth.rb` and `lib/tickets.rb`, never solely by hiding UI controls:

| Role | Allowed Capabilities | Blocked Actions (Server-Enforced) |
| :--- | :--- | :--- |
| **Reporter** (`reporter`) | Sign in; create tickets with optional photo; check duplicate open tickets; view **own** tickets, attachments, history, and resolution notes; post reporter follow-up comments on own tickets. | Cannot view another reporter's ticket (`403`); cannot assign tickets (`403`); cannot change ticket status (`403`); cannot access Admin dashboard metrics or user directory (`403`). |
| **Technician** (`technician`) | Sign in; view **assigned** tickets; filter by status/priority/category/department/search; move `Assigned -> In Progress` and `In Progress -> Resolved` (with mandatory resolution note); add progress notes and upload evidence on assigned tickets. | Cannot view or update tickets not assigned to them (`403`); cannot assign tickets (`403`); cannot skip `Open -> Resolved` (`403`/`409`); cannot resolve without a resolution note (`400`). |
| **Admin** (`admin`) | View all tickets across departments; filter by department, priority, category, status, date range, unassigned, and overdue SLA; assign `Open` tickets to active `Technician` users; reassign or return `Assigned`/`In Progress` tickets to `Open` with a mandatory reason; view `/dashboard/metrics` and manage users. | Cannot assign tickets to `reporter` or `admin` accounts (`400`); cannot concurrently double-assign an `Open` ticket (`409`); cannot resolve a ticket on behalf of a technician outside the transition rules (`409`). |

---

## 3. Data Model
Defined in `db/schema.sql` with `PRAGMA foreign_keys = ON`:

1. **`users`**: `user_id` (PK), `name`, `email` (UNIQUE), `password_hash` (`pbkdf2_sha256`), `role` (`reporter` | `technician` | `admin`), `department`, `active`, `created_at`.
2. **`sessions`**: `token` (PK), `user_id` (FK -> `users`), `created_at`, `expires_at`.
3. **`tickets`**: `ticket_id` (PK, e.g., `TKT-101`), `seq_num` (UNIQUE), `title`, `description`, `category` (`Hardware` | `Software` | `Network` | `Facility`), `priority` (`Low` | `Medium` | `High` | `Critical`), `location`, `department`, `reporter_id` (FK -> `users`), `technician_id` (nullable FK -> `users`), `status` (`Open` | `Assigned` | `In Progress` | `Resolved`), `created_at`, `updated_at`.
4. **`attachments`**: `attachment_id` (PK), `ticket_id` (FK -> `tickets`), `file_name`, `file_type`, `file_path`, `file_size`, `uploaded_by` (FK -> `users`), `uploaded_at`.
5. **`ticket_history`**: Append-only audit trail (`history_id`, `ticket_id`, `changed_by`, `old_status`, `new_status`, `note`, `changed_at`).
6. **`resolutions`**: `resolution_id` (PK), `ticket_id` (UNIQUE FK -> `tickets`), `technician_id` (FK -> `users`), `resolution_note`, `resolved_at`.

---

## 4. Ticket Workflow
1. **Creation (`POST /tickets`)**: Validates non-empty `title`, `description`, `category`, `priority`, and `location`, checks optional photo evidence, assigns `status = 'Open'` and `created_at = UTC now`, and inserts both the `tickets` row and initial `ticket_history` row in one `BEGIN IMMEDIATE` transaction.
2. **Duplicate Warning (`GET /tickets/duplicate-check`)**: Normalizes `location` (lowercasing, stripping punctuation, collapsing whitespace) and compares against `Open` tickets. Exact location matches or overlapping location + matching category/title keywords return `duplicate_warning: true` with matching `ticket_id`s without silently merging or blocking valid distinct submissions.
3. **Assignment (`PATCH /tickets/{id}/assign`)**: Admin-only. Verifies target user has `role = 'technician'` and `active = 1`. Normal assignment executes an atomic `UPDATE tickets ... WHERE ticket_id = ? AND status = 'Open'` followed by `INSERT INTO ticket_history ... WHERE changes() = 1`, returning `409 Conflict` if another admin assigned the ticket concurrently. Reassignment of `Assigned`/`In Progress` tickets requires `reassign: true` and a non-empty `reason`.
4. **Status Transitions (`PATCH /tickets/{id}/status`)**:
   - `Assigned -> In Progress`: Assigned Technician only.
   - `In Progress -> Resolved`: Assigned Technician only; requires non-empty `resolution_note` and records `resolutions.resolved_at` + history atomically.
   - `Assigned / In Progress -> Open`: Admin only; requires non-empty `reason` and clears `technician_id`.
   - All other transitions are rejected (`403`/`409`).

---

## 5. Dashboard Metrics
Implemented in `Tickets.dashboard_metrics` (`GET /dashboard/metrics`, Admin-only):
- **Open-Ticket Count (`open_count`)**: Exact SQL count of tickets with `status = 'Open'` (unassigned backlog). Also reports `active_count` (`status != 'Resolved'`), `assigned_count`, `in_progress_count`, `resolved_count`, and `overdue_count` (based on priority SLA thresholds: Critical 2h, High 8h, Medium 24h, Low 72h).
- **Average Resolution Time (`average_resolution_time_minutes`)**:
  $$\text{Avg Resolution Time (minutes)} = \frac{1}{N} \sum_{i=1}^{N} \left(\text{julianday}(\text{resolutions.resolved\_at}_i) - \text{julianday}(\text{tickets.created\_at}_i)\right) \times 1440.0$$
  where $N$ is the count of `Resolved` tickets joined with `resolutions`. Rounded to 2 decimal places (`0.0` when $N = 0$).

---

## 6. Methods and Decisions
- **Stack Choice**: **Ruby 2.6.10 (stdlib `webrick`, `json`, `openssl`, `open3`, `securerandom`) + SQLite 3.51.0 CLI + Vanilla HTML/CSS/JS**. On the target machine, Xcode Command Line Tools (`python3` shim) and `node`/`npm` were unavailable; Ruby + `sqlite3` were pre-installed and enabled a zero-dependency, self-contained server and automated test runner.
- **Database Over Flat Files**: Rejected JSON file persistence because concurrent admin assignments (Test `T14`) and relational joins (`resolutions`, `ticket_history`, `attachments`) require transactional guarantees (`BEGIN IMMEDIATE` + `WHERE status = 'Open'`).
- **Photo Validation**: Implemented binary multipart parsing (`Uploads.parse_multipart`) and magic-byte signature verification (`PNG`, `JPEG`, `GIF`, `WEBP`) in addition to extension, MIME type, and 5 MB size checks so renamed non-image files cannot bypass upload security.

---

## 7. Results — Executed Test Table
All tests below were executed end-to-end against a clean HTTP server instance (`ruby tests/run_tests.rb`, evidence stored in `tests/test_evidence.json`). **15/15 passed.**

| ID | Test Case | Input | Expected Result | Observed Output | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **T1** | Valid ticket with photo | `POST /tickets` (Hardware, High, `CSE AI Lab - PC-19` + PNG) | `201 Created`, unique `TKT-ID`, `status=Open`, 1 attachment saved | `HTTP 201, ticket_id=TKT-106, status=Open, attachments=1` | **PASS** |
| **T2** | Missing fields | `POST /tickets` with empty `title` and `location` | `400 Bad Request` with clear validation message | `HTTP 400, error=Missing required fields: title, location.` | **PASS** |
| **T3** | Invalid category | `POST /tickets` with `category=Catering` | `400 Bad Request`; no ticket created | `HTTP 400, error=Invalid category 'Catering'. Allowed: Hardware, Software, Network, Facility.` | **PASS** |
| **T4** | Photo validation | Spoofed `fake.png` + >5MB `huge.png` | Both rejected with `400`; no invalid attachment stored | `spoofed=HTTP 400` (signature mismatch); `oversized=HTTP 400` (>5 MB limit) | **PASS** |
| **T5** | Duplicate warning | `GET /tickets/duplicate-check` & `POST /tickets` at `CSE AI Lab - PC-12` | `duplicate_warning=true` with `TKT-101` without merging | `check=true matches=["TKT-101"]; new_ticket=TKT-107 warn=true` | **PASS** |
| **T6** | Role access enforcement | Reporter calls `PATCH /tickets/TKT-106/assign` | `403 Forbidden`; ticket remains `Open` | `HTTP 403 (Forbidden: reporter role cannot perform this action.); ticket status=Open` | **PASS** |
| **T7** | Valid assignment | Admin assigns `TKT-106` to `USR-TECH-01` | `200 OK`; technician linked; `status=Assigned` | `HTTP 200, status=Assigned, tech=USR-TECH-01` | **PASS** |
| **T8** | Invalid technician check | Admin assigns `TKT-107` to `USR-REP-01` (reporter) | `400 Rejected`; role requirement enforced | `HTTP 400 (User 'Ananya Sharma' has role 'reporter', not 'technician'.)` | **PASS** |
| **T9** | Status transition | Assigned Technician moves `TKT-106` to `In Progress` | `200 OK`; `status=In Progress`; history updated | `HTTP 200, status=In Progress, history_entries=3` | **PASS** |
| **T10** | Invalid transition | Technician moves Open `TKT-107` directly to `Resolved` | Rejected (`403`/`409`); ticket stays `Open` | `HTTP 403 (Forbidden: You are not assigned to this ticket.)` | **PASS** |
| **T11** | Resolution note required | Technician resolves `TKT-106` with blank `resolution_note` | `400 Rejected`; ticket remains `In Progress` | `HTTP 400 (Resolution note is required before marking a ticket Resolved.); status=In Progress` | **PASS** |
| **T12** | Dashboard metrics | Resolve `TKT-106` and fetch `GET /dashboard/metrics` | `open_count=2`, `avg_resolution_minutes ~ 80.0` | `HTTP 200, open_count=2, avg_min=80.0 (sample=3)` | **PASS** |
| **T13** | Unknown ticket ID | `GET /tickets/TKT-99999` | `404 Not Found` without server crash | `HTTP 404 (Ticket 'TKT-99999' not found.)` | **PASS** |
| **T14** | Concurrent assignment | 2 simultaneous `PATCH /tickets/TKT-108/assign` calls | One `200 OK`, one `409 Conflict`; 1 history entry | `statuses=[200, 409], assign_history_count=1, winner_tech=USR-TECH-02` | **PASS** |
| **T15** | Privacy & return-to-Open | Other reporter `GET` + unassigned tech `PATCH` + Admin return to `Open` | `403` on unauthorized; `200` on Admin return | `other_rep=403, other_tech=403, admin_return=200 (status=Open)` | **PASS** |

---

## 8. Component Summary & Dead End Encountered
- **Components**:
  - Data Schema & Seeding: `db/schema.sql`, `db/seed.rb`, `lib/database.rb`
  - Auth & Uploads: `lib/auth.rb`, `lib/uploads.rb`
  - Ticket Engine & API Router: `lib/tickets.rb`, `server.rb`
  - Frontend UI: `public/index.html`, `public/styles.css`, `public/app.js`
  - Automated Verification: `tests/run_tests.rb`
- **Dead End Encountered & Fixed**: Using `WEBrick::HTTPServer#mount_proc '/'` initially caused all `PATCH` requests (`/tickets/{id}/assign` and `/tickets/{id}/status`) to fail with `HTTP 405 Method Not Allowed` because Ruby 2.6's `WEBrick::HTTPServlet::ProcHandler` only defines `do_GET`, `do_POST`, `do_PUT`, `do_DELETE`, and `do_OPTIONS`. Replacing `mount_proc` with a custom `WEBrick::HTTPServlet::AbstractServlet` subclass explicitly defining `do_GET`, `do_POST`, `do_PATCH`, `do_PUT`, `do_DELETE`, and `do_OPTIONS` resolved the issue completely.

---

## 9. Limitations and Next Steps
1. **Database Driver Overhead**: `lib/database.rb` invokes the `sqlite3` CLI via `Open3.capture3` under a `Mutex` because no native `sqlite3` gem is installed. For high-throughput production workloads, switching to a native C-extension driver (`sqlite3` gem or PostgreSQL pool) would reduce per-query process-spawn latency.
2. **Local Disk Attachments**: Uploaded photos are stored on local disk (`uploads/`). Production campus deployment should move attachments to object storage (e.g., S3/GCS) with signed URLs.
3. **Notification Delivery**: Status updates are visible in the UI timeline, but automated email/SMS alerts on assignment and resolution are not yet wired to an SMTP gateway.
4. **UI Browser E2E Tests**: Automated tests verify all HTTP API contracts, uploads, RBAC, and concurrency; browser-level DOM automation (Playwright/Puppeteer) can be added next.

---

## 10. How to Run
```bash
cd /Users/aishwariyakripa/.gemini/antigravity/scratch/smart-campus-issue-tracker
ruby server.rb
```
- **URL**: `http://127.0.0.1:4567` (override via `PORT` or `HOST` environment variables).
- **Run Automated Tests**: `ruby tests/run_tests.rb`
- **Demo Accounts**:
  - Reporter: `ananya@campus.edu` / `reporter123` (or `rohan@campus.edu` / `reporter123`)
  - Technician: `karthik@campus.edu` / `tech123` (or `meera@campus.edu` / `tech123`)
  - Admin: `admin@campus.edu` / `admin123` (or `admin2@campus.edu` / `admin123`)
