"""D-79: imports, family link on the user page, custom charts, System health actions and
clearing a chat's bell entries."""

import json
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.integrations.push import LogPushClient, PushMessage
from app.services.health_tools import ERRORS
from app.services.notifications import Notifier
from tests.conftest import (
    FakeIdentityProvider,
    InMemoryAnalyticsSource,
    InMemoryCatalogRepository,
    InMemoryInboxRepository,
    InMemoryOrderRepository,
    InMemoryTokenRepository,
    InMemoryUserRepository,
    bearer,
)

P, A, F, D = "u-patient", "u-admin", "u-family", "u-doctor"
PATIENT, ADMIN, PHARM, DOCTOR = (
    bearer("patient-token"),
    bearer("admin-token"),
    bearer("pharmacist-token"),
    bearer("doctor-token"),
)


@pytest.fixture(autouse=True)
def people(repo: InMemoryUserRepository) -> None:
    repo.users.update(
        {
            P: {"role": "patient", "name": "Siti", "email": "siti@x.my", "assignedDoctorId": D},
            D: {"role": "doctor", "name": "Dr Tan", "email": "tan@x.my"},
            A: {"role": "admin", "name": "Admin Lee", "email": "admin@x.my"},
            F: {"role": "family_member", "name": "Son", "patientId": P},
            "u-pharm": {"role": "pharmacist", "name": "Aisyah"},
        }
    )


# ---- imports ----

INVENTORY_CSV = (
    "name,strength,form,drugClass,unitPrice,units,lowStockAt,expiryDate\n"
    "Amlodipine,5mg,tablet,Calcium channel blocker,0.35,500,100,2027-06-30\n"
    "Bisoprolol,5mg,tablet,Beta blocker,0.40,200,50,2027-01-31\n"
    "Bad,,tablet,,0.10,,,\n"
    "Losartan,50mg,powder,,0.5,,,\n"
    "Bisoprolol,5mg,tablet,Beta blocker,0.40,,,\n"
    "Valsartan,80mg,tablet,,0.9,10,5,\n"
)


