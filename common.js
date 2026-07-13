/* ===== 공통 스크립트 (Supabase 연동) ===== */
// 주소 끝의 슬래시나 앞뒤 공백이 있어도 자동으로 정리합니다 (흔한 실수 방지)
const _URL = String(SUPABASE_URL).trim().replace(/\/+$/, '').replace(/\/rest\/v1$/, '');
const _KEY = String(SUPABASE_ANON_KEY).trim();
const sb = window.supabase.createClient(_URL, _KEY);

const SETUP_NEEDED = _URL.includes('여기에');
if (SETUP_NEEDED) {
  document.addEventListener('DOMContentLoaded', () => {
    document.body.insertAdjacentHTML('afterbegin',
      `<div style="background:#fef3e2;color:#92400e;padding:12px 20px;font-size:14px;text-align:center;font-weight:700">
        ⚙️ 아직 Supabase 설정이 안 됐습니다 — <code>js/config.js</code> 파일에 프로젝트 URL과 anon key를 넣어주세요.
      </div>`);
  });
}

/* ---------- 데이터 접근 ---------- */
const DB = {
  async contest() {
    const { data, error } = await sb.from('contests').select('*')
      .neq('status', 'closed').order('created_at', { ascending: false }).limit(1);
    if (error) throw error;
    if (!data.length) {
      const r = await sb.from('contests').select('*').order('created_at', { ascending: false }).limit(1);
      if (!r.data || !r.data.length) return null;
      return r.data[0];
    }
    return data[0];
  },
  async count(contestId) {
    const { data } = await sb.rpc('submission_count', { p_contest: contestId });
    return data || 0;
  },
  async faqs() {
    const { data } = await sb.from('faqs').select('*').order('sort');
    return data || [];
  },
  async winners() {
    const { data } = await sb.rpc('get_winners');
    return data || [];
  },
  async lookup(receiptNo, name) {
    const { data, error } = await sb.rpc('lookup_submission', { p_receipt: receiptNo, p_name: name });
    if (error) throw new Error(cleanErr(error.message));
    return data;
  },
  async inquire(name, email, question) {
    const { error } = await sb.from('inquiries').insert({ name, email, question });
    if (error) throw new Error('문의 등록에 실패했습니다.');
  },
  /* 작품 제출: ① 파일을 저장소에 업로드 → ② 접수 함수 호출 */
  async submit(info, files, onProgress) {
    const folder = crypto.randomUUID();
    const uploaded = [];
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      const ext = (f.name.split('.').pop() || 'bin').toLowerCase();
      const path = `${folder}/${i + 1}.${ext}`;
      const { error } = await sb.storage.from('submissions').upload(path, f, {
        contentType: f.type || 'application/octet-stream', upsert: false
      });
      if (error) throw new Error('파일 업로드 실패: ' + error.message);
      uploaded.push({ path, name: f.name, size: f.size, mime: f.type || '' });
      onProgress && onProgress(i + 1, files.length);
    }
    const { data, error } = await sb.rpc('submit_entry', {
      p_name: info.name, p_student_id: info.studentId, p_phone: info.phone,
      p_email: info.email || '', p_title: info.title, p_concept: info.concept || '',
      p_files: uploaded
    });
    if (error) throw new Error(cleanErr(error.message));
    return data; // 접수번호
  },
  winnerImageUrl(path) {
    return sb.storage.from('winners').getPublicUrl(path).data.publicUrl;
  }
};

function cleanErr(m) {
  return String(m || '').replace(/^.*?(?=[가-힣])/, '') || '요청을 처리하지 못했습니다.';
}

/* ---------- 화면 유틸 ---------- */
const STATUS = {
  open:      { label: '접수 중',   cls: 'badge-open' },
  judging:   { label: '심사 중',   cls: 'badge-judging' },
  announced: { label: '결과 발표', cls: 'badge-announced' },
  closed:    { label: '마감',      cls: 'badge-closed' }
};
const SUB_STATUS = { received: '접수 완료', reviewing: '심사 중', awarded: '수상', rejected: '반려' };

