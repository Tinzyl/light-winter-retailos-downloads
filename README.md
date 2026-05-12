# Light Winter RetailOS

Premium multi-platform retail/POS/inventory/sync/licensing platform by **Light Winter Technologies** for Android, iOS, SUNMI Android devices, and Windows.

## Stack

- Client: Flutter, targeting Android, iOS, Windows, and SUNMI-optimized Android builds.
- Backend: Python FastAPI with SQLAlchemy and Alembic-ready structure.
- Database: PostgreSQL in production, SQLite for local development/tests.
- Licensing: Python-generated short random tokens with day/minute durations, trusted-time checkpoints, and device binding.
- Deployment/dev services: Docker Compose.

## Current Foundation

This repo starts the production foundation:

- backend licensing engine
- activation/provisioning endpoints
- device enrollment data model
- anti-date-cheat license service
- fiscal readiness status model
- product and branch stock APIs
- sales engine with stock-safe checkout
- debt sale creation
- full and partial void/return reversal engine
- audit log, stock movement, sync heartbeat, backup event, and dashboard models
- suppliers, purchase orders, purchase receiving, branch transfers, price rules, receipts, fraud alerts, and import batch tracking
- PIN/password user authentication with JWT sessions
- offline sync queue with version conflict detection
- local/cloud storage target abstraction and backup snapshots
- holistic print job tracking for share sheet, Bluetooth, SUNMI, iOS AirPrint, Android print, Windows print, PDF, and WhatsApp channels
- ZIMRA FDMS API v7.2 adapter with test/live endpoint mapping, taxpayer verification, device registration, server certificate lookup, mTLS device calls, fiscal day open/close, receipt submission, and signed sample invoice/credit/debit document generation
- Flutter app skeleton with activation, licensing, POS, and fiscal setup screens
- install/check scripts
- phase roadmap

Fiscal integration is intentionally gated. When fiscal readiness is reached, the product must ask for the correct fiscal API documentation and credentials before continuing.

## Quick Start

```powershell
.\scripts\setup-dev.ps1
.\backend\.venv\Scripts\python.exe -m pytest backend\tests
.\backend\.venv\Scripts\uvicorn app.main:app --app-dir backend --reload
```

API docs open at `http://127.0.0.1:8000/docs`.

Flutter is required for the client:

```powershell
flutter pub get apps\pos_flutter
flutter run -d windows --project-dir apps\pos_flutter
```

If Flutter is missing, install it from the official Flutter Windows guide, then re-run `scripts\check-tooling.ps1`.

## Local Tool State

Verified on this machine:

- Python: installed
- Node.js: installed
- Docker: installed
- Git: installed
- Flutter SDK: installed at `%USERPROFILE%\dev-tools\flutter`
- Android SDK/build tools: installed and APK builds work
- Visual Studio Build Tools: installed for Windows builds
- Windows Developer Mode: still required for Flutter Windows plugin builds that create symlinks

Backend tests pass from the local virtual environment.

## Implemented API Surface

- `POST /api/provision/organization`
- `POST /api/activation/terminal`
- `POST /api/licenses/tokens`
- `POST /api/licenses/apply`
- `GET /api/licenses/device/{device_uid}`
- `PUT /api/organizations/{organization_id}/fiscal`
- `POST /api/fiscal/open-day`
- `POST /api/fiscal/close-day`
- `POST /api/products`
- `GET /api/organizations/{organization_id}/products`
- `POST /api/stock/adjust`
- `GET /api/branches/{branch_id}/stock`
- `POST /api/customers`
- `GET /api/organizations/{organization_id}/customers`
- `POST /api/sales`
- `GET /api/sales/{sale_id}`
- `POST /api/sales/{sale_id}/reversals`
- `GET /api/organizations/{organization_id}/dashboard`
- `POST /api/sync/heartbeat`
- `POST /api/backups/events`
- `POST /api/suppliers`
- `GET /api/organizations/{organization_id}/suppliers`
- `POST /api/purchase-orders`
- `POST /api/purchase-orders/{order_id}/receive`
- `POST /api/branch-transfers`
- `POST /api/price-rules`
- `POST /api/receipts`
- `GET /api/organizations/{organization_id}/fraud-alerts`
- `POST /api/imports/batches`
- `POST /api/auth/users`
- `POST /api/auth/login/pin`
- `POST /api/auth/login/password`
- `POST /api/storage/targets`
- `POST /api/backups/snapshots`
- `POST /api/sync/queue`
- `POST /api/print/jobs`
- `PATCH /api/print/jobs/{job_id}`
- `GET /api/fiscal/zimra/endpoints`
- `POST /api/fiscal/zimra/verify-taxpayer`
- `POST /api/fiscal/zimra/register-device`
- `POST /api/fiscal/zimra/server-certificate`
- `POST /api/fiscal/zimra/config`
- `POST /api/fiscal/zimra/status`
- `POST /api/fiscal/zimra/open-day`
- `POST /api/fiscal/zimra/close-day`
- `POST /api/fiscal/zimra/submit-receipt`
- `POST /api/fiscal/zimra/sample-documents`

## Fiscal Boundary

The fiscal foundation includes fiscal mode, taxpayer profile, TIN/VAT fields, fiscal day opening/closing, and a fiscal queue marker.

ZIMRA FDMS addresses are now locked into the backend:

- Test: `https://fdmsapitest.zimra.co.zw`
- Test Swagger: `https://fdmsapitest.zimra.co.zw/swagger/index.html`
- Live: `https://fdmsapi.zimra.co.zw`
- Live Swagger: `https://fdmsapi.zimra.co.zw/swagger/index.html`

The receipt QR/redirect value is read from FDMS `GetConfig.qrUrl` for the registered device. Device endpoints require the ZIMRA-issued client certificate/private key before live calls can complete.
