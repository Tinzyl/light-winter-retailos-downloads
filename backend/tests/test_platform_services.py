def test_auth_pin_login_and_password_login(client):
    provision = client.post("/api/provision/organization", json={"business_name": "Auth Store"}).json()
    user = client.post(
        "/api/auth/users",
        json={
            "organization_id": provision["organization_id"],
            "name": "Owner",
            "role": "owner",
            "pin": "1234",
            "password": "StrongPass1",
        },
    )
    assert user.status_code == 200

    pin_login = client.post(
        "/api/auth/login/pin",
        json={"organization_id": provision["organization_id"], "pin": "1234"},
    )
    assert pin_login.status_code == 200
    assert pin_login.json()["access_token"]

    password_login = client.post(
        "/api/auth/login/password",
        json={"organization_id": provision["organization_id"], "name": "Owner", "password": "StrongPass1"},
    )
    assert password_login.status_code == 200


def test_offline_sync_detects_stale_client_version(client):
    synced = client.post(
        "/api/sync/queue",
        json={
            "device_uid": "ANDROID-OFFLINE-001",
            "entity_type": "sale",
            "entity_id": "sale-1",
            "operation": "upsert",
            "payload_json": "{\"total\":100}",
            "client_version": 1,
            "server_version": 1,
        },
    )
    assert synced.status_code == 200
    assert synced.json()["status"] == "synced"

    conflict = client.post(
        "/api/sync/queue",
        json={
            "device_uid": "ANDROID-OFFLINE-001",
            "entity_type": "sale",
            "entity_id": "sale-1",
            "operation": "upsert",
            "payload_json": "{\"total\":120}",
            "client_version": 1,
            "server_version": 4,
        },
    )
    assert conflict.status_code == 200
    assert conflict.json()["status"] == "failed"
    assert conflict.json()["conflict_detail"]


def test_storage_backup_snapshot_and_print_job(client):
    provision = client.post("/api/provision/organization", json={"business_name": "Backup Store"}).json()
    target = client.post(
        "/api/storage/targets",
        json={
            "organization_id": provision["organization_id"],
            "provider": "local",
            "name": "Local Backup",
            "base_path": "C:/LightWinterBackups",
            "encrypted": True,
        },
    ).json()
    backup = client.post(
        "/api/backups/snapshots",
        json={"organization_id": provision["organization_id"], "storage_target_id": target["id"], "content": "{\"ok\":true}"},
    )
    assert backup.status_code == 200
    assert backup.json()["checksum"]

    job = client.post(
        "/api/print/jobs",
        json={
            "device_uid": "SUNMI-PRINT-001",
            "channel": "sunmi_bluetooth_app",
            "target_name": "Bluetooth print app share sheet",
            "payload": "Receipt text for sharing or printing",
        },
    )
    assert job.status_code == 200
    assert job.json()["status"] == "queued"
