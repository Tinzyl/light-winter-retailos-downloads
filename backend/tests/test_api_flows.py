def test_provision_activate_license_and_fiscal_gate(client):
    provision = client.post(
        "/api/provision/organization",
        json={
            "business_name": "Light Winter Demo Store",
            "branch_name": "CBD Branch",
            "tin": "TIN123",
            "vat_number": "VAT123",
        },
    )
    assert provision.status_code == 200
    provision_data = provision.json()

    activation = client.post(
        "/api/activation/terminal",
        json={
            "activation_code": provision_data["activation_code"],
            "device_uid": "WINDOWS-DEVICE-001",
            "device_name": "Front Counter Windows",
            "platform": "windows",
        },
    )
    assert activation.status_code == 200
    assert activation.json()["activated"] is True

    generated = client.post(
        "/api/licenses/tokens",
        json={"duration_mode": "minutes", "duration_value": 90, "quantity": 1, "target_device_uid": "WINDOWS-DEVICE-001"},
    )
    assert generated.status_code == 200
    token = generated.json()[0]["token"]

    applied = client.post("/api/licenses/apply", json={"device_uid": "WINDOWS-DEVICE-001", "token": token})
    assert applied.status_code == 200
    assert applied.json()["status"] == "active"

    fiscal = client.put(
        f"/api/organizations/{provision_data['organization_id']}/fiscal",
        json={
            "fiscal_mode": "fiscal",
            "taxpayer_registered_name": "Light Winter Demo Store Pvt Ltd",
            "tin": "TIN123",
            "vat_number": "VAT123",
            "fiscal_authority": "ZIMRA",
            "stage": "fiscal_readiness_reached",
        },
    )
    assert fiscal.status_code == 200
    assert "Upload Fiscal API Documentation" in fiscal.json()["message"]

    opened = client.post("/api/fiscal/open-day", json={"device_uid": "WINDOWS-DEVICE-001", "user_id": "owner"})
    assert opened.status_code == 200
    assert opened.json()["fiscal_day_no"] == 1
    assert opened.json()["status"] == "opened"

    duplicate_open = client.post("/api/fiscal/open-day", json={"device_uid": "WINDOWS-DEVICE-001", "user_id": "owner"})
    assert duplicate_open.status_code == 409

    closed = client.post("/api/fiscal/close-day", json={"device_uid": "WINDOWS-DEVICE-001", "user_id": "owner"})
    assert closed.status_code == 200
    assert closed.json()["status"] == "closed"


def test_non_fiscal_mode_rejects_fiscal_day_controls(client):
    provision = client.post(
        "/api/provision/organization",
        json={"business_name": "Non Fiscal Shop", "branch_name": "Main"},
    )
    activation_code = provision.json()["activation_code"]

    client.post(
        "/api/activation/terminal",
        json={
            "activation_code": activation_code,
            "device_uid": "ANDROID-NON-FISCAL-001",
            "device_name": "Android Counter",
            "platform": "android",
        },
    )

    opened = client.post("/api/fiscal/open-day", json={"device_uid": "ANDROID-NON-FISCAL-001"})
    assert opened.status_code == 400
    assert "only in fiscal mode" in opened.json()["detail"]
