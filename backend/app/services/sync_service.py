from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.models.domain import SyncOperation, SyncQueueItem, SyncStatus


def enqueue_sync_item(
    db: Session,
    *,
    device_uid: str,
    entity_type: str,
    entity_id: str,
    operation: SyncOperation,
    payload_json: str,
    client_version: int,
) -> SyncQueueItem:
    item = SyncQueueItem(
        device_uid=device_uid,
        entity_type=entity_type,
        entity_id=entity_id,
        operation=operation,
        payload_json=payload_json,
        client_version=client_version,
        status=SyncStatus.pending,
    )
    db.add(item)
    db.commit()
    db.refresh(item)
    return item


def apply_sync_item(db: Session, item: SyncQueueItem, *, server_version: int | None = None) -> SyncQueueItem:
    if server_version is not None and item.client_version < server_version:
        item.status = SyncStatus.failed
        item.conflict_detail = "Client version is older than server version."
    else:
        item.status = SyncStatus.synced
        item.server_version = (server_version or item.client_version) + 1
        item.applied_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(item)
    return item
