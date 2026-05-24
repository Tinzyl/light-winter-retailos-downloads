alter table public.lwr_license_tokens
  add column if not exists target_device_uid text;

alter table public.lwr_organizations add column if not exists registered_name text not null default '';
alter table public.lwr_organizations add column if not exists tin text not null default '';
alter table public.lwr_organizations add column if not exists vat_number text not null default '';
alter table public.lwr_organizations add column if not exists zimra_device_id text not null default '';
alter table public.lwr_organizations add column if not exists fiscal_serial_number text not null default '';
alter table public.lwr_organizations add column if not exists fiscal_qr_url text not null default '';
alter table public.lwr_organizations add column if not exists recovery_code text not null default '';
alter table public.lwr_sales add column if not exists fiscal_status text not null default 'not_required';
alter table public.lwr_sales add column if not exists discount_cents integer not null default 0;
alter table public.lwr_sales add column if not exists paid_cents integer not null default 0;
alter table public.lwr_sales add column if not exists change_cents integer not null default 0;
alter table public.lwr_sales add column if not exists debt_cents integer not null default 0;

create table if not exists public.lwr_sale_voids (
  id text primary key,
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  branch_id text not null references public.lwr_branches(id) on delete restrict,
  sale_id text not null references public.lwr_sales(id) on delete cascade,
  device_uid text not null default '',
  user_id text,
  user_name text not null default '',
  void_type text not null check (void_type in ('full_void', 'partial_void', 'full_return', 'partial_return')) default 'partial_void',
  reason text not null default '',
  total_cents integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.lwr_sale_void_lines (
  id text primary key,
  void_id text not null references public.lwr_sale_voids(id) on delete cascade,
  product_id text not null references public.lwr_products(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_price_cents integer not null default 0,
  line_total_cents integer not null default 0
);

alter table public.lwr_sale_voids enable row level security;
alter table public.lwr_sale_void_lines enable row level security;
drop policy if exists lwr_anon_all on public.lwr_sale_voids;
drop policy if exists lwr_anon_all on public.lwr_sale_void_lines;
create policy lwr_anon_all on public.lwr_sale_voids for all to anon using (true) with check (true);
create policy lwr_anon_all on public.lwr_sale_void_lines for all to anon using (true) with check (true);
create index if not exists idx_lwr_sale_voids_org_branch on public.lwr_sale_voids(organization_id, branch_id, created_at desc);
create index if not exists idx_lwr_sale_void_lines_void on public.lwr_sale_void_lines(void_id);

create unique index if not exists idx_lwr_organizations_recovery_code
  on public.lwr_organizations(recovery_code)
  where recovery_code <> '';

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
create index if not exists idx_lwr_owner_reset_tokens_org on public.lwr_owner_reset_tokens(organization_id, used, created_at desc);

drop policy if exists lwr_anon_all on public.lwr_license_tokens;
drop policy if exists lwr_license_tokens_no_direct_select on public.lwr_license_tokens;
drop policy if exists lwr_license_tokens_no_direct_insert on public.lwr_license_tokens;
drop policy if exists lwr_license_tokens_no_direct_update on public.lwr_license_tokens;
drop policy if exists lwr_license_tokens_no_direct_delete on public.lwr_license_tokens;

create policy lwr_license_tokens_no_direct_select on public.lwr_license_tokens for select to anon using (false);
create policy lwr_license_tokens_no_direct_insert on public.lwr_license_tokens for insert to anon with check (false);
create policy lwr_license_tokens_no_direct_update on public.lwr_license_tokens for update to anon using (false) with check (false);
create policy lwr_license_tokens_no_direct_delete on public.lwr_license_tokens for delete to anon using (false);

create or replace function public.lwr_apply_license(p_device_uid text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  token_row public.lwr_license_tokens%rowtype;
  expires_at_value timestamptz;
begin
  select *
    into token_row
    from public.lwr_license_tokens
   where regexp_replace(token, '[^A-Z0-9]', '', 'g') = regexp_replace(upper(trim(p_token)), '[^A-Z0-9]', '', 'g')
     and used = false
     and (target_device_uid is null or target_device_uid = p_device_uid)
   for update;

  if not found then
    raise exception 'License voucher not found, already used, or not assigned to this device.';
  end if;

  if not exists (select 1 from public.lwr_devices where device_uid = p_device_uid and active = true) then
    raise exception 'Device is not activated. Create/join a shop first.';
  end if;

  expires_at_value :=
    case token_row.duration_mode
      when 'minutes' then now() + make_interval(mins => token_row.duration_value)
      else now() + make_interval(days => token_row.duration_value)
    end;

  insert into public.lwr_licenses(device_uid, token, status, duration_mode, duration_value, expires_at)
  values (p_device_uid, token_row.token, 'active', token_row.duration_mode, token_row.duration_value, expires_at_value);

  update public.lwr_license_tokens
     set used = true,
         used_by_device_uid = p_device_uid
   where token = token_row.token;

  return jsonb_build_object(
    'device_uid', p_device_uid,
    'token', token_row.token,
    'expires_at', expires_at_value,
    'server_time', now()
  );
end;
$$;

grant execute on function public.lwr_apply_license(text, text) to anon;

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

create or replace function public.lwr_apply_license(p_device_uid text, p_token text, p_organization_id text, p_branch_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_organization_id is not null and p_branch_id is not null then
    insert into public.lwr_devices(device_uid, organization_id, branch_id, device_name, platform, active)
    values (p_device_uid, p_organization_id, p_branch_id, 'Light Winter POS Device', 'flutter', true)
    on conflict (device_uid) do update
      set organization_id = excluded.organization_id,
          branch_id = excluded.branch_id,
          active = true,
          last_seen_at = now();
  end if;

  return public.lwr_apply_license(p_device_uid, p_token);
end;
$$;

grant execute on function public.lwr_apply_license(text, text, text, text) to anon;

create or replace function public.lwr_activate_device_license(
  p_device_uid text,
  p_token text,
  p_organization_id text,
  p_branch_id text,
  p_platform text default 'flutter'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  token_row public.lwr_license_tokens%rowtype;
  expires_at_value timestamptz;
begin
  if trim(coalesce(p_device_uid, '')) = '' then
    raise exception 'Device ID is missing.';
  end if;

  if trim(coalesce(p_organization_id, '')) = '' or trim(coalesce(p_branch_id, '')) = '' then
    raise exception 'Shop/branch context is missing. Create or join the shop again.';
  end if;

  if not exists (select 1 from public.lwr_organizations where id = p_organization_id and active = true) then
    raise exception 'Shop was not found in Supabase.';
  end if;

  if not exists (select 1 from public.lwr_branches where id = p_branch_id and organization_id = p_organization_id and active = true) then
    raise exception 'Branch was not found in Supabase.';
  end if;

  insert into public.lwr_devices(device_uid, organization_id, branch_id, device_name, platform, active, last_seen_at)
  values (p_device_uid, p_organization_id, p_branch_id, 'Light Winter POS Device', coalesce(p_platform, 'flutter'), true, now())
  on conflict (device_uid) do update
    set organization_id = excluded.organization_id,
        branch_id = excluded.branch_id,
        platform = excluded.platform,
        active = true,
        last_seen_at = now();

  select *
    into token_row
    from public.lwr_license_tokens
   where regexp_replace(token, '[^A-Z0-9]', '', 'g') = regexp_replace(upper(trim(p_token)), '[^A-Z0-9]', '', 'g')
     and used = false
     and (target_device_uid is null or target_device_uid = p_device_uid)
   for update;

  if not found then
    raise exception 'License voucher not found, already used, or not assigned to this device.';
  end if;

  expires_at_value :=
    case token_row.duration_mode
      when 'minutes' then now() + make_interval(mins => token_row.duration_value)
      else now() + make_interval(days => token_row.duration_value)
    end;

  insert into public.lwr_licenses(device_uid, token, status, duration_mode, duration_value, expires_at)
  values (p_device_uid, token_row.token, 'active', token_row.duration_mode, token_row.duration_value, expires_at_value);

  update public.lwr_license_tokens
     set used = true,
         used_by_device_uid = p_device_uid
   where token = token_row.token;

  return jsonb_build_object(
    'device_uid', p_device_uid,
    'token', token_row.token,
    'status', 'active',
    'expires_at', expires_at_value,
    'server_time', now()
  );
end;
$$;

grant execute on function public.lwr_activate_device_license(text, text, text, text, text) to anon;

create or replace function public.lwr_activate_device_license(
  p_device_uid text,
  p_token text,
  p_platform text default 'flutter'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  device_row public.lwr_devices%rowtype;
begin
  select *
    into device_row
    from public.lwr_devices
   where device_uid = p_device_uid
     and active = true
   order by created_at desc
   limit 1;

  if not found then
    raise exception 'Device is not activated. Create or join a shop first.';
  end if;

  return public.lwr_activate_device_license(
    p_device_uid,
    p_token,
    device_row.organization_id,
    device_row.branch_id,
    p_platform
  );
end;
$$;

grant execute on function public.lwr_activate_device_license(text, text, text) to anon;

create or replace function public.lwr_server_now()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

grant execute on function public.lwr_server_now() to anon;

-- Quick check query you can edit/run in Supabase SQL Editor:
-- select token, duration_mode, duration_value, target_device_uid, used, used_by_device_uid
-- from public.lwr_license_tokens
-- where regexp_replace(token, '[^A-Z0-9]', '', 'g') = regexp_replace('PASTE-VOUCHER-HERE', '[^A-Z0-9]', '', 'g');

create or replace function public.lwr_random_code(p_length integer default 10)
returns text
language plpgsql
volatile
as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  output text := '';
  i integer;
begin
  for i in 1..p_length loop
    output := output || substr(alphabet, floor(random() * length(alphabet) + 1)::integer, 1);
  end loop;
  return output;
end;
$$;

update public.lwr_organizations
set recovery_code = public.lwr_random_code(10)
where coalesce(recovery_code, '') = '';

create or replace function public.lwr_create_shop(
  p_shop_name text,
  p_main_branch jsonb,
  p_fiscal_mode boolean,
  p_owner jsonb,
  p_users jsonb,
  p_branches jsonb,
  p_device_uid text,
  p_platform text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  org_id text := (extract(epoch from clock_timestamp()) * 1000000)::bigint::text;
  main_branch_id text := coalesce(nullif(p_main_branch->>'id', ''), ((extract(epoch from clock_timestamp()) * 1000000)::bigint + 1)::text);
  recovery text := public.lwr_random_code(10);
  branch_item jsonb;
  user_item jsonb;
  branch_id text;
  owner_id text := coalesce(nullif(p_owner->>'id', ''), ((extract(epoch from clock_timestamp()) * 1000000)::bigint + 2)::text);
begin
  if trim(coalesce(p_shop_name, '')) = '' then
    raise exception 'Shop name is required.';
  end if;

  if trim(coalesce(p_device_uid, '')) = '' then
    raise exception 'Device ID is missing.';
  end if;

  insert into public.lwr_organizations(id, name, fiscal_mode, phone, address, recovery_code, active)
  values (
    org_id,
    trim(p_shop_name),
    coalesce(p_fiscal_mode, false),
    coalesce(p_main_branch->>'phone', ''),
    coalesce(p_main_branch->>'address', ''),
    recovery,
    true
  );

  insert into public.lwr_branches(id, organization_id, name, phone, address, active)
  values (
    main_branch_id,
    org_id,
    coalesce(nullif(p_main_branch->>'name', ''), 'Main Branch'),
    coalesce(p_main_branch->>'phone', ''),
    coalesce(p_main_branch->>'address', ''),
    true
  );

  insert into public.lwr_activation_codes(code, organization_id, branch_id, active)
  values (public.lwr_random_code(), org_id, main_branch_id, true);

  for branch_item in select value from jsonb_array_elements(coalesce(p_branches, '[]'::jsonb)) loop
    branch_id := coalesce(nullif(branch_item->>'id', ''), ((extract(epoch from clock_timestamp()) * 1000000)::bigint)::text);
    insert into public.lwr_branches(id, organization_id, name, phone, address, active)
    values (
      branch_id,
      org_id,
      coalesce(nullif(branch_item->>'name', ''), 'Branch'),
      coalesce(branch_item->>'phone', ''),
      coalesce(branch_item->>'address', ''),
      true
    );

    insert into public.lwr_activation_codes(code, organization_id, branch_id, active)
    values (public.lwr_random_code(), org_id, branch_id, true);
  end loop;

  insert into public.lwr_devices(device_uid, organization_id, branch_id, device_name, platform, active, last_seen_at)
  values (p_device_uid, org_id, main_branch_id, 'Light Winter POS Device', coalesce(p_platform, 'flutter'), true, now())
  on conflict (device_uid) do update
    set organization_id = excluded.organization_id,
        branch_id = excluded.branch_id,
        active = true,
        last_seen_at = now();

  insert into public.lwr_users(id, organization_id, name, username, role, pin_plain, permissions, active)
  values (
    owner_id,
    org_id,
    coalesce(nullif(p_owner->>'name', ''), 'Owner'),
    coalesce(nullif(p_owner->>'username', ''), 'owner'),
    coalesce(nullif(p_owner->>'role', ''), 'owner'),
    coalesce(nullif(p_owner->>'pin_plain', ''), '0000'),
    coalesce(p_owner->'permissions', '[]'::jsonb),
    true
  );

  for user_item in select value from jsonb_array_elements(coalesce(p_users, '[]'::jsonb)) loop
    insert into public.lwr_users(id, organization_id, name, username, role, pin_plain, permissions, active)
    values (
      coalesce(nullif(user_item->>'id', ''), ((extract(epoch from clock_timestamp()) * 1000000)::bigint)::text),
      org_id,
      coalesce(nullif(user_item->>'name', ''), 'User'),
      coalesce(nullif(user_item->>'username', ''), lower(replace(coalesce(user_item->>'name', 'user'), ' ', '.'))),
      coalesce(nullif(user_item->>'role', ''), 'cashier'),
      coalesce(nullif(user_item->>'pin_plain', ''), '0000'),
      coalesce(user_item->'permissions', '[]'::jsonb),
      true
    );
  end loop;

  return jsonb_build_object('organization_id', org_id, 'branch_id', main_branch_id, 'device_uid', p_device_uid);
end;
$$;

grant execute on function public.lwr_create_shop(text, jsonb, boolean, jsonb, jsonb, jsonb, text, text) to anon;

create table if not exists public.lwr_exchange_rates (
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  currency_code text not null,
  rate numeric not null check (rate > 0),
  is_default boolean not null default false,
  updated_by_device_uid text,
  updated_at timestamptz not null default now(),
  primary key (organization_id, currency_code)
);

create table if not exists public.lwr_stock_transfers (
  id text primary key,
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  product_id text not null,
  product_name text not null default '',
  from_branch_id text not null references public.lwr_branches(id) on delete restrict,
  to_branch_id text not null references public.lwr_branches(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  device_uid text not null default '',
  user_name text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.lwr_fiscal_days (
  id text primary key,
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  branch_id text not null references public.lwr_branches(id) on delete restrict,
  device_uid text not null default '',
  day_no integer not null,
  status text not null check (status in ('open', 'closed')) default 'open',
  opened_by_user_id text,
  closed_by_user_id text,
  opened_at timestamptz not null default now(),
  closed_at timestamptz
);

create table if not exists public.lwr_fiscal_submissions (
  id text primary key,
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  branch_id text not null references public.lwr_branches(id) on delete restrict,
  sale_id text references public.lwr_sales(id) on delete cascade,
  submission_type text not null default 'fiscal_invoice',
  status text not null check (status in ('pending', 'submitted', 'approved', 'failed')) default 'pending',
  attempt_count integer not null default 0,
  last_error text not null default '',
  fdms_reference text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.lwr_exchange_rates enable row level security;
alter table public.lwr_stock_transfers enable row level security;
alter table public.lwr_fiscal_days enable row level security;
alter table public.lwr_fiscal_submissions enable row level security;

drop policy if exists lwr_anon_all on public.lwr_exchange_rates;
drop policy if exists lwr_anon_all on public.lwr_stock_transfers;
drop policy if exists lwr_anon_all on public.lwr_fiscal_days;
drop policy if exists lwr_anon_all on public.lwr_fiscal_submissions;
create policy lwr_anon_all on public.lwr_exchange_rates for all to anon using (true) with check (true);
create policy lwr_anon_all on public.lwr_stock_transfers for all to anon using (true) with check (true);
create policy lwr_anon_all on public.lwr_fiscal_days for all to anon using (true) with check (true);
create policy lwr_anon_all on public.lwr_fiscal_submissions for all to anon using (true) with check (true);

create index if not exists idx_lwr_exchange_rates_org on public.lwr_exchange_rates(organization_id);
create index if not exists idx_lwr_stock_transfers_org on public.lwr_stock_transfers(organization_id, created_at desc);
create index if not exists idx_lwr_fiscal_days_org_branch on public.lwr_fiscal_days(organization_id, branch_id, opened_at desc);
create index if not exists idx_lwr_fiscal_submissions_org_status on public.lwr_fiscal_submissions(organization_id, status, created_at desc);
create unique index if not exists idx_lwr_fiscal_days_one_open on public.lwr_fiscal_days(organization_id, branch_id) where status = 'open';
create unique index if not exists idx_lwr_fiscal_submissions_sale_type on public.lwr_fiscal_submissions(sale_id, submission_type) where sale_id is not null;

insert into public.lwr_exchange_rates(organization_id, currency_code, rate, is_default)
select id, 'USD', 1, true from public.lwr_organizations
on conflict (organization_id, currency_code) do nothing;

insert into public.lwr_exchange_rates(organization_id, currency_code, rate, is_default)
select id, 'ZWL', 25000, false from public.lwr_organizations
on conflict (organization_id, currency_code) do nothing;

insert into public.lwr_exchange_rates(organization_id, currency_code, rate, is_default)
select id, 'ZAR', 18.5, false from public.lwr_organizations
on conflict (organization_id, currency_code) do nothing;

insert into public.lwr_exchange_rates(organization_id, currency_code, rate, is_default)
select id, 'BWP', 13.6, false from public.lwr_organizations
on conflict (organization_id, currency_code) do nothing;
