-- =====================================================================
-- 업체회의 누적분석 · Supabase 데이터 저장소
--
-- ▶ 사용법: Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣기 → 맨 아래
--   관리자 임시 비밀번호('여기에_임시비밀번호')를 바꾼 뒤 Run.
--   여러 번 실행해도 안전함 (있는 테이블은 그대로 두고 함수만 새로 고침).
--
-- 설계
--  · 모든 테이블 이름은 upche_ 로 시작 (같은 프로젝트의 다른 앱과 섞이지 않게)
--  · 데이터 테이블(public.upche_*)은 RLS 를 켜고 정책을 하나도 두지 않음
--      → anon / authenticated 키로는 직접 읽기·쓰기 모두 불가
--  · 계정·세션(private.upche_*)은 API 로 노출되지 않는 private 스키마 + RLS
--  · 화면은 public.upche_* RPC 함수만 호출. 함수가 로그인 토큰을 확인한 뒤
--    SECURITY DEFINER 권한으로 테이블을 읽고 씀 (search_path 고정)
--  · Supabase Auth(이메일 로그인) 설정은 건드리지 않음 → 다른 앱에 영향 없음
-- =====================================================================

-- private 스키마는 같은 프로젝트의 다른 앱도 쓰므로 스키마 권한은 건드리지 않고,
-- 이 앱의 테이블·함수 권한만 하나씩 막는다.
create schema if not exists private;

-- ---------------------------------------------------------------------
-- 계정 · 세션 (private)
-- ---------------------------------------------------------------------
create table if not exists private.upche_accounts (
  id            text primary key check (id ~ '^[A-Za-z0-9._-]{2,40}$'),
  name          text not null default '',
  pw_hash       text not null,
  role          text not null default 'user' check (role in ('admin','user')),
  enabled       boolean not null default true,
  must_change   boolean not null default false,
  created_at    timestamptz not null default now(),
  last_login_at timestamptz
);
comment on table private.upche_accounts is '업체회의 · 로그인 계정 (비밀번호는 bcrypt 해시)';

create table if not exists private.upche_sessions (
  token_hash text primary key,
  account_id text not null references private.upche_accounts(id) on delete cascade,
  expires_at timestamptz not null
);
comment on table private.upche_sessions is '업체회의 · 로그인 세션 (토큰 원문은 저장하지 않음)';

create table if not exists private.upche_login_attempts (
  id bigint generated always as identity primary key,
  ip text, account_id text, ok boolean not null, at timestamptz not null default now()
);
create index if not exists upche_login_attempts_ip_at_idx on private.upche_login_attempts (ip, at);
comment on table private.upche_login_attempts is '업체회의 · 로그인 시도 기록 (연속 실패 시 잠시 차단)';

alter table private.upche_accounts       enable row level security;
alter table private.upche_sessions       enable row level security;
alter table private.upche_login_attempts enable row level security;
revoke all on private.upche_accounts, private.upche_sessions, private.upche_login_attempts from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 데이터 (public, RLS on, 정책 없음 = 직접 접근 불가)
-- ---------------------------------------------------------------------
create table if not exists public.upche_months (
  month       text primary key check (month ~ '^\d{4}-\d{2}$'),
  n           integer not null default 0,
  file_name   text not null default '',
  uploaded_at timestamptz not null default now(),
  uploaded_by text not null default ''
);
comment on table public.upche_months is '업체회의 · 월별 접수 데이터 업로드 기록';

create table if not exists public.upche_units (
  month     text not null references public.upche_months(month) on delete cascade,
  seq       integer not null,
  partner   text not null default '',
  grp       text not null default '',   -- 유선/무선/렌탈
  rcv_date  text not null default '',   -- 접수일
  status    text not null default '',   -- 개통/해지/취소/진행
  excl      text not null default '',   -- 제외유형
  cust_key  text not null default '',   -- 고객키 (마스킹·해시)
  telco     text not null default '',   -- 통신사
  primary key (month, seq)
);
comment on table public.upche_units is '업체회의 · 접수 단위 (한 달치를 통째로 교체)';

create table if not exists public.upche_master (
  seq          integer primary key,
  shop_name    text not null default '',  -- 상호명
  settle_group text not null default '',  -- 정산그룹
  trade_yn     text not null default '',  -- 거래유무
  partner      text not null default '',  -- 협력점
  reg_date     text not null default ''   -- 등록일
);
comment on table public.upche_master is '업체회의 · 협력점정보(원장)';

create table if not exists public.upche_settings (
  key   text primary key,
  value text not null default ''
);
comment on table public.upche_settings is '업체회의 · 설정값 (원장 파일명 등)';

