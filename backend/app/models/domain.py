from __future__ import annotations

import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Enum, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Platform(str, enum.Enum):
    android = "android"
    ios = "ios"
    sunmi = "sunmi"
    windows = "windows"


class DurationMode(str, enum.Enum):
    days = "days"
    minutes = "minutes"


class LicenseStatus(str, enum.Enum):
    active = "active"
    expiring_soon = "expiring_soon"
    expired = "expired"
    not_licensed = "not_licensed"


class FiscalStage(str, enum.Enum):
    non_fiscal_active = "non_fiscal_active"
    tax_groups_configured = "tax_groups_configured"
    receipt_tax_mapping_ready = "receipt_tax_mapping_ready"
    fiscal_readiness_reached = "fiscal_readiness_reached"
    documents_required = "documents_required"
    sandbox_integration = "sandbox_integration"
    validation_testing = "validation_testing"
    production_go_live = "production_go_live"


class FiscalMode(str, enum.Enum):
    non_fiscal = "non_fiscal"
    fiscal = "fiscal"


class FiscalDayStatus(str, enum.Enum):
    closed = "closed"
    opened = "opened"
    close_initiated = "close_initiated"
    close_failed = "close_failed"


class UserRole(str, enum.Enum):
    owner = "owner"
    manager = "manager"
    cashier = "cashier"
    auditor = "auditor"
    stock_clerk = "stock_clerk"
    branch_supervisor = "branch_supervisor"


class StockMovementType(str, enum.Enum):
    opening = "opening"
    sale = "sale"
    stock_in = "stock_in"
    stock_out = "stock_out"
    adjustment = "adjustment"
    return_to_stock = "return_to_stock"
    void_restore = "void_restore"
    damage = "damage"
    transfer_out = "transfer_out"
    transfer_in = "transfer_in"


class SaleStatus(str, enum.Enum):
    completed = "completed"
    partially_voided = "partially_voided"
    voided = "voided"
    partially_returned = "partially_returned"
    returned = "returned"


class PaymentMethod(str, enum.Enum):
    cash = "cash"
    card = "card"
    mobile_wallet = "mobile_wallet"
    debt = "debt"
    mixed = "mixed"


class ReversalType(str, enum.Enum):
    full_void = "full_void"
    partial_void = "partial_void"
    full_return = "full_return"
    partial_return = "partial_return"


class DebtStatus(str, enum.Enum):
    open = "open"
    settled = "settled"
    written_off = "written_off"


class SyncStatus(str, enum.Enum):
    pending = "pending"
    synced = "synced"
    failed = "failed"


class SyncOperation(str, enum.Enum):
    create = "create"
    update = "update"
    delete = "delete"
    upsert = "upsert"


class BackupStatus(str, enum.Enum):
    succeeded = "succeeded"
    failed = "failed"
    pending = "pending"


class StorageProvider(str, enum.Enum):
    local = "local"
    s3_compatible = "s3_compatible"
    google_drive = "google_drive"
    onedrive = "onedrive"
    azure_blob = "azure_blob"


class PrintChannel(str, enum.Enum):
    app_share = "app_share"
    android_print = "android_print"
    ios_airprint = "ios_airprint"
    bluetooth_direct = "bluetooth_direct"
    sunmi_internal = "sunmi_internal"
    sunmi_bluetooth_app = "sunmi_bluetooth_app"
    windows_print = "windows_print"
    pdf_export = "pdf_export"
    whatsapp = "whatsapp"


class PrintJobStatus(str, enum.Enum):
    queued = "queued"
    sent = "sent"
    printed = "printed"
    failed = "failed"


class PurchaseOrderStatus(str, enum.Enum):
    draft = "draft"
    ordered = "ordered"
    partially_received = "partially_received"
    received = "received"
    cancelled = "cancelled"


class TransferStatus(str, enum.Enum):
    draft = "draft"
    sent = "sent"
    received = "received"
    cancelled = "cancelled"


