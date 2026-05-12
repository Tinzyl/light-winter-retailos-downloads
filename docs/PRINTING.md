# Printing Strategy

Light Winter RetailOS supports printing as a set of channels rather than one hard-coded printer path.

## Supported Channels

- on-screen receipt
- Android share sheet
- Android print framework
- installed Bluetooth printing apps through share/open intent
- direct Bluetooth printer job tracking
- SUNMI internal printer
- SUNMI Bluetooth/app-based printing
- iOS AirPrint/share sheet
- Windows print
- PDF export
- WhatsApp text/PDF share

## Client Implementation

The Flutter client uses:

- `printing` for native print dialogs and PDF sharing
- `pdf` for receipt PDF generation
- `share_plus` for platform share sheets

This means Android/SUNMI can send receipt text or PDF to any installed share target, including a Bluetooth printing app, WhatsApp, SMS/share apps, or other receipt tools. Windows and iOS use their native print/share paths where available.

## SUNMI Example

If a SUNMI device has a separate Bluetooth printing application installed, RetailOS should send receipt text or PDF through the share/open flow. The print app appears as a target, and the cashier can select it. Direct SUNMI internal printer support can be added separately through a native plugin/channel.

## Backend Model

Print jobs are tracked with:

- device UID
- channel
- target name
- payload
- queued/sent/printed/failed status
- error message

This lets the POS show print success/failure without pretending every platform prints the same way.
