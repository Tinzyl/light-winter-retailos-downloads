from __future__ import annotations

import base64
import hashlib
import json
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Any

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa


class ZimraEnvironment(str, Enum):
    test = "test"
    live = "live"


TEST_BASE_URL = "https://fdmsapitest.zimra.co.zw"
LIVE_BASE_URL = "https://fdmsapi.zimra.co.zw"

DEVICE_MODEL_NAME = "Light Winter RetailOS"
DEVICE_MODEL_VERSION = "1.0.0"


FDMS_SWAGGER_URLS = {
    "test": {
        "root": f"{TEST_BASE_URL}/swagger/index.html",
        "device": f"{TEST_BASE_URL}/swagger/Device-v1/swagger.json",
        "public": f"{TEST_BASE_URL}/swagger/Public-v1/swagger.json",
        "products_stock": f"{TEST_BASE_URL}/swagger/ProductsStock-v1/swagger.json",
        "user": f"{TEST_BASE_URL}/swagger/User-v1/swagger.json",
    },
    "live": {
        "root": f"{LIVE_BASE_URL}/swagger/index.html",
        "device": f"{LIVE_BASE_URL}/swagger/Device-v1/swagger.json",
        "public": f"{LIVE_BASE_URL}/swagger/Public-v1/swagger.json",
        "products_stock": f"{LIVE_BASE_URL}/swagger/ProductsStock-v1/swagger.json",
        "user": f"{LIVE_BASE_URL}/swagger/User-v1/swagger.json",
    },
}


FDMS_ENDPOINTS = {
    "public": {
        "verify_taxpayer_information": "/Public/v1/{deviceID}/VerifyTaxpayerInformation",
        "register_device": "/Public/v1/{deviceID}/RegisterDevice",
        "get_server_certificate": "/Public/v1/GetServerCertificate",
    },
    "device": {
        "get_config": "/Device/v1/{deviceID}/GetConfig",
        "get_status": "/Device/v1/{deviceID}/GetStatus",
        "open_day": "/Device/v1/{deviceID}/OpenDay",
        "close_day": "/Device/v1/{deviceID}/CloseDay",
        "issue_certificate": "/Device/v1/{deviceID}/IssueCertificate",
        "submit_receipt": "/Device/v1/{deviceID}/SubmitReceipt",
        "ping": "/Device/v1/{deviceID}/Ping",
        "submit_file": "/Device/v1/{deviceID}/SubmitFile",
        "submitted_file_list": "/Device/v1/{deviceID}/SubmittedFileList",
    },
    "products_stock": {
        "search": "/ProductsStock/v1/{deviceID}/Search",
    },
    "user": {
        "get_users_list": "/User/v1/{deviceID}/GetUsersList",
        "send_security_code_to_taxpayer": "/User/v1/{deviceID}/SendSecurityCodeToTaxpayer",
        "create_user": "/User/v1/{deviceID}/CreateUser",
        "login": "/User/v1/{deviceID}/Login",
        "send_security_code_to_user_email": "/User/v1/{deviceID}/SendSecurityCodeToUserEmail",
        "send_security_code_to_user_phone": "/User/v1/{deviceID}/SendSecurityCodeToUserPhone",
        "confirm_user": "/User/v1/{deviceID}/ConfirmUser",
        "change_password": "/User/v1/{deviceID}/ChangePassword",
        "reset_password": "/User/v1/{deviceID}/ResetPassword",
        "confirm_contact": "/User/v1/{deviceID}/ConfirmContact",
        "update": "/User/v1/{deviceID}/Update",
        "block": "/User/v1/{deviceID}/Block/{userName}",
        "unblock": "/User/v1/{deviceID}/Unblock/{userName}",
        "confirm_password_reset": "/User/v1/{deviceID}/ConfirmPasswordReset",
    },
}


class ZimraFdmsError(RuntimeError):
    pass


@dataclass(frozen=True)
class ClientCertificate:
    certificate_path: str
    private_key_path: str

    @property
    def httpx_cert(self) -> tuple[str, str]:
        return self.certificate_path, self.private_key_path


def fdms_base_url(environment: ZimraEnvironment) -> str:
    return LIVE_BASE_URL if environment == ZimraEnvironment.live else TEST_BASE_URL


def fdms_endpoint_map() -> dict[str, Any]:
    return {
        "product": "Light Winter RetailOS",
        "authority": "ZIMRA Fiscal Device Management System",
        "test_base_url": TEST_BASE_URL,
        "live_base_url": LIVE_BASE_URL,
        "test_swagger": FDMS_SWAGGER_URLS["test"],
        "live_swagger": FDMS_SWAGGER_URLS["live"],
        "endpoints": FDMS_ENDPOINTS,
        "receipt_qr_rule": "Use qrUrl returned by /Device/v1/{deviceID}/GetConfig for the registered device; do not hardcode a receipt QR redirect URL.",
    }


