/**
 * 업체회의 누적분석 — 데이터 서버 (Apps Script)  Ver8.2
 *
 * 화면(index.html)은 깃허브(woori-001/upche-meeting)에 있고,
 * 이 스크립트는 "로그인 확인 + 구글시트 읽기·쓰기"만 합니다.
 *
 * 배포: 배포 → 새 배포(또는 배포 관리 → 새 버전) → 웹 앱
 *       다음 사용자 인증 정보로 실행: 나 / 액세스 권한: 모든 사용자
 *       (깃허브 화면에서 호출하려면 "모든 사용자"여야 합니다. 대신 아이디·비밀번호 로그인으로 막습니다)
 *
 * 시트 구성 (처음 실행 시 자동 생성)
 *   - 계정         : 아이디 | 이름 | 비밀번호 | 사용 | 마지막로그인
 *                    비밀번호 칸에 처음엔 그냥 숫자/글자를 적으면, 첫 로그인 때 자동으로 암호화(sha256…)로 바뀝니다.
 *                    사용 칸에 N 을 적으면 그 계정은 로그인할 수 없습니다.
 *   - 업로드기록   : 월 | 건수 | 파일 | 올린시각 | 올린사람
 *   - 협력점정보   : 상호명 | 정산그룹 | 거래유무 | 협력점 | 등록일
 *   - 접수_YYYY-MM : 협력점 | 구분 | 접수일 | 상태 | 제외유형 | 고객키 | 통신사   (월별 1개 탭)
 *   - 마진_요약 / 마진_협력점 / 마진_구분 / 마진_저마진 : 유통마진 메뉴에서 저장한 월별 결과
 */

const API_VERSION = 3;
const SHEET_ACCOUNT = "계정";
const ACCOUNT_HEADER = ["아이디", "이름", "비밀번호", "사용", "마지막로그인"];
const TOKEN_HOURS = 6;   // 로그인 유지 시간
let CURRENT_USER = null; // 요청한 사람 (로그인 확인 후 채워짐)

const SHEET_LOG = "업로드기록";
const SHEET_MASTER = "협력점정보";
const MONTH_PREFIX = "접수_";
const REPORT_PREFIX = "회의자료_";
const UNIT_HEADER = ["협력점", "구분", "접수일", "상태", "제외유형", "고객키", "통신사"];
const MASTER_HEADER = ["상호명", "정산그룹", "거래유무", "협력점", "등록일"];
const LOG_HEADER = ["월", "건수", "파일", "올린시각", "올린사람"];

// ---------- 웹 API (깃허브 화면이 호출) ----------
function doGet() {
  ensureSheets_();   // 웹앱 주소를 브라우저로 한 번 열면 계정·업로드기록·협력점정보 탭이 만들어진다
  return json_({ ok: true, app: "업체회의 누적분석", version: API_VERSION, message: "서버가 정상입니다. 이 주소를 화면의 [연결 설정]에 넣어주세요." });
}

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || "{}");
    const action = body.action;
    if (action === "ping") return json_({ ok: true, version: API_VERSION });
    if (action === "login") return json_(Object.assign({ ok: true, version: API_VERSION }, login_(body.id, body.password)));
    CURRENT_USER = checkToken_(body.token);
    if (!CURRENT_USER) return json_({ ok: false, error: "AUTH: 로그인이 필요합니다." });
    const args = body.args || [];
    const fns = { getInfo: getInfo, getMonth: getMonth, saveMonth: saveMonth, deleteMonth: deleteMonth, saveMaster: saveMaster,
                  changePassword: changePassword, logout: logout,
                  marginList: marginList, marginSave: marginSave, marginDelete: marginDelete,
                  marginPartnerMemo: marginPartnerMemo, marginReason: marginReason };
    const fn = fns[action];
    if (!fn) return json_({ ok: false, error: "알 수 없는 요청: " + action });
    return json_({ ok: true, version: API_VERSION, result: fn.apply(null, args) });
  } catch (err) {
    return json_({ ok: false, error: String(err && err.message || err) });
  }
}
function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}