create table if not exists public.upche_margin_summary (
  month         text primary key check (month ~ '^\d{4}-\d{2}$'),
  customers     integer not null default 0,
  ext_customers integer not null default 0,
  ja_customers  integer not null default 0,
  upper         bigint  not null default 0,
  ja_margin     bigint  not null default 0,
  hq_incentive  bigint  not null default 0,
  total         bigint  not null default 0,
  margin        bigint  not null default 0,
  per_customer  bigint  not null default 0,
  low_count     integer not null default 0,
  neg_count     integer not null default 0,
  saved_at      timestamptz not null default now(),
  saved_by      text not null default '',
  memo          text not null default ''
);
comment on table public.upche_margin_summary is '유통마진 · 월 요약';

create table if not exists public.upche_margin_partners (
  month        text not null references public.upche_margin_summary(month) on delete cascade,
  partner      text not null,
  ja           boolean not null default false,
  customers    integer not null default 0,
  upper        bigint  not null default 0,
  ja_margin    bigint  not null default 0,
  hq_incentive bigint  not null default 0,
  total        bigint  not null default 0,
  margin       bigint  not null default 0,
  low_count    integer not null default 0,
  neg_count    integer not null default 0,
  memo         text not null default '',
  memo_by      text not null default '',
  memo_at      timestamptz,
  primary key (month, partner)
);
comment on table public.upche_margin_partners is '유통마진 · 협력점별 (메모 포함)';

create table if not exists public.upche_margin_categories (
  month        text not null references public.upche_margin_summary(month) on delete cascade,
  category     text not null,
  customers    integer not null default 0,
  upper        bigint  not null default 0,
  ja_margin    bigint  not null default 0,
  hq_incentive bigint  not null default 0,
  total        bigint  not null default 0,
  margin       bigint  not null default 0,
  low_count    integer not null default 0,
  neg_count    integer not null default 0,
  primary key (month, category)
);
comment on table public.upche_margin_categories is '유통마진 · 구분(통신사)별';

create table if not exists public.upche_margin_partner_cats (
  month        text not null references public.upche_margin_summary(month) on delete cascade,
  partner      text not null,
  category     text not null,
  customers    integer not null default 0,
  upper        bigint  not null default 0,
  ja_margin    bigint  not null default 0,
  hq_incentive bigint  not null default 0,
  total        bigint  not null default 0,
  margin       bigint  not null default 0,
  low_count    integer not null default 0,
  neg_count    integer not null default 0,
  primary key (month, partner, category)
);
comment on table public.upche_margin_partner_cats is '유통마진 · 협력점 × 구분';

create table if not exists public.upche_margin_lows (
  id           bigint generated always as identity primary key,
  month        text not null references public.upche_margin_summary(month) on delete cascade,
  key          text not null,             -- 고객 키 (이름+연락처+상부점 해시)
  name         text not null default '',
  phone        text not null default '',  -- 마스킹된 연락처
  partner      text not null default '',
  ja           boolean not null default false,
  upper_shop   text not null default '',
  carrier      text not null default '',
  category     text not null default '',
  products     text not null default '',
  upper        bigint not null default 0,
  ja_margin    bigint not null default 0,
  hq_incentive bigint not null default 0,
  total        bigint not null default 0,
  margin       bigint not null default 0,
  reason       text not null default '',
  reason_by    text not null default '',
  reason_at    timestamptz
);
create index if not exists upche_margin_lows_month_key_idx on public.upche_margin_lows (month, key);
comment on table public.upche_margin_lows is '유통마진 · 1만원 미만·역마진 고객 (사유 포함)';

