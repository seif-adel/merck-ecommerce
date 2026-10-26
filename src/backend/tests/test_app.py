import pytest
from fastapi.testclient import TestClient

from app import InMemoryStore, create_app

SESSION = {"X-Session-Id": "session-aaaa1111"}
OTHER_SESSION = {"X-Session-Id": "session-bbbb2222"}


@pytest.fixture
def client() -> TestClient:
    # A fresh store per test keeps tests independent of each other.
    return TestClient(create_app(InMemoryStore()))


def add(client: TestClient, product_id: int, quantity: int = 1, headers: dict = SESSION):
    return client.post("/cart/items", json={"product_id": product_id, "quantity": quantity}, headers=headers)


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_list_products(client):
    response = client.get("/products")
    assert response.status_code == 200
    products = response.json()
    assert len(products) >= 5
    assert {"id", "name", "price_cents", "currency"} <= products[0].keys()


def test_get_product_and_not_found(client):
    assert client.get("/products/1").json()["id"] == 1
    missing = client.get("/products/9999")
    assert missing.status_code == 404


def test_cart_requires_session_header(client):
    assert client.get("/cart").status_code == 400
    assert client.get("/cart", headers={"X-Session-Id": "bad id!"}).status_code == 400


def test_empty_cart(client):
    assert client.get("/cart", headers=SESSION).json() == {"items": [], "total_cents": 0, "currency": "EUR"}


def test_add_item_and_total(client):
    price = client.get("/products/1").json()["price_cents"]
    response = add(client, 1, quantity=2)
    assert response.status_code == 201
    cart = client.get("/cart", headers=SESSION).json()
    assert len(cart["items"]) == 1
    assert cart["items"][0]["quantity"] == 2
    assert cart["total_cents"] == price * 2


def test_adding_same_product_merges_lines(client):
    add(client, 1)
    cart = add(client, 1, quantity=3).json()
    assert len(cart["items"]) == 1
    assert cart["items"][0]["quantity"] == 4


def test_add_unknown_product_and_invalid_quantity(client):
    assert add(client, 9999).status_code == 404
    assert add(client, 1, quantity=0).status_code == 422
    assert add(client, 1, quantity=100).status_code == 422


def test_quantity_cap_when_merging(client):
    add(client, 1, quantity=99)
    assert add(client, 1, quantity=1).status_code == 400


def test_remove_item(client):
    item_id = add(client, 1).json()["items"][0]["id"]
    response = client.delete(f"/cart/items/{item_id}", headers=SESSION)
    assert response.status_code == 200
    assert response.json()["items"] == []
    assert client.delete(f"/cart/items/{item_id}", headers=SESSION).status_code == 404


def test_update_quantity_keeps_the_line(client):
    price = client.get("/products/1").json()["price_cents"]
    item_id = add(client, 1, quantity=3).json()["items"][0]["id"]
    response = client.patch(f"/cart/items/{item_id}", json={"quantity": 1}, headers=SESSION)
    assert response.status_code == 200
    cart = response.json()
    assert [i["id"] for i in cart["items"]] == [item_id]
    assert cart["items"][0]["quantity"] == 1
    assert cart["total_cents"] == price


def test_update_quantity_rejects_bad_input(client):
    item_id = add(client, 1).json()["items"][0]["id"]
    assert client.patch(f"/cart/items/{item_id}", json={"quantity": 0}, headers=SESSION).status_code == 422
    assert client.patch(f"/cart/items/{item_id}", json={"quantity": 100}, headers=SESSION).status_code == 422
    assert client.patch("/cart/items/unknown", json={"quantity": 2}, headers=SESSION).status_code == 404
    assert client.patch(f"/cart/items/{item_id}", json={"quantity": 2}, headers=OTHER_SESSION).status_code == 404


def test_checkout_creates_order_and_empties_cart(client):
    add(client, 1, quantity=2)
    add(client, 2)
    response = client.post("/cart/checkout", headers=SESSION)
    assert response.status_code == 201
    order = response.json()
    assert order["status"] == "PLACED"
    assert len(order["items"]) == 2
    assert order["total_cents"] == sum(i["line_total_cents"] for i in order["items"])
    assert client.get("/cart", headers=SESSION).json()["items"] == []


def test_checkout_empty_cart_is_rejected(client):
    assert client.post("/cart/checkout", headers=SESSION).status_code == 400


def test_checkout_retry_with_same_key_returns_the_same_order(client):
    headers = {**SESSION, "Idempotency-Key": "checkout-key-0001"}
    add(client, 1, quantity=2)
    first = client.post("/cart/checkout", headers=headers)
    retry = client.post("/cart/checkout", headers=headers)
    assert first.status_code == retry.status_code == 201
    assert retry.json() == first.json()
    assert client.get("/cart", headers=SESSION).json()["items"] == []


def test_checkout_with_a_new_key_is_a_new_order(client):
    add(client, 1)
    first = client.post("/cart/checkout", headers={**SESSION, "Idempotency-Key": "checkout-key-0001"})
    add(client, 2)
    second = client.post("/cart/checkout", headers={**SESSION, "Idempotency-Key": "checkout-key-0002"})
    assert second.json()["order_id"] != first.json()["order_id"]


def test_idempotency_key_is_scoped_to_the_session(client):
    key = {"Idempotency-Key": "checkout-key-0001"}
    add(client, 1)
    mine = client.post("/cart/checkout", headers={**SESSION, **key})
    add(client, 2, headers=OTHER_SESSION)
    theirs = client.post("/cart/checkout", headers={**OTHER_SESSION, **key})
    assert theirs.status_code == 201
    assert theirs.json()["order_id"] != mine.json()["order_id"]


def test_invalid_idempotency_key_is_rejected(client):
    add(client, 1)
    response = client.post("/cart/checkout", headers={**SESSION, "Idempotency-Key": "bad key!"})
    assert response.status_code == 400
    assert client.get("/cart", headers=SESSION).json()["items"] != []
