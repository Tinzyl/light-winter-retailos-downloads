from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
import json
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.domain import (
    ActivationCode,
    BackupEvent,
    BackupStatus,
    BranchTransfer,
    BranchTransferLine,
    Branch,
    BranchStock,
    Customer,
    Device,
    FiscalDay,
    FiscalDayStatus,
    FiscalMode,
    FiscalStage,
    License,
    Organization,
    PriceRule,
    Product,
    PurchaseOrder,
    PurchaseOrderLine,
    PurchaseOrderStatus,
    Receipt,
    Supplier,
    FraudAlert,
    ImportBatch,
    ImportStatus,
    Sale,
    StorageTarget,
    StockMovement,
    StockMovementType,
    SyncEvent,
    SyncStatus,
    TransferStatus,
    User,
)
from app.schemas.api import (
    ActivateTerminalRequest,
    ActivateTerminalResponse,
    ApplyLicenseRequest,
    AppApplyLicenseRequest,
    AppBootstrapResponse,
    AppBranchPayload,
    AppCreateShopRequest,
    AppJoinShopRequest,
    AppUpdateUserRequest,
    AppUserPayload,
    BackupEventRequest,
    BackupSnapshotRequest,
    BackupSnapshotResponse,
    BranchCreateRequest,
    BranchResponse,
    BranchTransferCreateRequest,
    BranchTransferResponse,
    CustomerCreateRequest,
    CustomerResponse,
    DashboardResponse,
    CreateLicenseTokensRequest,
    CreateSaleRequest,
    FiscalSettingsRequest,
    FiscalSettingsResponse,
    FiscalDayRequest,
    FiscalDayResponse,
    FraudAlertResponse,
    ImportBatchRequest,
    ImportBatchResponse,
    LicenseStatusResponse,
    LicenseTokenResponse,
    LoginResponse,
    PasswordLoginRequest,
    PinLoginRequest,
    ProductCreateRequest,
    ProductResponse,
    PurchaseOrderCreateRequest,
    PurchaseOrderResponse,
    PurchaseReceiveRequest,
    PriceRuleCreateRequest,
    PriceRuleResponse,
    ReceiptCreateRequest,
    ReceiptResponse,
    PrintJobCreateRequest,
    PrintJobResponse,
    PrintJobStatusRequest,
    ProvisionOrganizationRequest,
    ProvisionOrganizationResponse,
    ReversalRequest,
    ReversalResponse,
    SaleLineResponse,
    SaleResponse,
    StockAdjustRequest,
    StockResponse,
    SupplierCreateRequest,
    SupplierResponse,
    StorageTargetRequest,
    StorageTargetResponse,
    SyncQueueRequest,
    SyncQueueResponse,
    SyncHeartbeatRequest,
    SyncHeartbeatResponse,
    UserCreateRequest,
    UserResponse,
    ZimraCloseDayRequest,
    ZimraDeviceRequest,
    ZimraEndpointMapResponse,
    ZimraOpenDayRequest,
    ZimraRegisterDeviceRequest,
    ZimraResponse,
    ZimraSampleDocumentsRequest,
    ZimraServerCertificateRequest,
    ZimraSubmitReceiptRequest,
    ZimraVerifyTaxpayerRequest,
)
from app.services.license_service import LicenseError, apply_license_token, create_license_tokens, reconcile_license_checkpoint
from app.services.auth_service import AuthError, create_user as auth_create_user, hash_secret, login_with_password, login_with_pin
from app.services.print_service import create_print_job, mark_print_job
from app.services.retail_service import RetailError, adjust_stock, create_sale, organization_debt_balance, reverse_sale
from app.services.storage_service import create_storage_target, record_backup_snapshot
from app.services.sync_service import apply_sync_item, enqueue_sync_item
from app.services.token_service import generate_random_token, normalize_token
from app.services.zimra_fdms_service import (
    ClientCertificate,
    ZimraFdmsClient,
    ZimraFdmsError,
    build_sample_document_set,
    fdms_base_url,
    fdms_endpoint_map,
    FDMS_ENDPOINTS,
)

router = APIRouter()


def _zimra_client(payload: ZimraDeviceRequest | ZimraVerifyTaxpayerRequest | ZimraRegisterDeviceRequest | ZimraServerCertificateRequest) -> ZimraFdmsClient:
    certificate = getattr(payload, "certificate", None)
    client_certificate = None
    if certificate is not None:
        client_certificate = ClientCertificate(certificate.certificate_path, certificate.private_key_path)
    return ZimraFdmsClient(environment=payload.environment, certificate=client_certificate)


def _zimra_response(payload, endpoint: str, response: dict) -> ZimraResponse:
    return ZimraResponse(environment=payload.environment, base_url=fdms_base_url(payload.environment), endpoint=endpoint, response=response)


def _role_value(role) -> str:
    return role.value if hasattr(role, "value") else str(role)


def _create_app_user(db: Session, organization_id: str, payload: AppUserPayload) -> User:
    existing = db.scalar(select(User).where(User.organization_id == organization_id, User.username == payload.username, User.active.is_(True)))
    if existing:
        raise HTTPException(status_code=409, detail="Username already exists in this shop.")
    user = User(
        organization_id=organization_id,
        name=payload.name,
        username=payload.username,
        role=payload.role,
        pin_plain=payload.pin,
        pin_hash=hash_secret(payload.pin),
        password_hash=hash_secret(payload.pin),
        permissions_json=json.dumps(payload.permissions),
    )
    db.add(user)
    db.flush()
    return user


def _branch_from_payload(org: Organization, payload: AppBranchPayload, code_prefix: str | None = None) -> Branch:
    return Branch(
        organization=org,
        name=payload.name,
        branch_code=code_prefix,
        address_line_1=payload.address,
        phone=payload.phone,
    )


