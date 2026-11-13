"""Cashflow and payment details for the pharmacy and the admin (D-85).

GET /cashflow?days=30          pharmacist / admin: money received, failed payments,
                               money still owed, daily series and recent payments
GET /orders/{id}/payments      pharmacist / admin: one order's payment history + receipt
GET /orders/{id}/receipt.pdf   the patient who owns it, pharmacist, admin: receipt PDF

Money in comes from `payment_transactions` (status succeeded); "outstanding" is the
total of confirmed orders still waiting for payment. Amounts are RM.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from typing import Any

from fastapi import APIRouter, Depends, Query, Response

from app.core.auth import CurrentUser, require_roles
from app.core.enums import UserRole
from app.core.errors import ApiError
from app.services.medications import MYT
from app.services.orders import OrderService, get_order_service, order_ref, total_of
from app.services.receipts import receipt_pdf

router = APIRouter(tags=["cashflow"])
pharmacy_staff = require_roles(UserRole.PHARMACIST, UserRole.ADMIN)
anyone_with_orders = require_roles(UserRole.PATIENT, UserRole.PHARMACIST, UserRole.ADMIN)

OPEN_UNPAID = {"awaiting_payment", "awaiting_confirmation"}


def _iso(v: Any) -> str | None:
    return v.isoformat() if isinstance(v, datetime) else None


def _myt_day(v: datetime) -> date:
    return v.astimezone(MYT).date()


@router.get("/cashflow")
def cashflow(
    days: int = Query(default=30, ge=1, le=366),
    _: CurrentUser = Depends(pharmacy_staff),
    svc: OrderService = Depends(get_order_service),
) -> dict[str, Any]:
    repo = svc.repo
    now = datetime.now(UTC)
    start = now - timedelta(days=days)
    orders = dict(repo.all_orders())
    names: dict[str, str] = {}

    def patient_name(uid: str | None) -> str:
        if not uid:
            return "Patient"
        if uid not in names:
            names[uid] = str((repo.user(uid) or {}).get("name") or "Patient")
        return names[uid]

    received = 0.0
    fees = 0.0
    paid_count = 0
    failed_count = 0
    failed_amount = 0.0
    by_day: dict[date, float] = defaultdict(float)
    by_method = {"delivery": 0.0, "collection": 0.0}
    recent: list[dict[str, Any]] = []
    for tx_id, t in repo.transactions():
        at = t.get("processedAt")
        if not isinstance(at, datetime) or at < start:
            continue
        amount = float(t.get("amount") or 0)
        order_id = str(t.get("orderId") or "")
        o = orders.get(order_id, {})
        status = str(t.get("status") or "")
        if status == "succeeded":
            received += amount
            paid_count += 1
            by_day[_myt_day(at)] += amount
            fee = float(o.get("deliveryFee") or 0)
            fees += fee
            by_method["delivery" if o.get("method") == "home_delivery" else "collection"] += amount
        elif status == "failed":
            failed_count += 1
            failed_amount += amount
        recent.append(
            {
                "id": tx_id,
                "orderId": order_id,
                "orderRef": order_ref(order_id) if order_id else None,
                "patientName": patient_name(o.get("patientId")),
                "amount": round(amount, 2),
                "status": status,
                "processedAt": _iso(at),
                "chargeId": t.get("stripeChargeId"),
            }
        )
    outstanding = 0.0
    outstanding_count = 0
    for o in orders.values():
        if o.get("paymentStatus") != "paid" and o.get("fulfilmentStatus") in OPEN_UNPAID:
            outstanding += total_of(o) or 0.0
            outstanding_count += 1
    series = []
    first = _myt_day(start) + timedelta(days=1)
    for i in range(days):
        d = first + timedelta(days=i)
        series.append({"date": d.isoformat(), "amount": round(by_day.get(d, 0.0), 2)})
    recent.sort(key=lambda r: r["processedAt"] or "", reverse=True)
    return {
        "days": days,
        "received": round(received, 2),
        "medicineRevenue": round(received - fees, 2),
        "deliveryFees": round(fees, 2),
        "paidCount": paid_count,
        "averagePayment": round(received / paid_count, 2) if paid_count else 0.0,
        "failedCount": failed_count,
        "failedAmount": round(failed_amount, 2),
        "outstanding": round(outstanding, 2),
        "outstandingCount": outstanding_count,
        "byMethod": {k: round(v, 2) for k, v in by_method.items()},
        "byDay": series,
        "transactions": recent[:100],
    }


def _order_or_404(svc: OrderService, order_id: str) -> dict[str, Any]:
    o = svc.repo.order(order_id)
    if o is None:
        raise ApiError("ORDER_NOT_FOUND", "Order not found.", 404)
    return o


@router.get("/orders/{order_id}/payments")
def order_payments(
    order_id: str,
    _: CurrentUser = Depends(pharmacy_staff),
    svc: OrderService = Depends(get_order_service),
) -> dict[str, Any]:
    o = _order_or_404(svc, order_id)
    patient = svc.repo.user(str(o.get("patientId") or "")) or {}
    txs = sorted(
        svc.repo.transactions(order_id),
        key=lambda p: p[1].get("processedAt") or datetime.min.replace(tzinfo=UTC),
        reverse=True,
    )
    paid = next((t for _, t in txs if t.get("status") == "succeeded"), None)
    amount = float(o.get("amount") or 0)
    fee = float(o.get("deliveryFee") or 0)
    return {
        "orderId": order_id,
        "orderRef": order_ref(order_id),
        "patient": {
            "id": o.get("patientId"),
            "name": patient.get("name"),
            "email": patient.get("email"),
        },
        "paymentStatus": o.get("paymentStatus"),
        "transactions": [
            {
                "id": tx_id,
                "amount": t.get("amount"),
                "status": t.get("status"),
                "processedAt": _iso(t.get("processedAt")),
                "chargeId": t.get("stripeChargeId"),
            }
            for tx_id, t in txs
        ],
        # The same lines as the patient's PDF receipt (services/receipts.py).
        "receipt": None
        if paid is None
        else {
            "paidAt": _iso(paid.get("processedAt")),
            "reference": paid.get("stripeChargeId"),
            "medication": o.get("medicationDetails"),
            "medicineAmount": round(amount, 2),
            "deliveryFee": round(fee, 2),
            "method": o.get("method"),
            "total": round(amount + fee, 2),
            "processor": "Stripe (test mode)",
        },
    }


@router.get("/orders/{order_id}/receipt.pdf")
def order_receipt_pdf(
    order_id: str,
    user: CurrentUser = Depends(anyone_with_orders),
    svc: OrderService = Depends(get_order_service),
) -> Response:
    o = _order_or_404(svc, order_id)
    if user.role == UserRole.PATIENT and o.get("patientId") != user.uid:
        raise ApiError("ORDER_NOT_FOUND", "Order not found.", 404)
    paid = [t for _, t in svc.repo.transactions(order_id) if t.get("status") == "succeeded"]
    if not paid:
        raise ApiError("NOT_PAID", "This order has not been paid, so there is no receipt.", 409)
    t = max(paid, key=lambda x: x.get("processedAt") or datetime.min.replace(tzinfo=UTC))
    raw = t.get("processedAt")
    at = raw if isinstance(raw, datetime) else datetime.now(UTC)
    pdf = receipt_pdf(order_id, o, str(t.get("stripeChargeId") or ""), at)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="receipt-{order_ref(order_id)}.pdf"'},
    )
