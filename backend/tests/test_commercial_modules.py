def create_store_product(client, suffix="001"):
    provision = client.post(
        "/api/provision/organization",
        json={"business_name": f"Commercial Store {suffix}", "branch_name": "Main"},
    ).json()
    product = client.post(
        "/api/products",
        json={
            "organization_id": provision["organization_id"],
            "sku": f"SKU-{suffix}",
            "name": "Commercial Product",
            "selling_price_cents": 500,
            "reorder_threshold": 2,
        },
    ).json()
    return provision, product


def test_purchase_order_receiving_adds_stock(client):
    provision, product = create_store_product(client, "PO")
    supplier = client.post(
        "/api/suppliers",
        json={"organization_id": provision["organization_id"], "name": "Blue Wholesale"},
    ).json()
    order = client.post(
        "/api/purchase-orders",
        json={
            "branch_id": provision["branch_id"],
            "supplier_id": supplier["id"],
            "invoice_number": "INV-100",
            "lines": [{"product_id": product["id"], "ordered_quantity": 12, "unit_cost_cents": 300}],
        },
    ).json()

    received = client.post(f"/api/purchase-orders/{order['id']}/receive", json={})
    assert received.status_code == 200
    assert received.json()["status"] == "received"

    stock = client.get(f"/api/branches/{provision['branch_id']}/stock").json()[0]
    assert stock["quantity"] == 12


def test_branch_transfer_moves_stock_between_branches(client):
    provision, product = create_store_product(client, "TR")
    second_branch = client.post(
        "/api/branches",
        json={"organization_id": provision["organization_id"], "name": "Second Branch", "branch_code": "B2"},
    ).json()
    client.post(
        "/api/stock/adjust",
        json={
            "branch_id": provision["branch_id"],
            "product_id": product["id"],
            "movement_type": "stock_in",
            "quantity_delta": 6,
            "reason": "Opening stock",
        },
    )
    transfer = client.post(
        "/api/branch-transfers",
        json={
            "from_branch_id": provision["branch_id"],
            "to_branch_id": second_branch["id"],
            "reason": "Rebalance branch stock",
            "lines": [{"product_id": product["id"], "quantity": 4}],
        },
    )
    assert transfer.status_code == 200
    assert transfer.json()["status"] == "received"

    source_stock = client.get(f"/api/branches/{provision['branch_id']}/stock").json()[0]
    target_stock = client.get(f"/api/branches/{second_branch['id']}/stock").json()[0]
    assert source_stock["quantity"] == 2
    assert target_stock["quantity"] == 4
