from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.models.domain import PrintChannel, PrintJob, PrintJobStatus


def create_print_job(
    db: Session,
    *,
    device_uid: str,
    channel: PrintChannel,
    payload: str,
    receipt_id: str | None = None,
    target_name: str | None = None,
) -> PrintJob:
    job = PrintJob(
        receipt_id=receipt_id,
        device_uid=device_uid,
        channel=channel,
        payload=payload,
        target_name=target_name,
        status=PrintJobStatus.queued,
    )
    db.add(job)
    db.commit()
    db.refresh(job)
    return job


def mark_print_job(db: Session, *, job: PrintJob, status: PrintJobStatus, error_message: str | None = None) -> PrintJob:
    job.status = status
    job.error_message = error_message
    if status in {PrintJobStatus.sent, PrintJobStatus.printed, PrintJobStatus.failed}:
        job.completed_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(job)
    return job
