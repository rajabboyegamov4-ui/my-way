-- Kunlik dollar limiti olib tashlandi (2026-10-07, bazaga qo'llangan).
create or replace function public.mw_credit(p_uid uuid, p_amount integer, p_reason text, p_ref text, p_capped boolean)
returns integer language plpgsql security definer set search_path to 'public' as $function$
begin
  if p_amount is null or p_amount <= 0 then return 0; end if;
  perform 1 from profiles where id = p_uid for update;
  update profiles set balance = balance + p_amount, total_earned = total_earned + p_amount where id = p_uid;
  insert into ledger(user_id, amount, reason, ref, capped) values (p_uid, p_amount, p_reason, p_ref, p_capped);
  return p_amount;
end $function$;
