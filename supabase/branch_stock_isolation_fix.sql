-- Light Winter RetailOS branch stock isolation fix.
-- Run in Supabase SQL Editor. Safe to run more than once.
--
-- This reverses the old zero-placeholder branch stock design.
-- Branch stock rows must mean the branch actually has/held that product.
-- Empty branches must not display another branch's catalogue as out of stock.

drop trigger if exists trg_lwr_ensure_product_branch_stock on public.lwr_products;
drop trigger if exists trg_lwr_ensure_branch_product_stock on public.lwr_branches;

drop function if exists public.lwr_ensure_product_branch_stock();
drop function if exists public.lwr_ensure_branch_product_stock();

delete from public.lwr_branch_stock bs
where not exists (
  select 1
  from public.lwr_products p
  where p.id = bs.product_id
    and p.active = true
);

delete from public.lwr_branch_stock bs
using public.lwr_products p, public.lwr_branches b
where bs.product_id = p.id
  and bs.branch_id = b.id
  and bs.quantity = 0
  and not exists (
    select 1
    from public.lwr_sale_lines sl
    join public.lwr_sales s on s.id = sl.sale_id
    where s.branch_id = bs.branch_id
      and sl.product_id = bs.product_id
  )
  and not exists (
    select 1
    from public.lwr_stock_transfers st
    where st.product_id = bs.product_id
      and (st.from_branch_id = bs.branch_id or st.to_branch_id = bs.branch_id)
  );

select
  b.name as branch_name,
  count(*) filter (where bs.quantity > 0) as stocked_products,
  coalesce(sum(greatest(bs.quantity, 0)), 0) as total_pieces,
  count(*) filter (where bs.quantity = 0) as kept_zero_history_rows
from public.lwr_branches b
left join public.lwr_branch_stock bs on bs.branch_id = b.id
where b.active = true
group by b.id, b.name
order by b.name;
