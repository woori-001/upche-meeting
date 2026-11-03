-- ---------------------------------------------------------------------
-- 코드실적 — 월별 결과 저장 (개인정보 없이 집계만)
-- ---------------------------------------------------------------------
create table if not exists public.upche_code_runs (
  month      text primary key check (month ~ '^\d{4}-\d{2}$'),
  result     jsonb not null,          -- SKYLIFE·SKB·SK매직·유선기타 집계
  diag       jsonb not null default '{}'::jsonb,   -- 조건·파일 정보
  hwansu     jsonb not null default '{}'::jsonb,   -- 환수 체크 합계(고객 목록 없음)
  source     text not null default '',            -- 어드민 / 파일
  saved_by   text not null default '',
  saved_at   timestamptz not null default now()
);
comment on table public.upche_code_runs is '코드실적 · 월별 저장 결과';
alter table public.upche_code_runs enable row level security;
revoke all on public.upche_code_runs from anon, authenticated;

create or replace function public.upche_code_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('month', c.month, 'result', c.result, 'diag', c.diag, 'hwansu', c.hwansu,
    'source', c.source, 'savedBy', c.saved_by, 'savedAt', private.upche_fmt(c.saved_at)) order by c.month) from public.upche_code_runs c), '[]'::jsonb);
end $$;

-- 같은 달은 덮어씀
create or replace function public.upche_code_save(p_token text, p_month text, p_result jsonb, p_diag jsonb, p_hwansu jsonb, p_source text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token);
begin
  if p_month !~ '^\d{4}-\d{2}$' then raise exception '월 형식 오류: %', p_month; end if;
  insert into public.upche_code_runs as t (month, result, diag, hwansu, source, saved_by, saved_at)
  values (p_month, coalesce(p_result, '{}'::jsonb), coalesce(p_diag, '{}'::jsonb), coalesce(p_hwansu, '{}'::jsonb), coalesce(p_source, ''), private.upche_who(a), now())
  on conflict (month) do update set result = excluded.result, diag = excluded.diag, hwansu = excluded.hwansu, source = excluded.source,
    saved_by = excluded.saved_by, saved_at = excluded.saved_at;
  return jsonb_build_object('month', p_month, 'savedBy', private.upche_who(a), 'savedAt', private.upche_fmt(now()));
end $$;

create or replace function public.upche_code_delete(p_token text, p_month text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  delete from public.upche_code_runs where month = p_month;
  return true;
end $$;

revoke all on function public.upche_code_list(text) from public;
grant execute on function public.upche_code_list(text) to anon, authenticated;
revoke all on function public.upche_code_save(text, text, jsonb, jsonb, jsonb, text) from public;
grant execute on function public.upche_code_save(text, text, jsonb, jsonb, jsonb, text) to anon, authenticated;
revoke all on function public.upche_code_delete(text, text) from public;
grant execute on function public.upche_code_delete(text, text) to anon, authenticated;