do $$
declare t text;
begin
  foreach t in array array['upche_months','upche_units','upche_master','upche_settings','upche_margin_summary',
    'upche_margin_partners','upche_margin_categories','upche_margin_partner_cats','upche_margin_lows'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 내부 도우미 (private, 외부에서 호출 불가)
-- ---------------------------------------------------------------------
create or replace function private.upche_hash(p text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(coalesce(p, ''), 'sha256'), 'hex')
$$;

-- 서울 시각 "YYYY-MM-DD HH24:MI" 글자 ↔ timestamptz
create or replace function private.upche_fmt(t timestamptz) returns text
language sql stable set search_path = '' as $$
  select coalesce(to_char(t at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'), '')
$$;
create or replace function private.upche_ts(s text) returns timestamptz
language plpgsql stable set search_path = '' as $$
begin
  if s is null or btrim(s) = '' then return null; end if;
  return (btrim(s)::timestamp at time zone 'Asia/Seoul');
exception when others then return null;
end $$;

-- 토큰 확인 → 계정 (실패하면 AUTH: 로 시작하는 오류. 화면은 이 글자를 보고 로그인 창을 띄움)
create or replace function private.upche_auth(p_token text, p_admin boolean default false)
returns private.upche_accounts
language plpgsql security definer set search_path = '' as $$
declare v_acc private.upche_accounts; v_th text := private.upche_hash(p_token);
begin
  select a.* into v_acc
  from private.upche_sessions s join private.upche_accounts a on a.id = s.account_id
  where s.token_hash = v_th and s.expires_at > now() and a.enabled;
  if v_acc.id is null then
    raise exception 'AUTH: 로그인이 필요해요. 다시 로그인해 주세요.';
  end if;
  -- 쓸 때마다 6시간 연장
  update private.upche_sessions set expires_at = now() + interval '6 hours' where token_hash = v_th;
  if p_admin and v_acc.role <> 'admin' then
    raise exception '관리자만 할 수 있어요.';
  end if;
  return v_acc;
end $$;

create or replace function private.upche_who(a private.upche_accounts) returns text
language sql immutable set search_path = '' as $$
  select case when coalesce(a.name, '') = '' then a.id else a.name || '(' || a.id || ')' end
$$;

-- ---------------------------------------------------------------------
-- 로그인 · 로그아웃 · 비밀번호
-- ---------------------------------------------------------------------
create or replace function public.upche_login(p_id text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ip text; v_fail int; v_acc private.upche_accounts; v_token text;
begin
  v_ip := split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1);
  select count(*) into v_fail from private.upche_login_attempts
   where ip = v_ip and not ok and at > now() - interval '10 minutes';
  if v_fail >= 10 then
    return jsonb_build_object('ok', false, 'error', '로그인 실패가 너무 많아요. 10분 뒤 다시 시도해 주세요.');
  end if;

  select * into v_acc from private.upche_accounts where id = btrim(coalesce(p_id, ''));
  if v_acc.id is null or v_acc.pw_hash <> extensions.crypt(coalesce(p_password, ''), v_acc.pw_hash) then
    insert into private.upche_login_attempts(ip, account_id, ok) values (v_ip, p_id, false);
    return jsonb_build_object('ok', false, 'error', '아이디 또는 비밀번호가 맞지 않아요.');
  end if;
  if not v_acc.enabled then
    return jsonb_build_object('ok', false, 'error', '사용이 중지된 계정이에요. 관리자에게 문의해 주세요.');
  end if;

  insert into private.upche_login_attempts(ip, account_id, ok) values (v_ip, v_acc.id, true);
  delete from private.upche_sessions where expires_at < now();
  delete from private.upche_login_attempts where at < now() - interval '30 days';

  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  insert into private.upche_sessions(token_hash, account_id, expires_at)
  values (private.upche_hash(v_token), v_acc.id, now() + interval '6 hours');
  update private.upche_accounts set last_login_at = now() where id = v_acc.id;

  return jsonb_build_object('ok', true, 'token', v_token, 'mustChange', v_acc.must_change,
    'user', jsonb_build_object('id', v_acc.id, 'name', coalesce(nullif(v_acc.name, ''), v_acc.id), 'role', v_acc.role));
end $$;

create or replace function public.upche_logout(p_token text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  delete from private.upche_sessions where token_hash = private.upche_hash(p_token);
  return true;
end $$;

create or replace function public.upche_change_password(p_token text, p_old text, p_new text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token);
begin
  if a.pw_hash <> extensions.crypt(coalesce(p_old, ''), a.pw_hash) then
    raise exception '현재 비밀번호가 맞지 않아요.';
  end if;
  if length(coalesce(p_new, '')) < 4 then raise exception '새 비밀번호는 4자 이상이어야 해요.'; end if;
  update private.upche_accounts
     set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf')), must_change = false
   where id = a.id;
  -- 다른 곳에 로그인된 세션은 끊고 지금 세션만 남김
  delete from private.upche_sessions where account_id = a.id and token_hash <> private.upche_hash(p_token);
  return true;
end $$;

-- ---------------------------------------------------------------------
-- 업체회의: 처음 화면 / 월 데이터 / 원장
-- ---------------------------------------------------------------------
create or replace function public.upche_get_info(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token);
begin
  return jsonb_build_object(
    'master', coalesce((select jsonb_agg(jsonb_build_array(shop_name, settle_group, trade_yn, partner, reg_date) order by seq) from public.upche_master), '[]'::jsonb),
    'masterNote', coalesce((select value from public.upche_settings where key = 'masterNote'), ''),
    'months', coalesce((select jsonb_agg(jsonb_build_object('m', month, 'n', n, 'file', file_name, 'at', private.upche_fmt(uploaded_at), 'by', uploaded_by) order by month) from public.upche_months), '[]'::jsonb),
    'user', jsonb_build_object('id', a.id, 'name', coalesce(nullif(a.name, ''), a.id), 'role', a.role),
    'mustChange', a.must_change);
end $$;

-- 한 달치 접수 단위: 줄마다 협력점\t구분\t접수일\t상태\t제외유형\t고객키\t통신사
create or replace function public.upche_get_month(p_token text, p_month text) returns text
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  return coalesce((select string_agg(concat_ws(E'\t', partner, grp, rcv_date, status, excl, cust_key, telco), E'\n' order by seq)
                   from public.upche_units where month = p_month), '');
end $$;

create or replace function public.upche_save_month(p_token text, p_month text, p_tsv text, p_file text,
  p_at text default null, p_by text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); v_replaced boolean; v_n int;
begin
  if p_month !~ '^\d{4}-\d{2}$' then raise exception '월 형식 오류: %', p_month; end if;
  select exists(select 1 from public.upche_months where month = p_month) into v_replaced;
  insert into public.upche_months(month, n, file_name, uploaded_at, uploaded_by)
  values (p_month, 0, coalesce(p_file, ''), coalesce(private.upche_ts(p_at), now()), coalesce(nullif(p_by, ''), private.upche_who(a)))
  on conflict (month) do update set file_name = excluded.file_name, uploaded_at = excluded.uploaded_at, uploaded_by = excluded.uploaded_by;
  delete from public.upche_units where month = p_month;
  insert into public.upche_units(month, seq, partner, grp, rcv_date, status, excl, cust_key, telco)
  select p_month, row_number() over (order by t.ord),
         split_part(t.l, E'\t', 1), split_part(t.l, E'\t', 2), split_part(t.l, E'\t', 3), split_part(t.l, E'\t', 4),
         split_part(t.l, E'\t', 5), split_part(t.l, E'\t', 6), split_part(t.l, E'\t', 7)
  from string_to_table(coalesce(p_tsv, ''), E'\n') with ordinality as t(l, ord)
  where t.l <> '';
  get diagnostics v_n = row_count;
  update public.upche_months set n = v_n where month = p_month;
  return jsonb_build_object('m', p_month, 'n', v_n, 'replaced', v_replaced);
end $$;

create or replace function public.upche_delete_month(p_token text, p_month text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  delete from public.upche_months where month = p_month;   -- 접수 단위는 함께 지워짐(cascade)
  return true;
end $$;

-- rows: [[상호명, 정산그룹, 거래유무, 협력점, 등록일], ...]
create or replace function public.upche_save_master(p_token text, p_rows jsonb, p_file text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_note text; v_n int;
begin
  perform private.upche_auth(p_token);
  delete from public.upche_master where seq >= 0;
  insert into public.upche_master(seq, shop_name, settle_group, trade_yn, partner, reg_date)
  select (r.ord - 1)::int, coalesce(r.v->>0, ''), coalesce(r.v->>1, ''), coalesce(r.v->>2, ''), coalesce(r.v->>3, ''), coalesce(r.v->>4, '')
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) with ordinality as r(v, ord);
  get diagnostics v_n = row_count;
  v_note := coalesce(nullif(p_note, ''), coalesce(p_file, '') || ' · ' || private.upche_fmt(now()));
  insert into public.upche_settings(key, value) values ('masterNote', v_note)
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('n', v_n, 'note', v_note);
end $$;

-- ---------------------------------------------------------------------
-- 유통마진
-- ---------------------------------------------------------------------
create or replace function public.upche_margin_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  return jsonb_build_object(
    'summaries', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'customers', customers, 'extCustomers', ext_customers,
        'jaCustomers', ja_customers, 'upper', upper, 'jaMargin', ja_margin, 'hqIncentive', hq_incentive, 'total', total, 'margin', margin,
        'perCustomer', per_customer, 'lowCount', low_count, 'negCount', neg_count, 'savedAt', private.upche_fmt(saved_at), 'savedBy', saved_by, 'memo', memo) order by month)
      from public.upche_margin_summary), '[]'::jsonb),
    'partners', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'partner', partner, 'ja', ja, 'customers', customers, 'upper', upper,
        'jaMargin', ja_margin, 'hqIncentive', hq_incentive, 'total', total, 'margin', margin, 'lowCount', low_count, 'negCount', neg_count,
        'memo', memo, 'memoBy', memo_by, 'memoAt', private.upche_fmt(memo_at)) order by month, partner)
      from public.upche_margin_partners), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'category', category, 'customers', customers, 'upper', upper,
        'jaMargin', ja_margin, 'hqIncentive', hq_incentive, 'total', total, 'margin', margin, 'lowCount', low_count, 'negCount', neg_count) order by month, category)
      from public.upche_margin_categories), '[]'::jsonb),
    'partnerCats', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'partner', partner, 'category', category, 'customers', customers, 'upper', upper,
        'jaMargin', ja_margin, 'hqIncentive', hq_incentive, 'total', total, 'margin', margin, 'lowCount', low_count, 'negCount', neg_count) order by month, partner, category)
      from public.upche_margin_partner_cats), '[]'::jsonb),
    'lows', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'key', key, 'name', name, 'phone', phone, 'partner', partner, 'ja', ja,
        'upperShop', upper_shop, 'carrier', carrier, 'category', category, 'products', products, 'upper', upper, 'jaMargin', ja_margin,
        'hqIncentive', hq_incentive, 'total', total, 'margin', margin, 'reason', reason, 'reasonBy', reason_by, 'reasonAt', private.upche_fmt(reason_at)) order by month, margin, id)
      from public.upche_margin_lows), '[]'::jsonb));
