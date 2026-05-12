-- Light Winter owner username/PIN reset patch.
-- Run this in Supabase SQL Editor if the app says:
-- Could not find the function public.lwr_reset_owner_access(...)

create table if not exists public.lwr_owner_reset_tokens (
  token text primary key,
  organization_id text references public.lwr_organizations(id) on delete cascade,
  target_device_uid text,
  purpose text not null check (purpose in ('owner_pin_reset', 'owner_username_lookup', 'owner_access_reset')) default 'owner_access_reset',
  used boolean not null default false,
  used_by_device_uid text,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.lwr_owner_reset_tokens enable row level security;

drop policy if exists lwr_owner_reset_tokens_no_direct_select on public.lwr_owner_reset_tokens;
drop policy if exists lwr_owner_reset_tokens_no_direct_insert on public.lwr_owner_reset_tokens;
drop policy if exists lwr_owner_reset_tokens_no_direct_update on public.lwr_owner_reset_tokens;
drop policy if exists lwr_owner_reset_tokens_no_direct_delete on public.lwr_owner_reset_tokens;

create policy lwr_owner_reset_tokens_no_direct_select on public.lwr_owner_reset_tokens for select to anon using (false);
create policy lwr_owner_reset_tokens_no_direct_insert on public.lwr_owner_reset_tokens for insert to anon with check (false);
create policy lwr_owner_reset_tokens_no_direct_update on public.lwr_owner_reset_tokens for update to anon using (false) with check (false);
create policy lwr_owner_reset_tokens_no_direct_delete on public.lwr_owner_reset_tokens for delete to anon using (false);

create index if not exists idx_lwr_owner_reset_tokens_org
  on public.lwr_owner_reset_tokens(organization_id, used, created_at desc);

create or replace function public.lwr_reset_owner_access(
  p_recovery_code text,
  p_device_uid text,
  p_token text,
  p_new_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_code text := upper(regexp_replace(coalesce(p_recovery_code, ''), '[^A-Z0-9]', '', 'g'));
  normalized_token text := upper(regexp_replace(coalesce(p_token, ''), '[^A-Z0-9]', '', 'g'));
  org_row public.lwr_organizations%rowtype;
  reset_row public.lwr_owner_reset_tokens%rowtype;
  owner_row public.lwr_users%rowtype;
begin
  if normalized_code = '' then
    raise exception 'Recovery code is required.';
  end if;
  if normalized_token = '' then
    raise exception 'Reset voucher is required.';
  end if;
  if trim(coalesce(p_device_uid, '')) = '' then
    raise exception 'Device ID is required.';
  end if;

  select * into org_row
  from public.lwr_organizations
  where recovery_code = normalized_code and active = true
  limit 1;

  if org_row.id is null then
    raise exception 'Recovery code not found.';
  end if;

  select * into reset_row
  from public.lwr_owner_reset_tokens
  where token = normalized_token
    and used = false
    and (organization_id is null or organization_id = org_row.id)
    and (target_device_uid is null or target_device_uid = '' or target_device_uid = p_device_uid)
  limit 1;

  if reset_row.token is null then
    raise exception 'Reset voucher not found, already used, or not assigned to this device/shop.';
  end if;

  select * into owner_row
  from public.lwr_users
  where organization_id = org_row.id
    and active = true
    and (lower(role) = 'owner' or permissions::text ilike '%all%')
  order by created_at asc
  limit 1;

  if owner_row.id is null then
    raise exception 'No owner account found for this shop.';
  end if;

  if nullif(trim(coalesce(p_new_pin, '')), '') is not null then
    update public.lwr_users
    set pin_plain = trim(p_new_pin)
    where id = owner_row.id;
  end if;

  update public.lwr_owner_reset_tokens
  set used = true, used_by_device_uid = p_device_uid, used_at = now()
  where token = reset_row.token;

  insert into public.lwr_audit_events(organization_id, branch_id, device_uid, actor_user_id, action, details)
  select org_row.id, b.id, p_device_uid, owner_row.id, 'owner_access_reset',
         jsonb_build_object('purpose', reset_row.purpose)
  from public.lwr_branches b
  where b.organization_id = org_row.id and b.active = true
  order by b.created_at asc
  limit 1;

  return jsonb_build_object(
    'shop_name', org_row.name,
    'owner_username', owner_row.username,
    'pin_reset', nullif(trim(coalesce(p_new_pin, '')), '') is not null
  );
end;
$$;

grant execute on function public.lwr_reset_owner_access(text, text, text, text) to anon;