def _app_user_dict(user: User) -> dict:
    return {
        "id": user.id,
        "name": user.name,
        "username": user.username or user.name,
        "role": _role_value(user.role),
        "pin": user.pin_plain or "",
        "active": user.active,
        "permissions": json.loads(user.permissions_json or "[]"),
    }


def _app_bootstrap(db: Session, device: Device) -> AppBootstrapResponse:
    branch = device.branch
    org = branch.organization
    branches = db.scalars(select(Branch).where(Branch.organization_id == org.id)).all()
    users = db.scalars(select(User).where(User.organization_id == org.id, User.active.is_(True))).all()
    products = db.scalars(select(Product).where(Product.organization_id == org.id, Product.active.is_(True))).all()
    customers = db.scalars(select(Customer).where(Customer.organization_id == org.id)).all()
    stock = db.scalars(select(BranchStock).where(BranchStock.branch_id == device.branch_id)).all()
    license_record = db.scalar(select(License).where(License.device_id == device.id).order_by(License.expires_at.desc()))
    license_label = "Not licensed"
    if license_record:
        license_label = f"{license_record.status.value} until {license_record.expires_at.date().isoformat()}"
    return AppBootstrapResponse(
        organization_id=org.id,
        shop_name=org.name,
        fiscal_mode=org.fiscal_mode,
        device_id=device.id,
        device_uid=device.device_uid,
        assigned_branch_id=device.branch_id,
        license_label=license_label,
        branches=[{"id": b.id, "name": b.name, "phone": b.phone, "address": b.address_line_1} for b in branches],
        users=[_app_user_dict(u) for u in users],
        products=[{"id": p.id, "name": p.name, "sku": p.sku, "barcode": p.barcode, "price_cents": p.selling_price_cents, "reorder_level": p.reorder_threshold} for p in products],
        stock=[{"branch_id": s.branch_id, "product_id": s.product_id, "quantity": s.quantity} for s in stock],
        customers=[{"id": c.id, "name": c.name, "phone": c.phone} for c in customers],
    )


@router.get("/fiscal/zimra/endpoints", response_model=ZimraEndpointMapResponse)
def zimra_endpoints() -> ZimraEndpointMapResponse:
    return ZimraEndpointMapResponse(**fdms_endpoint_map())


@router.post("/fiscal/zimra/verify-taxpayer", response_model=ZimraResponse)
def zimra_verify_taxpayer(payload: ZimraVerifyTaxpayerRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).verify_taxpayer_information(
            device_id=payload.device_id,
            activation_key=payload.activation_key,
            device_serial_no=payload.device_serial_no,
        )
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["public"]["verify_taxpayer_information"], response)


@router.post("/fiscal/zimra/register-device", response_model=ZimraResponse)
def zimra_register_device(payload: ZimraRegisterDeviceRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).register_device(
            device_id=payload.device_id,
            activation_key=payload.activation_key,
            certificate_request=payload.certificate_request,
            device_model_name=payload.device_model_name,
            device_model_version=payload.device_model_version,
        )
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["public"]["register_device"], response)


@router.post("/fiscal/zimra/server-certificate", response_model=ZimraResponse)
def zimra_server_certificate(payload: ZimraServerCertificateRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).get_server_certificate(payload.thumbprint)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["public"]["get_server_certificate"], response)


@router.post("/fiscal/zimra/config", response_model=ZimraResponse)
def zimra_get_config(payload: ZimraDeviceRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).get_config(payload.device_id)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["device"]["get_config"], response)


@router.post("/fiscal/zimra/status", response_model=ZimraResponse)
def zimra_get_status(payload: ZimraDeviceRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).get_status(payload.device_id)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["device"]["get_status"], response)


@router.post("/fiscal/zimra/open-day", response_model=ZimraResponse)
def zimra_open_day(payload: ZimraOpenDayRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).open_day(payload.device_id, payload.fiscal_day_opened, payload.fiscal_day_no)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["device"]["open_day"], response)


@router.post("/fiscal/zimra/close-day", response_model=ZimraResponse)
def zimra_close_day(payload: ZimraCloseDayRequest) -> ZimraResponse:
    close_payload = {
        "fiscalDayNo": payload.fiscal_day_no,
        "fiscalDayCounters": payload.fiscal_day_counters,
        "fiscalDayDeviceSignature": payload.fiscal_day_device_signature,
        "receiptCounter": payload.receipt_counter,
    }
    try:
        response = _zimra_client(payload).close_day(payload.device_id, close_payload)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["device"]["close_day"], response)


@router.post("/fiscal/zimra/submit-receipt", response_model=ZimraResponse)
def zimra_submit_receipt(payload: ZimraSubmitReceiptRequest) -> ZimraResponse:
    try:
        response = _zimra_client(payload).submit_receipt(payload.device_id, payload.receipt)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return _zimra_response(payload, FDMS_ENDPOINTS["device"]["submit_receipt"], response)


@router.post("/fiscal/zimra/sample-documents")
def zimra_sample_documents(payload: ZimraSampleDocumentsRequest) -> dict:
    try:
        return build_sample_document_set(private_key_pem=payload.private_key_pem, started_at=payload.started_at)
    except ZimraFdmsError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/app/create-shop", response_model=AppBootstrapResponse)
