-- Light Winter RetailOS branch stock membership hardening.
-- Run this in Supabase SQL Editor. Safe to run more than once.
--
-- Purpose:
-- 1. Every active product should have a lwr_branch_stock row for every active
--    branch in the same shop, even when quantity is 0.
-- 2. This lets the Stock screen show the product under "Current branch" so the
--    user can restock with + / edit without needing the owner to revisit.
-- 3. POS still only sells items with positive stock; this only improves stock
--    visibility and restocking.

insert into public.lwr_branch_stock(branch_id, product_id, quantity, updated_at)
select b.id, p.id, 0, now()
from public.lwr_branches b
join public.lwr_products p
  on p.organization_id = b.organization_id
where b.active = true
  and p.active = true
on conflict (branch_id, product_id) do nothing;

create or replace function public.lwr_ensure_product_branch_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.active = true then
    insert into public.lwr_branch_stock(branch_id, product_id, quantity, updated_at)
    select b.id, new.id, 0, now()
    from public.lwr_branches b
    where b.organization_id = new.organization_id
      and b.active = true
    on conflict (branch_id, product_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_lwr_ensure_product_branch_stock on public.lwr_products;
create trigger trg_lwr_ensure_product_branch_stock
after insert or update of active, organization_id on public.lwr_products
for each row
execute function public.lwr_ensure_product_branch_stock();

create or replace function public.lwr_ensure_branch_product_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.active = true then
    insert into public.lwr_branch_stock(branch_id, product_id, quantity, updated_at)
    select new.id, p.id, 0, now()
    from public.lwr_products p
    where p.organization_id = new.organization_id
      and p.active = true
    on conflict (branch_id, product_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_lwr_ensure_branch_product_stock on public.lwr_branches;
create trigger trg_lwr_ensure_branch_product_stock
after insert or update of active, organization_id on public.lwr_branches
for each row
execute function public.lwr_ensure_branch_product_stock();
