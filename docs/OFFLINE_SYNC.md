# Offline Sync Strategy

RetailOS is designed as offline-first.

## Local Device Behavior

The client should store local sales, stock movements, customer/debt updates, receipts, and license checkpoints in a durable local database. Device local time is not licensing authority.

## Sync Queue

Each local change is queued with:

- device UID
- entity type
- entity ID
- operation
- payload
- client version

The backend assigns/applies server versions and rejects stale updates as conflicts.

## Conflict Handling

Conflicts must be visible to owner/manager roles. The system must not silently overwrite server data when the device has been offline for too long or has an older entity version.