end $$;

-- 한 달 저장 (같은 달은 교체). 이미 적어둔 사유·협력점 메모는 유지
-- (구글시트에서 옮겨올 때는 들어온 사유·메모·저장시각을 그대로 씀)
create or replace function public.upche_margin_save(p_token text, p_month text, p_summary jsonb, p_partners jsonb,
  p_categories jsonb, p_lows jsonb, p_memo text default '', p_partner_cats jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); v_kept_r int; v_kept_m int; v_memo jsonb; v_reason jsonb;
begin
  if p_month !~ '^\d{4}-\d{2}$' then raise exception '월 형식 오류: %', p_month; end if;

  -- 지우기 전에 적어둔 메모·사유를 기억
  select coalesce(jsonb_object_agg(partner, jsonb_build_object('memo', memo, 'by', memo_by, 'at', memo_at)), '{}'::jsonb) into v_memo
    from public.upche_margin_partners where month = p_month and memo <> '';
  select coalesce(jsonb_object_agg(key, jsonb_build_object('reason', reason, 'by', reason_by, 'at', reason_at)), '{}'::jsonb) into v_reason
    from (select distinct on (key) key, reason, reason_by, reason_at from public.upche_margin_lows
          where month = p_month and reason <> '' order by key, id) r;

  delete from public.upche_margin_summary where month = p_month;   -- 하위 표는 cascade 로 함께 삭제
  insert into public.upche_margin_summary(month, customers, ext_customers, ja_customers, upper, ja_margin, hq_incentive, total, margin,
    per_customer, low_count, neg_count, saved_at, saved_by, memo)
  select p_month, coalesce((s->>'customers')::numeric, 0), coalesce((s->>'extCustomers')::numeric, 0), coalesce((s->>'jaCustomers')::numeric, 0),
    round(coalesce((s->>'upper')::numeric, 0)), round(coalesce((s->>'jaMargin')::numeric, 0)), round(coalesce((s->>'hqIncentive')::numeric, 0)),
    round(coalesce((s->>'total')::numeric, 0)), round(coalesce((s->>'margin')::numeric, 0)), round(coalesce((s->>'perCustomer')::numeric, 0)),
    coalesce((s->>'lowCount')::numeric, 0), coalesce((s->>'negCount')::numeric, 0),
    coalesce(private.upche_ts(s->>'savedAt'), now()), coalesce(nullif(s->>'savedBy', ''), private.upche_who(a)),
    coalesce(nullif(p_memo, ''), s->>'memo', '')
  from (select coalesce(p_summary, '{}'::jsonb) as s) x;

  insert into public.upche_margin_partners(month, partner, ja, customers, upper, ja_margin, hq_incentive, total, margin, low_count, neg_count, memo, memo_by, memo_at)
  select p_month, p->>'partner', coalesce((p->>'ja')::boolean, false), coalesce((p->>'customers')::numeric, 0),
    round(coalesce((p->>'upper')::numeric, 0)), round(coalesce((p->>'jaMargin')::numeric, 0)), round(coalesce((p->>'hqIncentive')::numeric, 0)),
    round(coalesce((p->>'total')::numeric, 0)), round(coalesce((p->>'margin')::numeric, 0)), coalesce((p->>'lowCount')::numeric, 0), coalesce((p->>'negCount')::numeric, 0),
    coalesce(nullif(p->>'memo', ''), v_memo->(p->>'partner')->>'memo', ''),
    case when coalesce(p->>'memo', '') <> '' then coalesce(p->>'memoBy', '') else coalesce(v_memo->(p->>'partner')->>'by', '') end,
    case when coalesce(p->>'memo', '') <> '' then private.upche_ts(p->>'memoAt') else (v_memo->(p->>'partner')->>'at')::timestamptz end
  from jsonb_array_elements(coalesce(p_partners, '[]'::jsonb)) p
  on conflict (month, partner) do nothing;

  insert into public.upche_margin_categories(month, category, customers, upper, ja_margin, hq_incentive, total, margin, low_count, neg_count)
  select p_month, c->>'category', coalesce((c->>'customers')::numeric, 0),
    round(coalesce((c->>'upper')::numeric, 0)), round(coalesce((c->>'jaMargin')::numeric, 0)), round(coalesce((c->>'hqIncentive')::numeric, 0)),
    round(coalesce((c->>'total')::numeric, 0)), round(coalesce((c->>'margin')::numeric, 0)), coalesce((c->>'lowCount')::numeric, 0), coalesce((c->>'negCount')::numeric, 0)
  from jsonb_array_elements(coalesce(p_categories, '[]'::jsonb)) c
  on conflict (month, category) do nothing;

  insert into public.upche_margin_partner_cats(month, partner, category, customers, upper, ja_margin, hq_incentive, total, margin, low_count, neg_count)
  select p_month, c->>'partner', c->>'category', coalesce((c->>'customers')::numeric, 0),
    round(coalesce((c->>'upper')::numeric, 0)), round(coalesce((c->>'jaMargin')::numeric, 0)), round(coalesce((c->>'hqIncentive')::numeric, 0)),
    round(coalesce((c->>'total')::numeric, 0)), round(coalesce((c->>'margin')::numeric, 0)), coalesce((c->>'lowCount')::numeric, 0), coalesce((c->>'negCount')::numeric, 0)
  from jsonb_array_elements(coalesce(p_partner_cats, '[]'::jsonb)) c
  on conflict (month, partner, category) do nothing;

  insert into public.upche_margin_lows(month, key, name, phone, partner, ja, upper_shop, carrier, category, products,
    upper, ja_margin, hq_incentive, total, margin, reason, reason_by, reason_at)
  select p_month, coalesce(l->>'key', ''), coalesce(l->>'name', ''), coalesce(l->>'phone', ''), coalesce(l->>'partner', ''), coalesce((l->>'ja')::boolean, false),
    coalesce(l->>'upperShop', ''), coalesce(l->>'carrier', ''), coalesce(l->>'category', ''), coalesce(l->>'products', ''),
    round(coalesce((l->>'upper')::numeric, 0)), round(coalesce((l->>'jaMargin')::numeric, 0)), round(coalesce((l->>'hqIncentive')::numeric, 0)),
    round(coalesce((l->>'total')::numeric, 0)), round(coalesce((l->>'margin')::numeric, 0)),
    coalesce(nullif(l->>'reason', ''), v_reason->(l->>'key')->>'reason', ''),
    case when coalesce(l->>'reason', '') <> '' then coalesce(l->>'reasonBy', '') else coalesce(v_reason->(l->>'key')->>'by', '') end,
    case when coalesce(l->>'reason', '') <> '' then private.upche_ts(l->>'reasonAt') else (v_reason->(l->>'key')->>'at')::timestamptz end
  from jsonb_array_elements(coalesce(p_lows, '[]'::jsonb)) with ordinality as x(l, ord)
  order by x.ord;

  select count(*) into v_kept_r from jsonb_object_keys(v_reason) k
   where exists (select 1 from public.upche_margin_lows l where l.month = p_month and l.key = k);
  select count(*) into v_kept_m from jsonb_object_keys(v_memo) k
   where exists (select 1 from public.upche_margin_partners p where p.month = p_month and p.partner = k);
  return jsonb_build_object('keptReasons', v_kept_r, 'keptMemos', v_kept_m);
