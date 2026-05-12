# Shared Business Domain Model

Core entities:

- Organization
- Branch
- Device
- User
- Role
- Product
- ProductVariant
- BranchStock
- Sale
- SaleLine
- Debt
- Customer
- Supplier
- PurchaseOrder
- StockMovement
- SyncEvent
- License
- LicenseEvent
- ActivationCode
- Receipt
- TaxGroup
- FiscalSubmission
- FiscalDay
- BackupEvent
- FraudAlert

Core rules:

- device local date is never the licensing authority
- random token licensing remains Python-generated and server verified
- stock movements are append-only and auditable
- voids and returns create reversal records instead of deleting original sales
- fiscal and non-fiscal modes share POS/inventory logic but fiscal mode adds submission, tax, fiscal day, credit note, and debit note rules
