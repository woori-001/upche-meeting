/* 어드민(workline.kr)에서 실행하는 "유통손익 가져오기" 즐겨찾기(북마클릿) 원본.
 * - 어드민에 로그인한 화면에서 즐겨찾기를 누르면 실행됩니다.
 * - 어드민의 '엑셀 다운로드'와 같은 기능으로 대상월 엑셀 6개(전체/상부 × 일반[개통일]/추가·환수[정산예정일])를 만들어 받고,
 *   옛날 데이터(옛 웹) 추가·환수도 같은 조건으로 받아 계산기 창으로 넘깁니다. 파일은 브라우저 안에서만 오가고 어떤 서버에도 올리지 않습니다.
 * - 어드민 데이터는 읽기만 합니다 (수정·삭제 없음).
 * - 어드민 보안정책(CSP)상 외부 스크립트를 불러올 수 없어서 코드 전체가 즐겨찾기 안에 들어갑니다.
 *   계산기 화면이 __CALC_URL__ 을 채운 즐겨찾기 링크를 만들어 줍니다.
 */
(() => {
  const CALC_URL = '__CALC_URL__';
  const CALC_ORIGIN = new URL(CALC_URL).origin;
  // 작은 중계 창 → 이미 열려 있는 업체회의 웹 탭으로 넘김 (없으면 그 창이 업체회의 웹으로 바뀜)
  const RELAY_URL = CALC_URL.replace(/\/?$/, '/') + 'relay.html';
  const ADMIN_HOST = 'workline.kr';

  if (location.hostname !== ADMIN_HOST) { alert('어드민(workline.kr)에 로그인한 화면에서 눌러주세요.'); return; }
  if (document.getElementById('dist-pnl-box')) return;

  const lastDay = ym => { const [y, m] = ym.split('-').map(Number); return new Date(y, m, 0).getDate(); };
  const wait = ms => new Promise(r => setTimeout(r, ms));

  async function req(url, label, headers = {}) {
    const r = await fetch(url, { credentials: 'include', headers });
    if (r.status === 401 || r.status === 403) throw new Error('어드민 로그인이 끊겼습니다. 다시 로그인한 뒤 눌러주세요.');
    if (r.status === 413) throw new Error(`${label}: 건수가 너무 많아 엑셀을 만들 수 없습니다.`);
    if (!r.ok) { let m = ''; try { m = (await r.json()).error || ''; } catch { /* */ } throw new Error(`${label}: 어드민 오류 ${m || r.status}`); }
    return r;
  }

  // 어드민 엑셀 만들기 → 완료 기다리기 → 받기
  async function exportFile(job, progress) {
    // 옛날 데이터(옛 웹 2019-11~2025-08)는 어드민 화면의 [옛날 데이터] 버튼과 같은 표시(X-Data-Source: old)로 요청
    const start = await (await req(`${job.ep}?${new URLSearchParams(job.params)}`, job.label, job.old ? { 'X-Data-Source': 'old' } : {})).json();
    let j = start.job;
    if (!j) throw new Error(`${job.label}: 엑셀 작업을 시작하지 못했습니다.`);
    const until = Date.now() + 10 * 60 * 1000;
    while (!['done', 'failed', 'cancelled'].includes(j.status)) {
      if (Date.now() > until) throw new Error(`${job.label}: 엑셀 만들기가 너무 오래 걸립니다.`);
      progress(j.queueAhead > 0 ? `대기 중 (앞에 ${j.queueAhead}건)` : `만드는 중 ${j.percent ?? 0}%`);
      await wait(1500);
      j = (await (await req(`/api/orders/export-jobs/${j.jobId}`, job.label)).json()).job;
    }
    if (j.status !== 'done') throw new Error(`${job.label}: 엑셀 만들기 실패 ${j.error || j.status}`);
    progress('받는 중');
    const buffer = await (await req(`/api/orders/export-jobs/${j.jobId}/download`, job.label)).arrayBuffer();
    return { name: `${job.label} · ${j.fileName}`, side: job.side, label: job.label, rows: j.rowCount, old: !!job.old, use: job.use || '', buffer };
  }

  // 어드민 화면의 날짜 기준 목록에서 '최초등록일' 값을 찾음 (못 찾으면 1)
  function regDateChk() {
    for (const o of document.querySelectorAll('select option')) if (/최초\s*등록/.test(o.textContent || '')) return o.value;
    for (const i of document.querySelectorAll('input[type=radio]')) {
      const t = (i.closest('label') || i.parentElement || {}).textContent || '';
      if (/최초\s*등록/.test(t)) return i.value;
    }
    return '1';
  }

  async function pull(period, progress, target) {
    const from = `${period}-01`, to = `${period}-${String(lastDay(period)).padStart(2, '0')}`;
    const ts = target.split(','), calc = ts.some(t => t === 'pnl' || t === 'code'), margin = ts.includes('margin');
    const jobs = [];
    // 업체회의: 전체정산 일반 · 최초등록일 기준 1개
    if (ts.includes('meet')) jobs.push({ side: '전체', use: 'meet', ep: '/api/exact/calc/export', label: '업체회의 접수(최초등록일)', params: { chargeType: 'G', dateChk: regDateChk(), dateFrom: from, dateTo: to } });
    if (calc || margin) for (const [side, ep] of [['전체', '/api/exact/calc/export'], ['상부', '/api/exact/calc/upper/export']]) {
      jobs.push({ side, ep, label: `${side}정산 일반`, params: { chargeType: 'G', dateChk: '2', dateFrom: from, dateTo: to } });
      if (!calc) continue;   // 유통마진만이면 일반(개통일) 상부·전체 2개만
      jobs.push({ side, ep, label: `${side}정산 추가`, params: { chargeType: 'A', dateChk: '4', dateFrom: from, dateTo: to } });
      jobs.push({ side, ep, label: `${side}정산 환수`, params: { chargeType: 'B', dateChk: '4', dateFrom: from, dateTo: to } });
      // 옛날 데이터: 같은 조건 (일반은 옛 웹 기간이 끝나 해당 없음 → 추가·환수만)
      jobs.push({ side, ep, old: true, label: `옛날 데이터 ${side}정산 추가`, params: { chargeType: 'A', dateChk: '4', dateFrom: from, dateTo: to } });
      jobs.push({ side, ep, old: true, label: `옛날 데이터 ${side}정산 환수`, params: { chargeType: 'B', dateChk: '4', dateFrom: from, dateTo: to } });
    }
    const files = [];
    for (let i = 0; i < jobs.length; i++) {
      files.push(await exportFile(jobs[i], t => progress(`${i + 1}/${jobs.length} ${jobs[i].label} — ${t}`)));
    }
    return files;
  }

  // ---------- 화면 ----------
  const prev = new Date(); prev.setDate(1); prev.setMonth(prev.getMonth() - 1);
  const defYm = `${prev.getFullYear()}-${String(prev.getMonth() + 1).padStart(2, '0')}`;
  const box = document.createElement('div');
  box.id = 'dist-pnl-box';
  box.setAttribute('style', 'position:fixed;top:16px;right:16px;z-index:2147483647;width:340px;background:#fff;color:#1d2229;border:1px solid #d0d5dc;border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.18);padding:16px;font:14px/1.5 system-ui,sans-serif');
  const rb = (v, l, on) => `<label style="flex:1;display:flex;align-items:center;justify-content:center;gap:5px;border:1px solid #d0d5dc;border-radius:8px;padding:6px 4px;cursor:pointer;font-size:13px"><input type="checkbox" name="upche-t" value="${v}"${on ? ' checked' : ''}>${l}</label>`;
  box.innerHTML = `<div style="font-weight:700;margin-bottom:8px">업체회의 웹 · 어드민에서 가져오기</div>
    <label style="display:flex;align-items:center;gap:8px;margin-bottom:10px">대상월 <input type="month" value="${defYm}" style="flex:1;padding:6px;border:1px solid #d0d5dc;border-radius:6px"></label>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:10px">${rb('meet', '업체회의')}${rb('margin', '유통마진')}${rb('code', '코드실적')}${rb('pnl', '유통매출', true)}</div>
    <div style="font-size:12px;color:#6b7380;margin-bottom:10px">여러 개 골라도 한 번에 받아요. 업체회의: 전체정산 일반(최초등록일) 1개 · 유통매출·코드실적: 전체·상부정산 일반(개통일)·추가·환수(정산예정일) 10개 · 유통마진만: 일반(개통일) 2개.<br>다 받으면 열려 있는 업체회의 웹으로 바로 넘겨요 (작은 창이 잠깐 떴다가 닫혀요).</div>
    <div data-msg style="font-size:12px;min-height:18px;margin-bottom:10px"></div>
    <div style="display:flex;gap:8px;justify-content:flex-end">
      <button data-close style="padding:7px 12px;border:1px solid #d0d5dc;border-radius:8px;background:#fff;cursor:pointer">닫기</button>
      <button data-go style="padding:7px 12px;border:0;border-radius:8px;background:#2b5bd7;color:#fff;font-weight:600;cursor:pointer">가져오기</button>
    </div>`;
  document.body.appendChild(box);
  const goBtn = box.querySelector('[data-go]');
  const msg = (t, err) => {
    const m = box.querySelector('[data-msg]'); m.textContent = t; m.style.color = err ? '#c8322b' : '#1d2229';
    // 계산기 창에도 진행 상황 표시
    if (calcWin && !calcWin.closed) { try { calcWin.postMessage({ type: 'dist-pnl-progress', text: t, error: !!err }, CALC_ORIGIN); } catch { /* 아직 로딩 중 */ } }
  };
  let busy = false, calcWin = null, calcReady = false, payload = null;

  function send() {
    if (!calcWin || calcWin.closed || !calcReady || !payload) return;
    calcWin.postMessage({ type: 'dist-pnl-admin-files', ...payload }, CALC_ORIGIN, payload.files.map(f => f.buffer));
    payload = null;
    msg('✓ 업체회의 웹으로 넘겼습니다. 결과를 확인하고 저장하세요.');
    goBtn.disabled = false; busy = false;
  }
  function onMsg(e) {
    if (e.origin !== CALC_ORIGIN || !e.data || e.data.type !== 'dist-pnl-calc-ready') return;
    calcReady = true; send();
  }
  window.addEventListener('message', onMsg);
  box.querySelector('[data-close]').onclick = () => { if (busy && !confirm('가져오는 중입니다. 닫을까요?')) return; window.removeEventListener('message', onMsg); box.remove(); };

  goBtn.onclick = async () => {
    const period = box.querySelector('input[type=month]').value;
    const picked = [...box.querySelectorAll('input[name=upche-t]:checked')].map(x => x.value);
    if (!picked.length) { msg('가져올 메뉴를 하나 이상 고르세요', true); return; }
    const target = picked.length === 1 && picked[0] === 'margin' ? 'margin' : picked.join(',');
    if (!/^\d{4}-\d{2}$/.test(period)) { msg('대상월을 고르세요', true); return; }
    busy = true; goBtn.disabled = true; payload = null; calcReady = false;
    // 팝업 차단을 피하려고 클릭하자마자 계산기 창부터 엽니다
    calcWin = window.open(RELAY_URL, 'upche_relay', 'width=460,height=280');
    if (!calcWin) { msg('팝업이 차단되었습니다. workline.kr 팝업을 허용한 뒤 다시 눌러주세요.', true); goBtn.disabled = false; busy = false; return; }
    try {
      const t0 = Date.now();
      const files = await pull(period, t => msg('가져오는 중… ' + t), target);
      const rows = files.reduce((a, f) => a + (f.rows || 0), 0);
      payload = { period, files, target, pulledAt: new Date().toISOString() };
      msg(`엑셀 ${files.length}개 ${rows.toLocaleString()}건 받음 (${Math.round((Date.now() - t0) / 1000)}초) — 넘기는 중…`);
      send();
    } catch (err) {
      msg(err.message || String(err), true); goBtn.disabled = false; busy = false;
    }
  };
})();