end $$;

create or replace function public.upche_margin_delete(p_token text, p_month text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  delete from public.upche_margin_summary where month = p_month;   -- 하위 표 cascade
  return true;
end $$;

create or replace function public.upche_margin_partner_memo(p_token text, p_month text, p_partner text, p_memo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); v_memo text := btrim(coalesce(p_memo, '')); v_at timestamptz := now();
begin
  update public.upche_margin_partners
     set memo = v_memo, memo_by = case when v_memo = '' then '' else private.upche_who(a) end, memo_at = case when v_memo = '' then null else v_at end
   where month = p_month and partner = p_partner;
  if not found then raise exception '해당 협력점을 찾을 수 없어요.'; end if;
  return jsonb_build_object('memoBy', case when v_memo = '' then '' else private.upche_who(a) end,
                            'memoAt', case when v_memo = '' then '' else private.upche_fmt(v_at) end);
end $$;

create or replace function public.upche_margin_reason(p_token text, p_month text, p_key text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); v_r text := btrim(coalesce(p_reason, '')); v_at timestamptz := now();
begin
  update public.upche_margin_lows
     set reason = v_r, reason_by = case when v_r = '' then '' else private.upche_who(a) end, reason_at = case when v_r = '' then null else v_at end
   where month = p_month and key = p_key;
  if not found then raise exception '해당 고객을 찾을 수 없어요.'; end if;
  return jsonb_build_object('reasonBy', case when v_r = '' then '' else private.upche_who(a) end,
                            'reasonAt', case when v_r = '' then '' else private.upche_fmt(v_at) end);
end $$;

-- ---------------------------------------------------------------------
-- 계정 관리 (관리자만)
-- ---------------------------------------------------------------------
create or replace function public.upche_account_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token, true);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'role', role, 'enabled', enabled,
      'mustChange', must_change, 'lastLogin', private.upche_fmt(last_login_at)) order by role, id)
    from private.upche_accounts), '[]'::jsonb);
