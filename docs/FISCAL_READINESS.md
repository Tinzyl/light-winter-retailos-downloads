# Fiscal Readiness Model

The platform supports non-fiscal shops and fiscal shops from one shared business profile.

## Shared Shop Profile

Required for both fiscal and non-fiscal operation:

- legal or trading shop name
- branch name
- physical address
- city/town
- country
- contact phone
- contact email where available
- receipt footer
- default currency
- branch code
- terminal/device name

## Fiscal-Only Identity

Shown only when fiscal mode is enabled or fiscal readiness is being configured:

- taxpayer registered name
- taxpayer TIN
- VAT number when applicable
- tax office or authority profile reference where applicable
- fiscal branch identifier
- fiscal device identifier
- fiscal terminal identifier
- certificate request/activation material
- API credentials
- tax groups and receipt tax mappings
- buyer TIN/VAT support for invoices where required

## Fiscal Day Controls

Fiscal mode must expose explicit controls:

- Open Fiscal Day
- Close Fiscal Day
- current fiscal day status
- last opened by / time
- last closed by / time
- fiscal queue status
- failed submission retry diagnostics

## Documents Required

Final fiscal integration requires the correct country/provider fiscal API documentation and credentials. Until supplied, the platform stops at readiness and shows the locked message.
