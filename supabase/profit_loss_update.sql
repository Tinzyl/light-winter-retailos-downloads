alter table public.lwr_products
  add column if not exists cost_price_cents integer not null default 0;

alter table public.lwr_sale_lines
  add column if not exists unit_cost_cents integer not null default 0;

alter table public.lwr_sale_lines
  add column if not exists line_cost_cents integer not null default 0;

alter table public.lwr_sale_void_lines
  add column if not exists unit_cost_cents integer not null default 0;

alter table public.lwr_sale_void_lines
  add column if not exists line_cost_cents integer not null default 0;

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

update public.lwr_sale_lines
set
  unit_cost_cents = coalesce(nullif(unit_cost_cents, 0), p.cost_price_cents, 0),
  line_cost_cents = coalesce(nullif(line_cost_cents, 0), p.cost_price_cents * lwr_sale_lines.quantity, 0)
from public.lwr_products p
where p.id = lwr_sale_lines.product_id;

update public.lwr_sale_void_lines
set
  unit_cost_cents = coalesce(nullif(unit_cost_cents, 0), p.cost_price_cents, 0),
  line_cost_cents = coalesce(nullif(line_cost_cents, 0), p.cost_price_cents * lwr_sale_void_lines.quantity, 0)
from public.lwr_products p
where p.id = lwr_sale_void_lines.product_id;