class PromotionType(str, enum.Enum):
    promo_price = "promo_price"
    quantity_discount = "quantity_discount"
    combo = "combo"
    customer_tier = "customer_tier"
    wholesale = "wholesale"


class ReceiptChannel(str, enum.Enum):
    screen = "screen"
    whatsapp_text = "whatsapp_text"
    whatsapp_pdf = "whatsapp_pdf"
    sms_intent = "sms_intent"
    share_intent = "share_intent"
    bluetooth_printer = "bluetooth_printer"
    sunmi_print = "sunmi_print"
    windows_print = "windows_print"


class ImportStatus(str, enum.Enum):
    pending = "pending"
    validated = "validated"
    imported = "imported"
    failed = "failed"
    rolled_back = "rolled_back"


class Organization(Base):
    __tablename__ = "organizations"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    trading_name: Mapped[str | None] = mapped_column(String(160))
    legal_name: Mapped[str | None] = mapped_column(String(160))
    country: Mapped[str] = mapped_column(String(80), default="Zimbabwe")
    default_currency: Mapped[str] = mapped_column(String(3), default="USD")
    phone: Mapped[str | None] = mapped_column(String(40))
    email: Mapped[str | None] = mapped_column(String(160))
    receipt_footer: Mapped[str | None] = mapped_column(String(240))
    fiscal_mode: Mapped[FiscalMode] = mapped_column(Enum(FiscalMode), default=FiscalMode.non_fiscal)
    tin: Mapped[str | None] = mapped_column(String(80))
    vat_number: Mapped[str | None] = mapped_column(String(80))
    taxpayer_registered_name: Mapped[str | None] = mapped_column(String(160))
    fiscal_authority: Mapped[str | None] = mapped_column(String(80))
    fiscal_stage: Mapped[FiscalStage] = mapped_column(Enum(FiscalStage), default=FiscalStage.non_fiscal_active)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    branches: Mapped[list[Branch]] = relationship(back_populates="organization", cascade="all, delete-orphan")
    users: Mapped[list[User]] = relationship(back_populates="organization")
    products: Mapped[list[Product]] = relationship(back_populates="organization")
    customers: Mapped[list[Customer]] = relationship(back_populates="organization")
    suppliers: Mapped[list[Supplier]] = relationship(back_populates="organization")


class Branch(Base):
    __tablename__ = "branches"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    branch_code: Mapped[str | None] = mapped_column(String(60))
    address_line_1: Mapped[str | None] = mapped_column(String(160))
    address_line_2: Mapped[str | None] = mapped_column(String(160))
    city: Mapped[str | None] = mapped_column(String(100))
    province: Mapped[str | None] = mapped_column(String(100))
    phone: Mapped[str | None] = mapped_column(String(40))
    email: Mapped[str | None] = mapped_column(String(160))
    fiscal_branch_id: Mapped[str | None] = mapped_column(String(120))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    organization: Mapped[Organization] = relationship(back_populates="branches")
    devices: Mapped[list[Device]] = relationship(back_populates="branch")
    stock: Mapped[list[BranchStock]] = relationship(back_populates="branch")
    sales: Mapped[list[Sale]] = relationship(back_populates="branch")


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (UniqueConstraint("device_uid", name="uq_devices_device_uid"),)

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    device_uid: Mapped[str] = mapped_column(String(180), nullable=False)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    platform: Mapped[Platform] = mapped_column(Enum(Platform), nullable=False)
    activated: Mapped[bool] = mapped_column(Boolean, default=False)
    fiscal_device_id: Mapped[str | None] = mapped_column(String(120))
    fiscal_terminal_id: Mapped[str | None] = mapped_column(String(120))
    fiscal_serial_number: Mapped[str | None] = mapped_column(String(120))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    branch: Mapped[Branch] = relationship(back_populates="devices")
    licenses: Mapped[list[License]] = relationship(back_populates="device")
    fiscal_days: Mapped[list[FiscalDay]] = relationship(back_populates="device")


