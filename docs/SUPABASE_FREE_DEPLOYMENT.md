# Supabase Free Deployment

This is the free-cloud route for Light Winter RetailOS when Oracle Cloud login is blocking progress.

## What Supabase Replaces

Supabase becomes the shared cloud database/API for:

- shops/organizations
- branches
- users and PINs
- devices
- activation codes
- products and stock
- sales and sale lines
- license tokens and device licenses

The existing FastAPI backend remains in the project for local testing and future Hetzner deployment. The Flutter app now decides at runtime:

- `https://xxxxx.supabase.co` means use Supabase REST directly.
- Any other URL means use the FastAPI backend.

## Create Supabase Project

1. Open `https://supabase.com`.
2. Sign in.
3. Create a new project.
4. Project name: `light-winter-retailos`.
5. Save the database password somewhere safe.
6. Wait until the project is ready.

## Create Tables

1. In Supabase, open your project.
2. Go to `SQL Editor`.
3. Open this local file:

`C:\Users\tinot\OneDrive\Documents\New project\supabase\light_winter_schema.sql`

4. Paste the whole SQL file into Supabase SQL Editor.
5. Click `Run`.

If you already created the tables before the licensing lock was added, also run:

`C:\Users\tinot\OneDrive\Documents\New project\supabase\hardening_update.sql`

## Get The API Values

In Supabase:

1. Go to `Project Settings`.
2. Go to `API`.
3. Copy:
   - `Project URL` / `API URL`, example `https://abcxyz.supabase.co`
   - `Publishable key`

If you use the legacy keys tab, `anon public` is also acceptable. Do not use `Secret key` or `service_role` inside the APK.

If the copied API URL ends with `/rest/v1`, the app now strips that automatically.

## Run On SUNMI Without Building Release

Use this while developing:

```powershell
$env:Path='C:\Users\tinot\dev-tools\flutter\bin;' + $env:Path
$env:LIGHT_WINTER_SUPABASE_URL='https://YOUR-PROJECT.supabase.co'
$env:LIGHT_WINTER_SUPABASE_ANON_KEY='YOUR-PUBLISHABLE-OR-ANON-PUBLIC-KEY'
Set-Location 'C:\Users\tinot\OneDrive\Documents\New project\apps\pos_flutter'
flutter run -d VE03P2CF00209 --dart-define=LIGHT_WINTER_SUPABASE_URL=$env:LIGHT_WINTER_SUPABASE_URL --dart-define=LIGHT_WINTER_SUPABASE_ANON_KEY=$env:LIGHT_WINTER_SUPABASE_ANON_KEY
```

SUNMI device ID currently seen by ADB:

`VE03P2CF00209`

No local IP address is needed for Supabase mode. Any phone/SUNMI/Windows device with internet can reach Supabase using the project URL.

## Build APK For Customers

```powershell
$env:Path='C:\Users\tinot\dev-tools\flutter\bin;' + $env:Path
$env:LIGHT_WINTER_SUPABASE_URL='https://YOUR-PROJECT.supabase.co'
$env:LIGHT_WINTER_SUPABASE_ANON_KEY='YOUR-PUBLISHABLE-OR-ANON-PUBLIC-KEY'
Set-Location 'C:\Users\tinot\OneDrive\Documents\New project\apps\pos_flutter'
flutter build apk --release --dart-define=LIGHT_WINTER_SUPABASE_URL=$env:LIGHT_WINTER_SUPABASE_URL --dart-define=LIGHT_WINTER_SUPABASE_ANON_KEY=$env:LIGHT_WINTER_SUPABASE_ANON_KEY
```

APK output:

`C:\Users\tinot\OneDrive\Documents\New project\apps\pos_flutter\build\app\outputs\flutter-apk\app-release.apk`

## Testing A One-Branch Shop

1. Install the APK on the owner device.
2. Open the app.
3. Tap `Create New Shop as Owner`.
4. Enter shop name, main branch, owner username, and owner PIN.
5. Choose fiscal or non-fiscal.
6. Save.
7. Login using owner username and PIN.
8. Add products in Inventory.
9. Sell from POS.
10. Tap sync/refresh where available and confirm data appears in Supabase tables.

## Testing A Multi-Branch Shop

1. Owner creates the shop on the first device.
2. Owner sends the first device `Device ID` to Light Winter Technologies.
3. You generate and insert a license voucher for that device.
4. Owner enters the voucher and the app unlocks.
5. Owner adds branches in the Branches screen.
6. The Branches screen shows/copies activation codes for each branch.
7. On each extra device, tap `Join Existing Shop / Branch`.
8. Enter shop name, branch name, and activation code.
9. Login with a user created by the owner.
10. That extra device will still show the license lock.
11. The extra device sends its own `Device ID`.
12. You generate a separate license voucher for that exact device.

## Licensing

After setup/login, the app locks every working section until a license voucher is applied for that device.

The customer must send you the displayed `Device ID`, for example:

`LWR-123456`

Then generate a voucher SQL insert from your PC:

```powershell
python 'C:\Users\tinot\OneDrive\Documents\New project\scripts\generate-supabase-license-tokens.py' --mode days --value 30 --quantity 1 --device LWR-123456
```

For a minute-based test:

```powershell
python 'C:\Users\tinot\OneDrive\Documents\New project\scripts\generate-supabase-license-tokens.py' --mode minutes --value 60 --quantity 1 --device LWR-123456
```

Copy the generated SQL into Supabase SQL Editor and run it.

Then send only the voucher token to the customer, for example:

`SWKAEJRB9X`

The customer enters that voucher on the license screen. The voucher:

- works only once
- can be locked to one device ID
- uses Supabase/Postgres server time for expiry calculation
- unlocks only that device

Do not reuse an old voucher if the displayed Device ID changes after clearing app data or reinstalling. Generate a fresh voucher for the exact Device ID shown on the license screen.

## License Debug Query

If a voucher fails, run this in Supabase SQL Editor after replacing the values:

```sql
with params as (
  select 'LWR-356717'::text as device_uid, 'ZZR8A-RMR89'::text as token
)
select
  p.device_uid,
  p.token,
  exists(select 1 from public.lwr_devices d where d.device_uid = p.device_uid and d.active = true) as device_is_active,
  (select d.organization_id from public.lwr_devices d where d.device_uid = p.device_uid limit 1) as device_org,
  (select d.branch_id from public.lwr_devices d where d.device_uid = p.device_uid limit 1) as device_branch,
  t.token as token_found,
  t.target_device_uid,
  t.used,
  t.used_by_device_uid
from params p
left join public.lwr_license_tokens t
  on regexp_replace(t.token, '[^A-Z0-9]', '', 'g') = regexp_replace(p.token, '[^A-Z0-9]', '', 'g');
```

Expected:

- `device_is_active` is `true`
- `token_found` is not empty
- `used` is `false`
- `target_device_uid` is empty/null or exactly the same as `device_uid`

Manual insert is also possible in Supabase Table Editor:

Table: `lwr_license_tokens`

Example row:

- `token`: `A7K9Q2P4MX`
- `duration_mode`: `days`
- `duration_value`: `30`
- `target_device_uid`: `LWR-123456`
- `used`: `false`

Then on the device, apply that token in the license screen.

The strict Python token generator script is the preferred way because every voucher is random from the first character.

## Important Security Note

This free Supabase setup still uses direct app access for normal shop data so the APK can work without a paid backend server. License token rows are now protected from direct anon reads/writes and applied through a Supabase RPC function. For serious commercial rollout we should still move sensitive licensing/fiscal logic behind the FastAPI backend on Hetzner or add full Supabase Auth/RLS scoped per shop/device.