def canonical_json(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True, ensure_ascii=False).encode("utf-8")


def sha256_b64(payload: dict[str, Any] | bytes) -> str:
    data = canonical_json(payload) if isinstance(payload, dict) else payload
    return base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")


def sign_hash_b64(hash_b64: str, private_key_pem: str) -> str:
    key = serialization.load_pem_private_key(private_key_pem.encode("utf-8"), password=None)
    digest = base64.b64decode(hash_b64)
    if isinstance(key, rsa.RSAPrivateKey):
        signature = key.sign(digest, padding.PKCS1v15(), hashes.SHA256())
    elif isinstance(key, ec.EllipticCurvePrivateKey):
        signature = key.sign(digest, ec.ECDSA(hashes.SHA256()))
    else:
        raise ZimraFdmsError("Unsupported fiscal private key type. Use RSA 2048 SHA256 or ECC P-256 ECDSA SHA256.")
    return base64.b64encode(signature).decode("ascii")


def prepare_signature(payload: dict[str, Any], private_key_pem: str | None) -> dict[str, str]:
    if not private_key_pem:
        raise ZimraFdmsError("FDMS receipt/day signature requires the registered fiscal device private key.")
    payload_hash = sha256_b64(payload)
    return {"hash": payload_hash, "signature": sign_hash_b64(payload_hash, private_key_pem)}


