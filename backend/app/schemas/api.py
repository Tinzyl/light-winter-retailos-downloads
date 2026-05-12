from datetime import datetime

from pydantic import BaseModel, Field

from app.models.domain import (
    BackupStatus,
    DurationMode,
    FiscalDayStatus,
    FiscalMode,
    FiscalStage,
    LicenseStatus,
    PaymentMethod,
    PrintChannel,
    PrintJobStatus,
    PromotionType,
    PurchaseOrderStatus,
    ReceiptChannel,
    ReversalType,
    SaleStatus,
    StockMovementType,
    StorageProvider,
    SyncOperation,
    SyncStatus,
    TransferStatus,
    UserRole,
    Platform,
)
from app.services.zimra_fdms_service import ZimraEnvironment


class ProvisionOrganizationRequest(BaseModel):
    business_name: str = Field(min_length=2, max_length=160)
    branch_name: str = Field(default="Main Branch", min_length=2, max_length=160)
    trading_name: str | None = None
    legal_name: str | None = None
    country: str = "Zimbabwe"
    default_currency: str = Field(default="USD", min_length=3, max_length=3)
    phone: str | None = None
    email: str | None = None
    receipt_footer: str | None = None
    branch_code: str | None = None
    address_line_1: str | None = None
    address_line_2: str | None = None
    city: str | None = None
    province: str | None = None
    tin: str | None = None
    vat_number: str | None = None


class ProvisionOrganizationResponse(BaseModel):
    organization_id: str
    branch_id: str
    activation_code: str


class BranchCreateRequest(BaseModel):
    organization_id: str
    name: str = Field(min_length=2, max_length=160)
    branch_code: str | None = None
    address_line_1: str | None = None
    city: str | None = None


class BranchResponse(BaseModel):
    id: str
    organization_id: str
    name: str
    branch_code: str | None


class ActivateTerminalRequest(BaseModel):
    activation_code: str
    device_uid: str = Field(min_length=8, max_length=180)
    device_name: str = Field(min_length=2, max_length=160)
    platform: Platform


class ActivateTerminalResponse(BaseModel):
    device_id: str
    branch_id: str
    activated: bool


class CreateLicenseTokensRequest(BaseModel):
    duration_mode: DurationMode
    duration_value: int = Field(gt=0)
    quantity: int = Field(gt=0, le=500)
    target_device_uid: str | None = None


class LicenseTokenResponse(BaseModel):
    token: str
    duration_mode: DurationMode
    duration_value: int
    target_device_uid: str | None


class ApplyLicenseRequest(BaseModel):
    device_uid: str
    token: str


class LicenseStatusResponse(BaseModel):
    status: LicenseStatus
    starts_at: datetime
    expires_at: datetime
    last_trusted_seen_at: datetime


class FiscalSettingsRequest(BaseModel):
    fiscal_mode: FiscalMode = FiscalMode.fiscal
    taxpayer_registered_name: str = Field(min_length=2, max_length=160)
    tin: str = Field(min_length=2, max_length=80)
    vat_number: str | None = Field(default=None, max_length=80)
    fiscal_authority: str = Field(default="ZIMRA", min_length=2, max_length=80)
    stage: FiscalStage


class FiscalSettingsResponse(BaseModel):
    organization_id: str
    fiscal_mode: FiscalMode
    taxpayer_registered_name: str | None
    tin: str | None
    vat_number: str | None
    fiscal_authority: str | None
    stage: FiscalStage
    message: str | None = None


class FiscalDayRequest(BaseModel):
    device_uid: str
    user_id: str | None = None


class FiscalDayResponse(BaseModel):
    fiscal_day_id: str
    device_uid: str
    fiscal_day_no: int
    status: FiscalDayStatus
    opened_at: datetime
    closed_at: datetime | None


class ProductCreateRequest(BaseModel):
    organization_id: str
    sku: str = Field(min_length=1, max_length=80)
    barcode: str | None = None
    name: str = Field(min_length=2, max_length=180)
    category: str | None = None
    unit_of_measure: str = "each"
    buying_cost_cents: int = Field(default=0, ge=0)
    selling_price_cents: int = Field(gt=0)
    reorder_threshold: int = Field(default=0, ge=0)