end $$;

-- 새 계정 만들기 / 고치기. 비밀번호를 비워두면 그대로 둠 (새 계정은 필수)
create or replace function public.upche_account_save(p_token text, p_id text, p_name text, p_password text,
  p_role text, p_enabled boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token, true); v_id text := btrim(coalesce(p_id, ''));
begin
  if v_id !~ '^[A-Za-z0-9._-]{2,40}$' then raise exception '아이디는 영문·숫자·._- 로 2~40자여야 해요.'; end if;
  if coalesce(p_role, 'user') not in ('admin', 'user') then raise exception '권한 값이 잘못됐어요.'; end if;
  if v_id = a.id and (coalesce(p_role, 'user') <> 'admin' or not coalesce(p_enabled, true)) then
    raise exception '내 계정의 관리자 권한은 내릴 수 없어요.';
  end if;
  if exists (select 1 from private.upche_accounts where id = v_id) then
    update private.upche_accounts
       set name = coalesce(p_name, name), role = coalesce(p_role, role), enabled = coalesce(p_enabled, enabled),
           pw_hash = case when coalesce(p_password, '') <> '' then extensions.crypt(p_password, extensions.gen_salt('bf')) else pw_hash end,
           must_change = case when coalesce(p_password, '') <> '' then true else must_change end
     where id = v_id;
    if coalesce(p_password, '') <> '' or not coalesce(p_enabled, true) then
      delete from private.upche_sessions where account_id = v_id;
    end if;
  else
    if length(coalesce(p_password, '')) < 4 then raise exception '새 계정의 비밀번호를 4자 이상으로 넣어주세요.'; end if;
    insert into private.upche_accounts(id, name, pw_hash, role, enabled, must_change)
    values (v_id, coalesce(p_name, ''), extensions.crypt(p_password, extensions.gen_salt('bf')), coalesce(p_role, 'user'), coalesce(p_enabled, true), true);
  end if;
  return true;