class ActivationCode(Base):
    __tablename__ = "activation_codes"
    __table_args__ = (UniqueConstraint("code", name="uq_activation_codes_code"),)

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    code: Mapped[str] = mapped_column(String(32), nullable=False)
    used: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class LicenseToken(Base):
    __tablename__ = "license_tokens"
    __table_args__ = (UniqueConstraint("token", name="uq_license_tokens_token"),)

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    token: Mapped[str] = mapped_column(String(32), nullable=False)
    duration_mode: Mapped[DurationMode] = mapped_column(Enum(DurationMode), nullable=False)
    duration_value: Mapped[int] = mapped_column(Integer, nullable=False)
    target_device_uid: Mapped[str | None] = mapped_column(String(180))
    used_by_device_uid: Mapped[str | None] = mapped_column(String(180))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class License(Base):
    __tablename__ = "licenses"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    device_id: Mapped[str] = mapped_column(ForeignKey("devices.id"), nullable=False)
    token_id: Mapped[str] = mapped_column(ForeignKey("license_tokens.id"), nullable=False)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_trusted_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    status: Mapped[LicenseStatus] = mapped_column(Enum(LicenseStatus), default=LicenseStatus.active)

    device: Mapped[Device] = relationship(back_populates="licenses")


class FiscalDay(Base):
    __tablename__ = "fiscal_days"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    device_id: Mapped[str] = mapped_column(ForeignKey("devices.id"), nullable=False)
    fiscal_day_no: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[FiscalDayStatus] = mapped_column(Enum(FiscalDayStatus), default=FiscalDayStatus.opened)
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    opened_by_user_id: Mapped[str | None] = mapped_column(String)
    closed_by_user_id: Mapped[str | None] = mapped_column(String)
    close_failure_reason: Mapped[str | None] = mapped_column(String(240))

    device: Mapped[Device] = relationship(back_populates="fiscal_days")


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    username: Mapped[str | None] = mapped_column(String(120))
    role: Mapped[UserRole] = mapped_column(Enum(UserRole), nullable=False)
    pin_plain: Mapped[str | None] = mapped_column(String(40))
    pin_hash: Mapped[str | None] = mapped_column(String(240))
    password_hash: Mapped[str | None] = mapped_column(String(240))
    permissions_json: Mapped[str | None] = mapped_column(Text)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    organization: Mapped[Organization] = relationship(back_populates="users")


class AuthSession(Base):
    __tablename__ = "auth_sessions"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), nullable=False)
    device_id: Mapped[str | None] = mapped_column(ForeignKey("devices.id"))
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)


class Product(Base):
    __tablename__ = "products"
    __table_args__ = (UniqueConstraint("organization_id", "sku", name="uq_products_org_sku"),)

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    sku: Mapped[str] = mapped_column(String(80), nullable=False)
    barcode: Mapped[str | None] = mapped_column(String(120))
    name: Mapped[str] = mapped_column(String(180), nullable=False)
    category: Mapped[str | None] = mapped_column(String(120))
    unit_of_measure: Mapped[str] = mapped_column(String(40), default="each")
    buying_cost_cents: Mapped[int] = mapped_column(Integer, default=0)
    selling_price_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    reorder_threshold: Mapped[int] = mapped_column(Integer, default=0)
    archived: Mapped[bool] = mapped_column(Boolean, default=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    organization: Mapped[Organization] = relationship(back_populates="products")
    branch_stock: Mapped[list[BranchStock]] = relationship(back_populates="product")
    variants: Mapped[list[ProductVariant]] = relationship(back_populates="product")


class ProductVariant(Base):
    __tablename__ = "product_variants"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    sku_suffix: Mapped[str | None] = mapped_column(String(80))
    barcode: Mapped[str | None] = mapped_column(String(120))
    selling_price_cents: Mapped[int | None] = mapped_column(Integer)
    active: Mapped[bool] = mapped_column(Boolean, default=True)

    product: Mapped[Product] = relationship(back_populates="variants")


class BranchStock(Base):
    __tablename__ = "branch_stock"
    __table_args__ = (UniqueConstraint("branch_id", "product_id", name="uq_branch_stock_product"),)

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    branch: Mapped[Branch] = relationship(back_populates="stock")
    product: Mapped[Product] = relationship(back_populates="branch_stock")


class Customer(Base):
    __tablename__ = "customers"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(40))
    address: Mapped[str | None] = mapped_column(String(240))
    tin: Mapped[str | None] = mapped_column(String(80))
    vat_number: Mapped[str | None] = mapped_column(String(80))
    debt_limit_cents: Mapped[int] = mapped_column(Integer, default=0)
    loyalty_points: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    organization: Mapped[Organization] = relationship(back_populates="customers")
    debts: Mapped[list[Debt]] = relationship(back_populates="customer")