class ProductResponse(BaseModel):
    id: str
    sku: str
    barcode: str | None
    name: str
    category: str | None
    unit_of_measure: str
    selling_price_cents: int
    reorder_threshold: int


class StockAdjustRequest(BaseModel):
    branch_id: str
    product_id: str
    movement_type: StockMovementType
    quantity_delta: int
    reason: str = Field(min_length=2, max_length=240)
    user_id: str | None = None


class StockResponse(BaseModel):
    branch_id: str
    product_id: str
    quantity: int
    low_stock: bool
    out_of_stock: bool


class CustomerCreateRequest(BaseModel):
    organization_id: str
    name: str = Field(min_length=2, max_length=160)
    phone: str | None = None
    address: str | None = None
    tin: str | None = None
    vat_number: str | None = None
    debt_limit_cents: int = Field(default=0, ge=0)


class CustomerResponse(BaseModel):
    id: str
    name: str
    phone: str | None
    debt_limit_cents: int
    debt_balance_cents: int


class SaleLineRequest(BaseModel):
    product_id: str
    quantity: int = Field(gt=0)
    unit_price_cents: int | None = Field(default=None, gt=0)
    discount_cents: int = Field(default=0, ge=0)


class CreateSaleRequest(BaseModel):
    device_uid: str
    cashier_user_id: str | None = None
    customer_id: str | None = None
    payment_method: PaymentMethod
    discount_cents: int = Field(default=0, ge=0)
    paid_cents: int = Field(default=0, ge=0)
    lines: list[SaleLineRequest] = Field(min_length=1)


class SaleLineResponse(BaseModel):
    id: str
    product_id: str
    quantity: int
    reversed_quantity: int
    total_cents: int


class SaleResponse(BaseModel):
    id: str
    branch_id: str
    status: SaleStatus
    payment_method: PaymentMethod
    subtotal_cents: int
    discount_cents: int
    tax_cents: int
    total_cents: int
    paid_cents: int
    change_cents: int
    fiscal_submission_status: SyncStatus
    created_at: datetime
    lines: list[SaleLineResponse]


class ReversalLineRequest(BaseModel):
    sale_line_id: str
    quantity: int = Field(gt=0)


class ReversalRequest(BaseModel):
    reversal_type: ReversalType
    reason: str = Field(min_length=3, max_length=240)
    user_id: str | None = None
    lines: list[ReversalLineRequest] | None = None


class ReversalResponse(BaseModel):
    reversal_id: str
    sale_id: str
    status: SaleStatus
    amount_cents: int


class DashboardResponse(BaseModel):
    organization_id: str
    sales_today_cents: int
    debt_open_cents: int
    low_stock_count: int
    out_of_stock_count: int
    unsynced_events: int
    backup_failures: int
    fiscal_pending: int


class SyncHeartbeatRequest(BaseModel):
    device_uid: str
    status: SyncStatus = SyncStatus.synced
    detail: str | None = None


class SyncHeartbeatResponse(BaseModel):
    status: SyncStatus
    server_time: datetime


class BackupEventRequest(BaseModel):
    organization_id: str
    status: BackupStatus
    location: str | None = None
    checksum: str | None = None
    detail: str | None = None


class SupplierCreateRequest(BaseModel):
    organization_id: str
    name: str = Field(min_length=2, max_length=160)
    phone: str | None = None
    email: str | None = None
    address: str | None = None
    tin: str | None = None


class SupplierResponse(BaseModel):
    id: str
    name: str
    phone: str | None
    email: str | None


class PurchaseLineRequest(BaseModel):
    product_id: str
    ordered_quantity: int = Field(gt=0)
    unit_cost_cents: int = Field(default=0, ge=0)


class PurchaseOrderCreateRequest(BaseModel):
    branch_id: str
    supplier_id: str | None = None
    invoice_number: str | None = None
    lines: list[PurchaseLineRequest] = Field(min_length=1)


class PurchaseReceiveRequest(BaseModel):
    user_id: str | None = None


class PurchaseOrderResponse(BaseModel):
    id: str
    branch_id: str
    supplier_id: str | None
    status: PurchaseOrderStatus
    total_cost_cents: int
    invoice_number: str | None