class ZimraFdmsClient:
    def __init__(
        self,
        environment: ZimraEnvironment = ZimraEnvironment.test,
        certificate: ClientCertificate | None = None,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.environment = environment
        self.base_url = fdms_base_url(environment)
        self.certificate = certificate
        self.transport = transport
        self.timeout = timeout

    def _headers(self, device_model_name: str | None = None, device_model_version: str | None = None) -> dict[str, str]:
        return {
            "DeviceModelName": device_model_name or DEVICE_MODEL_NAME,
            "DeviceModelVersion": device_model_version or DEVICE_MODEL_VERSION,
        }

    def _request(
        self,
        method: str,
        path: str,
        *,
        device_id: int | None = None,
        require_certificate: bool = False,
        device_model_name: str | None = None,
        device_model_version: str | None = None,
        json_body: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if device_id is not None:
            path = path.replace("{deviceID}", str(device_id))
        if require_certificate and self.certificate is None and self.transport is None:
            raise ZimraFdmsError("FDMS device endpoint requires the registered client certificate and private key.")

        with httpx.Client(
            base_url=self.base_url,
            cert=self.certificate.httpx_cert if self.certificate else None,
            transport=self.transport,
            timeout=self.timeout,
        ) as client:
            response = client.request(
                method,
                path,
                headers=self._headers(device_model_name, device_model_version),
                json=json_body,
                params=params,
            )
        if response.status_code >= 400:
            detail = response.text
            try:
                detail = response.json()
            except ValueError:
                pass
            raise ZimraFdmsError(f"FDMS {method} {path} failed with {response.status_code}: {detail}")
        if not response.content:
            return {}
        return response.json()

    def verify_taxpayer_information(self, device_id: int, activation_key: str, device_serial_no: str) -> dict[str, Any]:
        return self._request(
            "POST",
            FDMS_ENDPOINTS["public"]["verify_taxpayer_information"],
            device_id=device_id,
            json_body={"activationKey": activation_key, "deviceSerialNo": device_serial_no},
        )

    def register_device(
        self,
        device_id: int,
        activation_key: str,
        certificate_request: str,
        device_model_name: str | None = None,
        device_model_version: str | None = None,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            FDMS_ENDPOINTS["public"]["register_device"],
            device_id=device_id,
            device_model_name=device_model_name,
            device_model_version=device_model_version,
            json_body={"activationKey": activation_key, "certificateRequest": certificate_request},
        )

    def get_server_certificate(self, thumbprint: str | None = None) -> dict[str, Any]:
        params = {"thumbprint": thumbprint} if thumbprint else None
        return self._request("GET", FDMS_ENDPOINTS["public"]["get_server_certificate"], params=params)

    def get_config(self, device_id: int) -> dict[str, Any]:
        return self._request("GET", FDMS_ENDPOINTS["device"]["get_config"], device_id=device_id, require_certificate=True)

    def get_status(self, device_id: int) -> dict[str, Any]:
        return self._request("GET", FDMS_ENDPOINTS["device"]["get_status"], device_id=device_id, require_certificate=True)

    def open_day(self, device_id: int, fiscal_day_opened: datetime, fiscal_day_no: int | None = None) -> dict[str, Any]:
        body: dict[str, Any] = {"fiscalDayOpened": fiscal_day_opened.replace(tzinfo=None).isoformat(timespec="seconds")}
        if fiscal_day_no is not None:
            body["fiscalDayNo"] = fiscal_day_no
        return self._request("POST", FDMS_ENDPOINTS["device"]["open_day"], device_id=device_id, require_certificate=True, json_body=body)

    def close_day(self, device_id: int, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request("POST", FDMS_ENDPOINTS["device"]["close_day"], device_id=device_id, require_certificate=True, json_body=payload)

    def submit_receipt(self, device_id: int, receipt_payload: dict[str, Any]) -> dict[str, Any]:
        return self._request(
            "POST",
            FDMS_ENDPOINTS["device"]["submit_receipt"],
            device_id=device_id,
            require_certificate=True,
            json_body={"receipt": receipt_payload},
        )


def build_sample_receipt(
    *,
    receipt_type: str,
    invoice_no: str,
    receipt_counter: int,
    receipt_global_no: int,
    receipt_date: datetime,
    currency: str = "USD",
    amount: float = 11.50,
    tax_id: int = 1,
    tax_percent: float = 15.0,
    line_name: str = "Sample taxable item",
    money_type: str = "Cash",
    user_name: str = "owner",
    user_full_name: str = "Light Winter Owner",
    private_key_pem: str | None = None,
    source_receipt: dict[str, int] | None = None,
) -> dict[str, Any]:
    tax_amount = round(amount - (amount / (1 + (tax_percent / 100))), 2) if tax_percent else 0.0
    signable = {
        "receiptType": receipt_type,
        "receiptCurrency": currency.upper(),
        "receiptCounter": receipt_counter,
        "receiptGlobalNo": receipt_global_no,
        "invoiceNo": invoice_no,
        "receiptDate": receipt_date.replace(tzinfo=None).isoformat(timespec="seconds"),
        "receiptTotal": round(amount, 2),
    }
    receipt = {
        **signable,
        "receiptLinesTaxInclusive": True,
        "receiptLines": [
            {
                "receiptLineType": "Sale",
                "receiptLineNo": 1,
                "receiptLineName": line_name,
                "receiptLinePrice": round(amount, 2),
                "receiptLineQuantity": 1,
                "receiptLineTotal": round(amount, 2),
                "taxPercent": tax_percent,
                "taxID": tax_id,
            }
        ],
        "receiptTaxes": [
            {
                "taxPercent": tax_percent,
                "taxID": tax_id,
                "taxAmount": tax_amount,
                "salesAmountWithTax": round(amount, 2),
            }
        ],
        "receiptPayments": [{"moneyTypeCode": money_type, "paymentAmount": round(amount, 2)}],
        "receiptPrintForm": "InvoiceA4" if receipt_type in {"CreditNote", "DebitNote"} else "Receipt48",
        "receiptDeviceSignature": prepare_signature(signable, private_key_pem),
        "userInfo": {"username": user_name, "userFullName": user_full_name},
    }
    if receipt_type in {"CreditNote", "DebitNote"} and source_receipt:
        receipt["creditDebitNote"] = source_receipt
    return receipt


def build_sample_document_set(*, private_key_pem: str, started_at: datetime | None = None) -> dict[str, Any]:
    now = started_at or datetime.utcnow()
    fiscal_invoice = build_sample_receipt(
        receipt_type="FiscalInvoice",
        invoice_no="LWR-SAMPLE-INV-001",
        receipt_counter=1,
        receipt_global_no=1,
        receipt_date=now,
        private_key_pem=private_key_pem,
    )
    reference = {"receiptGlobalNo": 1, "fiscalDayNo": 1}
    credit_note = build_sample_receipt(
        receipt_type="CreditNote",
        invoice_no="LWR-SAMPLE-CN-001",
        receipt_counter=2,
        receipt_global_no=2,
        receipt_date=now,
        amount=5.75,
        line_name="Sample credit adjustment",
        private_key_pem=private_key_pem,
        source_receipt=reference,
    )
    debit_note = build_sample_receipt(
        receipt_type="DebitNote",
        invoice_no="LWR-SAMPLE-DN-001",
        receipt_counter=3,
        receipt_global_no=3,
        receipt_date=now,
        amount=2.30,
        line_name="Sample debit adjustment",
        private_key_pem=private_key_pem,
        source_receipt=reference,
    )
    return {"FiscalInvoice": fiscal_invoice, "CreditNote": credit_note, "DebitNote": debit_note}
