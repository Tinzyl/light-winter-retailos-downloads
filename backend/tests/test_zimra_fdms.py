from datetime import datetime

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from app.services.zimra_fdms_service import (
    FDMS_ENDPOINTS,
    TEST_BASE_URL,
    ClientCertificate,
    ZimraEnvironment,
    ZimraFdmsClient,
    build_sample_document_set,
)


def test_zimra_endpoint_map_exposes_exact_test_and_live_addresses(client):
    response = client.get("/api/fiscal/zimra/endpoints")

    assert response.status_code == 200
    body = response.json()
    assert body["test_base_url"] == "https://fdmsapitest.zimra.co.zw"
    assert body["live_base_url"] == "https://fdmsapi.zimra.co.zw"
    assert body["test_swagger"]["root"] == "https://fdmsapitest.zimra.co.zw/swagger/index.html"
    assert body["endpoints"]["device"]["open_day"] == "/Device/v1/{deviceID}/OpenDay"
    assert "qrUrl returned by /Device/v1/{deviceID}/GetConfig" in body["receipt_qr_rule"]


def test_public_verify_taxpayer_uses_official_path():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = request.read().decode()
        return httpx.Response(200, json={"operationID": "op-1", "taxPayerTIN": "1234567890"})

    client = ZimraFdmsClient(environment=ZimraEnvironment.test, transport=httpx.MockTransport(handler))
    response = client.verify_taxpayer_information(123, "ABC12345", "SN-1")

    assert seen["url"] == f"{TEST_BASE_URL}/Public/v1/123/VerifyTaxpayerInformation"
    assert response["taxPayerTIN"] == "1234567890"


def test_device_open_day_uses_official_path_with_client_certificate_context():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = request.read().decode()
        return httpx.Response(200, json={"operationID": "op-2", "fiscalDayNo": 7})

    client = ZimraFdmsClient(
        environment=ZimraEnvironment.test,
        certificate=ClientCertificate("device.crt", "device.key"),
        transport=httpx.MockTransport(handler),
    )
    response = client.open_day(55, datetime(2026, 4, 28, 8, 30, 0), fiscal_day_no=7)

    assert seen["url"] == f"{TEST_BASE_URL}{FDMS_ENDPOINTS['device']['open_day'].replace('{deviceID}', '55')}"
    assert '"fiscalDayOpened":"2026-04-28T08:30:00"' in seen["body"]
    assert response["fiscalDayNo"] == 7


def test_sample_documents_include_invoice_credit_and_debit_notes():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("utf-8")

    documents = build_sample_document_set(private_key_pem=private_key_pem, started_at=datetime(2026, 4, 28, 9, 0, 0))

    assert set(documents) == {"FiscalInvoice", "CreditNote", "DebitNote"}
    assert documents["FiscalInvoice"]["receiptType"] == "FiscalInvoice"
    assert documents["CreditNote"]["creditDebitNote"]["receiptGlobalNo"] == 1
    assert documents["DebitNote"]["receiptDeviceSignature"]["hash"]