class TransferLineRequest(BaseModel):
    product_id: str
    quantity: int = Field(gt=0)


class BranchTransferCreateRequest(BaseModel):
    from_branch_id: str
    to_branch_id: str
    reason: str | None = None
    user_id: str | None = None
    lines: list[TransferLineRequest] = Field(min_length=1)


class BranchTransferResponse(BaseModel):
    id: str
    from_branch_id: str
    to_branch_id: str
    status: TransferStatus


class PriceRuleCreateRequest(BaseModel):
    organization_id: str
    name: str = Field(min_length=2, max_length=160)
    promotion_type: PromotionType
    product_id: str | None = None
    branch_id: str | None = None
    price_cents: int | None = Field(default=None, ge=0)
    discount_basis_points: int | None = Field(default=None, ge=0, le=10000)
    min_quantity: int | None = Field(default=None, gt=0)


class PriceRuleResponse(BaseModel):
    id: str
    name: str
    promotion_type: PromotionType
    active: bool


class ReceiptCreateRequest(BaseModel):
    sale_id: str | None = None
    channel: ReceiptChannel
    content: str = Field(min_length=2)
    fiscal_qr_data: str | None = None


class ReceiptResponse(BaseModel):
    id: str
    channel: ReceiptChannel
    delivered: bool


class FraudAlertResponse(BaseModel):
    id: str
    severity: str
    alert_type: str
    detail: str
    resolved: bool


class ImportBatchRequest(BaseModel):
    organization_id: str
    import_type: str = Field(min_length=2, max_length=80)
    filename: str = Field(min_length=2, max_length=180)
    rows_total: int = Field(default=0, ge=0)
    rows_valid: int = Field(default=0, ge=0)
    rows_failed: int = Field(default=0, ge=0)
    validation_report: str | None = None


class ImportBatchResponse(BaseModel):
    id: str
    import_type: str
    filename: str
    status: str
    rows_total: int
    rows_valid: int
    rows_failed: int


class UserCreateRequest(BaseModel):
    organization_id: str
    name: str = Field(min_length=2, max_length=160)
    role: UserRole
    pin: str | None = Field(default=None, min_length=4, max_length=12)
    password: str | None = Field(default=None, min_length=6, max_length=120)


class UserResponse(BaseModel):
    id: str
    name: str
    role: UserRole
    active: bool


class PinLoginRequest(BaseModel):
    organization_id: str
    pin: str = Field(min_length=4, max_length=12)
    device_uid: str | None = None


class PasswordLoginRequest(BaseModel):
    organization_id: str
    name: str
    password: str = Field(min_length=6)
    device_uid: str | None = None


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserResponse


class SyncQueueRequest(BaseModel):
    device_uid: str
    entity_type: str = Field(min_length=2, max_length=80)
    entity_id: str = Field(min_length=1, max_length=120)
    operation: SyncOperation
    payload_json: str = Field(min_length=2)
    client_version: int = Field(default=1, ge=1)
    server_version: int | None = Field(default=None, ge=1)


class SyncQueueResponse(BaseModel):
    id: str
    status: SyncStatus
    server_version: int | None
    conflict_detail: str | None


class StorageTargetRequest(BaseModel):
    organization_id: str
    provider: StorageProvider
    name: str = Field(min_length=2, max_length=120)
    base_path: str = Field(min_length=2, max_length=240)
    encrypted: bool = True


class StorageTargetResponse(BaseModel):
    id: str
    provider: StorageProvider
    name: str
    base_path: str
    encrypted: bool


class BackupSnapshotRequest(BaseModel):
    organization_id: str
    storage_target_id: str
    content: str = Field(min_length=2)


class BackupSnapshotResponse(BaseModel):
    id: str
    status: BackupStatus
    location: str | None
    checksum: str | None


class PrintJobCreateRequest(BaseModel):
    device_uid: str
    channel: PrintChannel
    payload: str = Field(min_length=2)
    receipt_id: str | None = None
    target_name: str | None = None


class PrintJobStatusRequest(BaseModel):
    status: PrintJobStatus
    error_message: str | None = None


