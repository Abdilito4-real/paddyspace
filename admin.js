// ================================================================
//  PADDY SPACE ADMIN — Real-Time Dashboard
//  • Supabase Realtime subscriptions on all tables
//  • Live clock + auto-refresh every 30 s
//  • Full CRUD: confirm / cancel / check-in / check-out
//  • Revenue chart from DB (monthly rollup)
//  • Dining panel live data
//  • Revenue panel live data
//  • Guest profile modal with full history
// ================================================================

const SUPABASE_URL = 'https://naxvssbtocfyxleaxfom.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5heHZzc2J0b2NmeXhsZWF4Zm9tIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM5NDQxNjMsImV4cCI6MjA4OTUyMDE2M30.dw3DO9qhanod64_m-CCJ_5wLDrhDcP521O8mLW-cLgU';

// ================================================================
// 1. SUPABASE SERVICE — all reads via SECURITY DEFINER RPC functions
// ================================================================
class SupabaseService {
  constructor() {
    if (!window.supabase) { console.error('[Admin] Supabase SDK not loaded'); return; }
    this.client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
      realtime: { params: { eventsPerSecond: 10 } }
    });
    this.channels = [];
  }

  // ── Helpers ───────────────────────────────────────────────
  async rpc(fn, params = {}) {
    if (!this.client) return null;
    const { data, error } = await this.client.rpc(fn, params);
    if (error) { console.error(`[RPC] ${fn}:`, error.message, error); return null; }
    return data;
  }

  // ── Dashboard ─────────────────────────────────────────────
  async getDashboardStats() {
    const data = await this.rpc('get_dashboard_stats_admin');
    if (!data) return null;
    return {
      pendingCount: data.pending_count || 0,
      activeGuests: data.active_guests || 0,
      totalGuests:  data.total_guests  || 0,
      occupancy:    data.occupancy     || [],
      revenue:      data.revenue       || {},
    };
  }

  async getMonthlyRevenueTrend() {
    const data = await this.rpc('get_revenue_trend_admin');
    if (!data) return [];
    const currentMonth = new Date().toLocaleString('en', { month: 'short', year: 'numeric' });
    return (data || []).map(row => ({
      month:     row.month.slice(0, 3),  // 'Jan', 'Feb' etc
      total:     parseFloat(row.total_revenue) / 1_000_000,
      isCurrent: row.month === currentMonth,
    }));
  }

  // ── Reservations ──────────────────────────────────────────
  async getReservations() {
    const rows = await this.rpc('get_reservations_admin');
    if (!rows) return [];
    // Reshape flat RPC result into nested structure UI expects
    return rows.map(r => ({
      id:               r.id,
      ref_code:         r.ref_code,
      status:           r.status,
      check_in_date:    r.check_in_date,
      check_out_date:   r.check_out_date,
      nights:           r.nights,
      total_amount:     r.total_amount,
      payment_status:   r.payment_status,
      special_requests: r.special_requests,
      arrival_time:     r.arrival_time,
      created_at:       r.created_at,
      guest_id:         r.guest_id,
      guests: {
        id:        r.guest_id,
        first_name: r.guest_first,
        last_name:  r.guest_last,
        email:      r.guest_email,
        phone:      r.guest_phone,
        vip_level:  r.guest_vip,
      },
      rooms: {
        room_number: r.room_number,
        room_type:   r.room_type,
      },
    }));
  }

  async updateReservationStatus(id, status) {
    const ok = await this.rpc('update_reservation_status_admin', { p_id: id, p_status: status });
    return ok !== null;
  }

  async createReservationAdmin({ firstName, lastName, email, phone, roomType, checkIn, checkOut, notes }) {
    const data = await this.rpc('create_reservation', {
      p_first_name: firstName, p_last_name: lastName,
      p_email: email, p_phone: phone || null,
      p_room_type: roomType,
      p_check_in: checkIn, p_check_out: checkOut,
      p_special_requests: notes || null,
    });
    return data || { error: 'Could not create reservation — check room availability and dates' };
  }

  // ── Rooms ─────────────────────────────────────────────────
  async getRooms() {
    const rows = await this.rpc('get_rooms_admin');
    if (!rows) return [];
    return rows.map(r => ({ ...r, currentGuest: r.current_guest || null }));
  }

  async updateRoomStatus(id, status, notes = null) {
    const ok = await this.rpc('update_room_status_admin', { p_id: id, p_status: status, p_notes: notes });
    return ok !== null;
  }

  async createRoom({ roomNumber, roomType, floor, sizeSqm, view, maxOccupancy, basePrice, amenities, description, notes }) {
    const data = await this.rpc('create_room_admin', {
      p_room_number: roomNumber, p_room_type: roomType,
      p_floor: parseInt(floor), p_size_sqm: sizeSqm ? parseFloat(sizeSqm) : null,
      p_view: view || null, p_max_occupancy: parseInt(maxOccupancy) || 2,
      p_base_price: parseFloat(basePrice) || 85000,
      p_amenities: amenities?.length ? amenities : null,
      p_description: description || null, p_notes: notes || null,
    });
    return data || { success: false, error: 'Could not create room' };
  }

  async updateRoom({ id, roomNumber, roomType, floor, sizeSqm, view, maxOccupancy, basePrice, amenities, description, notes }) {
    const ok = await this.rpc('update_room_admin', {
      p_id: id, p_room_number: roomNumber, p_room_type: roomType,
      p_floor: parseInt(floor), p_size_sqm: sizeSqm ? parseFloat(sizeSqm) : null,
      p_view: view || null, p_max_occupancy: parseInt(maxOccupancy) || 2,
      p_base_price: parseFloat(basePrice) || 85000,
      p_amenities: amenities?.length ? amenities : null,
      p_description: description || null, p_notes: notes || null,
    });
    return ok !== null;
  }

  async toggleRoomAvailability(id) {
    const data = await this.rpc('toggle_room_availability_admin', { p_id: id });
    return data || { success: false, error: 'Could not toggle availability' };
  }

  async deleteRoom(id) {
    const data = await this.rpc('delete_room_admin', { p_id: id });
    return data || { success: false, error: 'Could not delete room' };
  }

  // ── Guests ────────────────────────────────────────────────
  async getGuests() {
    const data = await this.rpc('get_guests_admin');
    return data || [];
  }

  async getGuestDetails(id) {
    const data = await this.rpc('get_guest_detail_admin', { p_guest_id: id });
    if (!data) return null;
    return { ...data.guest, history: data.history || [] };
  }

  async updateGuestNotes(id, notes) {
    const ok = await this.rpc('update_guest_notes_admin', { p_guest_id: id, p_notes: notes });
    return ok !== null;
  }

  // ── Dining ────────────────────────────────────────────────
  async getDiningReservations() {
    const rows = await this.rpc('get_dining_reservations_admin');
    if (!rows) return [];
    // Reshape to match UI expectations
    return rows.map(r => ({
      id:               r.id,
      status:           r.status,
      guest_name:       r.guest_name,
      guest_phone:      r.guest_phone,
      covers:           r.covers,
      reservation_date: r.reservation_date,
      reservation_time: r.reservation_time,
      occasion:         r.occasion,
      confirmed_at:     r.confirmed_at,
      seated_at:        r.seated_at,
      dining_tables: {
        table_number: r.table_number,
        dining_areas: { name: r.area_name },
      },
    }));
  }

  async updateDiningStatus(id, status) {
    const ok = await this.rpc('update_dining_status_admin', { p_id: id, p_status: status });
    return ok !== null;
  }

  async getDiningStats() {
    // Derive from dining reservations we already have
    const rows = await this.rpc('get_dining_reservations_admin');
    if (!rows) return { seatedCovers: 0, confirmedCount: 0, totalTables: 0 };
    const today = new Date().toISOString().split('T')[0];
    const todayRows = rows.filter(r => r.reservation_date === today);
    const seatedCovers  = todayRows.filter(r => r.status === 'seated').reduce((s, r) => s + (r.covers || 0), 0);
    const confirmedCount = todayRows.filter(r => r.status === 'confirmed').length;
    return { seatedCovers, confirmedCount, totalTables: 0 };
  }

  // ── Activity log ──────────────────────────────────────────
  async getAuditLogs(limit = 12) {
    const data = await this.rpc('get_audit_log_admin', { p_limit: limit });
    return data || [];
  }

  async getTodayArrivals() {
    const data = await this.rpc('get_arrivals_today_admin');
    return data || [];
  }

  async getTodayDepartures() {
    const data = await this.rpc('get_departures_today_admin');
    return data || [];
  }

  // ── Realtime subscriptions ────────────────────────────────
  subscribeAll(callbacks) {
    if (!this.client?.channel) return;

    const tables = [
      { table: 'reservations', key: 'onReservationChange' },
      { table: 'rooms',        key: 'onRoomChange'        },
      { table: 'guests',       key: 'onGuestChange'       },
      { table: 'dining_reservations', key: 'onDiningChange' },
    ];

    this.channels = tables.map(({ table, key }) =>
      this.client.channel(`realtime:${table}`)
        .on('postgres_changes', { event: '*', schema: 'public', table }, payload => {
          callbacks[key]?.(payload);
        })
        .subscribe(status => {
          if (status === 'SUBSCRIBED') console.log(`[Admin RT] ${table} live ✓`);
          if (status === 'CHANNEL_ERROR') console.warn(`[Admin RT] ${table} error — polling only`);
        })
    );
  }

  unsubscribeAll() {
    this.channels.forEach(ch => { try { this.client?.removeChannel(ch); } catch(e) {} });
    this.channels = [];
  }
}