// ---------- 로그인 ----------
function hash_(salt, pw) {
  const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, salt + "|" + pw, Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ("0" + (b & 255).toString(16)).slice(-2); }).join("");
}
function accounts_() {
  const sh = ensureSheet_(SHEET_ACCOUNT, ACCOUNT_HEADER);
  return { sh: sh, rows: readTable_(sh, ACCOUNT_HEADER.length) };
}
function login_(id, pw) {
  id = String(id || "").trim(); pw = String(pw || "");
  if (!id || !pw) throw new Error("아이디와 비밀번호를 입력하세요.");
  return withLock_(function () {
    const a = accounts_();
    const i = a.rows.findIndex(function (r) { return String(r[0]).trim() === id; });
    if (i < 0) throw new Error("아이디 또는 비밀번호가 맞지 않습니다.");
    const r = a.rows[i];
    if (String(r[3]).trim().toUpperCase() === "N") throw new Error("사용이 중지된 계정입니다.");
    const stored = String(r[2]);
    let ok = false;
    if (stored.indexOf("sha256$") === 0) {
      const p = stored.split("$"); ok = hash_(p[1], pw) === p[2];
    } else {
      ok = stored === pw;   // 처음 적어둔 비밀번호 → 맞으면 바로 암호화해서 저장
      if (ok) { const salt = Utilities.getUuid().slice(0, 8); a.sh.getRange(i + 2, 3).setValue("sha256$" + salt + "$" + hash_(salt, pw)); }
    }
    if (!ok) throw new Error("아이디 또는 비밀번호가 맞지 않습니다.");
    a.sh.getRange(i + 2, 5).setValue(now_());
    const token = Utilities.getUuid() + Utilities.getUuid().slice(0, 8);
    const user = { id: id, name: String(r[1] || id) };
    CacheService.getScriptCache().put("t_" + token, JSON.stringify(user), TOKEN_HOURS * 3600);
    return { token: token, user: user };
  });
}
function checkToken_(token) {
  if (!token) return null;
  const c = CacheService.getScriptCache(), v = c.get("t_" + token);
  if (!v) return null;
  c.put("t_" + token, v, TOKEN_HOURS * 3600);   // 쓰는 동안은 계속 연장
  return JSON.parse(v);
}
function logout() { return true; }
function changePassword(cur, next) {
  next = String(next || "");
  if (next.length < 4) throw new Error("새 비밀번호는 4자 이상으로 해주세요.");
  login_(CURRENT_USER.id, cur);   // 현재 비밀번호 확인
  return withLock_(function () {
    const a = accounts_();
    const i = a.rows.findIndex(function (r) { return String(r[0]).trim() === CURRENT_USER.id; });
    const salt = Utilities.getUuid().slice(0, 8);
    a.sh.getRange(i + 2, 3).setValue("sha256$" + salt + "$" + hash_(salt, next));
    return true;
  });
}

// ---------- 내부 도우미 ----------
function ss_() { return SpreadsheetApp.getActiveSpreadsheet(); }

