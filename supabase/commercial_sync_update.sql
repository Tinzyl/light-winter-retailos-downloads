alter table public.lwr_products
  add column if not exists category text not null default '';

alter table public.lwr_products
  add column if not exists supplier_id text;

alter table public.lwr_products
  add column if not exists cost_price_cents integer not null default 0;

alter table public.lwr_sale_lines
  add column if not exists unit_cost_cents integer not null default 0;

alter table public.lwr_sale_lines
  add column if not exists line_cost_cents integer not null default 0;

alter table public.lwr_sale_lines
  add column if not exists product_name text not null default '';

alter table public.lwr_sale_void_lines
  add column if not exists unit_cost_cents integer not null default 0;

alter table public.lwr_sale_void_lines
  add column if not exists line_cost_cents integer not null default 0;

alter table public.lwr_sale_void_lines
  add column if not exists product_name text not null default '';

alter table public.lwr_products
  drop constraint if exists lwr_products_organization_id_sku_key;

create unique index if not exists idx_lwr_products_org_sku_nonempty
  on public.lwr_products(organization_id, lower(sku))
  where active = true and trim(sku) <> '';

create table if not exists public.lwr_suppliers (
  id text primary key,
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  name text not null,
  phone text not null default '',
  notes text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.lwr_suppliers enable row level security;
drop policy if exists lwr_anon_all on public.lwr_suppliers;
create policy lwr_anon_all on public.lwr_suppliers
  for all to anon using (true) with check (true);

create index if not exists idx_lwr_suppliers_org
  on public.lwr_suppliers(organization_id, active, name);

create table if not exists public.lwr_accounting_entries (
  id text primary key,
  organization_id text not null references public.lwr_organizations(id) on delete cascade,
  branch_id text references public.lwr_branches(id) on delete set null,
  device_uid text not null default '',
  type text not null check (type in ('expense', 'income')) default 'expense',
  category text not null default 'General',
  description text not null default '',
  amount_cents integer not null default 0,
  payment_method text not null default '',
  counterparty text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.lwr_accounting_entries enable row level security;
drop policy if exists lwr_anon_all on public.lwr_accounting_entries;
create policy lwr_anon_all on public.lwr_accounting_entries
  for all to anon using (true) with check (true);

create index if not exists idx_lwr_accounting_entries_org_branch
  on public.lwr_accounting_entries(organization_id, branch_id, created_at desc);

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

update public.lwr_sale_lines
set
  product_name = coalesce(nullif(lwr_sale_lines.product_name, ''), p.name, ''),
  unit_cost_cents = coalesce(nullif(unit_cost_cents, 0), p.cost_price_cents, 0),
  line_cost_cents = coalesce(nullif(line_cost_cents, 0), p.cost_price_cents * lwr_sale_lines.quantity, 0)
from public.lwr_products p
where p.id = lwr_sale_lines.product_id;

update public.lwr_sale_void_lines
set
  product_name = coalesce(nullif(lwr_sale_void_lines.product_name, ''), p.name, ''),
  unit_cost_cents = coalesce(nullif(unit_cost_cents, 0), p.cost_price_cents, 0),
  line_cost_cents = coalesce(nullif(line_cost_cents, 0), p.cost_price_cents * lwr_sale_void_lines.quantity, 0)
from public.lwr_products p
where p.id = lwr_sale_void_lines.product_id;