class Sale(Base):
    __tablename__ = "sales"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    device_id: Mapped[str] = mapped_column(ForeignKey("devices.id"), nullable=False)
    cashier_user_id: Mapped[str | None] = mapped_column(String)
    customer_id: Mapped[str | None] = mapped_column(ForeignKey("customers.id"))
    payment_method: Mapped[PaymentMethod] = mapped_column(Enum(PaymentMethod), nullable=False)
    subtotal_cents: Mapped[int] = mapped_column(Integer, default=0)
    discount_cents: Mapped[int] = mapped_column(Integer, default=0)
    tax_cents: Mapped[int] = mapped_column(Integer, default=0)
    total_cents: Mapped[int] = mapped_column(Integer, default=0)
    paid_cents: Mapped[int] = mapped_column(Integer, default=0)
    change_cents: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[SaleStatus] = mapped_column(Enum(SaleStatus), default=SaleStatus.completed)
    fiscal_submission_status: Mapped[SyncStatus] = mapped_column(Enum(SyncStatus), default=SyncStatus.pending)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    branch: Mapped[Branch] = relationship(back_populates="sales")
    lines: Mapped[list[SaleLine]] = relationship(back_populates="sale", cascade="all, delete-orphan")
    reversals: Mapped[list[SaleReversal]] = relationship(back_populates="sale")
    debt: Mapped[Debt | None] = relationship(back_populates="sale")


class SaleLine(Base):
    __tablename__ = "sale_lines"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    sale_id: Mapped[str] = mapped_column(ForeignKey("sales.id"), nullable=False)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    unit_price_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    discount_cents: Mapped[int] = mapped_column(Integer, default=0)
    total_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    reversed_quantity: Mapped[int] = mapped_column(Integer, default=0)

    sale: Mapped[Sale] = relationship(back_populates="lines")


class SaleReversal(Base):
    __tablename__ = "sale_reversals"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    sale_id: Mapped[str] = mapped_column(ForeignKey("sales.id"), nullable=False)
    reversal_type: Mapped[ReversalType] = mapped_column(Enum(ReversalType), nullable=False)
    reason: Mapped[str] = mapped_column(String(240), nullable=False)
    user_id: Mapped[str | None] = mapped_column(String)
    amount_cents: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    sale: Mapped[Sale] = relationship(back_populates="reversals")


class Debt(Base):
    __tablename__ = "debts"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), nullable=False)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sales.id"), nullable=False, unique=True)
    principal_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    balance_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[DebtStatus] = mapped_column(Enum(DebtStatus), default=DebtStatus.open)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    customer: Mapped[Customer] = relationship(back_populates="debts")
    sale: Mapped[Sale] = relationship(back_populates="debt")


