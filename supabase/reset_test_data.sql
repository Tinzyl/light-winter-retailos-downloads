truncate table
  public.lwr_audit_events,
  public.lwr_sale_lines,
  public.lwr_sales,
  public.lwr_licenses,
  public.lwr_license_tokens,
  public.lwr_branch_stock,
  public.lwr_products,
  public.lwr_customers,
  public.lwr_users,
  public.lwr_devices,
  public.lwr_activation_codes,
  public.lwr_branches,
  public.lwr_organizations
restart identity cascade;
