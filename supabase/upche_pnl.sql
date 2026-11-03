-- ---------------------------------------------------------------------
-- 유통매출(손익매출 계산기) — 업체회의 계정으로 쓰는 서버 함수
-- 데이터는 계산기가 쓰던 dist_pnl_runs / dist_pnl_lines 를 그대로 씀 (예전 계산기 주소도 계속 동작)
-- ---------------------------------------------------------------------
create or replace function public.upche_pnl_runs(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'period', r.period, 'status', r.status, 'seg_status', r.seg_status, 'note', r.note,
    'files', r.files, 'summary', r.summary, 'rules', r.rules, 'created_by', r.created_by, 'created_at', r.created_at,
    'confirmed_by', r.confirmed_by, 'confirmed_at', r.confirmed_at) order by r.period desc, r.created_at desc)
    from public.dist_pnl_runs r), '[]'::jsonb);
end $$;

create or replace function public.upche_pnl_lines(p_token text, p_run uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from public.dist_pnl_lines l where l.run_id = p_run), '[]'::jsonb);
end $$;

create or replace function public.upche_pnl_save(p_token text, p_period date, p_seg_status jsonb, p_note text, p_files jsonb,
  p_summary jsonb, p_rules jsonb, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a private.upche_accounts := private.upche_auth(p_token); v_id uuid;
begin
  insert into public.dist_pnl_runs (period, status, seg_status, note, files, summary, rules, created_by)
  values (p_period, '가정산', coalesce(p_seg_status, '{}'::jsonb), p_note, coalesce(p_files, '[]'::jsonb), p_summary, coalesce(p_rules, '{}'::jsonb), private.upche_who(a))
  returning id into v_id;
  insert into public.dist_pnl_lines (run_id, segment, upper_name, side, item, partner_type, included, cnt, amount, gift_cash, gift_goods, gift_coupon, jj_fee, direct_gift)
  select v_id, l.segment, l.upper_name, l.side, l.item, l.partner_type, l.included, l.cnt, l.amount, l.gift_cash, l.gift_goods, l.gift_coupon, coalesce(l.jj_fee, 0), l.direct_gift
    from jsonb_to_recordset(coalesce(p_lines, '[]'::jsonb)) as l(segment text, upper_name text, side text, item text, partner_type text,
         included boolean, cnt integer, amount bigint, gift_cash bigint, gift_goods bigint, gift_coupon bigint, jj_fee bigint, direct_gift bigint);
  return v_id;
end $$;

revoke all on function public.upche_pnl_runs(text) from public;
grant execute on function public.upche_pnl_runs(text) to anon, authenticated;
revoke all on function public.upche_pnl_lines(text, uuid) from public;
grant execute on function public.upche_pnl_lines(text, uuid) to anon, authenticated;
revoke all on function public.upche_pnl_save(text, date, jsonb, text, jsonb, jsonb, jsonb, jsonb) from public;
grant execute on function public.upche_pnl_save(text, date, jsonb, text, jsonb, jsonb, jsonb, jsonb) to anon, authenticated;

-- 저장 기록 삭제
create or replace function public.upche_pnl_delete(p_token text, p_run uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform private.upche_auth(p_token);
  delete from public.dist_pnl_lines where run_id = p_run;
  delete from public.dist_pnl_runs where id = p_run;
  return true;
end $$;
revoke all on function public.upche_pnl_delete(text, uuid) from public;
grant execute on function public.upche_pnl_delete(text, uuid) to anon, authenticated;