class PrintJobResponse(BaseModel):
    id: str
    device_uid: str
    channel: PrintChannel
    status: PrintJobStatus
    target_name: str | None


class ZimraEndpointMapResponse(BaseModel):
    product: str
    authority: str
    test_base_url: str
    live_base_url: str
    test_swagger: dict[str, str]
    live_swagger: dict[str, str]
    endpoints: dict[str, dict[str, str]]
    receipt_qr_rule: str


class ZimraCertificatePaths(BaseModel):
    certificate_path: str = Field(min_length=2)
    private_key_path: str = Field(min_length=2)


class ZimraVerifyTaxpayerRequest(BaseModel):
    environment: ZimraEnvironment = ZimraEnvironment.test
    device_id: int = Field(gt=0)
    activation_key: str = Field(min_length=1, max_length=8)
    device_serial_no: str = Field(min_length=1, max_length=20)


class ZimraRegisterDeviceRequest(BaseModel):
    environment: ZimraEnvironment = ZimraEnvironment.test
    device_id: int = Field(gt=0)
    activation_key: str = Field(min_length=1, max_length=8)
    certificate_request: str = Field(min_length=20)
    device_model_name: str = Field(default="Light Winter RetailOS", min_length=2, max_length=120)
    device_model_version: str = Field(default="1.0.0", min_length=1, max_length=40)


class ZimraServerCertificateRequest(BaseModel):
    environment: ZimraEnvironment = ZimraEnvironment.test
    thumbprint: str | None = None


class ZimraDeviceRequest(BaseModel):
    environment: ZimraEnvironment = ZimraEnvironment.test
    device_id: int = Field(gt=0)
    certificate: ZimraCertificatePaths


class ZimraOpenDayRequest(ZimraDeviceRequest):
    fiscal_day_opened: datetime
    fiscal_day_no: int | None = Field(default=None, gt=0)


class ZimraCloseDayRequest(ZimraDeviceRequest):
    fiscal_day_no: int = Field(gt=0)
    fiscal_day_counters: list[dict] = Field(min_length=1)
    fiscal_day_device_signature: dict
    receipt_counter: int = Field(ge=0)


class ZimraSubmitReceiptRequest(ZimraDeviceRequest):
    receipt: dict


class ZimraSampleDocumentsRequest(BaseModel):
    private_key_pem: str = Field(min_length=20)
    started_at: datetime | None = None


class ZimraResponse(BaseModel):
    environment: ZimraEnvironment
    base_url: str
    endpoint: str
    response: dict


class AppUserPayload(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    username: str = Field(min_length=1, max_length=120)
    pin: str = Field(min_length=4, max_length=12)
    role: UserRole
    permissions: list[str] = Field(default_factory=list)


class AppBranchPayload(BaseModel):
    name: str = Field(min_length=2, max_length=160)
    phone: str | None = None
    address: str | None = None


class AppCreateShopRequest(BaseModel):
    shop_name: str = Field(min_length=2, max_length=160)
    main_branch: AppBranchPayload
    fiscal_mode: FiscalMode = FiscalMode.non_fiscal
    owner: AppUserPayload
    users: list[AppUserPayload] = Field(default_factory=list)
    branches: list[AppBranchPayload] = Field(default_factory=list)
    device_uid: str = Field(min_length=4, max_length=180)
    device_name: str = Field(min_length=2, max_length=160)
    platform: Platform
    backend_url: str | None = None


class AppJoinShopRequest(BaseModel):
    activation_code: str = Field(min_length=1, max_length=32)
    device_uid: str = Field(min_length=4, max_length=180)
    device_name: str = Field(min_length=2, max_length=160)
    platform: Platform


class AppUpdateUserRequest(AppUserPayload):
    active: bool = True


class AppApplyLicenseRequest(BaseModel):
    device_uid: str
    token: str


class AppBootstrapResponse(BaseModel):
    organization_id: str
    shop_name: str
    fiscal_mode: FiscalMode
    device_id: str
    device_uid: str
    assigned_branch_id: str
    license_label: str
    branches: list[dict]
    users: list[dict]
    products: list[dict]
    stock: list[dict]
    customers: list[dict]
