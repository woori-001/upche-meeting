// 어드민 가져오기 → 이미 열려 있는 업체회의 웹 탭으로 넘기는 통로 (같은 주소끼리만)
// 중계 창(relay.html)이 받은 파일을 브라우저 저장소(IndexedDB)에 잠깐 두고, 열린 탭에 "가져가세요" 신호를 보냄
const DB = 'upche_admin_import', STORE = 'p', KEY = 'pending';
const CH = 'upche-admin-import';
function idb() {
  return new Promise((ok, no) => { const r = indexedDB.open(DB, 1); r.onupgradeneeded = () => r.result.createObjectStore(STORE); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
}
async function tx(mode, fn) { const db = await idb(); return new Promise((ok, no) => { const t = db.transaction(STORE, mode); const s = t.objectStore(STORE); const r = fn(s); t.oncomplete = () => { ok(r && r.result); db.close(); }; t.onerror = () => no(t.error); }); }
export const putPending = (data) => tx('readwrite', s => s.put(data, KEY));
export const takePending = async () => { const v = await tx('readonly', s => s.get(KEY)); if (v) await tx('readwrite', s => s.delete(KEY)); return v || null; };
export const channel = () => new BroadcastChannel(CH);
