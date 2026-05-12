# ZIMRA FDMS Integration

Light Winter RetailOS now has a concrete backend adapter for the ZIMRA Fiscal Device Management System API v7.2.

## Official Addresses

- Test API base: `https://fdmsapitest.zimra.co.zw`
- Test Swagger: `https://fdmsapitest.zimra.co.zw/swagger/index.html`
- Live API base: `https://fdmsapi.zimra.co.zw`
- Live Swagger: `https://fdmsapi.zimra.co.zw/swagger/index.html`
- API document download: `https://www.zimra.co.zw/downloads/category/9-domestic-taxes?download=3807:fiscalisation-apidocumentation`

The receipt validation/QR redirect address must not be hardcoded. FDMS returns the device-specific `qrUrl` in `GET /Device/v1/{deviceID}/GetConfig`; receipts should use that configured value.

## Implemented FDMS Backend Endpoints

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

## Official FDMS Paths Used

Public endpoints:

- `POST /Public/v1/{deviceID}/VerifyTaxpayerInformation`
- `POST /Public/v1/{deviceID}/RegisterDevice`
- `GET /Public/v1/GetServerCertificate`

Device endpoints using mutual TLS:

- `GET /Device/v1/{deviceID}/GetConfig`
- `GET /Device/v1/{deviceID}/GetStatus`
- `POST /Device/v1/{deviceID}/OpenDay`
- `POST /Device/v1/{deviceID}/CloseDay`
- `POST /Device/v1/{deviceID}/SubmitReceipt`
- `POST /Device/v1/{deviceID}/IssueCertificate`
- `POST /Device/v1/{deviceID}/Ping`
- `POST /Device/v1/{deviceID}/SubmitFile`
- `GET /Device/v1/{deviceID}/SubmittedFileList`

Product stock and user endpoints are mapped for the next fiscal UI layer:

- `GET /ProductsStock/v1/{deviceID}/Search`
- `GET /User/v1/{deviceID}/GetUsersList`
- `POST /User/v1/{deviceID}/CreateUser`
- `POST /User/v1/{deviceID}/Login`

## Required From Portal/ZIMRA Before Live Calls Work

- FDMS `deviceID`
- activation key
- fiscal device serial number
- registered `DeviceModelName` and `DeviceModelVersion`
- CSR/private key generated for the fiscal device
- certificate returned by `RegisterDevice`
- certificate/private-key paths for mutual TLS calls
- taxpayer legal name, shop/trading name, branch name, branch address, contacts, TIN, and VAT number where fiscal mode applies

Non-fiscal shops still use shop name, branch, address, contacts, receipt footer, products, users, sync, backup, receipts, and licensing. VAT/TIN fiscal fields are required only when fiscal mode is configured.

## Testing Workflow

1. Verify taxpayer information with activation key and fiscal device serial number.
2. Register the device by submitting a CSR.
3. Store the returned device certificate safely with the matching private key.
4. Call `GetConfig`; persist taxpayer, branch, tax groups, day limits, certificate validity, and `qrUrl`.
5. Call `GetStatus`.
6. Open fiscal day using `OpenDay`.
7. Submit sample `FiscalInvoice`, `CreditNote`, and `DebitNote`.
8. Close fiscal day using `CloseDay`; check returned operation and errors.
9. Submit approved sample documents to ZIMRA.
10. After ZIMRA approval, switch the same integration from test to live credentials and `https://fdmsapi.zimra.co.zw`.

## Accuracy Notes

- FDMS device endpoints require mutual TLS; the backend will reject those calls until certificate/private-key paths are supplied.
- Receipt and fiscal-day signatures are generated from the fiscal device private key. The backend does not fake those signatures.
- `OpenDay` sends local date-time without timezone, matching the FDMS schema.
- `CloseDay` requires fiscal day counters, receipt counter, and fiscal day device signature.
- `SubmitReceipt` supports `FiscalInvoice`, `CreditNote`, and `DebitNote`; credit/debit notes include source receipt reference fields.
