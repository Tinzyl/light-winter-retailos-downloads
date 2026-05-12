-- Light Winter Technologies internal Supabase admin dashboard.
-- Run this in Supabase SQL Editor while logged into your own Supabase project.
-- Do not place these controls in the customer APK.

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

create or replace view public.lwr_admin_shop_overview as
select
  o.id as organization_id,
  o.name as shop_name,
  case when o.fiscal_mode then 'fiscal' else 'non_fiscal' end as mode,
  o.phone,
  o.address,
  o.recovery_code,
  o.active as shop_active,
  count(distinct b.id) filter (where b.active = true) as active_branches,
  count(distinct d.device_uid) as devices,
  count(distinct d.device_uid) filter (where d.active = true) as active_devices,
  count(distinct u.id) filter (where u.active = true) as active_users,
  count(distinct p.id) filter (where p.active = true) as active_products,
  count(distinct s.id) as sales_count,
  coalesce(sum(s.total_cents), 0) as lifetime_sales_cents,
  max(d.last_seen_at) as last_device_seen_at,
  o.created_at
from public.lwr_organizations o
left join public.lwr_branches b on b.organization_id = o.id
left join public.lwr_devices d on d.organization_id = o.id
left join public.lwr_users u on u.organization_id = o.id
left join public.lwr_products p on p.organization_id = o.id
left join public.lwr_sales s on s.organization_id = o.id
group by o.id;

create or replace view public.lwr_admin_device_overview as
select
  d.device_uid,
  d.organization_id,
  o.name as shop_name,
  d.branch_id,
  b.name as branch_name,
  d.platform,
  d.device_name,
  d.active as device_active,
  d.created_at as device_created_at,
  d.last_seen_at,
  case
    when d.last_seen_at is null then 'never_seen'
    when d.last_seen_at < now() - interval '7 days' then 'offline_7_days'
    when d.last_seen_at < now() - interval '2 days' then 'offline_2_days'
    else 'recent'
  end as seen_status,
  l.status as license_status,
  l.expires_at as license_expires_at,
  case
    when l.expires_at is null then 'unlicensed'
    when l.expires_at < now() then 'expired'
    when l.expires_at < now() + interval '3 days' then 'expiring_soon'
    else 'licensed'
  end as license_health,
  coalesce(s.sales_count, 0) as sales_count,
  coalesce(s.sales_cents, 0) as sales_cents
from public.lwr_devices d
join public.lwr_organizations o on o.id = d.organization_id
left join public.lwr_branches b on b.id = d.branch_id
left join lateral (
  select status, expires_at
  from public.lwr_licenses lx
  where lx.device_uid = d.device_uid
    and lx.status = 'active'
  order by lx.expires_at desc
  limit 1
) l on true
left join lateral (
  select count(*) as sales_count, coalesce(sum(total_cents), 0) as sales_cents
  from public.lwr_sales sx
  where sx.device_uid = d.device_uid
) s on true;

create or replace view public.lwr_admin_suspicious_devices as
select *
from public.lwr_admin_device_overview
where device_active = false
   or license_health in ('unlicensed', 'expired', 'expiring_soon')
   or seen_status in ('never_seen', 'offline_7_days')
order by
  case
    when device_active = false then 1
    when license_health = 'expired' then 2
    when license_health = 'unlicensed' then 3
    when license_health = 'expiring_soon' then 4
    else 5
  end,
  last_seen_at desc nulls last;

create or replace view public.lwr_admin_license_overview as
select
  lt.token,
  lt.duration_mode,
  lt.duration_value,
  lt.target_device_uid,
  lt.used,
  lt.used_by_device_uid,
  lt.created_at as token_created_at,
  l.device_uid,
  l.status,
  l.expires_at,
  case
    when l.expires_at is null and lt.used = false then 'unused'
    when l.expires_at < now() then 'expired'
    when l.expires_at < now() + interval '3 days' then 'expiring_soon'
    when l.status = 'active' then 'active'
    else coalesce(l.status, 'unknown')
  end as license_health
from public.lwr_license_tokens lt
left join public.lwr_licenses l on l.token = lt.token
order by lt.created_at desc;

create or replace view public.lwr_admin_reset_voucher_overview as
select
  rt.token,
  rt.organization_id,
  o.name as shop_name,
  rt.target_device_uid,
  rt.purpose,
  rt.used,
  rt.used_by_device_uid,
  rt.used_at,
  rt.created_at
from public.lwr_owner_reset_tokens rt
left join public.lwr_organizations o on o.id = rt.organization_id
order by rt.created_at desc;

create or replace function public.lwr_admin_deactivate_device(
  p_device_uid text,
  p_reason text default 'Light Winter admin deactivation'
)
returns table(device_uid text, device_active boolean, shop_name text, branch_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  device_row public.lwr_devices%rowtype;
begin
  select * into device_row
  from public.lwr_devices
  where lwr_devices.device_uid = p_device_uid
  limit 1;

  if device_row.device_uid is null then
    raise exception 'Device not found.';
  end if;

  update public.lwr_devices
  set active = false, last_seen_at = now()
  where lwr_devices.device_uid = p_device_uid;

  update public.lwr_licenses
  set status = 'deactivated'
  where lwr_licenses.device_uid = p_device_uid
    and status = 'active';

  insert into public.lwr_audit_events(organization_id, branch_id, device_uid, action, details)
  values (
    device_row.organization_id,
    device_row.branch_id,
    p_device_uid,
    'light_winter_device_deactivated',
    jsonb_build_object('reason', coalesce(p_reason, ''))
  );

  return query
  select d.device_uid, d.active, o.name, b.name
  from public.lwr_devices d
  join public.lwr_organizations o on o.id = d.organization_id
  left join public.lwr_branches b on b.id = d.branch_id
  where d.device_uid = p_device_uid;
end;
$$;

create or replace function public.lwr_admin_reactivate_device(
  p_device_uid text,
  p_reason text default 'Light Winter admin reactivation'
)
returns table(device_uid text, device_active boolean, shop_name text, branch_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  device_row public.lwr_devices%rowtype;
begin
  select * into device_row
  from public.lwr_devices
  where lwr_devices.device_uid = p_device_uid
  limit 1;

  if device_row.device_uid is null then
    raise exception 'Device not found.';
  end if;

  update public.lwr_devices
  set active = true, last_seen_at = now()
  where lwr_devices.device_uid = p_device_uid;

  insert into public.lwr_audit_events(organization_id, branch_id, device_uid, action, details)
  values (
    device_row.organization_id,
    device_row.branch_id,
    p_device_uid,
    'light_winter_device_reactivated',
    jsonb_build_object('reason', coalesce(p_reason, ''))
  );

  return query
  select d.device_uid, d.active, o.name, b.name
  from public.lwr_devices d
  join public.lwr_organizations o on o.id = d.organization_id
  left join public.lwr_branches b on b.id = d.branch_id
  where d.device_uid = p_device_uid;
end;
$$;

-- Do not grant these admin functions to anon. Use them from Supabase SQL Editor only.
revoke all on function public.lwr_admin_deactivate_device(text, text) from anon;
revoke all on function public.lwr_admin_reactivate_device(text, text) from anon;
