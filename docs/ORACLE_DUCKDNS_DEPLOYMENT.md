# Oracle + DuckDNS Deployment

This is the zero-monthly-cost deployment path for Light Winter RetailOS demos and early production.

## Final URLs

Use these once the server is deployed:

- API base URL: `https://lightwinter.duckdns.org`
- Swagger: `https://lightwinter.duckdns.org/docs`
- Health check: `https://lightwinter.duckdns.org/health`

If `lightwinter` is already taken on DuckDNS, use another short name and replace the host everywhere.

## What Runs Where

- Oracle Always Free VM runs Docker, PostgreSQL, and the FastAPI backend.
- DuckDNS points a free subdomain to the Oracle public IP.
- Nginx terminates HTTPS and forwards traffic to the backend.
- FastAPI Swagger remains available at `/docs` for testing.

## Oracle Setup

1. Create an Oracle Cloud Always Free account.
2. Create an Ubuntu VM using an Always Free eligible shape.
3. Open inbound ports in the Oracle security list:
   - `22/tcp` for SSH
   - `80/tcp` for HTTP/Let's Encrypt
   - `443/tcp` for HTTPS/API
4. SSH into the VM.
5. Run the setup script from this repository after setting these variables:

```bash
export REPO_URL="https://your-git-repository-url"
export DUCKDNS_DOMAIN="lightwinter"
export DUCKDNS_TOKEN="your-duckdns-token"
export ADMIN_EMAIL="your-email@example.com"
bash deploy/oracle/setup-oracle-ubuntu.sh
```

The script creates `/opt/lightwinter-retailos/deploy/.env.oracle` with generated production secrets.

## DuckDNS Setup

1. Create a DuckDNS account.
2. Add the domain `lightwinter`.
3. Copy your DuckDNS token.
4. Use that token in `DUCKDNS_TOKEN` when running the Oracle setup script.

The server installs a timer that refreshes DuckDNS every five minutes.

## Build APK Against Oracle/DuckDNS

From the Windows project folder:

```powershell
$env:Path='C:\Users\tinot\dev-tools\flutter\bin;' + $env:Path
Set-Location 'C:\Users\tinot\OneDrive\Documents\New project\apps\pos_flutter'
flutter build apk --release --dart-define=LIGHT_WINTER_API_URL=https://lightwinter.duckdns.org
```

The APK will be created at:

`C:\Users\tinot\OneDrive\Documents\New project\apps\pos_flutter\build\app\outputs\flutter-apk\app-release.apk`

## Testing

Open these in a browser:

- `https://lightwinter.duckdns.org/health`
- `https://lightwinter.duckdns.org/docs`

Then install the APK on SUNMI/Android and create a shop. The backend URL field should default to the DuckDNS address if the APK was built with `LIGHT_WINTER_API_URL`.

## Later Move To Hetzner

Keep the same DuckDNS name. Install the backend on Hetzner, then point DuckDNS to the Hetzner public IP. Devices keep using the same API URL.