// 2. UI MANAGER
// ================================================================
class UIManager {
  constructor() {
    this.panels   = document.querySelectorAll('.panel');
    this.links    = document.querySelectorAll('.sidebar-link');
    this.titles   = {
      dashboard: 'Dashboard', reservations: 'Reservations',
      rooms: 'Room Management', guests: 'Guests',
      dining: 'Dining & Tables', revenue: 'Revenue Analytics', settings: 'Settings',
    };
  }

  showPanel(id) {
    this.panels.forEach(p => p.classList.remove('active'));
    this.links.forEach(l => l.classList.remove('active'));
    document.getElementById('panel-' + id)?.classList.add('active');
    this.links.forEach(l => { if (l.getAttribute('onclick')?.includes(`'${id}'`)) l.classList.add('active'); });
    document.getElementById('page-title').textContent  = this.titles[id] || id;
    document.getElementById('breadcrumb').textContent  = 'Admin / ' + (this.titles[id] || id);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  showToast(msg, type = 'info', title = '') {
    const c      = document.getElementById('admin-toast-container');
    const icons = {
      success: '<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="1.5,5 4,7.5 8.5,2.5"/></svg>',
      error:   '<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/><line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/></svg>',
      info:    '<svg width="10" height="10" viewBox="0 0 10 10" fill="currentColor"><circle cx="5" cy="5" r="1.5"/><rect x="4.2" y="5.5" width="1.6" height="3" rx=".6"/></svg>',
    };
    const titles = { success: 'Done', error: 'Error', info: 'Paddy Space Admin' };
    const el     = document.createElement('div');
    el.className = 'toast-item';
    el.innerHTML = `<div class="toast-icon ${type}">${icons[type]}</div>
      <div class="toast-body">
        <div class="toast-title">${title || titles[type]}</div>
        <div class="toast-msg">${msg}</div>
      </div>`;
    c.appendChild(el);
    requestAnimationFrame(() => el.classList.add('show'));
    setTimeout(() => { el.classList.remove('show'); el.classList.add('hide'); setTimeout(() => el.remove(), 400); }, 4500);
  }

  toggleModal(id, open = true) {
    const el = document.getElementById(id);
    if (el) open ? el.classList.add('open') : el.classList.remove('open');
  }

  /** Show a loading skeleton in a container */
  skeleton(containerId, rows = 3) {
    const el = document.getElementById(containerId);
    if (!el) return;
    el.innerHTML = Array.from({ length: rows }, () =>
      `<div class="activity-item"><div style="height:12px;background:rgba(201,168,76,.06);width:70%;border-radius:1px;animation:skeleton-pulse 1.4s ease infinite"></div></div>`
    ).join('');
  }

  /** Update a stat card by index (0-3) in a given panel */
  setStatCard(panelId, index, { value, sub, trend, trendUp }) {
    const cards = document.querySelectorAll(`#panel-${panelId} .stat-card`);
    const card  = cards[index];
    if (!card) return;
    if (value !== undefined) card.querySelector('.stat-value').innerHTML = value;
    if (sub   !== undefined) card.querySelector('.stat-sub').textContent  = sub;
    if (trend !== undefined) {
      const el = card.querySelector('.stat-trend');
      el.textContent = trend;
      el.className   = 'stat-trend ' + (trendUp ? 'up' : 'down');
    }
  }

  /** Build the revenue bar chart */
  buildRevChart(containerId, data) {
    const el = document.getElementById(containerId);
    if (!el || !data.length) return;
    const maxV = Math.max(...data.map(d => d.total), 0.1);
    el.innerHTML = data.map(d => `
      <div class="rev-bar-col">
        <div class="rev-bar${d.isCurrent ? ' current' : ''}"
          style="height:${Math.round((d.total / maxV) * 100)}%;min-height:4px"
          data-val="₦${d.total.toFixed(1)}M"></div>
        <div class="rev-month">${d.month}</div>
      </div>`).join('');
  }

  /** Build occupancy bars by room type */
  buildOccBars(containerId, occupancyData) {
    const el = document.getElementById(containerId);
    if (!el) return;
    const labels = { deluxe: 'Deluxe', junior_suite: 'Junior Suites', grand_suite: 'Grand Suites', penthouse: 'Penthouse' };
    el.innerHTML = occupancyData.map(d => {
      const pct = parseFloat(d.occupancy_pct) || 0;
      const cls = pct < 40 ? 'low' : pct < 70 ? 'med' : '';
      return `
        <div class="occ-row">
          <div class="occ-label">${labels[d.room_type] || d.room_type}</div>
          <div class="occ-track"><div class="occ-fill ${cls}" style="width:${pct}%"></div></div>
          <div class="occ-pct">${pct.toFixed(0)}%</div>
        </div>`;
    }).join('') || '<div style="font-size:.75rem;color:rgba(245,239,228,.3);padding:.5rem 0">No data yet</div>';
  }

  /** Format currency */
  fmtMoney(n) { return '₦' + (parseFloat(n) || 0).toLocaleString('en-NG', { maximumFractionDigits: 0 }); }
  fmtMillions(n) { return '₦' + ((parseFloat(n) || 0) / 1_000_000).toFixed(2) + 'M'; }

  /** Animate a numeric counter from 0 to target value */
  animateCounter(selector, target, duration = 1400) {
    const el = document.querySelector(selector);
    if (!el || target <= 0) return;
    const start     = performance.now();
    const startVal  = 0;
    const endVal    = parseFloat(target);
    const fmt       = (v) => '₦' + Math.round(v).toLocaleString('en-NG');
    const ease      = (t) => t < .5 ? 2*t*t : -1+(4-2*t)*t; // ease-in-out
    const tick      = (now) => {
      const elapsed = now - start;
      const progress = Math.min(elapsed / duration, 1);
      el.innerHTML = fmt(startVal + (endVal - startVal) * ease(progress));
      if (progress < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  timeAgo(dateStr) {
    if (!dateStr) return '—';
    const sec = Math.floor((Date.now() - new Date(dateStr)) / 1000);
    if (sec < 60)    return 'Just now';
    if (sec < 3600)  return Math.floor(sec / 60)   + ' min ago';
    if (sec < 86400) return Math.floor(sec / 3600)  + ' hr ago';
    return Math.floor(sec / 86400) + ' days ago';
  }

  pillClass(status) {
    const map = {
      pending: 'pending', confirmed: 'confirmed', checked_in: 'checkedin',
      checked_out: 'confirmed', cancelled: 'cancelled', no_show: 'cancelled',
      available: 'available', occupied: 'occupied', maintenance: 'maintenance',
      housekeeping: 'maintenance', seated: 'checkedin', completed: 'confirmed',
    };
    return 'pill pill-' + (map[status] || 'pending');
  }
}

// ================================================================
// 3. DASHBOARD CONTROLLER
// ================================================================
class DashboardController {
  constructor(svc, ui) {
    this.svc          = svc;
    this.ui           = ui;
    this.refreshTimer = null;
    this.clockTimer   = null;
    this.currentPanel = 'dashboard';
    this.init();
  }

  // ── Initialization ─────────────────────────────────────────
  async init() {
    this._bindGlobals();
    this._startClock();
    this._bindKeyboard();

    // Initial data load (all panels in parallel)
    await this.refreshAll();

    // Supabase Realtime — push-based updates
    this.svc.subscribeAll({
      onReservationChange: (payload) => this._onRealtimeChange('reservation', payload),
      onRoomChange:        (payload) => this._onRealtimeChange('room', payload),
      onGuestChange:       (payload) => this._onRealtimeChange('guest', payload),
      onDiningChange:      (payload) => this._onRealtimeChange('dining', payload),
    });

    // Polling fallback every 30 s (catches changes Realtime might miss)
    this.refreshTimer = setInterval(() => this.refreshAll(), 30_000);
  }

  _bindGlobals() {
    window.showPanel            = (id) => { this.currentPanel = id; this.ui.showPanel(id); this._loadPanel(id); };
    window.showToast            = (m, t, l) => this.ui.showToast(m, t, l);
    window.openNewReservation   = () => this._openNewReservation();
    window.submitNewReservation = () => this._submitNewReservation();
    window.confirmReservation   = (id, name) => this._updateResStatus(id, 'confirmed', name);
    window.cancelReservation    = (id) => this._cancelReservation(id);
    window.checkInGuest         = (id, name) => this._updateResStatus(id, 'checked_in', name);
    window.checkOutGuest        = (id, name) => this._updateResStatus(id, 'checked_out', name);
    window.viewGuest            = (id) => this._viewGuestProfile(id);
    window.roomAction           = (id, num, status) => this._roomAction(id, num, status);
    window.filterTable          = (el, tableId) => this._filterTable(el, tableId);
    window.filterByStatus       = (sel) => this._filterTable(sel, 'res-table', true);
    window.filterRoomGrid       = () => this._filterRoomGrid();
    window.confirmDining        = (id, name) => this._updateDiningStatus(id, 'confirmed', name);
    window.seatDining           = (id, name) => this._updateDiningStatus(id, 'seated', name);
    window.saveSettings         = () => this._saveSettings();
    window.openAddRoom          = () => this._openRoomModal();
    window.openEditRoom         = (id) => this._openRoomModal(id);
    window.submitRoomForm       = () => this._submitRoomForm();
    window.deleteRoom           = (id, num) => this._deleteRoom(id, num);
    window.toggleAvailability   = (id) => this._toggleAvailability(id);
    window.closeRoomModal       = () => this.ui.toggleModal('roomModal', false);
    window.jumpToRef            = () => this._jumpToRef();
    window.manualRefresh        = () => { this.refreshAll(); this.ui.showToast('Refreshed', 'success', 'Data Updated'); };
    window.closeAdmModal        = (e) => { if (e.target === e.currentTarget) e.currentTarget.classList.remove('open'); };
    window.closeGuestModal      = (e) => { if (e.target === e.currentTarget) this.ui.toggleModal('guestDetailModal', false); };
    document.addEventListener('keydown', e => { if (e.key === 'Escape') { document.querySelectorAll('.adm-modal-overlay.open').forEach(m => m.classList.remove('open')); } });
  }

  // ... (rest of methods like _startClock, _bindKeyboard, _onRealtimeChange, _prependActivity, etc. are implicitly included as part of the extraction)
  // For brevity in diff, I am assuming the user copies the full block.
  // The content above shows the structure.
  // The actual file creation will contain the Full JS code from admin.html

  _startClock() { /* ... implementation from original ... */
    const tick = () => {
      const now = new Date();
      const timeStr = now.toLocaleTimeString('en-NG', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
      const dateStr = now.toLocaleDateString('en-NG', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
      const el = document.getElementById('live-clock');
      if (el) el.textContent = timeStr;
      const el2 = document.getElementById('live-date');
      if (el2) el2.textContent = dateStr;
    };
    tick();
    this.clockTimer = setInterval(tick, 1000);
  }
  _bindKeyboard() { /* ... */
    document.addEventListener('keydown', e => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'r' && e.shiftKey) {
        e.preventDefault();
        this.refreshAll();
        this.ui.showToast('Data refreshed', 'success', 'Refreshed');
      }
    });
  }
  _onRealtimeChange(type, payload) { /* ... */
    const labels = { reservation: 'Reservations', room: 'Rooms', guest: 'Guests', dining: 'Dining' };
    const eventLabels = { INSERT: 'New', UPDATE: 'Updated', DELETE: 'Removed' };
    const colors = { reservation: 'gold', room: 'blue', guest: 'green', dining: 'gold' };
    this._prependActivity({
      color: colors[type] || 'gold',
      text:  `${eventLabels[payload.eventType] || payload.eventType}: ${labels[type]}`,
      time:  'Just now',
    });
    const reloaders = {
      reservation: () => { this.loadStats(); this.loadReservations(); this.loadArrivals(); },
      room:        () => { this.loadRooms(); this.loadStats(); },
      guest:       () => this.loadGuests(),
      dining:      () => { this.loadDining(); },
    };
    reloaders[type]?.();
  }
  _prependActivity({ color, text, time }) { /* ... */
    const feed = document.getElementById('feed-list');
    if (!feed) return;
    const el = document.createElement('div');
    el.className = 'activity-item';
    el.style.opacity = '0';
    el.innerHTML = `<div class="act-dot ${color}"></div>
      <div><div class="act-text">${text}</div><div class="act-time">${time}</div></div>`;
    feed.prepend(el);
    requestAnimationFrame(() => { el.style.transition = 'opacity .4s'; el.style.opacity = '1'; });
    while (feed.children.length > 12) feed.lastChild.remove();
  }
  async refreshAll() { /* ... */
    const indicator = document.getElementById('refresh-indicator');
    if (indicator) { indicator.style.opacity = '1'; }
    await Promise.all([
      this.loadStats(),
      this.loadReservations(),
      this.loadRooms(),
      this.loadGuests(),
      this.loadActivityFeed(),
      this.loadArrivals(),
      this.loadRevenueTrend(),
      this.loadDining(),
    ]);
    if (indicator) {
      indicator.textContent = 'Updated ' + new Date().toLocaleTimeString('en-NG', { hour: '2-digit', minute: '2-digit' });
      setTimeout(() => { if (indicator) indicator.style.opacity = '.4'; }, 1500);
    }
  }
  _loadPanel(id) { /* ... */
    const loaders = {
      dashboard:    () => { this.loadStats(); this.loadActivityFeed(); this.loadArrivals(); this.loadRevenueTrend(); },
      reservations: () => this.loadReservations(),
      rooms:        () => this.loadRooms(),
      guests:       () => this.loadGuests(),
      dining:       () => this.loadDining(),
      revenue:      () => { this.loadRevenueTrend(); this.loadRevenuePanel(); },
    };
    loaders[id]?.();
  }
  async loadStats() { /* ... */
    const stats = await this.svc.getDashboardStats();
    if (!stats) return;
    let totalRooms = 0, occupiedRooms = 0;
    stats.occupancy.forEach(r => { totalRooms += (r.total_rooms || 0); occupiedRooms += (r.occupied || 0); });
    const occPct = totalRooms > 0 ? Math.round((occupiedRooms / totalRooms) * 100) : 0;
    this.ui.setStatCard('dashboard', 0, {
      value:   `${occPct}<span style="font-size:1.4rem;color:var(--gold-dim)">%</span>`,
      sub:     `${occupiedRooms} of ${totalRooms} rooms occupied`,
      trend:   `● ${occPct >= 70 ? 'Strong' : occPct >= 40 ? 'Moderate' : 'Low'} occupancy`,
      trendUp: occPct >= 50,
    });
    const rev = parseFloat(stats.revenue.total_revenue || 0);
    this.ui.setStatCard('dashboard', 1, {
      value: this.ui.fmtMoney(rev),
      sub:   'Month to Date',
      trend: '▲ Room + F&B + Spa',
      trendUp: true,
    });
    // Animate counter from 0 up to actual value
    this.ui.animateCounter('#panel-dashboard .stat-card:nth-child(2) .stat-value', rev);
    this.ui.setStatCard('dashboard', 2, {
      value: String(stats.activeGuests),
      sub:   `of ${stats.totalGuests} registered guests`,
      trend: `● ${stats.activeGuests} in-house`,
      trendUp: true,
    });
    this.ui.setStatCard('dashboard', 3, {
      value: `<span style="color:var(--warning)">${stats.pendingCount}</span>`,
      sub:   'Reservations awaiting',
      trend: stats.pendingCount > 0 ? `● Requires attention` : '● All clear',
      trendUp: stats.pendingCount === 0,
    });
    const badge = document.getElementById('pending-badge');
    if (badge) badge.textContent = stats.pendingCount;
    this.ui.buildOccBars(
      document.querySelector('#panel-dashboard .occ-bar-wrap'),
      stats.occupancy
    );
  }
  async loadRevenueTrend() { /* ... */
    const data = await this.svc.getMonthlyRevenueTrend();
    this.ui.buildRevChart('revChart',  data);
    this.ui.buildRevChart('revChart2', data);
  }
  async loadRevenuePanel() { /* ... */
    const stats = await this.svc.getDashboardStats();
    if (!stats) return;
    const rev = stats.revenue;
    const panels = document.querySelectorAll('#panel-revenue .stat-card');
    if (panels[0]) panels[0].querySelector('.stat-value').innerHTML = this.ui.fmtMillions(rev.total_revenue || 0);
    if (panels[1]) panels[1].querySelector('.stat-value').innerHTML = this.ui.fmtMillions(rev.room_revenue  || 0);
    if (panels[2]) panels[2].querySelector('.stat-value').innerHTML = this.ui.fmtMillions(rev.extras_revenue || 0);
  }
  async loadReservations() { /* ... */
    const data  = await this.svc.getReservations();
    const tbody = document.querySelector('#res-table tbody');
    if (!tbody) return;
    if (!data.length) {
      tbody.innerHTML = `<tr><td colspan="9" style="text-align:center;padding:2rem;color:rgba(245,239,228,.3);font-size:.8rem">No reservations found</td></tr>`;
      return;
    }
    tbody.innerHTML = data.map(r => {
      const name    = r.guests ? `${r.guests.first_name} ${r.guests.last_name}` : 'Unknown';
      const email   = r.guests?.email || '';
      const phone   = r.guests?.phone || '';
      const vip     = r.guests?.vip_level > 0 ? ` <span style="color:var(--gold);font-size:.55rem;display:inline-flex;align-items:center;gap:.15rem"><svg xmlns='http://www.w3.org/2000/svg' width='9' height='9' viewBox='0 0 24 24' fill='#c9a84c'><polygon points='12,2 15.09,8.26 22,9.27 17,14.14 18.18,21.02 12,17.77 5.82,21.02 7,14.14 2,9.27 8.91,8.26'/></svg>VIP</span>` : '';
      const room    = r.rooms  ? `${r.rooms.room_type.replace('_',' ')} · ${r.rooms.room_number}` : '—';
      const ciDate  = r.check_in_date  ? new Date(r.check_in_date  + 'T12:00:00').toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric' }) : '—';
      const coDate  = r.check_out_date ? new Date(r.check_out_date + 'T12:00:00').toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric' }) : '—';
      const actions = [];
      if (phone) actions.push(`<a href="tel:${phone}" class="act-btn act-btn-icon" title="Call ${name}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07A19.5 19.5 0 013.07 9.81 19.79 19.79 0 01.0 1.18 2 2 0 012 0h3a2 2 0 012 1.72c.127.96.361 1.903.7 2.81a2 2 0 01-.45 2.11L6.91 7.91a16 16 0 006.16 6.16l1.27-1.27a2 2 0 012.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0122 16.92z"/>
          </svg>Call</a>`);
      if (email) actions.push(`<a href="mailto:${email}" class="act-btn act-btn-icon" title="Email ${name}">
          <svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/>
            <polyline points="22,6 12,13 2,6"/>
          </svg>Email</a>`);
      if (r.status === 'pending')    actions.push(`<button class="act-btn" onclick="confirmReservation('${r.id}','${name.replace(/'/g,"\\'")}')" title="Confirm">Confirm</button>`);
      if (r.status === 'confirmed')  actions.push(`<button class="act-btn" onclick="checkInGuest('${r.id}','${name.replace(/'/g,"\\'")}')" title="Check In">Check In</button>`);
      if (r.status === 'checked_in') actions.push(`<button class="act-btn" onclick="checkOutGuest('${r.id}','${name.replace(/'/g,"\\'")}')" title="Check Out">Check Out</button>`);
      if (r.status !== 'cancelled' && r.status !== 'checked_out') actions.push(`<button class="act-btn danger" onclick="cancelReservation('${r.id}')" title="Cancel">Cancel</button>`);
      actions.push(`<button class="act-btn" onclick="viewGuest('${r.guest_id}')">Profile</button>`);
      return `<tr data-status="${r.status}">
        <td><span style="font-family:'Cormorant Garamond',serif;font-size:1.05rem;letter-spacing:.08em;color:var(--gold);display:block;">${r.ref_code}</span></td>
        <td class="td-name">${name}${vip}</td><td class="td-room">${room}</td>
        <td>${ciDate}</td><td>${coDate}</td><td style="text-align:center">${r.nights || '—'}</td>
        <td>${this.ui.fmtMoney(r.total_amount)}</td>
        <td><span class="${this.ui.pillClass(r.status)}">${r.status.replace(/_/g,' ')}</span></td>
        <td style="display:flex;gap:.3rem;flex-wrap:wrap">${actions.join('')}</td></tr>`;
    }).join('');
  }
  async _updateResStatus(id, status, name = '') { /* ... */
    const labels = { confirmed: 'Confirmed', checked_in: 'Checked in', checked_out: 'Checked out' };
    const ok = await this.svc.updateReservationStatus(id, status);
    if (ok) {
      this.ui.showToast(`${labels[status] || status} — ${name}`, 'success', 'Status Updated');
      this.loadReservations(); this.loadStats(); this.loadRooms();
    } else { this.ui.showToast('Could not update status. Please try again.', 'error'); }
  }
  async _cancelReservation(id) { /* ... */
    if (!confirm('Cancel this reservation? This cannot be undone.')) return;
    const ok = await this.svc.updateReservationStatus(id, 'cancelled');
    if (ok) {
      this.ui.showToast('Reservation cancelled. Guest will be notified.', 'error', 'Cancelled');
      this.loadReservations(); this.loadStats();
    } else { this.ui.showToast('Could not cancel reservation.', 'error'); }
  }
  async loadRooms() { /* ... */
    const data      = await this.svc.getRooms();
    const container = document.querySelector('.rooms-admin-grid');
    if (!container) return;
    if (!data.length) {
      container.innerHTML = `<div style="grid-column:1/-1;padding:2rem;text-align:center;color:rgba(245,239,228,.3);font-size:.8rem">No rooms configured</div>`;
      return;
    }
    container.innerHTML = data.map(r => {
      const st      = r.status;
      const stClass = st === 'housekeeping' ? 'maintenance' : st;
      const label   = st.replace(/_/g, ' ');
      const typeLabel = r.room_type.replace(/_/g, ' ');
      const canToggle = st !== 'occupied';
      const toggleLabel = st === 'maintenance' ? 'Set Available' : 'Maintenance';
      return `<div class="room-tile" data-status="${st}" data-id="${r.id}">
        <div class="room-tile-header">
          <div class="room-tile-num">${r.room_number}</div>
          <div class="room-tile-actions">
            <button class="room-tile-btn" onclick="openEditRoom('${r.id}')" title="Edit room">
              <svg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M11 4H4a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2v-7'/><path d='M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z'/></svg>
            </button>
            ${canToggle ? `<button class="room-tile-btn room-tile-btn--toggle" onclick="toggleAvailability('${r.id}')" title="${toggleLabel}">
              <svg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='12' cy='12' r='10'/><line x1='12' y1='8' x2='12' y2='12'/><line x1='12' y1='16' x2='12.01' y2='16'/></svg>
            </button>` : ''}
            <button class="room-tile-btn room-tile-btn--del" onclick="deleteRoom('${r.id}','${r.room_number}')" title="Remove room">
              <svg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polyline points='3 6 5 6 21 6'/><path d='M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6'/><path d='M10 11v6'/><path d='M14 11v6'/><path d='M9 6V4a1 1 0 011-1h4a1 1 0 011 1v2'/></svg>
            </button>
          </div>
        </div>
        <div class="room-tile-type">${typeLabel}</div>
        <span class="pill pill-${stClass}">${label}</span>
        ${r.currentGuest ? `<div class="room-tile-guest">${r.currentGuest}</div>` : ''}
        ${r.base_price ? `<div style="font-size:.65rem;color:var(--gold-dim);margin-top:.4rem">₦${parseInt(r.base_price).toLocaleString()} / night</div>` : ''}
        ${r.view ? `<div style="font-size:.6rem;color:rgba(245,239,228,.3);margin-top:.1rem">${r.view}</div>` : ''}
        ${r.notes ? `<div style="font-size:.6rem;color:var(--danger);margin-top:.2rem">${r.notes}</div>` : ''}
      </div>`;
    }).join('');
  }
  async _roomAction(id, roomNum, currentStatus) { /* ... */
    const nextStatus = { available: 'housekeeping', occupied: null, maintenance: 'available', housekeeping: 'available', reserved: 'available' };
    const msgs = {
      available:    `Mark Room ${roomNum} as Housekeeping?`,
      maintenance:  `Mark Room ${roomNum} as Available (maintenance resolved)?`,
      housekeeping: `Mark Room ${roomNum} as Available (cleaning done)?`,
      occupied:     `Room ${roomNum} is occupied. Check out the guest from Reservations.`,
    };
    if (currentStatus === 'occupied') { this.ui.showToast(msgs.occupied, 'info', `Room ${roomNum}`); return; }
    const next = nextStatus[currentStatus];
    if (!next) return;
    if (!confirm(msgs[currentStatus])) return;
    const ok = await this.svc.updateRoomStatus(id, next);
    if (ok) { this.ui.showToast(`Room ${roomNum} → ${next.replace(/_/g,' ')}`, 'success', 'Room Updated'); this.loadRooms(); this.loadStats(); }
  }
  async loadGuests() { /* ... */
    const data  = await this.svc.getGuests();
    const tbody = document.querySelector('#guest-table tbody');
    if (!tbody) return;
    if (!data.length) { tbody.innerHTML = `<tr><td colspan="7" style="text-align:center;padding:2rem;color:rgba(245,239,228,.3);font-size:.8rem">No guests registered yet</td></tr>`; return; }
    tbody.innerHTML = data.map(g => {
      const vipLabel = ['Standard','Silver','Gold','Platinum'][g.vip_level] || 'Standard';
      return `<tr><td class="td-name">${g.first_name} ${g.last_name}${g.vip_level > 0 ? `<span style="color:var(--gold);font-size:.55rem;margin-left:.4rem;display:inline-flex;align-items:center;gap:.15rem"><svg xmlns='http://www.w3.org/2000/svg' width='9' height='9' viewBox='0 0 24 24' fill='#c9a84c'><polygon points='12,2 15.09,8.26 22,9.27 17,14.14 18.18,21.02 12,17.77 5.82,21.02 7,14.14 2,9.27 8.91,8.26'/></svg>${vipLabel}</span>` : ''}</td>
        <td><a href="mailto:${g.email}" style="color:var(--gold-dim)">${g.email}</a></td><td><a href="tel:${g.phone||''}" style="color:var(--gold-dim)">${g.phone || '—'}</a></td>
        <td style="text-align:center">${g.total_stays || 0}</td><td>${this.ui.fmtMoney(g.total_spend)}</td><td><span class="${this.ui.pillClass('confirmed')}">${vipLabel}</span></td>
        <td><button class="act-btn" onclick="viewGuest('${g.id}')">Profile</button></td></tr>`;
    }).join('');
  }
  async _viewGuestProfile(id) { /* ... */
    this.ui.showToast('Loading guest profile…', 'info');
    const data = await this.svc.getGuestDetails(id);
    if (!data) { this.ui.showToast('Could not load guest profile', 'error'); return; }
    const { first_name, last_name, email, phone, notes, vip_level, total_stays, total_spend, created_at, history } = data;
    const vipLabel = ['Standard','Silver','Gold','Platinum'][vip_level] || 'Standard';
    const content  = document.getElementById('guest-modal-content');
    if (!content) return;
    content.innerHTML = `
      <div style="display:flex;align-items:flex-start;gap:1.5rem;margin-bottom:2rem">
        <div class="user-avatar" style="width:64px;height:64px;font-size:1.8rem;flex-shrink:0;border-color:var(--gold-dim)">${first_name[0]}</div>
        <div style="flex:1">
          <div style="display:flex;align-items:center;gap:.8rem;margin-bottom:.4rem">
            <h2 style="font-family:'Cormorant Garamond',serif;font-size:1.8rem;font-weight:300;color:var(--parchment)">${first_name} ${last_name}</h2>
            ${vip_level > 0 ? `<span class="pill pill-checkedin"><svg xmlns='http://www.w3.org/2000/svg' width='9' height='9' viewBox='0 0 24 24' fill='currentColor' style='margin-right:.2rem;vertical-align:middle'><polygon points='12,2 15.09,8.26 22,9.27 17,14.14 18.18,21.02 12,17.77 5.82,21.02 7,14.14 2,9.27 8.91,8.26'/></svg>${vipLabel}</span>` : ''}
          </div>
          <div style="font-size:.8rem;color:rgba(245,239,228,.55);line-height:2">
            <a href="mailto:${email}" style="color:var(--gold-dim)">${email}</a><br>
            ${phone ? `<a href="tel:${phone}" style="color:var(--gold-dim)">${phone}</a><br>` : ''}
            Guest since ${new Date(created_at).toLocaleDateString('en-GB',{month:'long',year:'numeric'})}
          </div>
          <div style="display:flex;gap:2rem;margin-top:.8rem">
            <div><div style="font-size:.55rem;letter-spacing:.2em;text-transform:uppercase;color:var(--gold-dim)">Total Stays</div><div style="font-family:'Cormorant Garamond',serif;font-size:1.4rem;color:var(--parchment)">${total_stays||0}</div></div>
            <div><div style="font-size:.55rem;letter-spacing:.2em;text-transform:uppercase;color:var(--gold-dim)">Lifetime Spend</div><div style="font-family:'Cormorant Garamond',serif;font-size:1.4rem;color:var(--gold)">${this.ui.fmtMoney(total_spend)}</div></div>
          </div></div></div>
      <div style="display:grid;grid-template-columns:1fr 1.2fr;gap:1.5rem">
        <div><div class="card-title" style="margin-bottom:.8rem">Guest Notes</div>
          <textarea id="guest-notes-field" style="width:100%;min-height:120px;background:var(--ink);border:1px solid var(--border);color:var(--parchment);padding:.8rem;font-family:'Jost',sans-serif;font-size:.8rem;outline:none;resize:vertical" placeholder="Add notes about this guest…">${notes || ''}</textarea>
          <button class="topbar-btn primary" style="margin-top:.8rem;width:100%" onclick="(async()=>{const ok=await window._app.svc.updateGuestNotes('${id}',document.getElementById('guest-notes-field').value);ok?showToast('Notes saved','success','Saved'):showToast('Could not save notes','error');})()">Save Notes</button></div>
        <div><div class="card-title" style="margin-bottom:.8rem">Reservation History (${history.length})</div>
          <div style="max-height:220px;overflow-y:auto;border:1px solid var(--border)">
            <table style="width:100%;font-size:.72rem;border-collapse:collapse">
              <thead><tr style="border-bottom:1px solid var(--border)">
                <th style="padding:.6rem .8rem;text-align:left;color:var(--gold-dim);font-size:.55rem;letter-spacing:.2em;text-transform:uppercase">Ref</th><th style="padding:.6rem .8rem;text-align:left;color:var(--gold-dim);font-size:.55rem;letter-spacing:.2em;text-transform:uppercase">Room</th>
                <th style="padding:.6rem .8rem;text-align:left;color:var(--gold-dim);font-size:.55rem;letter-spacing:.2em;text-transform:uppercase">Check-In</th><th style="padding:.6rem .8rem;text-align:left;color:var(--gold-dim);font-size:.55rem;letter-spacing:.2em;text-transform:uppercase">Total</th>
                <th style="padding:.6rem .8rem;text-align:left;color:var(--gold-dim);font-size:.55rem;letter-spacing:.2em;text-transform:uppercase">Status</th></tr></thead>
              <tbody>${history.length ? history.map(h => `
                  <tr style="border-bottom:1px solid rgba(201,168,76,.05)">
                    <td style="padding:.6rem .8rem;font-family:'Cormorant Garamond',serif;font-size:.95rem;letter-spacing:.06em;color:var(--gold)">${h.ref_code}</td>
                    <td style="padding:.6rem .8rem;color:rgba(245,239,228,.6)">${h.rooms ? h.rooms.room_number : '—'}</td>
                    <td style="padding:.6rem .8rem;color:rgba(245,239,228,.6)">${h.check_in_date}</td>
                    <td style="padding:.6rem .8rem;color:rgba(245,239,228,.6)">${this.ui.fmtMoney(h.total_amount)}</td>
                    <td style="padding:.6rem .8rem"><span class="${this.ui.pillClass(h.status)}">${h.status.replace(/_/g,' ')}</span></td>
                  </tr>`).join('') : '<tr><td colspan="5" style="padding:1.5rem;text-align:center;color:rgba(245,239,228,.3)">No reservation history</td></tr>'}</tbody></table></div></div></div>`;
    window._app = { svc: this.svc, ui: this.ui };
    this.ui.toggleModal('guestDetailModal', true);
  }
  async loadDining() { /* ... */
    const [data, stats] = await Promise.all([this.svc.getDiningReservations(), this.svc.getDiningStats()]);
    const cards = document.querySelectorAll('#panel-dining .stat-card');
    if (cards[0]) { cards[0].querySelector('.stat-value').textContent = stats.seatedCovers || 0; cards[0].querySelector('.stat-sub').textContent = 'covers currently seated'; }
    if (cards[1]) { cards[1].querySelector('.stat-value').textContent = stats.confirmedCount || 0; }
    if (cards[3]) { cards[3].querySelector('.stat-value').textContent = data.filter(d => d.status === 'pending').length; }
    const tbody = document.querySelector('#dining-table tbody');
    if (!tbody) return;
    if (!data.length) { tbody.innerHTML = `<tr><td colspan="7" style="text-align:center;padding:2rem;color:rgba(245,239,228,.3);font-size:.8rem">No upcoming dining reservations</td></tr>`; return; }
    tbody.innerHTML = data.map(d => {
      const tableName = d.dining_tables?.table_number ? `T${d.dining_tables.table_number}` : '—';
      const dateStr   = new Date(d.reservation_date + 'T12:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
      const timeStr   = d.reservation_time ? d.reservation_time.slice(0, 5) : '—';
      const actions = [];
      if (d.status === 'pending')   actions.push(`<button class="act-btn" onclick="confirmDining('${d.id}','${(d.guest_name||'').replace(/'/g,"\\'")}')">Confirm</button>`);
      if (d.status === 'confirmed') actions.push(`<button class="act-btn" onclick="seatDining('${d.id}','${(d.guest_name||'').replace(/'/g,"\\'")}')">Seat</button>`);
      return `<tr data-status="${d.status}">
        <td style="color:var(--gold-dim)">${tableName}</td><td style="text-align:center">${d.covers}</td>
        <td class="td-name">${d.guest_name || '—'}</td><td>${dateStr} · ${timeStr}</td>
        <td style="color:rgba(245,239,228,.5)">${d.occasion || '—'}</td>
        <td><span class="${this.ui.pillClass(d.status)}">${d.status}</span></td>
        <td>${actions.join(' ')}</td></tr>`;
    }).join('');
  }
  async _updateDiningStatus(id, status, name) { /* ... */
    const ok = await this.svc.updateDiningStatus(id, status);
    if (ok) { this.ui.showToast(`${status === 'confirmed' ? 'Confirmed' : 'Seated'} — ${name}`, 'success', 'Dining Updated'); this.loadDining(); }
    else { this.ui.showToast('Could not update dining status', 'error'); }
  }
  async loadActivityFeed() { /* ... */
    const logs = await this.svc.getAuditLogs(12);
    const el   = document.getElementById('feed-list');
    if (!el) return;
    if (!logs.length) { el.innerHTML = `<div class="activity-item" style="padding:1rem;font-size:.75rem;color:rgba(245,239,228,.3)">No activity recorded yet.</div>`; return; }
    const colorMap = { 'reservation.confirmed': 'green', 'reservation.checked_in': 'green', 'reservation.cancelled': 'red', 'reservation.created': 'gold', 'dining': 'blue', 'room': 'blue' };
    el.innerHTML = logs.map(log => {
      const color = Object.entries(colorMap).find(([k]) => log.action.includes(k))?.[1] || 'gold';
      const label = log.action.replace(/[._]/g, ' ');
      const detail = log.new_value ? ` — ${log.new_value.ref || log.new_value.guest || ''}` : '';
      return `<div class="activity-item"><div class="act-dot ${color}"></div><div><div class="act-text"><strong>${label}</strong>${detail}</div><div class="act-time">${this.ui.timeAgo(log.created_at)}</div></div></div>`;
    }).join('');
  }
  async loadArrivals() { /* ... */
    const [arrivals, departures] = await Promise.all([ this.svc.getTodayArrivals(), this.svc.getTodayDepartures() ]);
    const arrEl = document.getElementById('arrivals-list');
    if (arrEl) {
      arrEl.innerHTML = arrivals.length ? arrivals.map(a => `
            <div class="activity-item"><div class="act-dot gold"></div><div>
                <div class="act-text"><strong>${a.guest_name}</strong> — ${String(a.room_type || '').replace(/_/g,' ')} ${a.room_number || ''}</div>
                <div class="act-time">
                  ${a.arrival_time ? 'ETA ' + String(a.arrival_time).slice(0,5) : 'Time TBD'} · <strong style="color:var(--gold);font-family:'Cormorant Garamond',serif;font-size:.9rem;letter-spacing:.06em">${a.ref_code}</strong>
                  ${a.vip_level > 0 ? ' · <span style="color:var(--gold);display:inline-flex;align-items:center;gap:.1rem"><svg xmlns="http://www.w3.org/2000/svg" width="9" height="9" viewBox="0 0 24 24" fill="#c9a84c"><polygon points="12,2 15.09,8.26 22,9.27 17,14.14 18.18,21.02 12,17.77 5.82,21.02 7,14.14 2,9.27 8.91,8.26"/></svg>VIP</span>' : ''}
                  ${a.special_requests ? ` · <span style="color:rgba(245,239,228,.4)">${a.special_requests.slice(0,40)}…</span>` : ''}
                </div></div></div>`).join('') : `<div class="activity-item" style="padding:1rem;font-size:.75rem;color:rgba(245,239,228,.3)">No arrivals scheduled today.</div>`;
    }
    this.ui.setStatCard('dashboard', 2, { sub: `${arrivals.length} arriving · ${departures.length} departing today` });
  }
  _openNewReservation() { /* ... */
    this.ui.toggleModal('newResModal', true);
    const today    = new Date();
    const tomorrow = new Date(today); tomorrow.setDate(today.getDate() + 1);
    const fmt = d => d.toISOString().split('T')[0];
    document.getElementById('adm-ci').value = fmt(today);
    document.getElementById('adm-co').value = fmt(tomorrow);
    document.getElementById('adm-ci').min   = fmt(today);
    document.getElementById('adm-co').min   = fmt(tomorrow);
  }
  async _submitNewReservation() { /* ... */
    const first    = document.getElementById('adm-first')?.value.trim();
    const last     = document.getElementById('adm-last')?.value.trim();
    const email    = document.getElementById('adm-email')?.value.trim();
    const phone    = document.getElementById('adm-phone')?.value.trim();
    const roomType = document.getElementById('adm-room')?.value;
    const ci       = document.getElementById('adm-ci')?.value;
    const co       = document.getElementById('adm-co')?.value;
    if (!first || !last || !email || !roomType || !ci || !co) { this.ui.showToast('Please fill in all required fields', 'error', 'Incomplete'); return; }
    const btn = document.querySelector('#newResModal .topbar-btn.primary');
    if (btn) { btn.textContent = 'Creating…'; btn.disabled = true; }
    const result = await this.svc.createReservationAdmin({ firstName: first, lastName: last, email, phone, roomType, checkIn: ci, checkOut: co });
    if (btn) { btn.textContent = 'Create Reservation'; btn.disabled = false; }
    if (result?.success) {
      this.ui.toggleModal('newResModal', false);
      this.ui.showToast(`Reservation ${result.ref_code} created for ${first} ${last}`, 'success', 'Reservation Created');
      this.loadReservations(); this.loadStats();
    } else { this.ui.showToast(result?.error || 'Could not create reservation. Check dates & room availability.', 'error', 'Error'); }
  }
  _filterTable(input, tableId, isSelect = false) { /* ... */
    const q = input.value.toLowerCase();
    document.querySelectorAll(`#${tableId} tbody tr`).forEach(row => {
      const haystack = isSelect ? (row.getAttribute('data-status') || '') : row.textContent.toLowerCase();
      row.style.display = (!q || haystack.includes(q)) ? '' : 'none';
    });
  }
  _filterRoomGrid() { /* ... */
    const q = (document.getElementById('room-search')?.value || '').toLowerCase();
    const s = (document.getElementById('room-filter')?.value || '').toLowerCase();
    document.querySelectorAll('.room-tile').forEach(tile => {
      const matchQ = !q || tile.textContent.toLowerCase().includes(q);
      const matchS = !s || tile.getAttribute('data-status') === s;
      tile.style.display = matchQ && matchS ? '' : 'none';
    });
  }
  _jumpToRef() { /* ... */
    const input = document.getElementById('refSearchInput');
    if (!input) return;
    const code = input.value.trim().toUpperCase();
    if (!code) return;
    this.ui.showPanel('reservations');
    window.showPanel('reservations');
    setTimeout(() => {
      let found = false;
      document.querySelectorAll('#res-table tbody tr').forEach(row => {
        const rowCode = row.cells[0]?.textContent?.trim().toUpperCase();
        if (rowCode === code || row.textContent.toUpperCase().includes(code)) {
          row.scrollIntoView({ behavior: 'smooth', block: 'center' });
          row.style.transition = 'background .3s';
          row.style.background = 'rgba(201,168,76,.12)';
          setTimeout(() => row.style.background = '', 2500);
          found = true;
        }
      });
      if (!found) { this.ui.showToast(`Reference ${code} not found in current results`, 'error', 'Not Found'); }
      input.value = '';
    }, 400);
  }
  // ── Room Modal (Create / Edit) ───────────────────────────────
  async _openRoomModal(id = null) {
    // Load room data if editing
    let room = null;
    if (id) {
      const rooms = await this.svc.getRooms();
      room = rooms.find(r => r.id === id);
    }

    const title  = id ? 'Edit Room' : 'Add New Room';
    const btn    = id ? 'Save Changes' : 'Create Room';

    // Populate modal
    document.getElementById('roomModalTitle').textContent = title;
    document.getElementById('roomSubmitBtn').textContent  = btn;
    document.getElementById('roomEditId').value           = id || '';
    document.getElementById('roomNumber').value           = room?.room_number   || '';
    document.getElementById('roomType').value             = room?.room_type     || 'deluxe';
    document.getElementById('roomFloor').value            = room?.floor         || '1';
    document.getElementById('roomSize').value             = room?.size_sqm      || '';
    document.getElementById('roomView').value             = room?.view          || '';
    document.getElementById('roomMaxOcc').value           = room?.max_occupancy || '2';
    document.getElementById('roomPrice').value            = room?.base_price    || '85000';
    document.getElementById('roomAmenities').value        = (room?.amenities || []).join(', ');
    document.getElementById('roomDesc').value             = room?.description   || '';
    document.getElementById('roomNotes').value            = room?.notes         || '';

    this.ui.toggleModal('roomModal', true);
  }

  async _submitRoomForm() {
    const id          = document.getElementById('roomEditId').value;
    const roomNumber  = document.getElementById('roomNumber').value.trim();
    const roomType    = document.getElementById('roomType').value;
    const floor       = document.getElementById('roomFloor').value;
    const sizeSqm     = document.getElementById('roomSize').value;
    const view        = document.getElementById('roomView').value.trim();
    const maxOccupancy= document.getElementById('roomMaxOcc').value;
    const basePrice   = document.getElementById('roomPrice').value;
    const amenitiesRaw= document.getElementById('roomAmenities').value;
    const description = document.getElementById('roomDesc').value.trim();
    const notes       = document.getElementById('roomNotes').value.trim();

    if (!roomNumber || !floor || !basePrice) {
      this.ui.showToast('Room number, floor and price are required', 'error', 'Incomplete');
      return;
    }

    const amenities = amenitiesRaw
      ? amenitiesRaw.split(',').map(s => s.trim()).filter(Boolean)
      : [];

    const btn = document.getElementById('roomSubmitBtn');
    btn.disabled = true; btn.textContent = 'Saving…';

    let result;
    const payload = { roomNumber, roomType, floor, sizeSqm, view, maxOccupancy, basePrice, amenities, description, notes };

    if (id) {
      const ok = await this.svc.updateRoom({ id, ...payload });
      result = ok ? { success: true } : { success: false, error: 'Update failed' };
    } else {
      result = await this.svc.createRoom(payload);
    }

    btn.disabled = false; btn.textContent = id ? 'Save Changes' : 'Create Room';

    if (result.success) {
      this.ui.toggleModal('roomModal', false);
      const action = id ? 'updated' : 'created';
      this.ui.showToast(`Room ${roomNumber} ${action} successfully`, 'success', id ? 'Room Updated' : 'Room Created');
      this.loadRooms(); this.loadStats();
    } else {
      this.ui.showToast(result.error || 'Could not save room', 'error', 'Error');
    }
  }

  async _deleteRoom(id, roomNum) {
    if (!confirm(`Permanently remove Room ${roomNum}? This cannot be undone.`)) return;
    const result = await this.svc.deleteRoom(id);
    if (result.success) {
      this.ui.showToast(`Room ${roomNum} removed`, 'error', 'Room Removed');
      this.loadRooms(); this.loadStats();
    } else {
      this.ui.showToast(result.error || 'Could not remove room', 'error', 'Error');
    }
  }

  async _toggleAvailability(id) {
    const result = await this.svc.toggleRoomAvailability(id);
    if (result.success) {
      const label = result.new_status === 'maintenance' ? 'set to Maintenance' : 'set to Available';
      this.ui.showToast(`Room ${result.room_number} ${label}`, 'success', 'Status Updated');
      this.loadRooms(); this.loadStats();
    } else {
      this.ui.showToast(result.error || 'Could not toggle availability', 'error');
    }
  }

  _saveSettings() { this.ui.showToast('Settings saved successfully', 'success', 'Saved'); }
}

// ================================================================
// 4. SKELETON PULSE ANIMATION
// ================================================================
const skeletonStyle = document.createElement('style');
skeletonStyle.textContent = `
  @keyframes skeleton-pulse { 0%,100%{opacity:.3} 50%{opacity:.7} }
  #refresh-indicator { font-size:.6rem; letter-spacing:.12em; color:rgba(201,168,76,.4);
    text-transform:uppercase; transition:opacity .4s; }
`;
document.head.appendChild(skeletonStyle);

// ================================================================
// 5. BOOT
// ================================================================
document.addEventListener('DOMContentLoaded', () => {
  const svc = new SupabaseService();
  const ui  = new UIManager();
  new DashboardController(svc, ui);
});