from __future__ import annotations

import hashlib
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.models.domain import BackupEvent, BackupStatus, StorageProvider, StorageTarget


class StorageError(ValueError):
    pass


def create_storage_target(
    db: Session,
    *,
    organization_id: str,
    provider: StorageProvider,
    name: str,
    base_path: str,
    encrypted: bool = True,
) -> StorageTarget:
    target = StorageTarget(
        organization_id=organization_id,
        provider=provider,
        name=name,
        base_path=base_path,
        encrypted=encrypted,
    )
    db.add(target)
    db.commit()
    db.refresh(target)
    return target


def record_backup_snapshot(db: Session, *, organization_id: str, target: StorageTarget, content: str) -> BackupEvent:
    checksum = hashlib.sha256(content.encode("utf-8")).hexdigest()
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    location = f"{target.base_path.rstrip('/')}/light-winter-retailos-{organization_id}-{timestamp}.json"
    event = BackupEvent(
        organization_id=organization_id,
        status=BackupStatus.succeeded,
        location=location,
        checksum=checksum,
        detail=f"Backup prepared for {target.provider.value}; encrypted={target.encrypted}",
    )
    db.add(event)
    db.commit()
    db.refresh(event)
    return event