end $$;

create or replace function public.upche_account_delete(p_token text, p_id text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token, true);
begin
  if p_id = a.id then raise exception '내 계정은 지울 수 없어요.'; end if;
  delete from private.upche_accounts where id = p_id;
  return true;
end $$;


-- ---------------------------------------------------------------------
-- 회의 결정 (업체 × 통신사). 회의는 그 달 실적(month)을 보고 함
-- ---------------------------------------------------------------------
create table if not exists public.upche_decisions (
  month       text not null check (month ~ '^\d{4}-\d{2}$'),
  partner     text not null,
  telco       text not null,
  action      text not null check (action in ('keep','grade','stop','hold')),   -- 유지 / 등급변경 / 정책중단(휴면) / 유예
  grade_from  text not null default '',
  grade_to    text not null default '',
  memo        text not null default '',
  decided_by  text not null default '',
  decided_at  timestamptz not null default now(),
  admin_done  boolean not null default false,
  admin_by    text not null default '',
  admin_at    timestamptz,
  kakao_done  boolean not null default false,
  kakao_by    text not null default '',
  kakao_at    timestamptz,
  primary key (month, partner, telco)
);
comment on table public.upche_decisions is '업체회의 · 회의 결정 (업체 × 통신사, 어드민·카톡 반영 체크)';
alter table public.upche_decisions enable row level security;
revoke all on public.upche_decisions from anon, authenticated;