function ensureSheet_(name, header) {
  const ss = ss_();
  let sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    trimSheet_(sh, 2, header.length);
    sh.getRange(1, 1, 1, header.length).setValues([header]).setFontWeight("bold");
    sh.setFrozenRows(1);
  }
  return sh;
}
function ensureSheets_() {
  ensureSheet_(SHEET_ACCOUNT, ACCOUNT_HEADER);
  ensureSheet_(SHEET_LOG, LOG_HEADER);
  ensureSheet_(SHEET_MASTER, MASTER_HEADER);
  // 새 시트에 기본으로 있는 빈 "시트1"은 정리
  const ss = ss_();
  ["시트1", "Sheet1"].forEach(function (n) {
    const s = ss.getSheetByName(n);
    if (s && ss.getSheets().length > 1 && s.getLastRow() === 0) ss.deleteSheet(s);
  });
}
// 시트 크기를 필요한 만큼만 남긴다 (구글시트 전체 1,000만 셀 한도 관리)
function trimSheet_(sh, rows, cols) {
  rows = Math.max(rows, 2); // 고정행(1행) 외에 최소 1행은 남겨야 함
  const mr = sh.getMaxRows(), mc = sh.getMaxColumns();
  if (mr < rows) sh.insertRowsAfter(mr, rows - mr);
  else if (mr > rows) sh.deleteRows(rows + 1, mr - rows);
  if (mc < cols) sh.insertColumnsAfter(mc, cols - mc);
  else if (mc > cols) sh.deleteColumns(cols + 1, mc - cols);
}
function writeTable_(sh, header, rows) {
  sh.clearContents();
  trimSheet_(sh, rows.length + 1, header.length);
  const all = [header].concat(rows);
  const rg = sh.getRange(1, 1, all.length, header.length);
  rg.setNumberFormat("@"); // 날짜·숫자 자동 변환 방지 (전부 글자로 저장)
  rg.setValues(all);
  sh.getRange(1, 1, 1, header.length).setFontWeight("bold");
  sh.setFrozenRows(1);
}
function readTable_(sh, cols) {
  const n = sh.getLastRow() - 1;
  if (n <= 0) return [];
  return sh.getRange(2, 1, n, cols).getDisplayValues();
}
function userEmail_() {
  return CURRENT_USER ? CURRENT_USER.name + "(" + CURRENT_USER.id + ")" : "";
}
function now_() {
  return Utilities.formatDate(new Date(), "Asia/Seoul", "yyyy-MM-dd HH:mm");
}
function withLock_(fn) {
  const lock = LockService.getDocumentLock();
  lock.waitLock(60000);
  try { return fn(); } finally { lock.releaseLock(); }
}

// ---------- 화면에서 호출하는 함수 ----------

/** 처음 화면 열 때: 원장 + 보유 월 목록 */
function getInfo() {
  ensureSheets_();
  const master = readTable_(ss_().getSheetByName(SHEET_MASTER), MASTER_HEADER.length);
  const masterNote = PropertiesService.getDocumentProperties().getProperty("masterNote") || "";
  const log = readTable_(ss_().getSheetByName(SHEET_LOG), LOG_HEADER.length)
    .map(function (r) { return { m: r[0], n: r[1], file: r[2], at: r[3], by: r[4] }; })
    .filter(function (r) { return /^\d{4}-\d{2}$/.test(r.m) && ss_().getSheetByName(MONTH_PREFIX + r.m); });
  return { master: master, masterNote: masterNote, months: log, user: CURRENT_USER };
}

/** 한 달치 접수 단위 (탭 구분 문자열로 반환 — 전송량 절약) */
function getMonth(m) {
  const sh = ss_().getSheetByName(MONTH_PREFIX + m);
  if (!sh) return "";
  // Ver7.2 이전에 저장된 탭은 통신사 칸이 없다(6칸) → 있는 칸까지만 읽는다
  const cols = Math.min(sh.getMaxColumns(), UNIT_HEADER.length);
  return readTable_(sh, cols).map(function (r) { return r.join("\t"); }).join("\n");
}

/** 한 달치 저장 (같은 달이 있으면 통째로 교체) — tsv: 줄마다 6칸 */
function saveMonth(m, tsv, fileName) {
  if (!/^\d{4}-\d{2}$/.test(m)) throw new Error("월 형식 오류: " + m);
  return withLock_(function () {
    ensureSheets_();
    // 화면(index.html)과 서버 버전이 달라 칸 수가 어긋나도 저장되도록 칸 수를 맞춘다
    const W = UNIT_HEADER.length;
    const rows = tsv ? tsv.split("\n").filter(function (l) { return l; }).map(function (l) {
      const r = l.split("\t");
      while (r.length < W) r.push("");
      return r.slice(0, W);
    }) : [];
    const name = MONTH_PREFIX + m;
    let sh = ss_().getSheetByName(name);
    const replaced = !!sh;
    if (!sh) sh = ss_().insertSheet(name, ss_().getSheets().length);
    writeTable_(sh, UNIT_HEADER, rows);
    upsertLog_(m, rows.length, fileName);
    return { m: m, n: rows.length, replaced: replaced };
  });
}