class StockMovement(Base):
    __tablename__ = "stock_movements"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), nullable=False)
    movement_type: Mapped[StockMovementType] = mapped_column(Enum(StockMovementType), nullable=False)
    quantity_delta: Mapped[int] = mapped_column(Integer, nullable=False)
    reference_id: Mapped[str | None] = mapped_column(String)
    reason: Mapped[str | None] = mapped_column(String(240))
    user_id: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str | None] = mapped_column(String)
    branch_id: Mapped[str | None] = mapped_column(String)
    device_id: Mapped[str | None] = mapped_column(String)
    user_id: Mapped[str | None] = mapped_column(String)
    action: Mapped[str] = mapped_column(String(100), nullable=False)
    entity_type: Mapped[str] = mapped_column(String(100), nullable=False)
    entity_id: Mapped[str | None] = mapped_column(String)
    detail: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class SyncEvent(Base):
    __tablename__ = "sync_events"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    device_id: Mapped[str | None] = mapped_column(String)
    status: Mapped[SyncStatus] = mapped_column(Enum(SyncStatus), default=SyncStatus.pending)
    detail: Mapped[str | None] = mapped_column(String(240))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class SyncQueueItem(Base):
    __tablename__ = "sync_queue_items"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    device_uid: Mapped[str] = mapped_column(String(180), nullable=False)
    entity_type: Mapped[str] = mapped_column(String(80), nullable=False)
    entity_id: Mapped[str] = mapped_column(String(120), nullable=False)
    operation: Mapped[SyncOperation] = mapped_column(Enum(SyncOperation), nullable=False)
    payload_json: Mapped[str] = mapped_column(Text, nullable=False)
    client_version: Mapped[int] = mapped_column(Integer, default=1)
    server_version: Mapped[int | None] = mapped_column(Integer)
    status: Mapped[SyncStatus] = mapped_column(Enum(SyncStatus), default=SyncStatus.pending)
    conflict_detail: Mapped[str | None] = mapped_column(String(240))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    applied_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class BackupEvent(Base):
    __tablename__ = "backup_events"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[BackupStatus] = mapped_column(Enum(BackupStatus), default=BackupStatus.pending)
    location: Mapped[str | None] = mapped_column(String(240))
    checksum: Mapped[str | None] = mapped_column(String(120))
    detail: Mapped[str | None] = mapped_column(String(240))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class StorageTarget(Base):
    __tablename__ = "storage_targets"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(String, nullable=False)
    provider: Mapped[StorageProvider] = mapped_column(Enum(StorageProvider), nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    base_path: Mapped[str] = mapped_column(String(240), nullable=False)
    encrypted: Mapped[bool] = mapped_column(Boolean, default=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class TaxGroup(Base):
    __tablename__ = "tax_groups"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    rate_basis_points: Mapped[int] = mapped_column(Integer, default=0)
    fiscal_code: Mapped[str | None] = mapped_column(String(80))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class Supplier(Base):
    __tablename__ = "suppliers"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(40))
    email: Mapped[str | None] = mapped_column(String(160))
    address: Mapped[str | None] = mapped_column(String(240))
    tin: Mapped[str | None] = mapped_column(String(80))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    organization: Mapped[Organization] = relationship(back_populates="suppliers")


class PurchaseOrder(Base):
    __tablename__ = "purchase_orders"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    supplier_id: Mapped[str | None] = mapped_column(ForeignKey("suppliers.id"))
    status: Mapped[PurchaseOrderStatus] = mapped_column(Enum(PurchaseOrderStatus), default=PurchaseOrderStatus.draft)
    total_cost_cents: Mapped[int] = mapped_column(Integer, default=0)
    invoice_number: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    lines: Mapped[list[PurchaseOrderLine]] = relationship(back_populates="purchase_order", cascade="all, delete-orphan")


class PurchaseOrderLine(Base):
    __tablename__ = "purchase_order_lines"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    purchase_order_id: Mapped[str] = mapped_column(ForeignKey("purchase_orders.id"), nullable=False)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), nullable=False)
    ordered_quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    received_quantity: Mapped[int] = mapped_column(Integer, default=0)
    unit_cost_cents: Mapped[int] = mapped_column(Integer, default=0)

    purchase_order: Mapped[PurchaseOrder] = relationship(back_populates="lines")


