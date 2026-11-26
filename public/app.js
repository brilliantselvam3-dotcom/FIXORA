(() => {
  'use strict';

  const STORAGE_KEY = 'campus_tracker_session_v1';

  const state = {
    token: null,
    user: null,
    activeTab: null,
    tickets: [],
    metrics: null,
    users: [],
    technicians: [],
    filters: {
      status: '',
      priority: '',
      category: '',
      department: '',
      search: '',
      date_from: '',
      date_to: '',
      unassigned: false,
      overdue: false
    },
    duplicateCheckTimer: null,
    lastDuplicateResult: null
  };

  const WORKSTATION_QR_PRESETS = [
    { label: 'QR: CSE AI Lab - PC-12', location: 'CSE AI Lab - PC-12', department: 'CSE (AI&ML)', category: 'Hardware' },
    { label: 'QR: ECE CAD Lab - WS-04', location: 'ECE CAD Lab - WS-04', department: 'ECE', category: 'Software' },
    { label: 'QR: Central Library - AP-02', location: 'Central Library - Floor 2', department: 'IT Infrastructure', category: 'Network' },
    { label: 'QR: Seminar Hall B - Podium', location: 'Seminar Hall B - Podium', department: 'Campus Operations', category: 'Facility' }
  ];

  // ---------- Helpers ----------
  function esc(str) {
    if (str === null || str === undefined) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function fmtDate(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }

  function statusClass(status) {
    return 'status-' + String(status || '').toLowerCase().replace(/\s+/g, '-');
  }

  function prioClass(priority) {
    return 'prio-' + String(priority || '').toLowerCase();
  }

  function toast(msg, type = 'info') {
    const container = document.getElementById('toast-container');
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    el.textContent = msg;
    container.appendChild(el);
    setTimeout(() => el.remove(), 3800);
  }

  async function api(path, options = {}) {
    const headers = Object.assign({}, options.headers || {});
    if (state.token) {
      headers['Authorization'] = `Bearer ${state.token}`;
    }
    if (options.json !== undefined) {
      headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(options.json);
      delete options.json;
    }

    const res = await fetch(path, { ...options, headers });
    const text = await res.text();
    let data = {};
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      data = { error: text || 'Unexpected response' };
    }

    if (!res.ok) {
      if (res.status === 401 && state.token) {
        clearSession();
        renderApp();
      }
      const err = new Error(data.error || `Request failed (${res.status})`);
      err.status = res.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  function saveSession(token, user) {
    state.token = token;
    state.user = user;
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ token, user }));
  }

  function clearSession() {
    state.token = null;
    state.user = null;
    state.tickets = [];
    state.metrics = null;
    state.users = [];
    localStorage.removeItem(STORAGE_KEY);
  }

  function loadSession() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (parsed && parsed.token && parsed.user) {
        state.token = parsed.token;
        state.user = parsed.user;
      }
    } catch {
      clearSession();
    }
  }

  // ---------- Navigation & Role Views ----------
  function defaultTabForRole(role) {
    if (role === 'reporter') return 'my-tickets';
    if (role === 'technician') return 'tech-queue';
    if (role === 'admin') return 'admin-dashboard';
    return 'my-tickets';
  }

  function tabsForRole(role) {
    if (role === 'reporter') {
      return [
        { id: 'my-tickets', label: 'My Tickets' },
        { id: 'new-ticket', label: '+ Report Issue' }
      ];
    }
    if (role === 'technician') {
      return [
        { id: 'tech-queue', label: 'My Assigned Queue' }
      ];
    }
    if (role === 'admin') {
      return [
        { id: 'admin-dashboard', label: 'Dashboard & SLA' },
        { id: 'admin-tickets', label: 'All Tickets' },
        { id: 'admin-users', label: 'Users & Technicians' }
      ];
    }
    return [];
  }

  async function renderApp() {
    const loginView = document.getElementById('login-view');
    const workspaceView = document.getElementById('workspace-view');
    const topbar = document.getElementById('topbar');

    if (!state.user || !state.token) {
      loginView.hidden = false;
      workspaceView.hidden = true;
      topbar.hidden = true;
      return;
    }

    loginView.hidden = true;
    workspaceView.hidden = false;
    topbar.hidden = false;

    const tabs = tabsForRole(state.user.role);
    if (!tabs.some((t) => t.id === state.activeTab)) {
      state.activeTab = defaultTabForRole(state.user.role);
    }

    const navEl = document.getElementById('nav-tabs');
    navEl.innerHTML = tabs
      .map(
        (t) =>
          `<button type="button" class="nav-tab ${t.id === state.activeTab ? 'active' : ''}" data-tab="${esc(
            t.id
          )}">${esc(t.label)}</button>`
      )
      .join('');

    navEl.querySelectorAll('.nav-tab').forEach((btn) => {
      btn.addEventListener('click', () => {
        state.activeTab = btn.dataset.tab;
        renderApp();
      });
    });

    document.getElementById('user-pill').innerHTML = `
      <span class="role-tag role-${esc(state.user.role)}">${esc(state.user.role.toUpperCase())}</span>
      <span><strong>${esc(state.user.name)}</strong> &middot; ${esc(state.user.department)}</span>
    `;

    await renderActiveTab();
  }

  async function renderActiveTab() {
    const container = document.getElementById('view-content');
    container.innerHTML = '<div class="card">Loading...</div>';

    try {
      if (state.activeTab === 'my-tickets') {
        await loadTickets();
        renderReporterTickets(container);
      } else if (state.activeTab === 'new-ticket') {
        renderNewTicketForm(container);
      } else if (state.activeTab === 'tech-queue') {
        await loadTickets();
        renderTechnicianQueue(container);
      } else if (state.activeTab === 'admin-dashboard') {
        await Promise.all([loadMetrics(), loadUsers()]);
        renderAdminDashboard(container);
      } else if (state.activeTab === 'admin-tickets') {
        await Promise.all([loadTickets(), loadUsers()]);
        renderAdminTickets(container);
      } else if (state.activeTab === 'admin-users') {
        await loadUsers();
        renderAdminUsers(container);
      }
    } catch (err) {
      container.innerHTML = `<div class="alert alert-error">${esc(err.message)}</div>`;
    }
  }

  async function loadTickets() {
    const qs = new URLSearchParams();
    Object.entries(state.filters).forEach(([k, v]) => {
      if (v !== '' && v !== false && v !== null && v !== undefined) {
        qs.set(k, String(v));
      }
    });
    const query = qs.toString();
    const data = await api(`/tickets${query ? '?' + query : ''}`);
    state.tickets = data.tickets || [];
  }

  async function loadMetrics() {
    state.metrics = await api('/dashboard/metrics');
  }

  async function loadUsers() {
    const data = await api('/users');
    state.users = data.users || [];
    state.technicians = state.users.filter((u) => u.role === 'technician' && Number(u.active) === 1);
  }

  // ---------- Reporter: My Tickets ----------
  function renderReporterTickets(container) {
    const openCount = state.tickets.filter((t) => t.status === 'Open').length;
    const activeCount = state.tickets.filter((t) => t.status !== 'Resolved').length;
    const resolvedCount = state.tickets.filter((t) => t.status === 'Resolved').length;

    container.innerHTML = `
      <div class="page-header">
        <div>
          <h1>My Reported Issues</h1>
          <p>Track status, assigned technician, timeline updates, and resolution notes for your tickets.</p>
        </div>
        <button type="button" class="btn btn-primary" id="btn-go-new">+ Report New Issue</button>
      </div>

      <div class="kpi-grid">
        <div class="kpi-card"><div class="kpi-label">Open (Unassigned)</div><div class="kpi-value">${openCount}</div></div>
        <div class="kpi-card"><div class="kpi-label">Active Issues</div><div class="kpi-value">${activeCount}</div></div>
        <div class="kpi-card"><div class="kpi-label">Resolved</div><div class="kpi-value">${resolvedCount}</div></div>
      </div>

      ${renderFilterBar({ showDepartment: false, showDate: false, showAdminFlags: false })}

      <div class="card">
        ${renderTicketsTable(state.tickets, { mode: 'reporter' })}
      </div>
    `;

    document.getElementById('btn-go-new').addEventListener('click', () => {
      state.activeTab = 'new-ticket';
      renderApp();
    });
    wireFilterBar();
    wireTicketLinks();
  }

  // ---------- Reporter: New Ticket Form ----------
  function renderNewTicketForm(container) {
    const params = new URLSearchParams(window.location.search);
    const qrLoc = params.get('qr_loc') || '';
    const qrDept = params.get('qr_dept') || state.user.department || '';
    const qrCat = params.get('qr_cat') || 'Hardware';

    container.innerHTML = `
      <div class="page-header">
        <div>
          <h1>Report Campus or Lab Issue</h1>
          <p>Provide accurate location and category details. Similar open tickets at the same location trigger an automatic warning.</p>
        </div>
        <button type="button" class="btn btn-secondary" id="btn-back-list">Back to My Tickets</button>
      </div>

      <div class="card">
        <form id="create-ticket-form" class="stack-md">
          <div>
            <div class="field-hint"><strong>Quick Lab Workstation QR Presets:</strong> click to simulate scanning a lab workstation tag</div>
            <div class="qr-presets">
              ${WORKSTATION_QR_PRESETS.map(
                (p, idx) =>
                  `<button type="button" class="qr-chip" data-qr-idx="${idx}">${esc(p.label)}</button>`
              ).join('')}
            </div>
          </div>

          <div class="form-grid">
            <div class="field">
              <label for="tk-title">Issue Title *</label>
              <input id="tk-title" name="title" type="text" placeholder="e.g. Lab PC not starting" required />
            </div>
            <div class="field">
              <label for="tk-location">Campus Location / Lab Identifier *</label>
              <input id="tk-location" name="location" type="text" value="${esc(qrLoc)}" placeholder="e.g. CSE AI Lab - PC-12" required />
            </div>
          </div>

          <div class="form-grid">
            <div class="field">
              <label for="tk-category">Category *</label>
              <select id="tk-category" name="category" required>
                <option value="Hardware" ${qrCat === 'Hardware' ? 'selected' : ''}>Hardware</option>
                <option value="Software" ${qrCat === 'Software' ? 'selected' : ''}>Software</option>
                <option value="Network" ${qrCat === 'Network' ? 'selected' : ''}>Network</option>
                <option value="Facility" ${qrCat === 'Facility' ? 'selected' : ''}>Facility</option>
              </select>
            </div>
            <div class="field">
              <label for="tk-priority">Priority *</label>
              <select id="tk-priority" name="priority" required>
                <option value="Low">Low (72h SLA)</option>
                <option value="Medium" selected>Medium (24h SLA)</option>
                <option value="High">High (8h SLA)</option>
                <option value="Critical">Critical (2h SLA)</option>
              </select>
            </div>
            <div class="field">
              <label for="tk-department">Department *</label>
              <input id="tk-department" name="department" type="text" value="${esc(qrDept)}" required />
            </div>
          </div>

          <div class="field">
            <label for="tk-description">Description *</label>
            <textarea id="tk-description" name="description" rows="3" placeholder="Describe symptoms, error codes, or safety impact..." required></textarea>
          </div>

          <!-- Duplicate Warning Banner -->
          <div id="duplicate-warning-box" class="alert alert-warning" hidden></div>

          <div class="field">
            <label for="tk-photo">Optional Photo Evidence (PNG, JPEG, GIF, WEBP &le; 5 MB)</label>
            <input id="tk-photo" name="photo" type="file" accept=".png,.jpg,.jpeg,.gif,.webp,image/png,image/jpeg,image/gif,image/webp" />
            <div id="photo-preview" class="field-hint"></div>
            <div id="upload-progress-wrap" class="progress-wrap" hidden>
              <div id="upload-progress-bar" class="progress-bar"></div>
            </div>
          </div>

          <div id="create-error" class="alert alert-error" hidden></div>

          <div class="row-wrap">
            <button type="submit" class="btn btn-primary" id="submit-ticket-btn">Submit Ticket</button>
            <button type="button" class="btn btn-secondary" id="check-dup-btn">Check Similar Tickets</button>
          </div>
        </form>
      </div>
    `;

    document.getElementById('btn-back-list').addEventListener('click', () => {
      state.activeTab = 'my-tickets';
      renderApp();
    });

    const titleInput = document.getElementById('tk-title');
    const locInput = document.getElementById('tk-location');
    const catSelect = document.getElementById('tk-category');
    const deptInput = document.getElementById('tk-department');
    const photoInput = document.getElementById('tk-photo');

    container.querySelectorAll('.qr-chip').forEach((chip) => {
      chip.addEventListener('click', () => {
        const preset = WORKSTATION_QR_PRESETS[Number(chip.dataset.qrIdx)];
        if (!preset) return;
        locInput.value = preset.location;
        deptInput.value = preset.department;
        catSelect.value = preset.category;
        runDuplicateCheck();
        toast(`Auto-filled from ${preset.label}`, 'info');
      });
    });

    const scheduleDuplicateCheck = () => {
      clearTimeout(state.duplicateCheckTimer);
      state.duplicateCheckTimer = setTimeout(runDuplicateCheck, 350);
    };

    locInput.addEventListener('input', scheduleDuplicateCheck);
    titleInput.addEventListener('input', scheduleDuplicateCheck);
    catSelect.addEventListener('change', scheduleDuplicateCheck);
    document.getElementById('check-dup-btn').addEventListener('click', runDuplicateCheck);

    photoInput.addEventListener('change', () => {
      const preview = document.getElementById('photo-preview');
      const file = photoInput.files[0];
      if (!file) {
        preview.textContent = '';
        return;
      }
      const mb = (file.size / 1024 / 1024).toFixed(2);
      preview.textContent = `Selected: ${file.name} (${mb} MB, ${file.type || 'unknown type'})`;
    });

    if (locInput.value.trim()) {
      runDuplicateCheck();
    }

    document.getElementById('create-ticket-form').addEventListener('submit', submitNewTicket);
  }

  async function runDuplicateCheck() {
    const locEl = document.getElementById('tk-location');
    const box = document.getElementById('duplicate-warning-box');
    if (!locEl || !box) return;

    const location = locEl.value.trim();
    if (!location) {
      box.hidden = true;
      state.lastDuplicateResult = null;
      return;
    }

    const category = document.getElementById('tk-category')?.value || '';
    const title = document.getElementById('tk-title')?.value || '';
    try {
      const qs = new URLSearchParams({ location, category, title });
      const res = await api(`/tickets/duplicate-check?${qs.toString()}`);
      state.lastDuplicateResult = res;
      if (res.duplicate_warning && res.candidates.length > 0) {
        box.hidden = false;
        box.innerHTML = `
          <strong>Duplicate Warning:</strong> ${esc(res.message)}
          <ul style="margin:6px 0 0 18px;padding:0;">
            ${res.candidates
              .map(
                (c) =>
                  `<li><strong>${esc(c.ticket_id)}</strong> (${esc(c.status)} &middot; ${esc(
                    c.category
                  )}): ${esc(c.title)} at <em>${esc(c.location)}</em></li>`
              )
              .join('')}
          </ul>
          <div style="margin-top:6px;font-size:12px;">You may still submit if this is a distinct issue — tickets are never silently merged.</div>
        `;
      } else {
        box.hidden = true;
      }
    } catch {
      box.hidden = true;
    }
  }

  function submitNewTicket(event) {
    event.preventDefault();
    const errEl = document.getElementById('create-error');
    const btn = document.getElementById('submit-ticket-btn');
    const progWrap = document.getElementById('upload-progress-wrap');
    const progBar = document.getElementById('upload-progress-bar');

    errEl.hidden = true;
    btn.disabled = true;

    const formData = new FormData();
    formData.append('title', document.getElementById('tk-title').value.trim());
    formData.append('location', document.getElementById('tk-location').value.trim());
    formData.append('category', document.getElementById('tk-category').value);
    formData.append('priority', document.getElementById('tk-priority').value);
    formData.append('department', document.getElementById('tk-department').value.trim());
    formData.append('description', document.getElementById('tk-description').value.trim());

    const photo = document.getElementById('tk-photo').files[0];
    if (photo) {
      formData.append('photo', photo);
      progWrap.hidden = false;
      progBar.style.width = '10%';
    }

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/tickets');
    xhr.setRequestHeader('Authorization', `Bearer ${state.token}`);

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && photo) {
        const pct = Math.round((e.loaded / e.total) * 100);
        progBar.style.width = `${pct}%`;
      }
    };

    xhr.onload = () => {
      btn.disabled = false;
      progWrap.hidden = true;
      let data = {};
      try {
        data = JSON.parse(xhr.responseText || '{}');
      } catch {
        data = { error: 'Invalid server response' };
      }

      if (xhr.status >= 200 && xhr.status < 300) {
        const warnNote = data.duplicate_warning
          ? ` (Note: similar open ticket ${data.matches.join(', ')} exists)`
          : '';
        toast(`Created ${data.ticket_id}${warnNote}`, 'success');
        state.activeTab = 'my-tickets';
        renderApp();
      } else {
        errEl.textContent = data.error || `Submission failed (${xhr.status})`;
        errEl.hidden = false;
      }
    };

    xhr.onerror = () => {
      btn.disabled = false;
      progWrap.hidden = true;
      errEl.textContent = 'Network error while submitting ticket.';
      errEl.hidden = false;
    };

    xhr.send(formData);
  }

  // ---------- Technician: Assigned Queue ----------
  function renderTechnicianQueue(container) {
    const assigned = state.tickets.filter((t) => t.status === 'Assigned').length;
    const inProg = state.tickets.filter((t) => t.status === 'In Progress').length;
    const resolved = state.tickets.filter((t) => t.status === 'Resolved').length;

    container.innerHTML = `
      <div class="page-header">
        <div>
          <h1>My Assigned Work Queue</h1>
          <p>Start assigned work, record progress notes, and resolve tickets with verified fix details.</p>
        </div>
      </div>

      <div class="kpi-grid">
        <div class="kpi-card"><div class="kpi-label">Assigned (Waiting)</div><div class="kpi-value">${assigned}</div></div>
        <div class="kpi-card"><div class="kpi-label">In Progress</div><div class="kpi-value">${inProg}</div></div>
        <div class="kpi-card"><div class="kpi-label">Resolved by Me</div><div class="kpi-value">${resolved}</div></div>
      </div>

      ${renderFilterBar({ showDepartment: true, showDate: false, showAdminFlags: false })}

      <div class="card">
        ${renderTicketsTable(state.tickets, { mode: 'technician' })}
      </div>
    `;

    wireFilterBar();
    wireTicketLinks();
  }

  // ---------- Admin: Dashboard ----------
  function renderAdminDashboard(container) {
    const m = state.metrics;
    const maxCat = Math.max(1, ...(m.by_category || []).map((x) => x.count));
    const maxDept = Math.max(1, ...(m.by_department || []).map((x) => x.count));
    const maxPrio = Math.max(1, ...(m.by_priority || []).map((x) => x.count));

    container.innerHTML = `
      <div class="page-header">
        <div>
          <h1>Service Operations Dashboard</h1>
          <p>Real-time open backlog, average resolution duration, SLA compliance, and technician workload.</p>
        </div>
        <button type="button" class="btn btn-primary" id="btn-view-all-tickets">Manage &amp; Assign Tickets</button>
      </div>

      <div class="kpi-grid">
        <div class="kpi-card">
          <div class="kpi-label">Open Tickets</div>
          <div class="kpi-value">${m.open_count}</div>
          <div class="kpi-sub">Awaiting technician assignment</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">Active Pipeline</div>
          <div class="kpi-value">${m.active_count}</div>
          <div class="kpi-sub">${m.assigned_count} Assigned &middot; ${m.in_progress_count} In Progress</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">Avg Resolution Time</div>
          <div class="kpi-value">${esc(m.average_resolution_time_display)}</div>
          <div class="kpi-sub">${m.average_resolution_time_minutes} min across ${m.resolved_sample_count} resolved</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">Overdue SLA</div>
          <div class="kpi-value" style="color:${m.overdue_count > 0 ? 'var(--danger)' : 'var(--success)'};">${m.overdue_count}</div>
          <div class="kpi-sub">${m.resolved_count} total resolved tickets</div>
        </div>
      </div>

      <div class="grid-2">
        <div class="card">
          <h3 class="card-title">Ticket Volume by Category</h3>
          ${renderBarChart(m.by_category, maxCat)}
        </div>
        <div class="card">
          <h3 class="card-title">Ticket Volume by Department</h3>
          ${renderBarChart(m.by_department, maxDept)}
        </div>
      </div>

      <div class="grid-2" style="margin-top:16px;">
        <div class="card">
          <h3 class="card-title">Ticket Volume by Priority</h3>
          ${renderBarChart(m.by_priority, maxPrio)}
        </div>
        <div class="card">
          <h3 class="card-title">Technician Workload</h3>
          <table>
            <thead>
              <tr>
                <th>Technician</th>
                <th>Department</th>
                <th>Assigned</th>
                <th>In Progress</th>
                <th>Resolved</th>
              </tr>
            </thead>
            <tbody>
              ${(m.technician_workload || [])
                .map(
                  (w) => `
                <tr>
                  <td><strong>${esc(w.name)}</strong></td>
                  <td>${esc(w.department)}</td>
                  <td><span class="badge status-assigned">${w.assigned_count}</span></td>
                  <td><span class="badge status-in-progress">${w.in_progress_count}</span></td>
                  <td><span class="badge status-resolved">${w.resolved_count}</span></td>
                </tr>`
                )
                .join('')}
            </tbody>
          </table>
        </div>
      </div>
    `;

    document.getElementById('btn-view-all-tickets').addEventListener('click', () => {
      state.activeTab = 'admin-tickets';
      renderApp();
    });
  }

  function renderBarChart(items, maxVal) {
    if (!items || items.length === 0) return '<div class="field-hint">No ticket data yet.</div>';
    return items
      .map((item) => {
        const pct = Math.round((item.count / maxVal) * 100);
        return `
          <div class="bar-row">
            <span>${esc(item.label)}</span>
            <div class="bar-track"><div class="bar-fill" style="width:${pct}%"></div></div>
            <strong>${item.count}</strong>
          </div>
        `;
      })
      .join('');
  }

  // ---------- Admin: All Tickets ----------
  function renderAdminTickets(container) {
    container.innerHTML = `
      <div class="page-header">
        <div>
          <h1>All Campus Tickets</h1>
          <p>Filter by department, priority, category, status, or date range; assign or reassign technicians.</p>
        </div>
      </div>

      ${renderFilterBar({ showDepartment: true, showDate: true, showAdminFlags: true })}

      <div class="card">
        ${renderTicketsTable(state.tickets, { mode: 'admin' })}
      </div>
    `;

    wireFilterBar();
    wireTicketLinks();
    wireQuickAssign();
  }

  // ---------- Admin: Users ----------
  function renderAdminUsers(container) {
    container.innerHTML = `
      <div class="page-header">
        <div>
          <h1>Users &amp; Technicians</h1>
          <p>Manage campus Reporter, Technician, and Admin accounts and inspect technician queue loads.</p>
        </div>
      </div>

      <div class="grid-2">
        <div class="card">
          <h3 class="card-title">Directory (${state.users.length})</h3>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Name &amp; Email</th>
                  <th>Role</th>
                  <th>Department</th>
                  <th>Active Load</th>
                </tr>
              </thead>
              <tbody>
                ${state.users
                  .map(
                    (u) => `
                  <tr>
                    <td><code>${esc(u.user_id)}</code></td>
                    <td><strong>${esc(u.name)}</strong><br><small style="color:var(--muted)">${esc(u.email)}</small></td>
                    <td><span class="role-tag role-${esc(u.role)}">${esc(u.role)}</span></td>
                    <td>${esc(u.department)}</td>
                    <td>${
                      u.role === 'technician'
                        ? `${u.assigned_count} Assigned / ${u.in_progress_count} In Progress`
                        : '—'
                    }</td>
                  </tr>`
                  )
                  .join('')}
              </tbody>
            </table>
          </div>
        </div>

        <div class="card">
          <h3 class="card-title">Create User Account</h3>
          <form id="create-user-form" class="stack-md">
            <div class="field">
              <label for="nu-name">Full Name *</label>
              <input id="nu-name" type="text" required placeholder="e.g. Arjun Verma" />
            </div>
            <div class="field">
              <label for="nu-email">Campus Email *</label>
              <input id="nu-email" type="email" required placeholder="e.g. arjun@campus.edu" />
            </div>
            <div class="form-grid">
              <div class="field">
                <label for="nu-role">Role *</label>
                <select id="nu-role">
                  <option value="reporter">Reporter (Student / Staff)</option>
                  <option value="technician">Technician</option>
                  <option value="admin">Admin</option>
                </select>
              </div>
              <div class="field">
                <label for="nu-dept">Department *</label>
                <input id="nu-dept" type="text" required placeholder="e.g. IT Infrastructure" />
              </div>
            </div>
            <div class="field">
              <label for="nu-pass">Initial Password *</label>
              <input id="nu-pass" type="password" required minlength="6" placeholder="Minimum 6 characters" />
            </div>
            <div id="nu-error" class="alert alert-error" hidden></div>
            <button type="submit" class="btn btn-primary">Create User</button>
          </form>
        </div>
      </div>
    `;

    document.getElementById('create-user-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const errEl = document.getElementById('nu-error');
      errEl.hidden = true;
      try {
        await api('/users', {
          method: 'POST',
          json: {
            name: document.getElementById('nu-name').value.trim(),
            email: document.getElementById('nu-email').value.trim(),
            role: document.getElementById('nu-role').value,
            department: document.getElementById('nu-dept').value.trim(),
            password: document.getElementById('nu-pass').value
          }
        });
        toast('User account created.', 'success');
        await renderActiveTab();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.hidden = false;
      }
    });
  }

  // ---------- Shared Filters & Table ----------
  function renderFilterBar({ showDepartment, showDate, showAdminFlags }) {
    const f = state.filters;
    return `
      <div class="filter-bar">
        <input id="flt-search" type="search" placeholder="Search ID, title, location..." value="${esc(f.search)}" style="min-width:200px;flex:1;" />
        <select id="flt-status">
          <option value="">All Statuses</option>
          ${['Open', 'Assigned', 'In Progress', 'Resolved']
            .map((s) => `<option value="${s}" ${f.status === s ? 'selected' : ''}>${s}</option>`)
            .join('')}
        </select>
        <select id="flt-priority">
          <option value="">All Priorities</option>
          ${['Low', 'Medium', 'High', 'Critical']
            .map((p) => `<option value="${p}" ${f.priority === p ? 'selected' : ''}>${p}</option>`)
            .join('')}
        </select>
        <select id="flt-category">
          <option value="">All Categories</option>
          ${['Hardware', 'Software', 'Network', 'Facility']
            .map((c) => `<option value="${c}" ${f.category === c ? 'selected' : ''}>${c}</option>`)
            .join('')}
        </select>
        ${
          showDepartment
            ? `<input id="flt-dept" type="text" placeholder="Department..." value="${esc(f.department)}" style="width:140px;" />`
            : ''
        }
        ${
          showDate
            ? `<input id="flt-from" type="date" value="${esc(f.date_from)}" title="From Date" />
               <input id="flt-to" type="date" value="${esc(f.date_to)}" title="To Date" />`
            : ''
        }
        ${
          showAdminFlags
            ? `<label style="display:inline-flex;align-items:center;gap:4px;font-size:12.5px;">
                 <input id="flt-unassigned" type="checkbox" ${f.unassigned ? 'checked' : ''} /> Unassigned
               </label>
               <label style="display:inline-flex;align-items:center;gap:4px;font-size:12.5px;">
                 <input id="flt-overdue" type="checkbox" ${f.overdue ? 'checked' : ''} /> Overdue SLA
               </label>`
            : ''
        }
        <button type="button" class="btn btn-secondary btn-sm" id="flt-apply">Apply</button>
        <button type="button" class="btn btn-ghost btn-sm" id="flt-reset">Reset</button>
      </div>
    `;
  }

  function wireFilterBar() {
    const apply = () => {
      state.filters.search = document.getElementById('flt-search')?.value.trim() || '';
      state.filters.status = document.getElementById('flt-status')?.value || '';
      state.filters.priority = document.getElementById('flt-priority')?.value || '';
      state.filters.category = document.getElementById('flt-category')?.value || '';
      state.filters.department = document.getElementById('flt-dept')?.value.trim() || '';
      state.filters.date_from = document.getElementById('flt-from')?.value || '';
      state.filters.date_to = document.getElementById('flt-to')?.value || '';
      state.filters.unassigned = Boolean(document.getElementById('flt-unassigned')?.checked);
      state.filters.overdue = Boolean(document.getElementById('flt-overdue')?.checked);
      renderActiveTab();
    };

    document.getElementById('flt-apply')?.addEventListener('click', apply);
    document.getElementById('flt-search')?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') apply();
    });
    document.getElementById('flt-reset')?.addEventListener('click', () => {
      state.filters = {
        status: '',
        priority: '',
        category: '',
        department: '',
        search: '',
        date_from: '',
        date_to: '',
        unassigned: false,
        overdue: false
      };
      renderActiveTab();
    });
  }

  function renderTicketsTable(tickets, { mode }) {
    if (!tickets || tickets.length === 0) {
      return '<div class="empty-state">No tickets match the current view or filters.</div>';
    }

    return `
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Ticket</th>
              <th>Title &amp; Location</th>
              <th>Category</th>
              <th>Priority</th>
              <th>Status</th>
              <th>SLA</th>
              <th>Technician</th>
              <th>Created</th>
              ${mode === 'admin' ? '<th>Quick Assign</th>' : '<th>Action</th>'}
            </tr>
          </thead>
          <tbody>
            ${tickets
              .map((t) => {
                const slaBadge =
                  t.status === 'Resolved'
                    ? `<span class="badge sla-ok">${t.resolution_duration_minutes ?? '—'} min</span>`
                    : t.is_overdue
                    ? `<span class="badge sla-overdue">Overdue</span>`
                    : `<span class="badge sla-ok">${Math.max(0, t.sla_remaining_minutes)}m left</span>`;

                const actionCell =
                  mode === 'admin' && t.status === 'Open'
                    ? `<div class="row-wrap" style="gap:5px;">
                         <select class="quick-tech-select" data-tid="${esc(t.ticket_id)}" style="padding:4px 6px;font-size:12px;">
                           <option value="">Select tech...</option>
                           ${state.technicians
                             .map((tech) => `<option value="${esc(tech.user_id)}">${esc(tech.name)}</option>`)
                             .join('')}
                         </select>
                         <button type="button" class="btn btn-primary btn-sm quick-assign-btn" data-tid="${esc(
                           t.ticket_id
                         )}">Assign</button>
                       </div>`
                    : `<button type="button" class="btn btn-secondary btn-sm open-ticket-btn" data-tid="${esc(
                        t.ticket_id
                      )}">Inspect</button>`;

                return `
                  <tr>
                    <td>
                      <button type="button" class="ticket-id-link open-ticket-btn" data-tid="${esc(t.ticket_id)}">${esc(
                  t.ticket_id
                )}</button>
                      ${t.attachment_count > 0 ? '<div style="font-size:11px;color:var(--muted);">📷 Photo</div>' : ''}
                    </td>
                    <td>
                      <strong>${esc(t.title)}</strong>
                      <div style="font-size:12px;color:var(--muted);">${esc(t.location)} &middot; ${esc(
                  t.department
                )}</div>
                    </td>
                    <td>${esc(t.category)}</td>
                    <td><span class="badge ${prioClass(t.priority)}">${esc(t.priority)}</span></td>
                    <td><span class="badge ${statusClass(t.status)}">${esc(t.status)}</span></td>
                    <td>${slaBadge}</td>
                    <td>${t.technician_name ? esc(t.technician_name) : '<em style="color:var(--muted)">Unassigned</em>'}</td>
                    <td style="font-size:12px;color:var(--muted);">${fmtDate(t.created_at)}</td>
                    <td>${actionCell}</td>
                  </tr>
                `;
              })
              .join('')}
          </tbody>
        </table>
      </div>
    `;
  }

  function wireTicketLinks() {
    document.querySelectorAll('.open-ticket-btn').forEach((btn) => {
      btn.addEventListener('click', () => openTicketModal(btn.dataset.tid));
    });
  }

  function wireQuickAssign() {
    document.querySelectorAll('.quick-assign-btn').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const tid = btn.dataset.tid;
        const select = document.querySelector(`.quick-tech-select[data-tid="${tid}"]`);
        const techId = select?.value;
        if (!techId) {
          toast('Please select a technician first.', 'error');
          return;
        }
        try {
          await api(`/tickets/${tid}/assign`, {
            method: 'PATCH',
            json: { technician_id: techId }
          });
          toast(`${tid} assigned successfully.`, 'success');
          await renderActiveTab();
        } catch (err) {
          toast(err.message, 'error');
        }
      });
    });
  }

  // ---------- Ticket Detail Modal ----------
  async function openTicketModal(ticketId) {
    const modal = document.getElementById('ticket-modal');
    const body = document.getElementById('modal-body');
    const titleEl = document.getElementById('modal-title');
    const kickerEl = document.getElementById('modal-kicker');

    modal.hidden = false;
    kickerEl.textContent = ticketId;
    titleEl.textContent = 'Loading ticket...';
    body.innerHTML = '<div>Loading details...</div>';

    try {
      const data = await api(`/tickets/${encodeURIComponent(ticketId)}`);
      const t = data.ticket;
      renderTicketModalContent(t);
    } catch (err) {
      body.innerHTML = `<div class="alert alert-error">${esc(err.message)}</div>`;
    }
  }

  function renderTicketModalContent(t) {
    const titleEl = document.getElementById('modal-title');
    const kickerEl = document.getElementById('modal-kicker');
    const body = document.getElementById('modal-body');

    kickerEl.innerHTML = `<code>${esc(t.ticket_id)}</code> &middot; <span class="badge ${statusClass(
      t.status
    )}">${esc(t.status)}</span> <span class="badge ${prioClass(t.priority)}">${esc(t.priority)}</span>`;
    titleEl.textContent = t.title;

    const attachmentsHtml =
      t.attachments && t.attachments.length > 0
        ? `<div class="attachment-grid">
             ${t.attachments
               .map(
                 (a) => `
               <div class="attachment-card">
                 <img src="${esc(a.url)}?token=${encodeURIComponent(state.token)}" alt="${esc(a.file_name)}" />
                 <div style="font-size:12px;margin-top:5px;"><strong>${esc(a.file_name)}</strong></div>
                 <div style="font-size:11px;color:var(--muted);">${Math.round(a.file_size / 1024)} KB</div>
               </div>`
               )
               .join('')}
           </div>`
        : '<div class="field-hint">No photo attachments uploaded.</div>';

    const resolutionHtml = t.resolution
      ? `<div class="alert alert-success">
           <strong>Resolution Record (${fmtDate(t.resolution.resolved_at)}):</strong><br>
           ${esc(t.resolution.resolution_note)}
           <div style="font-size:12px;margin-top:4px;">Resolved by ${esc(t.resolution.technician_name || 'Technician')} &middot; Duration: ${t.resolution_duration_minutes} min</div>
         </div>`
      : '';

    const actionsHtml = buildModalRoleActions(t);

    body.innerHTML = `
      <dl class="detail-meta">
        <div><dt>Location</dt><dd>${esc(t.location)}</dd></div>
        <div><dt>Category</dt><dd>${esc(t.category)}</dd></div>
        <div><dt>Department</dt><dd>${esc(t.department)}</dd></div>
        <div><dt>Reporter</dt><dd>${esc(t.reporter_name)}</dd></div>
        <div><dt>Assigned Technician</dt><dd>${esc(t.technician_name || 'Unassigned')}</dd></div>
        <div><dt>Created At</dt><dd>${fmtDate(t.created_at)}</dd></div>
      </dl>

      <div>
        <h4 style="margin:0 0 6px;">Issue Description</h4>
        <div class="card" style="padding:12px;background:var(--surface-alt);">${esc(t.description)}</div>
      </div>

      ${resolutionHtml}
      ${actionsHtml}

      <div>
        <h4 style="margin:0 0 8px;">Photo Evidence</h4>
        ${attachmentsHtml}
      </div>

      <div>
        <h4 style="margin:0 0 8px;">Append-Only Ticket History (${t.history.length})</h4>
        <div class="timeline">
          ${t.history
            .map(
              (h) => `
            <div class="timeline-item">
              <div>
                <strong>${esc(h.old_status ? `${h.old_status} → ${h.new_status}` : `Created (${h.new_status})`)}</strong>
                <span style="color:var(--muted);font-size:12px;"> &middot; ${fmtDate(h.changed_at)}</span>
              </div>
              <div>${esc(h.note)}</div>
              <div style="font-size:12px;color:var(--muted);">By ${esc(h.changed_by_name)} (${esc(h.changed_by_role)})</div>
            </div>`
            )
            .join('')}
        </div>
      </div>
    `;

    wireModalActions(t);
  }

  function buildModalRoleActions(t) {
    const role = state.user.role;
    const blocks = [];

    if (role === 'admin' && t.status === 'Open') {
      blocks.push(`
        <div class="card" style="background:var(--primary-soft);border-color:#bfdbfe;">
          <h4 style="margin:0 0 10px;">Admin Assignment (Open &rarr; Assigned)</h4>
          <div class="form-grid">
            <div class="field">
              <label for="mod-assign-tech">Technician</label>
              <select id="mod-assign-tech">
                <option value="">Select Technician...</option>
                ${state.technicians
                  .map((tech) => `<option value="${esc(tech.user_id)}">${esc(tech.name)} (${esc(tech.department)})</option>`)
                  .join('')}
              </select>
            </div>
            <div class="field">
              <label for="mod-assign-note">Assignment Note (Optional)</label>
              <input id="mod-assign-note" type="text" placeholder="Dispatch instructions..." />
            </div>
          </div>
          <button type="button" class="btn btn-primary btn-sm" id="mod-assign-btn" style="margin-top:10px;">Assign Technician</button>
        </div>
      `);
    }

    if (role === 'admin' && (t.status === 'Assigned' || t.status === 'In Progress')) {
      blocks.push(`
        <div class="card" style="background:var(--warning-soft);border-color:#fde68a;">
          <h4 style="margin:0 0 10px;">Admin Reassign or Return to Open</h4>
          <div class="form-grid">
            <div class="field">
              <label for="mod-reassign-tech">New Technician (for Reassign)</label>
              <select id="mod-reassign-tech">
                <option value="">Select Technician...</option>
                ${state.technicians
                  .map(
                    (tech) =>
                      `<option value="${esc(tech.user_id)}" ${
                        tech.user_id === t.technician_id ? 'selected' : ''
                      }>${esc(tech.name)} (${esc(tech.department)})</option>`
                  )
                  .join('')}
              </select>
            </div>
            <div class="field">
              <label for="mod-reassign-reason">Reason (Required) *</label>
              <input id="mod-reassign-reason" type="text" placeholder="e.g. Shift handover / technician unavailable" />
            </div>
          </div>
          <div class="row-wrap" style="margin-top:10px;">
            <button type="button" class="btn btn-warning btn-sm" id="mod-reassign-btn">Reassign Ticket</button>
            <button type="button" class="btn btn-secondary btn-sm" id="mod-return-open-btn">Return to Open</button>
          </div>
        </div>
      `);
    }

    if (role === 'technician' && t.technician_id === state.user.user_id) {
      if (t.status === 'Assigned') {
        blocks.push(`
          <div class="card" style="background:var(--info-soft);border-color:#bae6fd;">
            <h4 style="margin:0 0 8px;">Technician Action: Start Work</h4>
            <div class="field">
              <label for="mod-start-note">Work Start Note (Optional)</label>
              <input id="mod-start-note" type="text" placeholder="e.g. Heading to lab to inspect workstation..." />
            </div>
            <button type="button" class="btn btn-primary btn-sm" id="mod-start-btn" style="margin-top:10px;">Move to In Progress</button>
          </div>
        `);
      }

      if (t.status === 'In Progress') {
        blocks.push(`
          <div class="card" style="background:var(--success-soft);border-color:#bbf7d0;">
            <h4 style="margin:0 0 8px;">Technician Progress &amp; Resolution</h4>
            <div class="field">
              <label for="mod-progress-note">Add Progress Note</label>
              <div class="row-wrap">
                <input id="mod-progress-note" type="text" placeholder="e.g. Ordered replacement power cable..." style="flex:1;" />
                <button type="button" class="btn btn-secondary btn-sm" id="mod-progress-btn">Save Note</button>
              </div>
            </div>
            <hr style="border:none;border-top:1px solid #bbf7d0;margin:12px 0;" />
            <div class="field">
              <label for="mod-resolution-note">Final Resolution Note (Required to Resolve) *</label>
              <textarea id="mod-resolution-note" rows="2" placeholder="Describe root cause and exact fix applied..."></textarea>
            </div>
            <button type="button" class="btn btn-success btn-sm" id="mod-resolve-btn" style="margin-top:10px;">Mark Resolved</button>
          </div>
        `);
      }
    }

    if (role === 'reporter' && t.reporter_id === state.user.user_id) {
      blocks.push(`
        <div class="card" style="background:var(--surface-alt);">
          <h4 style="margin:0 0 8px;">Add Reporter Note or Follow-up Feedback</h4>
          <div class="row-wrap">
            <input id="mod-reporter-note" type="text" placeholder="Add clarification or post-resolution feedback..." style="flex:1;" />
            <button type="button" class="btn btn-secondary btn-sm" id="mod-reporter-note-btn">Post Comment</button>
          </div>
        </div>
      `);
    }

    return blocks.join('');
  }

  function wireModalActions(t) {
    document.getElementById('mod-assign-btn')?.addEventListener('click', async () => {
      const techId = document.getElementById('mod-assign-tech').value;
      const note = document.getElementById('mod-assign-note').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/assign`, {
          method: 'PATCH',
          json: { technician_id: techId, note }
        });
        toast('Ticket assigned.', 'success');
        renderTicketModalContent(res.ticket);
        await renderActiveTab();
      } catch (err) {
        toast(err.message, 'error');
      }
    });

    document.getElementById('mod-reassign-btn')?.addEventListener('click', async () => {
      const techId = document.getElementById('mod-reassign-tech').value;
      const reason = document.getElementById('mod-reassign-reason').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/assign`, {
          method: 'PATCH',
          json: { technician_id: techId, reassign: true, reason }
        });
        toast('Ticket reassigned.', 'success');
        renderTicketModalContent(res.ticket);
        await renderActiveTab();
      } catch (err) {
        toast(err.message, 'error');
      }
    });

    document.getElementById('mod-return-open-btn')?.addEventListener('click', async () => {
      const reason = document.getElementById('mod-reassign-reason').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/status`, {
          method: 'PATCH',
          json: { status: 'Open', reason }
        });
        toast('Ticket returned to Open.', 'success');
        renderTicketModalContent(res.ticket);
        await renderActiveTab();
      } catch (err) {
        toast(err.message, 'error');
      }
    });

    document.getElementById('mod-start-btn')?.addEventListener('click', async () => {
      const note = document.getElementById('mod-start-note').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/status`, {
          method: 'PATCH',
          json: { status: 'In Progress', note }
        });
        toast('Ticket moved to In Progress.', 'success');
        renderTicketModalContent(res.ticket);
        await renderActiveTab();
      } catch (err) {
        toast(err.message, 'error');
      }
    });

    document.getElementById('mod-progress-btn')?.addEventListener('click', async () => {
      const note = document.getElementById('mod-progress-note').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/notes`, {
          method: 'POST',
          json: { note }
        });
        toast('Progress note saved.', 'success');
        renderTicketModalContent(res.ticket);
      } catch (err) {
        toast(err.message, 'error');
      }
    });

    document.getElementById('mod-resolve-btn')?.addEventListener('click', async () => {
      const resolution_note = document.getElementById('mod-resolution-note').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/status`, {
          method: 'PATCH',
          json: { status: 'Resolved', resolution_note }
        });
        toast('Ticket resolved.', 'success');
        renderTicketModalContent(res.ticket);
        await renderActiveTab();
      } catch (err) {
        toast(err.message, 'error');
      }
    });

    document.getElementById('mod-reporter-note-btn')?.addEventListener('click', async () => {
      const note = document.getElementById('mod-reporter-note').value.trim();
      try {
        const res = await api(`/tickets/${t.ticket_id}/notes`, {
          method: 'POST',
          json: { note }
        });
        toast('Comment added.', 'success');
        renderTicketModalContent(res.ticket);
      } catch (err) {
        toast(err.message, 'error');
      }
    });
  }

  // ---------- Event Wiring ----------
  async function handleLogin(email, password) {
    const errEl = document.getElementById('login-error');
    errEl.hidden = true;
    try {
      const data = await api('/auth/login', {
        method: 'POST',
        json: { email, password }
      });
      saveSession(data.token, data.user);
      state.activeTab = defaultTabForRole(data.user.role);
      toast(`Signed in as ${data.user.name} (${data.user.role})`, 'success');
      await renderApp();
    } catch (err) {
      errEl.textContent = err.message;
      errEl.hidden = false;
    }
  }

  document.addEventListener('DOMContentLoaded', async () => {
    loadSession();

    document.getElementById('login-form').addEventListener('submit', (e) => {
      e.preventDefault();
      handleLogin(
        document.getElementById('login-email').value.trim(),
        document.getElementById('login-password').value
      );
    });

    document.querySelectorAll('.demo-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.getElementById('login-email').value = btn.dataset.email;
        document.getElementById('login-password').value = btn.dataset.pass;
        handleLogin(btn.dataset.email, btn.dataset.pass);
      });
    });

    const toggleDemoDrawer = () => {
      const drawer = document.getElementById('demo-drawer');
      if (drawer) drawer.hidden = !drawer.hidden;
    };

    document.getElementById('toggle-demo-btn')?.addEventListener('click', toggleDemoDrawer);
    document.getElementById('show-creds-link')?.addEventListener('click', toggleDemoDrawer);
    document.getElementById('bottom-demo-link')?.addEventListener('click', () => {
      const drawer = document.getElementById('demo-drawer');
      if (drawer) drawer.hidden = false;
    });

    document.getElementById('toggle-password-vis')?.addEventListener('click', () => {
      const pwdInput = document.getElementById('login-password');
      if (!pwdInput) return;
      pwdInput.type = pwdInput.type === 'password' ? 'text' : 'password';
    });

    document.getElementById('logout-btn').addEventListener('click', async () => {
      try {
        await api('/auth/logout', { method: 'POST' });
      } catch {
        // ignore logout failure
      }
      clearSession();
      renderApp();
    });

    document.getElementById('modal-close').addEventListener('click', () => {
      document.getElementById('ticket-modal').hidden = true;
    });

    document.getElementById('ticket-modal').addEventListener('click', (e) => {
      if (e.target.id === 'ticket-modal') {
        document.getElementById('ticket-modal').hidden = true;
      }
    });

    if (state.token) {
      try {
        const me = await api('/auth/me');
        state.user = me.user;
      } catch {
        clearSession();
      }
    }
    renderApp();
  });
})();