function upsertLog_(m, n, fileName) {
  const sh = ss_().getSheetByName(SHEET_LOG);
  const log = readTable_(sh, LOG_HEADER.length).filter(function (r) { return r[0] && r[0] !== m; });
  if (n !== null) log.push([m, String(n), fileName || "", now_(), userEmail_()]);
  log.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
  writeTable_(sh, LOG_HEADER, log);
}

function deleteMonth(m) {
  return withLock_(function () {
    const sh = ss_().getSheetByName(MONTH_PREFIX + m);
    if (sh) ss_().deleteSheet(sh);
    upsertLog_(m, null);
    return true;
  });
}

/** 협력점정보(원장) 저장 — rows: [상호명, 정산그룹, 거래유무, 협력점, 등록일] */
function saveMaster(rows, fileName) {
  return withLock_(function () {
    ensureSheets_();
    writeTable_(ss_().getSheetByName(SHEET_MASTER), MASTER_HEADER, rows);
    const note = (fileName || "") + " · " + now_();
    PropertiesService.getDocumentProperties().setProperty("masterNote", note);
    return { n: rows.length, note: note };
  });
}

// =====================================================================
// 유통마진 (월별 결과 저장)
// =====================================================================
// 시트 칸 정의: [시트 칸 이름, 데이터 키, 숫자 여부]
const M_SPECS = {
  "마진_요약": [["월","month"],["고객수","customers",1],["외부고객","extCustomers",1],["자점고객","jaCustomers",1],["상부정산","upper",1],["자점마진","jaMargin",1],
    ["본점인센","hqIncentive",1],["전체정산","total",1],["유통마진","margin",1],["고객당마진","perCustomer",1],["1만원미만","lowCount",1],["역마진","negCount",1],
    ["저장시각","savedAt"],["저장자","savedBy"],["메모","memo"]],
  "마진_협력점": [["월","month"],["협력점","partner"],["자점","ja"],["고객수","customers",1],["상부정산","upper",1],["자점마진","jaMargin",1],["본점인센","hqIncentive",1],
    ["전체정산","total",1],["유통마진","margin",1],["1만원미만","lowCount",1],["역마진","negCount",1],["메모","memo"],["메모작성자","memoBy"],["메모시각","memoAt"]],
  "마진_구분": [["월","month"],["구분","category"],["건수","customers",1],["상부정산","upper",1],["자점마진","jaMargin",1],["본점인센","hqIncentive",1],
    ["전체정산","total",1],["유통마진","margin",1],["1만원미만","lowCount",1],["역마진","negCount",1]],
  "마진_저마진": [["월","month"],["키","key"],["고객명","name"],["연락처","phone"],["협력점","partner"],["자점","ja"],["상부점","upperShop"],["통신사","carrier"],
    ["구분","category"],["상품","products"],["상부정산","upper",1],["자점마진","jaMargin",1],["본점인센","hqIncentive",1],["전체정산","total",1],["유통마진","margin",1],
    ["사유","reason"],["사유작성자","reasonBy"],["사유시각","reasonAt"]],
  "마진_협력점구분": [["월","month"],["협력점","partner"],["구분","category"],["건수","customers",1],["상부정산","upper",1],["자점마진","jaMargin",1],["본점인센","hqIncentive",1],
    ["전체정산","total",1],["유통마진","margin",1],["1만원미만","lowCount",1],["역마진","negCount",1]],
};
function mRead_(name) {
  const spec = M_SPECS[name];
  const sh = ensureSheet_(name, spec.map(function (s) { return s[0]; }));
  return readTable_(sh, spec.length).filter(function (r) { return r[0]; }).map(function (r) {
    const o = {};
    spec.forEach(function (s, i) {
      if (s[2]) o[s[1]] = Number(String(r[i]).replace(/,/g, "")) || 0;
      else if (s[1] === "ja") o.ja = r[i] === "Y";
      else o[s[1]] = r[i];
    });
    return o;
  });
}
function mWrite_(name, objs) {
  const spec = M_SPECS[name];
  const sh = ensureSheet_(name, spec.map(function (s) { return s[0]; }));
  const rows = objs.map(function (o) {
    return spec.map(function (s) { const v = o[s[1]]; return s[1] === "ja" ? (v ? "Y" : "") : (v == null ? "" : String(v)); });
  });
  rows.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
  writeTable_(sh, spec.map(function (s) { return s[0]; }), rows);
}
function marginList() {
  return { summaries: mRead_("마진_요약"), partners: mRead_("마진_협력점"), categories: mRead_("마진_구분"), lows: mRead_("마진_저마진"), partnerCats: mRead_("마진_협력점구분") };
}
/** 한 달 저장 (같은 달은 교체). 이미 적어둔 사유·협력점 메모는 유지 */
function marginSave(month, summary, partners, categories, lows, memo, partnerCats) {
  if (!/^\d{4}-\d{2}$/.test(month)) throw new Error("월 형식 오류: " + month);
  return withLock_(function () {
    const oldP = mRead_("마진_협력점"), oldL = mRead_("마진_저마진");
    const keptMemo = {}, keptReason = {};
    oldP.filter(function (p) { return p.month === month && p.memo; }).forEach(function (p) { keptMemo[p.partner] = p; });
    oldL.filter(function (l) { return l.month === month && l.reason; }).forEach(function (l) { keptReason[l.key] = l; });
    const sums = mRead_("마진_요약").filter(function (s) { return s.month !== month; });
    sums.push(Object.assign({}, summary, { month: month, savedAt: now_(), savedBy: userEmail_(), memo: memo || "" }));
    mWrite_("마진_요약", sums);
    mWrite_("마진_협력점", oldP.filter(function (p) { return p.month !== month; }).concat(partners.map(function (p) {
      const k = keptMemo[p.partner] || {};
      return Object.assign({}, p, { month: month, memo: k.memo || "", memoBy: k.memoBy || "", memoAt: k.memoAt || "" });
    })));
    mWrite_("마진_구분", mRead_("마진_구분").filter(function (c) { return c.month !== month; })
      .concat(categories.map(function (c) { return Object.assign({}, c, { month: month }); })));
    mWrite_("마진_저마진", oldL.filter(function (l) { return l.month !== month; }).concat(lows.map(function (l) {
      const k = keptReason[l.key] || {};
      return Object.assign({}, l, { month: month, reason: k.reason || "", reasonBy: k.reasonBy || "", reasonAt: k.reasonAt || "" });
    })));
    mWrite_("마진_협력점구분", mRead_("마진_협력점구분").filter(function (c) { return c.month !== month; })
      .concat((partnerCats || []).map(function (c) { return Object.assign({}, c, { month: month }); })));
    return { keptReasons: Object.keys(keptReason).length, keptMemos: Object.keys(keptMemo).length };
  });
}
function marginDelete(month) {
  return withLock_(function () {
    Object.keys(M_SPECS).forEach(function (name) { mWrite_(name, mRead_(name).filter(function (x) { return x.month !== month; })); });
    return true;
  });
}
function marginPartnerMemo(month, partner, memo) {
  return withLock_(function () {
    const all = mRead_("마진_협력점");
    const p = all.find(function (x) { return x.month === month && x.partner === partner; });
    if (!p) throw new Error("해당 협력점을 찾을 수 없습니다.");
    p.memo = memo || ""; p.memoBy = memo ? userEmail_() : ""; p.memoAt = memo ? now_() : "";
    mWrite_("마진_협력점", all);
    return { memoBy: p.memoBy, memoAt: p.memoAt };
  });
}
function marginReason(month, key, reason) {
  return withLock_(function () {
    const all = mRead_("마진_저마진");
    const l = all.find(function (x) { return x.month === month && x.key === key; });
    if (!l) throw new Error("해당 고객을 찾을 수 없습니다.");
    l.reason = reason || ""; l.reasonBy = reason ? userEmail_() : ""; l.reasonAt = reason ? now_() : "";
    mWrite_("마진_저마진", all);
    return { reasonBy: l.reasonBy, reasonAt: l.reasonAt };
  });
}