class BranchTransfer(Base):
    __tablename__ = "branch_transfers"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    from_branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    to_branch_id: Mapped[str] = mapped_column(ForeignKey("branches.id"), nullable=False)
    status: Mapped[TransferStatus] = mapped_column(Enum(TransferStatus), default=TransferStatus.draft)
    reason: Mapped[str | None] = mapped_column(String(240))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    lines: Mapped[list[BranchTransferLine]] = relationship(back_populates="transfer", cascade="all, delete-orphan")


class BranchTransferLine(Base):
    __tablename__ = "branch_transfer_lines"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    transfer_id: Mapped[str] = mapped_column(ForeignKey("branch_transfers.id"), nullable=False)
    product_id: Mapped[str] = mapped_column(ForeignKey("products.id"), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)

    transfer: Mapped[BranchTransfer] = relationship(back_populates="lines")


class PriceRule(Base):
    __tablename__ = "price_rules"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    product_id: Mapped[str | None] = mapped_column(ForeignKey("products.id"))
    branch_id: Mapped[str | None] = mapped_column(ForeignKey("branches.id"))
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    promotion_type: Mapped[PromotionType] = mapped_column(Enum(PromotionType), nullable=False)
    price_cents: Mapped[int | None] = mapped_column(Integer)
    discount_basis_points: Mapped[int | None] = mapped_column(Integer)
    min_quantity: Mapped[int | None] = mapped_column(Integer)
    starts_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ends_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class Receipt(Base):
    __tablename__ = "receipts"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    sale_id: Mapped[str | None] = mapped_column(ForeignKey("sales.id"))
    channel: Mapped[ReceiptChannel] = mapped_column(Enum(ReceiptChannel), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    fiscal_qr_data: Mapped[str | None] = mapped_column(Text)
    delivered: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class PrintJob(Base):
    __tablename__ = "print_jobs"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    receipt_id: Mapped[str | None] = mapped_column(ForeignKey("receipts.id"))
    device_uid: Mapped[str] = mapped_column(String(180), nullable=False)
    channel: Mapped[PrintChannel] = mapped_column(Enum(PrintChannel), nullable=False)
    status: Mapped[PrintJobStatus] = mapped_column(Enum(PrintJobStatus), default=PrintJobStatus.queued)
    target_name: Mapped[str | None] = mapped_column(String(160))
    payload: Mapped[str] = mapped_column(Text, nullable=False)
    error_message: Mapped[str | None] = mapped_column(String(240))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class FraudAlert(Base):
    __tablename__ = "fraud_alerts"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(String, nullable=False)
    branch_id: Mapped[str | None] = mapped_column(String)
    severity: Mapped[str] = mapped_column(String(20), default="medium")
    alert_type: Mapped[str] = mapped_column(String(100), nullable=False)
    detail: Mapped[str] = mapped_column(String(240), nullable=False)
    resolved: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class ImportBatch(Base):
    __tablename__ = "import_batches"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    organization_id: Mapped[str] = mapped_column(ForeignKey("organizations.id"), nullable=False)
    import_type: Mapped[str] = mapped_column(String(80), nullable=False)
    filename: Mapped[str] = mapped_column(String(180), nullable=False)
    status: Mapped[ImportStatus] = mapped_column(Enum(ImportStatus), default=ImportStatus.pending)
    rows_total: Mapped[int] = mapped_column(Integer, default=0)
    rows_valid: Mapped[int] = mapped_column(Integer, default=0)
    rows_failed: Mapped[int] = mapped_column(Integer, default=0)
    validation_report: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