def app_create_shop(payload: AppCreateShopRequest, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    org = Organization(
        name=payload.shop_name,
        trading_name=payload.shop_name,
        fiscal_mode=payload.fiscal_mode,
        receipt_footer="Powered by Light Winter Technologies",
    )
    main_branch = _branch_from_payload(org, payload.main_branch, "MAIN")
    db.add_all([org, main_branch])
    db.flush()
    for idx, branch_payload in enumerate(payload.branches, start=2):
        db.add(_branch_from_payload(org, branch_payload, f"B{idx:03d}"))
    _create_app_user(db, org.id, payload.owner)
    for user_payload in payload.users:
        _create_app_user(db, org.id, user_payload)
    device = Device(branch_id=main_branch.id, device_uid=payload.device_uid, name=payload.device_name, platform=payload.platform, activated=True)
    db.add(device)
    db.add(ActivationCode(branch_id=main_branch.id, code=generate_random_token(groups=2, group_size=4)))
    db.commit()
    db.refresh(device)
    return _app_bootstrap(db, device)


@router.post("/app/join-shop", response_model=AppBootstrapResponse)
def app_join_shop(payload: AppJoinShopRequest, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    code = db.scalar(select(ActivationCode).where(ActivationCode.code == normalize_token(payload.activation_code)))
    if code is None or code.used:
        raise HTTPException(status_code=400, detail="Activation code is invalid or already used.")
    existing = db.scalar(select(Device).where(Device.device_uid == payload.device_uid))
    if existing:
        return _app_bootstrap(db, existing)
    device = Device(branch_id=code.branch_id, device_uid=payload.device_uid, name=payload.device_name, platform=payload.platform, activated=True)
    code.used = True
    db.add(device)
    db.commit()
    db.refresh(device)
    return _app_bootstrap(db, device)


@router.get("/app/bootstrap/{device_uid}", response_model=AppBootstrapResponse)
def app_bootstrap(device_uid: str, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    if device is None or not device.activated:
        raise HTTPException(status_code=404, detail="Activated device was not found.")
    return _app_bootstrap(db, device)


@router.post("/app/devices/{device_uid}/license", response_model=AppBootstrapResponse)
def app_apply_license(device_uid: str, payload: AppApplyLicenseRequest, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    if payload.device_uid != device_uid:
        raise HTTPException(status_code=400, detail="Device UID mismatch.")
    try:
        apply_license_token(db, device_uid=device_uid, token_value=payload.token)
    except LicenseError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    return _app_bootstrap(db, device)


@router.post("/app/organizations/{organization_id}/branches", response_model=AppBootstrapResponse)
def app_create_branch(organization_id: str, payload: AppBranchPayload, device_uid: str, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    org = db.get(Organization, organization_id)
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    if org is None or device is None:
        raise HTTPException(status_code=404, detail="Organization or device not found.")
    branch = _branch_from_payload(org, payload)
    db.add(branch)
    db.flush()
    db.add(ActivationCode(branch_id=branch.id, code=generate_random_token(groups=2, group_size=4)))
    db.commit()
    return _app_bootstrap(db, device)


@router.delete("/app/branches/{branch_id}", response_model=AppBootstrapResponse)
def app_delete_branch(branch_id: str, device_uid: str, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    branch = db.get(Branch, branch_id)
    if device is None or branch is None:
        raise HTTPException(status_code=404, detail="Device or branch not found.")
    count = db.scalar(select(func.count(Branch.id)).where(Branch.organization_id == branch.organization_id))
    if count <= 1:
        raise HTTPException(status_code=400, detail="At least one branch is required.")
    if device.branch_id == branch_id:
        raise HTTPException(status_code=400, detail="Move this device before deleting its branch.")
    db.delete(branch)
    db.commit()
    return _app_bootstrap(db, device)


@router.post("/app/organizations/{organization_id}/users", response_model=AppBootstrapResponse)
def app_create_user(organization_id: str, payload: AppUserPayload, device_uid: str, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    if device is None:
        raise HTTPException(status_code=404, detail="Device not found.")
    _create_app_user(db, organization_id, payload)
    db.commit()
    return _app_bootstrap(db, device)


@router.put("/app/users/{user_id}", response_model=AppBootstrapResponse)
def app_update_user(user_id: str, payload: AppUpdateUserRequest, device_uid: str, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    user = db.get(User, user_id)
    if device is None or user is None:
        raise HTTPException(status_code=404, detail="Device or user not found.")
    user.name = payload.name
    user.username = payload.username
    user.role = payload.role
    user.pin_plain = payload.pin
    user.pin_hash = hash_secret(payload.pin)
    user.password_hash = hash_secret(payload.pin)
    user.permissions_json = json.dumps(payload.permissions)
    user.active = payload.active
    db.commit()
    return _app_bootstrap(db, device)


@router.delete("/app/users/{user_id}", response_model=AppBootstrapResponse)
def app_delete_user(user_id: str, device_uid: str, db: Session = Depends(get_db)) -> AppBootstrapResponse:
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    user = db.get(User, user_id)
    if device is None or user is None:
        raise HTTPException(status_code=404, detail="Device or user not found.")
    active_users = db.scalars(select(User).where(User.organization_id == user.organization_id, User.active.is_(True))).all()
    if len(active_users) <= 1:
        raise HTTPException(status_code=400, detail="At least one user is required.")
    user.active = False
    db.commit()
    return _app_bootstrap(db, device)


@router.post("/provision/organization", response_model=ProvisionOrganizationResponse)
def provision_organization(payload: ProvisionOrganizationRequest, db: Session = Depends(get_db)) -> ProvisionOrganizationResponse:
    org = Organization(
        name=payload.business_name,
        trading_name=payload.trading_name or payload.business_name,
        legal_name=payload.legal_name,
        country=payload.country,
        default_currency=payload.default_currency.upper(),
        phone=payload.phone,
        email=payload.email,
        receipt_footer=payload.receipt_footer or "Powered by Light Winter Technologies",
        tin=payload.tin,
        vat_number=payload.vat_number,
    )
    branch = Branch(
        name=payload.branch_name,
        organization=org,
        branch_code=payload.branch_code,
        address_line_1=payload.address_line_1,
        address_line_2=payload.address_line_2,
        city=payload.city,
        province=payload.province,
        phone=payload.phone,
        email=payload.email,
    )
    db.add_all([org, branch])
    db.flush()
    activation = ActivationCode(branch_id=branch.id, code=generate_random_token(groups=2, group_size=4))
    db.add(activation)
    db.commit()
    db.refresh(org)
    db.refresh(branch)
    db.refresh(activation)
    return ProvisionOrganizationResponse(organization_id=org.id, branch_id=branch.id, activation_code=activation.code)


@router.post("/activation/terminal", response_model=ActivateTerminalResponse)
def activate_terminal(payload: ActivateTerminalRequest, db: Session = Depends(get_db)) -> ActivateTerminalResponse:
    code = db.scalar(select(ActivationCode).where(ActivationCode.code == normalize_token(payload.activation_code)))
    if code is None or code.used:
        raise HTTPException(status_code=400, detail="Activation code is invalid or already used.")

    existing = db.scalar(select(Device).where(Device.device_uid == payload.device_uid))
    if existing:
        raise HTTPException(status_code=409, detail="Device UID is already enrolled.")

    device = Device(
        branch_id=code.branch_id,
        device_uid=payload.device_uid,
        name=payload.device_name,
        platform=payload.platform,
        activated=True,
    )
    code.used = True
    db.add(device)
    db.commit()
    db.refresh(device)
    return ActivateTerminalResponse(device_id=device.id, branch_id=device.branch_id, activated=device.activated)


@router.post("/branches", response_model=BranchResponse)
def create_branch(payload: BranchCreateRequest, db: Session = Depends(get_db)) -> BranchResponse:
    org = db.get(Organization, payload.organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found.")
    branch = Branch(
        organization_id=payload.organization_id,
        name=payload.name,
        branch_code=payload.branch_code,
        address_line_1=payload.address_line_1,
        city=payload.city,
    )
    db.add(branch)
    db.commit()
    db.refresh(branch)
    return BranchResponse(id=branch.id, organization_id=branch.organization_id, name=branch.name, branch_code=branch.branch_code)


@router.post("/auth/users", response_model=UserResponse)
def api_create_user(payload: UserCreateRequest, db: Session = Depends(get_db)) -> UserResponse:
    try:
        user = auth_create_user(
            db,
            organization_id=payload.organization_id,
            name=payload.name,
            role=payload.role,
            pin=payload.pin,
            password=payload.password,
        )
    except AuthError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _user_response(user)


@router.post("/auth/login/pin", response_model=LoginResponse)
def api_pin_login(payload: PinLoginRequest, db: Session = Depends(get_db)) -> LoginResponse:
    try:
        user, token = login_with_pin(db, organization_id=payload.organization_id, pin=payload.pin, device_uid=payload.device_uid)
    except AuthError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    return LoginResponse(access_token=token, user=_user_response(user))


@router.post("/auth/login/password", response_model=LoginResponse)
def api_password_login(payload: PasswordLoginRequest, db: Session = Depends(get_db)) -> LoginResponse:
    try:
        user, token = login_with_password(
            db,
            organization_id=payload.organization_id,
            name=payload.name,
            password=payload.password,
            device_uid=payload.device_uid,
        )
    except AuthError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    return LoginResponse(access_token=token, user=_user_response(user))


@router.post("/licenses/tokens", response_model=list[LicenseTokenResponse])
def create_tokens(payload: CreateLicenseTokensRequest, db: Session = Depends(get_db)) -> list[LicenseTokenResponse]:
    try:
        tokens = create_license_tokens(
            db,
            duration_mode=payload.duration_mode,
            duration_value=payload.duration_value,
            quantity=payload.quantity,
            target_device_uid=payload.target_device_uid,
        )
    except LicenseError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return [
        LicenseTokenResponse(
            token=token.token,
            duration_mode=token.duration_mode,
            duration_value=token.duration_value,
            target_device_uid=token.target_device_uid,
        )
        for token in tokens
    ]


@router.post("/licenses/apply", response_model=LicenseStatusResponse)
def apply_license(payload: ApplyLicenseRequest, db: Session = Depends(get_db)) -> LicenseStatusResponse:
    try:
        license_record = apply_license_token(db, device_uid=payload.device_uid, token_value=payload.token)
    except LicenseError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return LicenseStatusResponse(
        status=license_record.status,
        starts_at=license_record.starts_at,
        expires_at=license_record.expires_at,
        last_trusted_seen_at=license_record.last_trusted_seen_at,
    )


@router.get("/licenses/device/{device_uid}", response_model=LicenseStatusResponse)
def license_status(device_uid: str, db: Session = Depends(get_db)) -> LicenseStatusResponse:
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    if device is None:
        raise HTTPException(status_code=404, detail="Device not found.")
    license_record = db.scalar(select(License).where(License.device_id == device.id).order_by(License.expires_at.desc()))
    if license_record is None:
        raise HTTPException(status_code=404, detail="Device is not licensed.")
    reconcile_license_checkpoint(
        license_record,
        candidate_device_time=datetime.now(timezone.utc),
        trusted_server_time=datetime.now(timezone.utc),
    )
    db.commit()
    db.refresh(license_record)
    return LicenseStatusResponse(
        status=license_record.status,
        starts_at=license_record.starts_at,
        expires_at=license_record.expires_at,
        last_trusted_seen_at=license_record.last_trusted_seen_at,
    )


@router.put("/organizations/{organization_id}/fiscal", response_model=FiscalSettingsResponse)
def update_fiscal_settings(
    organization_id: str,
    payload: FiscalSettingsRequest,
    db: Session = Depends(get_db),
) -> FiscalSettingsResponse:
    org = db.get(Organization, organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found.")
    org.fiscal_mode = payload.fiscal_mode
    org.taxpayer_registered_name = payload.taxpayer_registered_name
    org.tin = payload.tin
    org.vat_number = payload.vat_number
    org.fiscal_authority = payload.fiscal_authority
    org.fiscal_stage = payload.stage
    db.commit()
    db.refresh(org)

    message = None
    if org.fiscal_stage in {FiscalStage.fiscal_readiness_reached, FiscalStage.documents_required}:
        message = "Fiscal Integration Stage Reached - Upload Fiscal API Documentation / Credentials to Continue."

    return FiscalSettingsResponse(
        organization_id=org.id,
        fiscal_mode=org.fiscal_mode,
        taxpayer_registered_name=org.taxpayer_registered_name,
        tin=org.tin,
        vat_number=org.vat_number,
        fiscal_authority=org.fiscal_authority,
        stage=org.fiscal_stage,
        message=message,
    )


@router.post("/fiscal/open-day", response_model=FiscalDayResponse)
def open_fiscal_day(payload: FiscalDayRequest, db: Session = Depends(get_db)) -> FiscalDayResponse:
    device = db.scalar(select(Device).where(Device.device_uid == payload.device_uid))
    if device is None or not device.activated:
        raise HTTPException(status_code=404, detail="Activated device not found.")

    org = device.branch.organization
    if org.fiscal_mode != FiscalMode.fiscal:
        raise HTTPException(status_code=400, detail="Fiscal day controls are available only in fiscal mode.")
    if org.fiscal_stage not in {
        FiscalStage.fiscal_readiness_reached,
        FiscalStage.documents_required,
        FiscalStage.sandbox_integration,
        FiscalStage.validation_testing,
        FiscalStage.production_go_live,
    }:
        raise HTTPException(status_code=400, detail="Fiscal readiness must be reached before opening a fiscal day.")

    existing_open = db.scalar(
        select(FiscalDay).where(FiscalDay.device_id == device.id, FiscalDay.status == FiscalDayStatus.opened)
    )
    if existing_open:
        raise HTTPException(status_code=409, detail="Fiscal day is already open for this device.")

    latest = db.scalar(select(FiscalDay).where(FiscalDay.device_id == device.id).order_by(FiscalDay.fiscal_day_no.desc()))
    fiscal_day = FiscalDay(
        device_id=device.id,
        fiscal_day_no=(latest.fiscal_day_no + 1) if latest else 1,
        status=FiscalDayStatus.opened,
        opened_at=datetime.now(timezone.utc),
        opened_by_user_id=payload.user_id,
    )
    db.add(fiscal_day)
    db.commit()
    db.refresh(fiscal_day)
    return FiscalDayResponse(
        fiscal_day_id=fiscal_day.id,
        device_uid=device.device_uid,
        fiscal_day_no=fiscal_day.fiscal_day_no,
        status=fiscal_day.status,
        opened_at=fiscal_day.opened_at,
        closed_at=fiscal_day.closed_at,
    )


@router.post("/fiscal/close-day", response_model=FiscalDayResponse)
def close_fiscal_day(payload: FiscalDayRequest, db: Session = Depends(get_db)) -> FiscalDayResponse:
    device = db.scalar(select(Device).where(Device.device_uid == payload.device_uid))
    if device is None or not device.activated:
        raise HTTPException(status_code=404, detail="Activated device not found.")

    fiscal_day = db.scalar(
        select(FiscalDay).where(FiscalDay.device_id == device.id, FiscalDay.status == FiscalDayStatus.opened)
    )
    if fiscal_day is None:
        raise HTTPException(status_code=409, detail="There is no open fiscal day for this device.")

    fiscal_day.status = FiscalDayStatus.closed
    fiscal_day.closed_at = datetime.now(timezone.utc)
    fiscal_day.closed_by_user_id = payload.user_id
    db.commit()
    db.refresh(fiscal_day)
    return FiscalDayResponse(
        fiscal_day_id=fiscal_day.id,
        device_uid=device.device_uid,
        fiscal_day_no=fiscal_day.fiscal_day_no,
        status=fiscal_day.status,
        opened_at=fiscal_day.opened_at,
        closed_at=fiscal_day.closed_at,
    )


@router.post("/products", response_model=ProductResponse)
def create_product(payload: ProductCreateRequest, db: Session = Depends(get_db)) -> ProductResponse:
    org = db.get(Organization, payload.organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found.")
    product = Product(
        organization_id=payload.organization_id,
        sku=payload.sku.upper(),
        barcode=payload.barcode,
        name=payload.name,
        category=payload.category,
        unit_of_measure=payload.unit_of_measure,
        buying_cost_cents=payload.buying_cost_cents,
        selling_price_cents=payload.selling_price_cents,
        reorder_threshold=payload.reorder_threshold,
    )
    db.add(product)
    db.commit()
    db.refresh(product)
    return ProductResponse(
        id=product.id,
        sku=product.sku,
        barcode=product.barcode,
        name=product.name,
        category=product.category,
        unit_of_measure=product.unit_of_measure,
        selling_price_cents=product.selling_price_cents,
        reorder_threshold=product.reorder_threshold,
    )


@router.get("/organizations/{organization_id}/products", response_model=list[ProductResponse])
def list_products(organization_id: str, db: Session = Depends(get_db)) -> list[ProductResponse]:
    products = db.scalars(select(Product).where(Product.organization_id == organization_id, Product.active.is_(True))).all()
    return [
        ProductResponse(
            id=product.id,
            sku=product.sku,
            barcode=product.barcode,
            name=product.name,
            category=product.category,
            unit_of_measure=product.unit_of_measure,
            selling_price_cents=product.selling_price_cents,
            reorder_threshold=product.reorder_threshold,
        )
        for product in products
    ]


@router.post("/stock/adjust", response_model=StockResponse)
def stock_adjust(payload: StockAdjustRequest, db: Session = Depends(get_db)) -> StockResponse:
    try:
        stock = adjust_stock(
            db,
            branch_id=payload.branch_id,
            product_id=payload.product_id,
            movement_type=payload.movement_type,
            quantity_delta=payload.quantity_delta,
            reason=payload.reason,
            user_id=payload.user_id,
        )
    except RetailError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    db.commit()
    db.refresh(stock)
    return _stock_response(stock)


@router.get("/branches/{branch_id}/stock", response_model=list[StockResponse])
def branch_stock(branch_id: str, db: Session = Depends(get_db)) -> list[StockResponse]:
    rows = db.scalars(select(BranchStock).where(BranchStock.branch_id == branch_id)).all()
    return [_stock_response(row) for row in rows]


@router.post("/customers", response_model=CustomerResponse)
def create_customer(payload: CustomerCreateRequest, db: Session = Depends(get_db)) -> CustomerResponse:
    org = db.get(Organization, payload.organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found.")
    customer = Customer(
        organization_id=payload.organization_id,
        name=payload.name,
        phone=payload.phone,
        address=payload.address,
        tin=payload.tin,
        vat_number=payload.vat_number,
        debt_limit_cents=payload.debt_limit_cents,
    )
    db.add(customer)
    db.commit()
    db.refresh(customer)
    return _customer_response(db, customer)


@router.get("/organizations/{organization_id}/customers", response_model=list[CustomerResponse])
def list_customers(organization_id: str, db: Session = Depends(get_db)) -> list[CustomerResponse]:
    customers = db.scalars(select(Customer).where(Customer.organization_id == organization_id)).all()
    return [_customer_response(db, customer) for customer in customers]


@router.post("/sales", response_model=SaleResponse)
def api_create_sale(payload: CreateSaleRequest, db: Session = Depends(get_db)) -> SaleResponse:
    try:
        sale = create_sale(db, payload)
    except RetailError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _sale_response(sale)


@router.get("/sales/{sale_id}", response_model=SaleResponse)
def get_sale(sale_id: str, db: Session = Depends(get_db)) -> SaleResponse:
    sale = db.get(Sale, sale_id)
    if sale is None:
        raise HTTPException(status_code=404, detail="Sale not found.")
    return _sale_response(sale)


@router.post("/sales/{sale_id}/reversals", response_model=ReversalResponse)
def api_reverse_sale(sale_id: str, payload: ReversalRequest, db: Session = Depends(get_db)) -> ReversalResponse:
    try:
        reversal = reverse_sale(db, sale_id=sale_id, payload=payload)
    except RetailError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    sale = db.get(Sale, sale_id)
    return ReversalResponse(
        reversal_id=reversal.id,
        sale_id=sale_id,
        status=sale.status if sale else reversal.sale.status,
        amount_cents=reversal.amount_cents,
    )


@router.get("/organizations/{organization_id}/dashboard", response_model=DashboardResponse)
def dashboard(organization_id: str, db: Session = Depends(get_db)) -> DashboardResponse:
    branch_ids = select(Branch.id).where(Branch.organization_id == organization_id)
    today = datetime.now(timezone.utc).date()
    sales_today = int(
        db.scalar(
            select(func.coalesce(func.sum(Sale.total_cents), 0)).where(
                Sale.branch_id.in_(branch_ids),
                func.date(Sale.created_at) == str(today),
            )
        )
        or 0
    )
    stock_rows = db.scalars(select(BranchStock).where(BranchStock.branch_id.in_(branch_ids))).all()
    low_stock_count = sum(1 for row in stock_rows if 0 < row.quantity <= row.product.reorder_threshold)
    out_of_stock_count = sum(1 for row in stock_rows if row.quantity <= 0)
    fiscal_pending = int(
        db.scalar(
            select(func.count(Sale.id)).where(Sale.branch_id.in_(branch_ids), Sale.fiscal_submission_status == SyncStatus.pending)
        )
        or 0
    )
    unsynced_events = int(db.scalar(select(func.count(SyncEvent.id)).where(SyncEvent.status != SyncStatus.synced)) or 0)
    backup_failures = int(
        db.scalar(select(func.count(BackupEvent.id)).where(BackupEvent.organization_id == organization_id, BackupEvent.status == BackupStatus.failed))
        or 0
    )
    return DashboardResponse(
        organization_id=organization_id,
        sales_today_cents=sales_today,
        debt_open_cents=organization_debt_balance(db, organization_id),
        low_stock_count=low_stock_count,
        out_of_stock_count=out_of_stock_count,
        unsynced_events=unsynced_events,
        backup_failures=backup_failures,
        fiscal_pending=fiscal_pending,
    )


@router.post("/sync/heartbeat", response_model=SyncHeartbeatResponse)
def sync_heartbeat(payload: SyncHeartbeatRequest, db: Session = Depends(get_db)) -> SyncHeartbeatResponse:
    device = db.scalar(select(Device).where(Device.device_uid == payload.device_uid))
    db.add(SyncEvent(device_id=device.id if device else None, status=payload.status, detail=payload.detail))
    db.commit()
    return SyncHeartbeatResponse(status=payload.status, server_time=datetime.now(timezone.utc))


@router.post("/backups/events")
def backup_event(payload: BackupEventRequest, db: Session = Depends(get_db)) -> dict[str, str]:
    db.add(
        BackupEvent(
            organization_id=payload.organization_id,
            status=payload.status,
            location=payload.location,
            checksum=payload.checksum,
            detail=payload.detail,
        )
    )
    db.commit()
    return {"status": "recorded"}


@router.post("/storage/targets", response_model=StorageTargetResponse)
def api_create_storage_target(payload: StorageTargetRequest, db: Session = Depends(get_db)) -> StorageTargetResponse:
    target = create_storage_target(
        db,
        organization_id=payload.organization_id,
        provider=payload.provider,
        name=payload.name,
        base_path=payload.base_path,
        encrypted=payload.encrypted,
    )
    return StorageTargetResponse(id=target.id, provider=target.provider, name=target.name, base_path=target.base_path, encrypted=target.encrypted)


@router.post("/backups/snapshots", response_model=BackupSnapshotResponse)
def api_backup_snapshot(payload: BackupSnapshotRequest, db: Session = Depends(get_db)) -> BackupSnapshotResponse:
    target = db.get(StorageTarget, payload.storage_target_id)
    if target is None or target.organization_id != payload.organization_id:
        raise HTTPException(status_code=404, detail="Storage target not found.")
    event = record_backup_snapshot(db, organization_id=payload.organization_id, target=target, content=payload.content)
    return BackupSnapshotResponse(id=event.id, status=event.status, location=event.location, checksum=event.checksum)


@router.post("/sync/queue", response_model=SyncQueueResponse)
def api_sync_queue(payload: SyncQueueRequest, db: Session = Depends(get_db)) -> SyncQueueResponse:
    item = enqueue_sync_item(
        db,
        device_uid=payload.device_uid,
        entity_type=payload.entity_type,
        entity_id=payload.entity_id,
        operation=payload.operation,
        payload_json=payload.payload_json,
        client_version=payload.client_version,
    )
    item = apply_sync_item(db, item, server_version=payload.server_version)
    return SyncQueueResponse(id=item.id, status=item.status, server_version=item.server_version, conflict_detail=item.conflict_detail)


@router.post("/print/jobs", response_model=PrintJobResponse)
def api_create_print_job(payload: PrintJobCreateRequest, db: Session = Depends(get_db)) -> PrintJobResponse:
    job = create_print_job(
        db,
        device_uid=payload.device_uid,
        channel=payload.channel,
        payload=payload.payload,
        receipt_id=payload.receipt_id,
        target_name=payload.target_name,
    )
    return PrintJobResponse(id=job.id, device_uid=job.device_uid, channel=job.channel, status=job.status, target_name=job.target_name)


@router.patch("/print/jobs/{job_id}", response_model=PrintJobResponse)
def api_update_print_job(job_id: str, payload: PrintJobStatusRequest, db: Session = Depends(get_db)) -> PrintJobResponse:
    from app.models.domain import PrintJob

    job = db.get(PrintJob, job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Print job not found.")
    job = mark_print_job(db, job=job, status=payload.status, error_message=payload.error_message)
    return PrintJobResponse(id=job.id, device_uid=job.device_uid, channel=job.channel, status=job.status, target_name=job.target_name)


@router.post("/suppliers", response_model=SupplierResponse)
def create_supplier(payload: SupplierCreateRequest, db: Session = Depends(get_db)) -> SupplierResponse:
    org = db.get(Organization, payload.organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found.")
    supplier = Supplier(
        organization_id=payload.organization_id,
        name=payload.name,
        phone=payload.phone,
        email=payload.email,
        address=payload.address,
        tin=payload.tin,
    )
    db.add(supplier)
    db.commit()
    db.refresh(supplier)
    return SupplierResponse(id=supplier.id, name=supplier.name, phone=supplier.phone, email=supplier.email)


@router.get("/organizations/{organization_id}/suppliers", response_model=list[SupplierResponse])
def list_suppliers(organization_id: str, db: Session = Depends(get_db)) -> list[SupplierResponse]:
    suppliers = db.scalars(select(Supplier).where(Supplier.organization_id == organization_id)).all()
    return [SupplierResponse(id=s.id, name=s.name, phone=s.phone, email=s.email) for s in suppliers]


@router.post("/purchase-orders", response_model=PurchaseOrderResponse)
def create_purchase_order(payload: PurchaseOrderCreateRequest, db: Session = Depends(get_db)) -> PurchaseOrderResponse:
    branch = db.get(Branch, payload.branch_id)
    if branch is None:
        raise HTTPException(status_code=404, detail="Branch not found.")
    total = 0
    lines = []
    for line in payload.lines:
        product = db.get(Product, line.product_id)
        if product is None or product.organization_id != branch.organization_id:
            raise HTTPException(status_code=400, detail="Product does not belong to this branch organization.")
        total += line.ordered_quantity * line.unit_cost_cents
        lines.append(PurchaseOrderLine(product_id=line.product_id, ordered_quantity=line.ordered_quantity, unit_cost_cents=line.unit_cost_cents))
    order = PurchaseOrder(
        branch_id=payload.branch_id,
        supplier_id=payload.supplier_id,
        invoice_number=payload.invoice_number,
        status=PurchaseOrderStatus.ordered,
        total_cost_cents=total,
        lines=lines,
    )
    db.add(order)
    db.commit()
    db.refresh(order)
    return _purchase_response(order)


@router.post("/purchase-orders/{order_id}/receive", response_model=PurchaseOrderResponse)
def receive_purchase_order(order_id: str, payload: PurchaseReceiveRequest, db: Session = Depends(get_db)) -> PurchaseOrderResponse:
    order = db.get(PurchaseOrder, order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="Purchase order not found.")
    if order.status == PurchaseOrderStatus.received:
        raise HTTPException(status_code=409, detail="Purchase order already received.")
    try:
        for line in order.lines:
            remaining = line.ordered_quantity - line.received_quantity
            if remaining > 0:
                adjust_stock(
                    db,
                    branch_id=order.branch_id,
                    product_id=line.product_id,
                    movement_type=StockMovementType.stock_in,
                    quantity_delta=remaining,
                    reason="Purchase received",
                    user_id=payload.user_id,
                    reference_id=order.id,
                )
                line.received_quantity += remaining
        order.status = PurchaseOrderStatus.received
        db.commit()
        db.refresh(order)
    except RetailError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _purchase_response(order)


@router.post("/branch-transfers", response_model=BranchTransferResponse)
def create_branch_transfer(payload: BranchTransferCreateRequest, db: Session = Depends(get_db)) -> BranchTransferResponse:
    from_branch = db.get(Branch, payload.from_branch_id)
    to_branch = db.get(Branch, payload.to_branch_id)
    if from_branch is None or to_branch is None:
        raise HTTPException(status_code=404, detail="Branch not found.")
    if from_branch.organization_id != to_branch.organization_id:
        raise HTTPException(status_code=400, detail="Branches must belong to the same organization.")
    transfer = BranchTransfer(
        from_branch_id=payload.from_branch_id,
        to_branch_id=payload.to_branch_id,
        status=TransferStatus.sent,
        reason=payload.reason,
        lines=[BranchTransferLine(product_id=line.product_id, quantity=line.quantity) for line in payload.lines],
    )
    db.add(transfer)
    db.flush()
    try:
        for line in transfer.lines:
            adjust_stock(
                db,
                branch_id=payload.from_branch_id,
                product_id=line.product_id,
                movement_type=StockMovementType.transfer_out,
                quantity_delta=-line.quantity,
                reason=payload.reason or "Branch transfer sent",
                user_id=payload.user_id,
                reference_id=transfer.id,
            )
            adjust_stock(
                db,
                branch_id=payload.to_branch_id,
                product_id=line.product_id,
                movement_type=StockMovementType.transfer_in,
                quantity_delta=line.quantity,
                reason=payload.reason or "Branch transfer received",
                user_id=payload.user_id,
                reference_id=transfer.id,
            )
        transfer.status = TransferStatus.received
        db.commit()
        db.refresh(transfer)
    except RetailError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return BranchTransferResponse(id=transfer.id, from_branch_id=transfer.from_branch_id, to_branch_id=transfer.to_branch_id, status=transfer.status)


@router.post("/price-rules", response_model=PriceRuleResponse)
def create_price_rule(payload: PriceRuleCreateRequest, db: Session = Depends(get_db)) -> PriceRuleResponse:
    org = db.get(Organization, payload.organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found.")
    rule = PriceRule(
        organization_id=payload.organization_id,
        product_id=payload.product_id,
        branch_id=payload.branch_id,
        name=payload.name,
        promotion_type=payload.promotion_type,
        price_cents=payload.price_cents,
        discount_basis_points=payload.discount_basis_points,
        min_quantity=payload.min_quantity,
    )
    db.add(rule)
    db.commit()
    db.refresh(rule)
    return PriceRuleResponse(id=rule.id, name=rule.name, promotion_type=rule.promotion_type, active=rule.active)


@router.post("/receipts", response_model=ReceiptResponse)
def create_receipt(payload: ReceiptCreateRequest, db: Session = Depends(get_db)) -> ReceiptResponse:
    receipt = Receipt(sale_id=payload.sale_id, channel=payload.channel, content=payload.content, fiscal_qr_data=payload.fiscal_qr_data)
    db.add(receipt)
    db.commit()
    db.refresh(receipt)
    return ReceiptResponse(id=receipt.id, channel=receipt.channel, delivered=receipt.delivered)


@router.get("/organizations/{organization_id}/fraud-alerts", response_model=list[FraudAlertResponse])
def list_fraud_alerts(organization_id: str, db: Session = Depends(get_db)) -> list[FraudAlertResponse]:
    alerts = db.scalars(select(FraudAlert).where(FraudAlert.organization_id == organization_id, FraudAlert.resolved.is_(False))).all()
    return [
        FraudAlertResponse(id=alert.id, severity=alert.severity, alert_type=alert.alert_type, detail=alert.detail, resolved=alert.resolved)
        for alert in alerts
    ]


@router.post("/imports/batches", response_model=ImportBatchResponse)
def create_import_batch(payload: ImportBatchRequest, db: Session = Depends(get_db)) -> ImportBatchResponse:
    failed = payload.rows_failed
    status = ImportStatus.validated if failed == 0 else ImportStatus.failed
    batch = ImportBatch(
        organization_id=payload.organization_id,
        import_type=payload.import_type,
        filename=payload.filename,
        rows_total=payload.rows_total,
        rows_valid=payload.rows_valid,
        rows_failed=failed,
        status=status,
        validation_report=payload.validation_report,
    )
    db.add(batch)
    db.commit()
    db.refresh(batch)
    return ImportBatchResponse(
        id=batch.id,
        import_type=batch.import_type,
        filename=batch.filename,
        status=batch.status.value,
        rows_total=batch.rows_total,
        rows_valid=batch.rows_valid,
        rows_failed=batch.rows_failed,
    )


def _stock_response(stock: BranchStock) -> StockResponse:
    return StockResponse(
        branch_id=stock.branch_id,
        product_id=stock.product_id,
        quantity=stock.quantity,
        low_stock=0 < stock.quantity <= stock.product.reorder_threshold,
        out_of_stock=stock.quantity <= 0,
    )


def _customer_response(db: Session, customer: Customer) -> CustomerResponse:
    balance = sum(debt.balance_cents for debt in customer.debts if debt.status.value == "open")
    return CustomerResponse(
        id=customer.id,
        name=customer.name,
        phone=customer.phone,
        debt_limit_cents=customer.debt_limit_cents,
        debt_balance_cents=balance,
    )


def _sale_response(sale: Sale) -> SaleResponse:
    return SaleResponse(
        id=sale.id,
        branch_id=sale.branch_id,
        status=sale.status,
        payment_method=sale.payment_method,
        subtotal_cents=sale.subtotal_cents,
        discount_cents=sale.discount_cents,
        tax_cents=sale.tax_cents,
        total_cents=sale.total_cents,
        paid_cents=sale.paid_cents,
        change_cents=sale.change_cents,
        fiscal_submission_status=sale.fiscal_submission_status,
        created_at=sale.created_at,
        lines=[
            SaleLineResponse(
                id=line.id,
                product_id=line.product_id,
                quantity=line.quantity,
                reversed_quantity=line.reversed_quantity,
                total_cents=line.total_cents,
            )
            for line in sale.lines
        ],
    )


def _purchase_response(order: PurchaseOrder) -> PurchaseOrderResponse:
    return PurchaseOrderResponse(
        id=order.id,
        branch_id=order.branch_id,
        supplier_id=order.supplier_id,
        status=order.status,
        total_cost_cents=order.total_cost_cents,
        invoice_number=order.invoice_number,
    )


def _user_response(user: User) -> UserResponse:
    return UserResponse(id=user.id, name=user.name, role=user.role, active=user.active)
    LoginResponse,
    PasswordLoginRequest,