create or replace function private.upche_dec_json(d public.upche_decisions) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('month', d.month, 'partner', d.partner, 'telco', d.telco, 'action', d.action,
    'gradeFrom', d.grade_from, 'gradeTo', d.grade_to, 'memo', d.memo, 'by', d.decided_by, 'at', private.upche_fmt(d.decided_at),
    'admin', d.admin_done, 'adminBy', d.admin_by, 'adminAt', private.upche_fmt(d.admin_at),
    'kakao', d.kakao_done, 'kakaoBy', d.kakao_by, 'kakaoAt', private.upche_fmt(d.kakao_at))
$$;
revoke all on function private.upche_dec_json(public.upche_decisions) from public, anon, authenticated;

create or replace function public.upche_decision_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  return coalesce((select jsonb_agg(private.upche_dec_json(d) order by d.month, d.telco, d.partner) from public.upche_decisions d), '[]'::jsonb);
end $$;

-- 결정 저장(같은 업체·통신사는 덮어씀). 결정 내용이 바뀌면 반영 체크는 다시 해야 하므로 풀어둠
create or replace function public.upche_decision_save(p_token text, p_month text, p_partner text, p_telco text,
  p_action text, p_from text, p_to text, p_memo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); r public.upche_decisions;
begin
  if p_month !~ '^\d{4}-\d{2}$' then raise exception '월 형식 오류: %', p_month; end if;
  if coalesce(p_action, '') not in ('keep','grade','stop','hold') then raise exception '결정 종류가 잘못됐어요.'; end if;
  if btrim(coalesce(p_partner, '')) = '' or btrim(coalesce(p_telco, '')) = '' then raise exception '업체와 통신사를 골라주세요.'; end if;
  insert into public.upche_decisions as t (month, partner, telco, action, grade_from, grade_to, memo, decided_by, decided_at)
  values (p_month, p_partner, p_telco, p_action, coalesce(p_from, ''), case when p_action = 'grade' then coalesce(p_to, '') else '' end,
          btrim(coalesce(p_memo, '')), private.upche_who(a), now())
  on conflict (month, partner, telco) do update set
    action = excluded.action, grade_from = excluded.grade_from, grade_to = excluded.grade_to, memo = excluded.memo,
    decided_by = excluded.decided_by, decided_at = excluded.decided_at,
    admin_done = case when (t.action, t.grade_to) is distinct from (excluded.action, excluded.grade_to) then false else t.admin_done end,
    kakao_done = case when (t.action, t.grade_to) is distinct from (excluded.action, excluded.grade_to) then false else t.kakao_done end
  returning * into r;
  return private.upche_dec_json(r);
end $$;

create or replace function public.upche_decision_delete(p_token text, p_month text, p_partner text, p_telco text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  delete from public.upche_decisions where month = p_month and partner = p_partner and telco = p_telco;
  return true;
end $$;

-- 어드민 / 카톡방 반영 체크
create or replace function public.upche_decision_check(p_token text, p_month text, p_partner text, p_telco text,
  p_field text, p_done boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); r public.upche_decisions;
begin
  if p_field = 'admin' then
    update public.upche_decisions set admin_done = p_done, admin_by = case when p_done then private.upche_who(a) else '' end,
      admin_at = case when p_done then now() else null end
    where month = p_month and partner = p_partner and telco = p_telco returning * into r;
  elsif p_field = 'kakao' then
    update public.upche_decisions set kakao_done = p_done, kakao_by = case when p_done then private.upche_who(a) else '' end,
      kakao_at = case when p_done then now() else null end
    where month = p_month and partner = p_partner and telco = p_telco returning * into r;
  else
    raise exception '항목이 잘못됐어요.';
  end if;
  if r.partner is null then raise exception '해당 결정을 찾을 수 없어요.'; end if;
  return private.upche_dec_json(r);
end $$;

-- ---------------------------------------------------------------------
-- 실행 권한: 화면(anon 키)은 public.upche_* 함수만 부를 수 있음
-- ---------------------------------------------------------------------
revoke all on function private.upche_hash(text), private.upche_fmt(timestamptz), private.upche_ts(text),
  private.upche_auth(text, boolean), private.upche_who(private.upche_accounts) from public, anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'upche\_%' loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 관리자 계정 (처음 한 번). 아래 '여기에_임시비밀번호' 를 원하는 임시 비밀번호로 바꾸고 실행하세요.
-- 처음 로그인하면 새 비밀번호로 바꾸라는 창이 떠요. 이미 admin 계정이 있으면 아무것도 바뀌지 않아요.
-- ---------------------------------------------------------------------
insert into private.upche_accounts(id, name, pw_hash, role, must_change)
values ('admin', '웨이브넷', extensions.crypt('여기에_임시비밀번호', extensions.gen_salt('bf')), 'admin', true)
on conflict (id) do nothing;
