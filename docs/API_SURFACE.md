# API Surface

The backend currently exposes a production-oriented first vertical slice.

## Activation and Licensing

- provision organization and first branch
- activate terminal/device
- generate short random day/minute tokens
- apply device-bound or general tokens
- reconcile license state against trusted server time

## Retail Operations

- create products
- adjust branch stock with movement logs
- create customers
- process sales
- create debt from debt sales
- full void
- partial void
- full return
- partial return
- restore stock from reversals
- reduce debt from reversals
- dashboard totals
- supplier creation/listing
- purchase order creation
- purchase receiving into branch stock
- branch-to-branch transfers
- price/promotion rules
- receipt records for screen, WhatsApp, SMS/share, Bluetooth, SUNMI, and Windows channels
- fraud alert listing
- import batch validation records

## Sync, Backup, and Fiscal

- device heartbeat/sync events
- offline sync queue with stale-version conflict detection
- backup event tracking
- local/cloud storage targets
- backup snapshot checksum records
- fiscal taxpayer setup
- fiscal/non-fiscal mode split
- fiscal open day
- fiscal close day
- fiscal integration documentation gate
- PIN/password auth sessions
- print jobs for share sheet, Bluetooth, SUNMI, AirPrint, Android, Windows, PDF, and WhatsApp channels
