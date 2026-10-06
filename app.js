/* ============================================================
   app.js — общая логика для всех страниц.
   Требует ДО этого файла подключить:
     1. <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>
     2. <script src="config.js"></script>
   Экспортирует всё через window.App
   ============================================================ */

(function () {
  'use strict';

  // ============================================================
  // 1. Supabase клиент
  // ============================================================

  let _client = null;

  function getClient() {
    if (_client) return _client;
    if (!window.supabase || typeof window.supabase.createClient !== 'function') {
      throw new Error('supabase-js SDK не загружен. Проверь <script> перед app.js');
    }
    const session = getSession();
    const headers = {};
    if (session && session.token) {
      headers['x-admin-session-token'] = session.token;
    }
    _client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: headers }
    });
    return _client;
  }

  // ============================================================
  // 2. Утилиты
  // ============================================================

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function safeHttpUrl(value) {
    try {
      const url = new URL(String(value || '').trim(), window.location.origin);
      return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null;
    } catch (error) {
      return null;
    }
  }

  function uuid() {
    if (window.crypto && typeof crypto.randomUUID === 'function') {
      return crypto.randomUUID();
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      const r = (Math.random() * 16) | 0;
      const v = c === 'x' ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  function getUrlParam(name) {
    return new URLSearchParams(window.location.search).get(name);
  }

  function formatDate(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return iso;
    return d.toLocaleDateString('ru-RU', {
      day: '2-digit', month: '2-digit', year: 'numeric'
    });
  }

  function formatDateTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return iso;
    return d.toLocaleString('ru-RU', {
      day: '2-digit', month: '2-digit', year: 'numeric',
      hour: '2-digit', minute: '2-digit'
    });
  }

  function formatTime(t) {
    if (!t) return '';
    return String(t).slice(0, 5);
  }

  function formatMoney(v) {
    if (v == null || v === '') return '';
    const n = Number(v);
    if (isNaN(n)) return String(v);
    return n.toLocaleString('ru-RU') + ' ₽';
  }

  async function copyToClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (e) {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      document.body.removeChild(ta);
      return ok;
    }
  }

  function debounce(fn, ms) {
    let t;
    return function () {
      const args = arguments, self = this;
      clearTimeout(t);
      t = setTimeout(function () { fn.apply(self, args); }, ms);
    };
  }

  // ============================================================
  // 3. Toast-уведомления
  // ============================================================

  function ensureToastContainer() {
    let el = document.getElementById('toast-container');
    if (!el) {
      el = document.createElement('div');
      el.id = 'toast-container';
      document.body.appendChild(el);
    }
    return el;
  }

  function toast(message, type) {
    type = type || 'info';
    const wrap = ensureToastContainer();
    const el = document.createElement('div');
    el.className = 'toast toast-' + type;
    el.textContent = message;
    wrap.appendChild(el);
    requestAnimationFrame(function () { el.classList.add('toast-show'); });
    setTimeout(function () {
      el.classList.remove('toast-show');
      setTimeout(function () { el.remove(); }, 300);
    }, 3000);
  }

  // ============================================================
  // 4. Звук уведомления (Web Audio, без внешних файлов)
  // ============================================================

  let _audioCtx = null;

  function playNotificationSound() {
    try {
      if (!_audioCtx) {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        if (!Ctx) return;
        _audioCtx = new Ctx();
      }
      const ctx = _audioCtx;
      if (ctx.state === 'suspended') ctx.resume();
      const now = ctx.currentTime;
      [880, 1320].forEach(function (freq, i) {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        const t0 = now + i * 0.15;
        gain.gain.setValueAtTime(0.0001, t0);
        gain.gain.exponentialRampToValueAtTime(0.25, t0 + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.25);
        osc.connect(gain).connect(ctx.destination);
        osc.start(t0);
        osc.stop(t0 + 0.3);
      });
    } catch (e) { /* noop */ }
  }

  // ============================================================
  // 5. Сессии
  // ============================================================

  function saveSession(token, projectId, expiresAt) {
    localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({
      token: token,
      project_id: projectId || null,
      expires_at: expiresAt
    }));
  }

  function getSession() {
    try {
      const raw = localStorage.getItem(SESSION_STORAGE_KEY);
      if (!raw) return null;
      const s = JSON.parse(raw);
      if (typeof s.token !== 'string' ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s.token)) {
        return null;
      }
      if (s.expires_at && new Date(s.expires_at) < new Date()) {
        localStorage.removeItem(SESSION_STORAGE_KEY);
        return null;
      }
      return s;
    } catch (e) {
      return null;
    }
  }

  function clearSession() {
    localStorage.removeItem(SESSION_STORAGE_KEY);
    localStorage.removeItem(SUPER_ADMIN_FLAG);
    _client = null;
  }

  function isSuperAdmin() {
    return localStorage.getItem(SUPER_ADMIN_FLAG) === '1';
  }

  function setSuperAdminFlag() {
    localStorage.setItem(SUPER_ADMIN_FLAG, '1');
  }

  async function createSession(projectId, login, password) {
    const { data, error } = await getClient().rpc('create_admin_session', {
      p_project_id: projectId,
      p_login: login,
      p_password: password
    });
    if (error) throw error;
    if (!data || typeof data.token !== 'string' || !data.expires_at) return false;
    saveSession(data.token, data.project_id, data.expires_at);
    _client = null;
    return data.token;
  }

  async function validateSession(projectId) {
    const s = getSession();
    if (!s) return false;
    const { data, error } = await getClient().rpc('validate_admin_session', {
      p_token: s.token,
      p_project_id: projectId || null
    });
    if (error) throw error;
    if (!data) { clearSession(); return false; }
    return true;
  }

  // ============================================================
  // 6. Логин
  // ============================================================

  async function loginProject(projectId, login, password) {
    const token = await createSession(projectId, login, password);
    if (!token) return false;
    localStorage.removeItem(SUPER_ADMIN_FLAG);
    return true;
  }

  async function loginSuperAdmin(login, password) {
    const token = await createSession(null, login, password);
    if (!token) return false;
    setSuperAdminFlag();
    return true;
  }

  async function loginWithCredentials(login, password, projectHint) {
    if (await loginSuperAdmin(login, password)) {
      return { role: 'super_admin' };
    }

    const client = getClient();
    const projectIds = [];

    if (projectHint) {
      const { data, error } = await client
        .from('projects_public')
        .select('id')
        .eq('id', projectHint)
        .eq('is_active', true)
        .maybeSingle();
      if (error) throw error;
      if (data) projectIds.push(data.id);
    }

    const { data: projects, error } = await client
      .from('projects_public')
      .select('id')
      .eq('is_active', true);
    if (error) throw error;

    (projects || []).forEach(function (project) {
      if (project.id !== projectHint) projectIds.push(project.id);
    });

    for (const projectId of projectIds) {
      if (await loginProject(projectId, login, password)) {
        return { role: 'project_admin', projectId: projectId };
      }
    }

    return null;
  }

  // ============================================================
  // 7. Guard-функции
  // ============================================================

  async function requireProjectAuth(projectId, redirectTo) {
    const ok = await validateSession(projectId);
    if (!ok) {
      window.location.href = redirectTo || ('/?b=' + encodeURIComponent(projectId));
      return false;
    }
    return true;
  }

  async function requireSuperAdmin(redirectTo) {
    if (!isSuperAdmin()) {
      window.location.href = redirectTo || '/';
      return false;
    }
    const ok = await validateSession(null);
    if (!ok) {
      localStorage.removeItem(SUPER_ADMIN_FLAG);
      window.location.href = redirectTo || '/';
      return false;
    }
    return true;
  }

  // ============================================================
  // 8. Проекты
  // ============================================================

  async function getProject(slug) {
    const { data, error } = await getClient()
      .from('projects_public')
      .select('*')
      .eq('id', slug)
      .eq('is_active', true)
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  async function listProjects() {
    const { data, error } = await getClient()
      .from('projects_public')
      .select('*')
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createProject(payload) {
    // payload: { id, business_name, admin_login, admin_password,
    //            phone?, address?, accent_color?, background_color? }
    const { error } = await getClient().rpc('admin_create_project', {
      p_id: payload.id,
      p_business_name: payload.business_name,
      p_admin_login: payload.admin_login,
      p_admin_password: payload.admin_password
    });
    if (error) throw error;

    // Остальные поля — обычным update
    const patch = {};
    ['industry', 'phone', 'address', 'accent_color', 'background_color',
     'logo_url', 'banner_url', 'social_links', 'work_hours'].forEach(function (k) {
      if (payload[k] !== undefined) patch[k] = payload[k];
    });
    if (Object.keys(patch).length) {
      await updateProject(payload.id, patch);
    }
    return getProjectAny(payload.id);
  }

  async function updateProject(slug, patch) {
    const { data, error } = await getClient()
      .from('projects')
      .update(patch)
      .eq('id', slug)
      .select('id')
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  async function updateProjectPassword(slug, newPassword) {
    const { error } = await getClient().rpc('admin_update_project_password', {
      p_id: slug,
      p_new_password: newPassword
    });
    if (error) throw error;
  }

  async function deleteProject(slug) {
    const { error } = await getClient().from('projects').delete().eq('id', slug);
    if (error) throw error;
  }

  // Служебная — вернуть проект без фильтра is_active (для super.html)
  async function getProjectAny(slug) {
    const { data, error } = await getClient()
      .from('projects_public')
      .select('*')
      .eq('id', slug)
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  // ============================================================
  // 9. Услуги
  // ============================================================

  async function listServices(projectId) {
    const { data, error } = await getClient()
      .from('services')
      .select('*')
      .eq('project_id', projectId)
      .order('sort_order', { ascending: true })
      .order('created_at', { ascending: true });
    if (error) throw error;
    return data || [];
  }

  async function createService(payload) {
    const { data, error } = await getClient()
      .from('services')
      .insert(payload)
      .select()
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  async function updateService(id, patch) {
    const { data, error } = await getClient()
      .from('services')
      .update(patch)
      .eq('id', id)
      .select()
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  async function deleteService(id) {
    const { error } = await getClient().from('services').delete().eq('id', id);
    if (error) throw error;
  }

  // ============================================================
  // 10. Заявки
  // ============================================================

  async function listBookings(projectId) {
    const { data, error } = await getClient()
      .from('bookings')
      .select('*')
      .eq('project_id', projectId)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createBooking(payload) {
    const { data, error } = await getClient()
      .from('bookings')
      .insert(payload);
    if (error) throw error;
    return data;
  }

  async function updateBookingStatus(id, status) {
    const { data, error } = await getClient()
      .from('bookings')
      .update({ status: status })
      .eq('id', id)
      .select()
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  async function deleteBooking(id) {
    const { error } = await getClient().from('bookings').delete().eq('id', id);
    if (error) throw error;
  }

  /**
   * Подписка на изменения bookings в рамках проекта.
   * handlers: { onInsert(row), onUpdate(row, old), onDelete(old) }
   * Возвращает канал (можно потом unsubscribe).
   */
  function subscribeBookings(projectId, handlers) {
    handlers = handlers || {};
    return getClient()
      .channel('bookings-' + projectId)
      .on('postgres_changes', {
        event: '*',
        schema: 'public',
        table: 'bookings',
        filter: 'project_id=eq.' + projectId
      }, function (payload) {
        if (payload.eventType === 'INSERT' && handlers.onInsert) handlers.onInsert(payload.new);
        else if (payload.eventType === 'UPDATE' && handlers.onUpdate) handlers.onUpdate(payload.new, payload.old);
        else if (payload.eventType === 'DELETE' && handlers.onDelete) handlers.onDelete(payload.old);
      })
      .subscribe();
  }

  /**
   * Подписка на изменения проекта (услуги, оформление).
   * handlers: { onService(payload), onProject(payload) }
   */
  function subscribeProject(projectId, handlers) {
    handlers = handlers || {};
    const ch = getClient().channel('project-' + projectId);
    ch.on('postgres_changes', {
      event: '*', schema: 'public', table: 'services',
      filter: 'project_id=eq.' + projectId
    }, function (p) { if (handlers.onService) handlers.onService(p); });
    ch.on('postgres_changes', {
      event: '*', schema: 'public', table: 'projects',
      filter: 'id=eq.' + projectId
    }, function (p) { if (handlers.onProject) handlers.onProject(p); });
    ch.subscribe();
    return ch;
  }

  // ============================================================
  // 11. Storage
  // ============================================================

  /**
   * Загрузка файла. folder: 'logos' | 'banners' | 'services'.
   * baseName: 'pisun123' или id услуги. Расширение берётся из имени файла.
   * Возвращает публичный URL.
   */
  async function uploadFile(file, folder, baseName) {
    const ext = (file.name.split('.').pop() || 'bin').toLowerCase();
    const path = folder + '/' + baseName + '.' + ext;
    const { error } = await getClient().storage
      .from(SUPABASE_BUCKET)
      .upload(path, file, { upsert: true, cacheControl: '3600' });
    if (error) throw error;
    return getPublicUrl(path);
  }

  function getPublicUrl(path) {
    const { data } = getClient().storage.from(SUPABASE_BUCKET).getPublicUrl(path);
    return data.publicUrl;
  }

  // ============================================================
  // 12. Тема
  // ============================================================

  function applyTheme(project) {
    if (!project) return;
    const root = document.documentElement;
    if (project.accent_color) root.style.setProperty('--accent', project.accent_color);
    if (project.background_color) root.style.setProperty('--bg', project.background_color);
  }

  // ============================================================
  // 13. Экспорт
  // ============================================================

  window.App = {
    // client
    getClient: getClient,

    // утилиты
    escapeHtml: escapeHtml,
    safeHttpUrl: safeHttpUrl,
    uuid: uuid,
    getUrlParam: getUrlParam,
    formatDate: formatDate,
    formatDateTime: formatDateTime,
    formatTime: formatTime,
    formatMoney: formatMoney,
    copyToClipboard: copyToClipboard,
    debounce: debounce,

    // toast / sound
    toast: toast,
    playNotificationSound: playNotificationSound,

    // сессии
    saveSession: saveSession,
    getSession: getSession,
    clearSession: clearSession,
    isSuperAdmin: isSuperAdmin,
    setSuperAdminFlag: setSuperAdminFlag,
    createSession: createSession,
    validateSession: validateSession,

    // логин
    loginProject: loginProject,
    loginSuperAdmin: loginSuperAdmin,
    loginWithCredentials: loginWithCredentials,

    // guards
    requireProjectAuth: requireProjectAuth,
    requireSuperAdmin: requireSuperAdmin,

    // проекты
    getProject: getProject,
    getProjectAny: getProjectAny,
    listProjects: listProjects,
    createProject: createProject,
    updateProject: updateProject,
    updateProjectPassword: updateProjectPassword,
    deleteProject: deleteProject,

    // услуги
    listServices: listServices,
    createService: createService,
    updateService: updateService,
    deleteService: deleteService,

    // заявки
    listBookings: listBookings,
    createBooking: createBooking,
    updateBookingStatus: updateBookingStatus,
    deleteBooking: deleteBooking,
    subscribeBookings: subscribeBookings,
    subscribeProject: subscribeProject,

    // storage
    uploadFile: uploadFile,
    getPublicUrl: getPublicUrl,

    // тема
    applyTheme: applyTheme
  };
})();
