from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.domain import Device, DurationMode, License, LicenseStatus, LicenseToken
from app.services.token_service import generate_random_token, normalize_token


class LicenseError(ValueError):
    pass


def trusted_now() -> datetime:
    return datetime.now(timezone.utc)


def create_license_tokens(
    db: Session,
    *,
    duration_mode: DurationMode,
    duration_value: int,
    quantity: int,
    target_device_uid: str | None = None,
) -> list[LicenseToken]:
    if duration_value <= 0:
        raise LicenseError("License duration must be greater than zero.")
    if quantity <= 0 or quantity > 500:
        raise LicenseError("Quantity must be between 1 and 500.")

    tokens: list[LicenseToken] = []
    seen: set[str] = set()
    while len(tokens) < quantity:
        value = generate_random_token()
        if value in seen:
            continue
        exists = db.scalar(select(LicenseToken).where(LicenseToken.token == value))
        if exists:
            continue
        seen.add(value)
        tokens.append(
            LicenseToken(
                token=value,
                duration_mode=duration_mode,
                duration_value=duration_value,
                target_device_uid=target_device_uid,
            )
        )
    db.add_all(tokens)
    db.commit()
    for token in tokens:
        db.refresh(token)
    return tokens


def apply_license_token(db: Session, *, device_uid: str, token_value: str, now: datetime | None = None) -> License:
    now = now or trusted_now()
    device = db.scalar(select(Device).where(Device.device_uid == device_uid))
    if device is None or not device.activated:
        raise LicenseError("Device must be activated before licensing.")

    token = db.scalar(select(LicenseToken).where(LicenseToken.token == normalize_token(token_value)))
    if token is None:
        raise LicenseError("License token was not found.")
    if token.used_at is not None:
        raise LicenseError("License token has already been used.")
    if token.target_device_uid and token.target_device_uid != device_uid:
        raise LicenseError("License token is not assigned to this device.")

    duration = timedelta(days=token.duration_value)
    if token.duration_mode == DurationMode.minutes:
        duration = timedelta(minutes=token.duration_value)

    license_record = License(
        device_id=device.id,
        token_id=token.id,
        starts_at=now,
        expires_at=now + duration,
        last_trusted_seen_at=now,
        status=LicenseStatus.active,
    )
    token.used_at = now
    token.used_by_device_uid = device_uid
    db.add(license_record)
    db.commit()
    db.refresh(license_record)
    return license_record


def reconcile_license_checkpoint(
    license_record: License,
    *,
    candidate_device_time: datetime,
    trusted_server_time: datetime | None,
) -> LicenseStatus:
    """Protect validity from local clock rollback/jump by only advancing from trusted time."""
    reference_time = trusted_server_time or license_record.last_trusted_seen_at
    if reference_time < license_record.last_trusted_seen_at:
        reference_time = license_record.last_trusted_seen_at

    if trusted_server_time and trusted_server_time > license_record.last_trusted_seen_at:
        license_record.last_trusted_seen_at = trusted_server_time

    if reference_time >= license_record.expires_at:
        license_record.status = LicenseStatus.expired
    elif license_record.expires_at - reference_time <= timedelta(days=3):
        license_record.status = LicenseStatus.expiring_soon
    else:
        license_record.status = LicenseStatus.active

    return license_record.status
