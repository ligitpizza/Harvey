"""D-85 cashflow, order payment details and the receipt PDF for staff."""

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from tests.conftest import InMemoryOrderRepository, InMemoryUserRepository, bearer

PHARM = bearer("pharmacist-token")
ADMIN = bearer("admin-token")
PATIENT = bearer("patient-token")
DOCTOR = bearer("doctor-token")
P = "u-patient"
NOW = datetime.now(UTC)


@pytest.fixture(autouse=True)
def data(repo: InMemoryUserRepository, order_repo: InMemoryOrderRepository) -> None:
    repo.users[P] = {"role": "patient", "name": "Siti", "email": "siti@x.my"}
    order_repo.orders.update(
        {
            "o1": {
                "patientId": P,
                "medicationDetails": "Amlodipine 5mg x30",
                "amount": 50.0,
                "deliveryFee": 8.2,
                "method": "home_delivery",
                "paymentStatus": "paid",
                "fulfilmentStatus": "delivered",
            },
            "o2": {
                "patientId": P,
                "medicationDetails": "Losartan 50mg x30",
                "amount": 25.0,
                "deliveryFee": 0,
                "method": "self_collection",
                "paymentStatus": "paid",
                "fulfilmentStatus": "collected",
            },
            "o3": {
                "patientId": P,
                "medicationDetails": "Atenolol 50mg x30",
                "amount": 30.0,
                "deliveryFee": 0,
                "paymentStatus": "pending",
                "fulfilmentStatus": "awaiting_payment",
            },
            "o4": {  # cancelled: not owed
                "patientId": P,
                "amount": 99.0,
                "paymentStatus": "pending",
                "fulfilmentStatus": "cancelled",
            },
        }
    )
    order_repo.tx.update(
        {
            "ch_1": {
                "orderId": "o1",
                "stripeChargeId": "ch_1",
                "amount": 58.2,
                "status": "succeeded",
                "processedAt": NOW - timedelta(days=1),
            },
            "ch_2": {
                "orderId": "o2",
                "stripeChargeId": "ch_2",
                "amount": 25.0,
                "status": "succeeded",
                "processedAt": NOW - timedelta(days=3),
            },
            "pi_9_failed": {
                "orderId": "o2",
                "stripeChargeId": "pi_9",
                "amount": 25.0,
                "status": "failed",
                "processedAt": NOW - timedelta(days=3, hours=1),
            },
            "ch_old": {
                "orderId": "o2",
                "stripeChargeId": "ch_old",
                "amount": 40.0,
                "status": "succeeded",
                "processedAt": NOW - timedelta(days=60),
            },
        }
    )


def test_cashflow_sums_money_in_out_and_owed(client: TestClient) -> None:
    res = client.get("/api/v1/cashflow?days=30", headers=PHARM)
    assert res.status_code == 200, res.text
    c = res.json()
    assert c["received"] == 83.2  # the 60-day-old payment is outside the window
    assert c["deliveryFees"] == 8.2 and c["medicineRevenue"] == 75.0
    assert c["paidCount"] == 2 and c["averagePayment"] == 41.6
    assert c["failedCount"] == 1 and c["failedAmount"] == 25.0
    assert c["outstanding"] == 30.0 and c["outstandingCount"] == 1
    assert c["byMethod"] == {"delivery": 58.2, "collection": 25.0}
    assert len(c["byDay"]) == 30 and sum(d["amount"] for d in c["byDay"]) == pytest.approx(83.2)
    assert [t["id"] for t in c["transactions"]] == ["ch_1", "ch_2", "pi_9_failed"]
    assert c["transactions"][0]["patientName"] == "Siti"
    assert client.get("/api/v1/cashflow", headers=ADMIN).status_code == 200
    assert client.get("/api/v1/cashflow", headers=DOCTOR).status_code == 403
    assert client.get("/api/v1/cashflow", headers=PATIENT).status_code == 403


def test_order_payments_show_history_and_receipt_lines(client: TestClient) -> None:
    res = client.get("/api/v1/orders/o2/payments", headers=ADMIN)
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["patient"]["name"] == "Siti"
    assert [t["status"] for t in body["transactions"]] == ["succeeded", "failed", "succeeded"]
    assert body["receipt"]["reference"] == "ch_2"
    assert body["receipt"]["total"] == 25.0
    unpaid = client.get("/api/v1/orders/o3/payments", headers=PHARM).json()
    assert unpaid["receipt"] is None and unpaid["transactions"] == []
    assert client.get("/api/v1/orders/o2/payments", headers=PATIENT).status_code == 403


def test_receipt_pdf_for_staff_and_the_owner_only(client: TestClient) -> None:
    res = client.get("/api/v1/orders/o1/receipt.pdf", headers=PHARM)
    assert res.status_code == 200
    assert res.headers["content-type"] == "application/pdf"
    assert res.content.startswith(b"%PDF")
    assert client.get("/api/v1/orders/o1/receipt.pdf", headers=PATIENT).status_code == 200
    assert client.get("/api/v1/orders/o3/receipt.pdf", headers=ADMIN).status_code == 409
    assert client.get("/api/v1/orders/nope/receipt.pdf", headers=ADMIN).status_code == 404