def test_d79_inventory_import_previews_then_saves_valid_rows(
    client: TestClient, catalog: InMemoryCatalogRepository, order_repo: InMemoryOrderRepository
) -> None:
    before = len(catalog.items)
    res = client.post(
        "/api/v1/pharmacy/import",
        json={"format": "csv", "content": INVENTORY_CSV, "commit": False},
        headers=PHARM,
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert [r["action"] for r in body["rows"][:2]] == ["update + stock", "add + stock"]
    errors = {r["row"]: r["error"] for r in body["rows"] if r["error"]}
    assert set(errors) == {3, 4, 5, 6}
    assert "form" in errors[4] and "Duplicate" in errors[5] and "expiryDate" in errors[6]
    assert len(catalog.items) == before  # preview saves nothing

    res = client.post(
        "/api/v1/pharmacy/import",
        json={"format": "csv", "content": INVENTORY_CSV, "commit": True},
        headers=ADMIN,
    )
    assert res.json()["added"] == 1 and res.json()["updated"] == 1
    assert catalog.items["amlodipine-5"]["unitPrice"] == 0.35
    stocks = {s["name"]: s for s in order_repo.stock_items.values()}
    assert stocks["Bisoprolol 5mg"]["units"] == 200


def test_d79_inventory_import_reads_json_and_rejects_bad_files(client: TestClient) -> None:
    rows = [{"name": "Indapamide", "strength": "1.5mg", "unitPrice": 0.6}]
    res = client.post(
        "/api/v1/pharmacy/import",
        json={"format": "json", "content": json.dumps({"rows": rows})},
        headers=PHARM,
    )
    assert res.json()["valid"] == 1
    bad = client.post(
        "/api/v1/pharmacy/import", json={"format": "json", "content": "{nope"}, headers=PHARM
    )
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "IMPORT_UNREADABLE"
    assert (
        client.post(
            "/api/v1/pharmacy/import", json={"format": "csv", "content": "x"}, headers=DOCTOR
        ).status_code
        == 403
    )


def test_d79_staff_import_creates_accounts_with_setup_links(
    client: TestClient, identity: FakeIdentityProvider, repo: InMemoryUserRepository
) -> None:
    csv_text = (
        "name,email,role,specialty\n"
        "Dr Aisha,aisha@x.my,doctor,Cardiology\n"
        "Lim Wei,lim@x.my,pharmacist,\n"
        "Someone,siti@x.my,doctor,\n"
        "Pat,pat@x.my,patient,\n"
        "Bad email,nope,admin,\n"
    )
    preview = client.post(
        "/api/v1/admin/users/import", json={"format": "csv", "content": csv_text}, headers=ADMIN
    ).json()
    assert preview["valid"] == 2 and preview["invalid"] == 3
    res = client.post(
        "/api/v1/admin/users/import",
        json={"format": "csv", "content": csv_text, "commit": True},
        headers=ADMIN,
    ).json()
    assert res["created"] == 2
    made = {
        u["email"]: u for u in repo.users.values() if u.get("email") in ("aisha@x.my", "lim@x.my")
    }
    assert (
        made["aisha@x.my"]["role"] == "doctor" and made["aisha@x.my"]["specialty"] == "Cardiology"
    )
    assert made["lim@x.my"]["role"] == "pharmacist"
    assert (
        client.post(
            "/api/v1/admin/users/import", json={"format": "csv", "content": csv_text}, headers=PHARM
        ).status_code
        == 403
    )


# ---- family link on the admin user page ----


def test_d79_family_detail_shows_the_linked_patient(client: TestClient) -> None:
    body = client.get(f"/api/v1/admin/users/{F}", headers=ADMIN).json()
    assert body["family"]["patient"]["name"] == "Siti"
    assert body["family"]["patient"]["assignedDoctor"] == "Dr Tan"


# ---- custom charts ----


def test_d79_charts_are_saved_per_admin_and_validated(client: TestClient) -> None:
    chart = {
        "title": "Readings",
        "measure": "readings_per_day",
        "type": "line",
        "days": 30,
        "page": "hospital",
    }
    res = client.put("/api/v1/admin/analytics/charts", json={"charts": [chart]}, headers=ADMIN)
    assert res.status_code == 200
    saved = client.get("/api/v1/admin/analytics/charts", headers=ADMIN).json()["charts"]
    assert saved[0]["measure"] == "readings_per_day" and saved[0]["id"]
    bad = {**chart, "type": "radar"}
    assert (
        client.put(
            "/api/v1/admin/analytics/charts", json={"charts": [bad]}, headers=ADMIN
        ).status_code
        == 422
    )
    measures = client.get("/api/v1/admin/analytics/measures", headers=ADMIN).json()
    assert {"readings_per_day", "logins_by_role"} <= {m["key"] for m in measures["measures"]}


def test_d79_series_counts_per_day_and_per_category(
    client: TestClient, analytics: InMemoryAnalyticsSource
) -> None:
    now = datetime.now(UTC)
    for h in (1, 2, 30):
        analytics.add("vital_readings", patientId=P, timestamp=now - timedelta(hours=h))
    analytics.add("clinical_alerts", severity="high", createdAt=now - timedelta(days=1))
    analytics.add("clinical_alerts", severity="critical", createdAt=now - timedelta(days=2))
    analytics.add("clinical_alerts", severity="high", createdAt=now - timedelta(days=40))
    day = client.get(
        "/api/v1/admin/analytics/series?measure=readings_per_day&days=7", headers=ADMIN
    ).json()
    assert day["kind"] == "time" and len(day["labels"]) == 7
    assert sum(day["series"]["Count"]) == 3
    cat = client.get(
        "/api/v1/admin/analytics/series?measure=alerts_by_severity&days=30", headers=ADMIN
    ).json()
    assert dict(zip(cat["labels"], cat["series"]["Count"], strict=True))["high"] == 1
    assert (
        client.get("/api/v1/admin/analytics/series?measure=nope", headers=ADMIN).status_code == 404
    )


# ---- System health actions ----


def test_d79_service_tests_and_recent_errors(
    client: TestClient, inbox: InMemoryInboxRepository
) -> None:
    res = client.post("/api/v1/admin/system-health/push/test", headers=ADMIN)
    assert res.status_code == 200 and res.json()["ok"] is True
    assert any(n["title"] == "Harvey test notification" for n in inbox.items.values())
    sms = client.post("/api/v1/admin/system-health/sms/test", headers=ADMIN).json()
    assert sms["ok"] is False and "phone" in sms["message"]
    assert client.post("/api/v1/admin/system-health/ai/test", headers=ADMIN).json()["ok"]
    assert client.post("/api/v1/admin/system-health/nope/test", headers=ADMIN).status_code == 404

    import logging

    logging.getLogger("careflow.payments").error("Stripe said no")
    errs = client.get("/api/v1/admin/system-health/stripe/errors", headers=ADMIN).json()
    assert errs["errors"][0]["message"] == "Stripe said no"
    ERRORS.items["stripe"].clear()


# ---- opening a chat clears its bell entries ----


def test_d79_read_matching_clears_only_that_chat(
    client: TestClient,
    inbox: InMemoryInboxRepository,
    tokens: InMemoryTokenRepository,
    push: LogPushClient,
) -> None:
    n = Notifier(tokens, push, inbox)
    n.notify(P, PushMessage("Harvey Pharmacy", "Ready", {"type": "pharmacy_chat"}))
    n.notify(P, PushMessage("Dr Tan", "Hi", {"type": "message", "from": D}))
    n.notify(P, PushMessage("Other", "Hi", {"type": "message", "from": "someone"}))
    res = client.post(
        "/api/v1/notifications/read-matching", json={"type": "pharmacy_chat"}, headers=PATIENT
    )
    assert res.json() == {"updated": 1}
    res = client.post(
        "/api/v1/notifications/read-matching",
        json={"type": "message", "data": {"from": D}},
        headers=PATIENT,
    )
    assert res.json() == {"updated": 1}
    assert client.get("/api/v1/notifications", headers=PATIENT).json()["unread"] == 1
