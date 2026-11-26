# FIXORA

A full-stack, zero-dependency issue-tracking web application (**FIXORA**, built for **IT HAPPENS @ RAALE #15**).

## Features
- **Multi-role Access Control (Server-Enforced)**:
  - **Reporter (Student / Staff)**: Submit issues with category, priority, campus location/lab ID, and optional photo evidence; receive live duplicate warnings for similar open tickets at the same location; track personal tickets, history, and resolution notes.
  - **Technician**: View assigned work queue with priority/category/department/status filters; transition `Assigned -> In Progress -> Resolved`; record progress notes and mandatory resolution notes.
  - **Admin**: View all tickets across campus; assign `Open` tickets to valid `Technician` accounts; reassign or return active tickets to `Open` with a recorded reason; inspect SLA compliance, technician workload, category/department/priority charts, and resolution metrics; manage users.
- **Strict Lifecycle Pipeline**: `Open -> Assigned -> In Progress -> Resolved` (plus documented Admin return `Assigned / In Progress -> Open` with reason). All transitions and permissions are enforced server-side inside atomic SQLite `BEGIN IMMEDIATE` transactions.
- **Attachment Validation**: Validates file extension, MIME type, file size (≤ 5 MB), and image magic-byte signatures (`PNG`, `JPEG`, `GIF`, `WEBP`).

## Quick Start
Requires macOS/Linux with `ruby` (2.6+) and `sqlite3` (no external gems or npm packages needed).

```bash
cd /Users/aishwariyakripa/.gemini/antigravity/scratch/smart-campus-issue-tracker
ruby server.rb
```

Open `http://127.0.0.1:4567` in your browser.

## Demo Credentials
| Role | Name | Email | Password |
| :--- | :--- | :--- | :--- |
| Reporter | Ananya Sharma | `ananya@campus.edu` | `reporter123` |
| Reporter | Rohan Nair | `rohan@campus.edu` | `reporter123` |
| Technician | Karthik Raj | `karthik@campus.edu` | `tech123` |
| Technician | Meera Menon | `meera@campus.edu` | `tech123` |
| Admin | Dr. Priya Kumar | `admin@campus.edu` | `admin123` |
| Admin | Vikram Rao | `admin2@campus.edu` | `admin123` |

## Automated Test Suite
```bash
ruby tests/run_tests.rb
```
Executes 15 end-to-end HTTP integration and concurrency tests (`T1`–`T15`) against an isolated SQLite database and writes observed outputs to `tests/test_evidence.json`.
