def setup_store(client):
    provision = client.post(
        "/api/provision/organization",
        json={"business_name": "Retail Ops Store", "branch_name": "Main", "default_currency": "USD"},
    ).json()
    client.post(
        "/api/activation/terminal",
        json={
            "activation_code": provision["activation_code"],
            "device_uid": "SUNMI-OPS-001",
            "device_name": "SUNMI Counter",
            "platform": "sunmi",
        },
    )
    product = client.post(
        "/api/products",
        json={
            "organization_id": provision["organization_id"],
            "sku": "MAZOE-2L",
            "barcode": "6001001",
            "name": "Mazoe Orange 2L",
            "category": "Groceries",
            "selling_price_cents": 250,
            "reorder_threshold": 3,
        },
    ).json()
    client.post(
        "/api/stock/adjust",
        json={
            "branch_id": provision["branch_id"],
            "product_id": product["id"],
            "movement_type": "stock_in",
            "quantity_delta": 10,
            "reason": "Opening stock",
        },
    )
    return provision, product


def test_sale_reduces_stock_and_partial_return_restores_it(client):
    provision, product = setup_store(client)

    sale = client.post(
        "/api/sales",
        json={
            "device_uid": "SUNMI-OPS-001",
            "payment_method": "cash",
            "paid_cents": 1000,
            "lines": [{"product_id": product["id"], "quantity": 2}],
        },
    )
    assert sale.status_code == 200
    sale_data = sale.json()
    assert sale_data["total_cents"] == 500
    line_id = sale_data["lines"][0]["id"]

    stock = client.get(f"/api/branches/{provision['branch_id']}/stock").json()[0]
    assert stock["quantity"] == 8

    reversal = client.post(
        f"/api/sales/{sale_data['id']}/reversals",
        json={
            "reversal_type": "partial_return",
            "reason": "Customer returned one bottle",
            "lines": [{"sale_line_id": line_id, "quantity": 1}],
        },
    )
    assert reversal.status_code == 200
    assert reversal.json()["amount_cents"] == 250

    stock = client.get(f"/api/branches/{provision['branch_id']}/stock").json()[0]
    assert stock["quantity"] == 9


def test_debt_sale_creates_debt_and_full_void_settles_it(client):
    provision, product = setup_store(client)
    customer = client.post(
        "/api/customers",
        json={"organization_id": provision["organization_id"], "name": "Tariro Moyo", "phone": "+263700000000"},
    ).json()

    sale = client.post(
        "/api/sales",
        json={
            "device_uid": "SUNMI-OPS-001",
            "customer_id": customer["id"],
            "payment_method": "debt",
            "lines": [{"product_id": product["id"], "quantity": 3}],
        },
    ).json()
    dashboard = client.get(f"/api/organizations/{provision['organization_id']}/dashboard").json()
    assert dashboard["debt_open_cents"] == 750

    reversal = client.post(
        f"/api/sales/{sale['id']}/reversals",
        json={"reversal_type": "full_void", "reason": "Wrong customer selected"},
    )
    assert reversal.status_code == 200
    assert reversal.json()["status"] == "voided"

    dashboard = client.get(f"/api/organizations/{provision['organization_id']}/dashboard").json()
    assert dashboard["debt_open_cents"] == 0
