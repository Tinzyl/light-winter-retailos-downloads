# Light Winter Supabase Admin Dashboard

Run this file once in Supabase SQL Editor:

```sql
-- Paste and run:
-- C:\Users\tinot\Downloads\New project\supabase\light_winter_admin_dashboard.sql
```

## View All Shops

```sql
select *
from public.lwr_admin_shop_overview
order by created_at desc;
```

## View All Devices

```sql
select *
from public.lwr_admin_device_overview
order by shop_name, branch_name, device_uid;
```

## View Suspicious / Payment-Risk Devices

```sql
select *
from public.lwr_admin_suspicious_devices;
```

## View License Tokens

```sql
select *
from public.lwr_admin_license_overview
order by token_created_at desc;
```

## View Owner Reset Vouchers

```sql
select *
from public.lwr_admin_reset_voucher_overview
order by created_at desc;
```

## Deactivate A Device

```sql
select *
from public.lwr_admin_deactivate_device(
  'LWR-DEVICEID',
  'Customer has not paid per-device license fee'
);
```

## Reactivate A Device

```sql
select *
from public.lwr_admin_reactivate_device(
  'LWR-DEVICEID',
  'Payment received'
);
```

These controls are for Light Winter Technologies only. Do not expose them inside the customer APK.
