from datetime import datetime, timedelta, timezone

from app.models.domain import License, LicenseStatus
from app.services.license_service import reconcile_license_checkpoint


def test_rollback_device_clock_does_not_extend_license():
    start = datetime(2026, 4, 27, 12, 0, tzinfo=timezone.utc)
    license_record = License(
        device_id="device",
        token_id="token",
        starts_at=start,
        expires_at=start + timedelta(days=1),
        last_trusted_seen_at=start + timedelta(hours=20),
        status=LicenseStatus.active,
    )

    status = reconcile_license_checkpoint(
        license_record,
        candidate_device_time=start - timedelta(days=100),
        trusted_server_time=None,
    )

    assert status == LicenseStatus.expiring_soon
    assert license_record.last_trusted_seen_at == start + timedelta(hours=20)


def test_forward_device_clock_without_server_does_not_expire_early():
    start = datetime(2026, 4, 27, 12, 0, tzinfo=timezone.utc)
    license_record = License(
        device_id="device",
        token_id="token",
        starts_at=start,
        expires_at=start + timedelta(days=30),
        last_trusted_seen_at=start,
        status=LicenseStatus.active,
    )

    status = reconcile_license_checkpoint(
        license_record,
        candidate_device_time=start + timedelta(days=999),
        trusted_server_time=None,
    )

    assert status == LicenseStatus.active
    assert license_record.last_trusted_seen_at == start


def test_server_time_expires_license_authoritatively():
    start = datetime(2026, 4, 27, 12, 0, tzinfo=timezone.utc)
    license_record = License(
        device_id="device",
        token_id="token",
        starts_at=start,
        expires_at=start + timedelta(minutes=10),
        last_trusted_seen_at=start,
        status=LicenseStatus.active,
    )

    status = reconcile_license_checkpoint(
        license_record,
        candidate_device_time=start,
        trusted_server_time=start + timedelta(minutes=11),
    )

    assert status == LicenseStatus.expired
    assert license_record.last_trusted_seen_at == start + timedelta(minutes=11)