function statusBadge(s) {
  const st = STATUS[s] || STATUS.closed;
  return `<span class="badge ${st.cls}"><i class="dot"></i>${st.label}</span>`;
}
function toast(msg, isErr) {
  let t = document.querySelector('.toast');
  if (!t) { t = document.createElement('div'); t.className = 'toast'; document.body.appendChild(t); }
  t.textContent = msg;
  t.classList.toggle('err', !!isErr);
  t.classList.add('show');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('show'), 3500);
}
function fmtDate(iso, withTime) {
  if (!iso) return '-';
  const d = new Date(iso);
  const s = `${d.getFullYear()}. ${String(d.getMonth() + 1).padStart(2, '0')}. ${String(d.getDate()).padStart(2, '0')}`;
  return withTime ? `${s} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` : s;
}
function fmtSize(b) {
  b = Number(b) || 0;
  if (b < 1024) return b + 'B';
  if (b < 1048576) return (b / 1024).toFixed(0) + 'KB';
  return (b / 1048576).toFixed(1) + 'MB';
}
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, m =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m]));
}

function renderHeader(active) {
  const links = [
    ['index.html', '공모전 소개'], ['notice.html', '공지사항'], ['submit.html', '작품 제출'],
    ['results.html', '결과 발표'], ['faq.html', 'FAQ · 문의'], ['lookup.html', '접수 조회']
  ];
  return `
  <header class="header">
    <div class="wrap">
      <a href="index.html" class="logo">
        <span class="logo-mark">목운</span>
        <span>교복 디자인 공모전<small>목운중학교 학생회</small></span>
      </a>
      <button class="burger" aria-label="메뉴" onclick="document.querySelector('.nav').classList.toggle('open')">☰</button>
      <nav class="nav">
        ${links.map(([h, t]) => `<a href="${h}" class="${active === h ? 'active' : ''}">${t}</a>`).join('')}
        <a href="notice.html" class="btn btn-primary btn-sm">참가하기</a>
      </nav>
    </div>
  </header>`;
}
function renderFooter() {
  return `
  <footer class="footer">
    <div class="wrap">
      <div>
        <b>목운중학교 학생회</b>
        교복 디자인 공모전 운영 · 서울특별시 양천구<br>
        문의: 학생회실 (점심시간) 또는 FAQ 페이지의 문의하기
      </div>
      <div>
        <b>바로가기</b>
        <div class="fnav">
          <a href="notice.html">공지사항</a><a href="submit.html">작품 제출</a>
          <a href="faq.html">FAQ</a><a href="lookup.html">접수 조회</a>
          <a href="admin.html">학생회 관리자</a>
        </div>
      </div>
    </div>
  </footer>`;
}
function mountLayout(active) {
  document.body.insertAdjacentHTML('afterbegin', renderHeader(active));
  document.body.insertAdjacentHTML('beforeend', renderFooter());
}

function startCountdown(endAt, els) {
  function tick() {
    const diff = new Date(endAt) - new Date();
    if (diff <= 0) {
      if (els.dday) els.dday.textContent = '마감';
      ['d', 'h', 'm', 's'].forEach(k => els[k] && (els[k].textContent = '00'));
      return;
    }
    const d = Math.floor(diff / 86400000), h = Math.floor(diff % 86400000 / 3600000);
    const m = Math.floor(diff % 3600000 / 60000), s = Math.floor(diff % 60000 / 1000);
    if (els.dday) els.dday.textContent = 'D-' + d;
    if (els.d) els.d.textContent = String(d).padStart(2, '0');
    if (els.h) els.h.textContent = String(h).padStart(2, '0');
    if (els.m) els.m.textContent = String(m).padStart(2, '0');
    if (els.s) els.s.textContent = String(s).padStart(2, '0');
  }
  tick();
  return setInterval(tick, 1000);
}

/* 공지 읽음 게이트 */
const NoticeGate = {
  key: 'mokun_notice_read',
  set(id) { try { localStorage.setItem(this.key, id + '|' + Date.now()); } catch {} },
  isRead(id) {
    try {
      const v = localStorage.getItem(this.key);
      if (!v) return false;
      const [cid, t] = v.split('|');
      return cid === id && Date.now() - Number(t) < 6048e5; // 7일
    } catch { return false; }
  }
};
