"""Merck e-commerce demo backend: product catalog, cart and checkout on an in-memory store."""

import logging
import os
import re
import threading
import time
import uuid
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

MAX_ITEM_PER_CARD = 99
SESSION_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
IDEMPOTENCY_KEY_PATTERN = SESSION_ID_PATTERN

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("shop")


# ----------------------------------------------------------------------------
# Data shapes (what the API accepts and returns)
# ----------------------------------------------------------------------------
class Product(BaseModel):
    id: int
    sku: str
    name: str
    description: str
    price_cents: int  # money as whole cents: floats cannot represent 0.10 exactly
    currency: str = "EUR"


class AddToCartRequest(BaseModel):
    product_id: int
    quantity: int = Field(default=1, ge=1, le=MAX_ITEM_PER_CARD)


class UpdateQuantityRequest(BaseModel):
    quantity: int = Field(ge=1, le=MAX_ITEM_PER_CARD)  # to go to zero, use DELETE


class CartItem(BaseModel):
    id: str
    product_id: int
    name: str
    unit_price_cents: int
    quantity: int
    line_total_cents: int


class Cart(BaseModel):
    items: list[CartItem]
    total_cents: int
    currency: str = "EUR"


class Order(BaseModel):
    order_id: str
    status: str
    items: list[CartItem]
    total_cents: int
    currency: str
    created_at: str


class ShopError(Exception):
    """A business-rule failure that is reported to the client with an HTTP status."""

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


DEFAULT_PRODUCTS = [
    Product(id=1, sku="LAB-PIP-200", name="Pipette Tips 200 µL (960 pcs)",
            description="Sterile, filtered, low-retention tips for precise liquid handling.", price_cents=3490),
    Product(id=2, sku="LAB-DMEM-500", name="DMEM Cell Culture Medium 500 mL",
            description="High-glucose medium for mammalian cell culture.", price_cents=2950),
    Product(id=3, sku="LAB-FLT-022", name="Syringe Filters 0.22 µm (50 pcs)",
            description="PES membrane filters for sterile filtration of small volumes.", price_cents=4120),
    Product(id=4, sku="LAB-ETH-1L", name="Ethanol 99.8% 1 L",
            description="Analytical-grade ethanol for laboratory use.", price_cents=1890),
    Product(id=5, sku="LAB-GLV-M", name="Nitrile Gloves, size M (100 pcs)",
            description="Powder-free disposable gloves, chemical resistant.", price_cents=1250),
    Product(id=6, sku="LAB-TUB-50", name="Centrifuge Tubes 50 mL (500 pcs)",
            description="Polypropylene conical tubes with screw cap.", price_cents=5675),
    Product(id=7, sku="LAB-PH-STR", name="pH Test Strips 0-14 (100 pcs)",
            description="Quick colorimetric pH measurement.", price_cents=790),
    Product(id=8, sku="LAB-BAL-220", name="Analytical Balance 220 g / 0.1 mg",
            description="Precision balance with internal calibration.", price_cents=129900),
]


# ----------------------------------------------------------------------------
# Data layer: swap this class for an Aurora/RDS-backed one without touching routes
# ----------------------------------------------------------------------------
class InMemoryStore:
    def __init__(self, products: list[Product] | None = None) -> None:
        self._lock = threading.Lock()  # request handlers run in several threads
        self._products = {p.id: p for p in (products or DEFAULT_PRODUCTS)}
        self._carts: dict[str, dict[str, dict]] = {}  # session -> item id -> {product_id, quantity}
        self._orders: dict[str, Order] = {}
        self._orders_by_key: dict[tuple[str, str], Order] = {}  # (session, idempotency key) -> order

    def list_products(self) -> list[Product]:
        return list(self._products.values())

    def get_product(self, product_id: int) -> Product:
        product = self._products.get(product_id)
        if product is None:
            raise ShopError(404, f"Product {product_id} not found")
        return product

    def get_cart(self, session_id: str) -> Cart:
        with self._lock:
            return self._build_cart(session_id)

    def add_item(self, session_id: str, product_id: int, quantity: int) -> Cart:
        self.get_product(product_id)  # raises 404 for unknown products
        with self._lock:
            lines = self._carts.setdefault(session_id, {})
            existing = next((line for line in lines.values() if line["product_id"] == product_id), None)
            if existing:
                if existing["quantity"] + quantity > MAX_ITEM_PER_CARD:
                    raise ShopError(400, f"Maximum quantity per item is {MAX_ITEM_PER_CARD}")
                existing["quantity"] += quantity
            else:
                lines[uuid.uuid4().hex[:12]] = {"product_id": product_id, "quantity": quantity}
            return self._build_cart(session_id)

    def remove_item(self, session_id: str, item_id: str) -> Cart:
        with self._lock:
            lines = self._carts.get(session_id, {})
            if item_id not in lines:
                raise ShopError(404, f"Cart item {item_id} not found")
            del lines[item_id]
            return self._build_cart(session_id)

    def set_item_quantity(self, session_id: str, item_id: str, quantity: int) -> Cart:
        with self._lock:
            line = self._carts.get(session_id, {}).get(item_id)
            if line is None:
                raise ShopError(404, f"Cart item {item_id} not found")
            line["quantity"] = quantity
            return self._build_cart(session_id)

    def checkout(self, session_id: str, idempotency_key: str | None = None) -> Order:
        with self._lock:
            if idempotency_key:
                # Looked up before the empty-cart check: after the first success the cart is empty.
                replay = self._orders_by_key.get((session_id, idempotency_key))
                if replay:
                    return replay
            cart = self._build_cart(session_id)
            if not cart.items:
                raise ShopError(400, "Cart is empty")
            order = Order(
                order_id=uuid.uuid4().hex[:12],
                status="PLACED",
                items=cart.items,
                total_cents=cart.total_cents,
                currency=cart.currency,
                created_at=datetime.now(timezone.utc).isoformat(),
            )
            self._orders[order.order_id] = order
            if idempotency_key:
                self._orders_by_key[(session_id, idempotency_key)] = order
            self._carts[session_id] = {}
            return order

    def _build_cart(self, session_id: str) -> Cart:
        items = []
        for item_id, line in self._carts.get(session_id, {}).items():
            product = self._products[line["product_id"]]
            items.append(CartItem(
                id=item_id,
                product_id=product.id,
                name=product.name,
                unit_price_cents=product.price_cents,
                quantity=line["quantity"],
                line_total_cents=product.price_cents * line["quantity"],
            ))
        return Cart(items=items, total_cents=sum(i.line_total_cents for i in items))


# ----------------------------------------------------------------------------
# HTTP layer
# ----------------------------------------------------------------------------
def get_session_id(x_session_id: str | None = Header(default=None)) -> str:
    """Identify the shopper. In production this comes from the authenticated session instead."""
    if not x_session_id or not SESSION_ID_PATTERN.fullmatch(x_session_id):
        raise ShopError(400, "Missing or invalid X-Session-Id header")
    return x_session_id


def get_idempotency_key(idempotency_key: str | None = Header(default=None)) -> str | None:
    """Optional client-chosen id: sending the same one again returns the original order."""
    if idempotency_key is not None and not IDEMPOTENCY_KEY_PATTERN.fullmatch(idempotency_key):
        raise ShopError(400, "Invalid Idempotency-Key header")
    return idempotency_key


def create_app(store: InMemoryStore | None = None) -> FastAPI:
    store = store or InMemoryStore()
    app_env = os.getenv("APP_ENV", "local")
    docs_enabled = os.getenv("ENABLE_DOCS", "true").lower() == "true"

    app = FastAPI(
        title="Merck E-commerce API",
        version="1.0.0",
        docs_url="/docs" if docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )

    @app.exception_handler(ShopError)
    async def handle_shop_error(_: Request, exc: ShopError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.message})

    @app.middleware("http")
    async def log_requests(request: Request, call_next):
        started = time.perf_counter()
        response = await call_next(request)
        logger.info("%s %s -> %s in %.1f ms", request.method, request.url.path,
                    response.status_code, (time.perf_counter() - started) * 1000)
        return response

    @app.get("/healthz")
    def healthz() -> dict:
        return {"status": "ok", "env": app_env}

    @app.get("/products", response_model=list[Product])
    def list_products() -> list[Product]:
        return store.list_products()

    @app.get("/products/{product_id}", response_model=Product)
    def get_product(product_id: int) -> Product:
        return store.get_product(product_id)

    @app.get("/cart", response_model=Cart)
    def view_cart(session_id: str = Depends(get_session_id)) -> Cart:
        return store.get_cart(session_id)

    @app.post("/cart/items", response_model=Cart, status_code=201)
    def add_to_cart(body: AddToCartRequest, session_id: str = Depends(get_session_id)) -> Cart:
        return store.add_item(session_id, body.product_id, body.quantity)

    @app.patch("/cart/items/{item_id}", response_model=Cart)
    def update_item_quantity(
        item_id: str, body: UpdateQuantityRequest, session_id: str = Depends(get_session_id)
    ) -> Cart:
        return store.set_item_quantity(session_id, item_id, body.quantity)

    @app.delete("/cart/items/{item_id}", response_model=Cart)
    def remove_item_from_cart(item_id: str, session_id: str = Depends(get_session_id)) -> Cart:
        return store.remove_item(session_id, item_id)

    @app.post("/cart/checkout", response_model=Order, status_code=201)
    def submit_cart(
        session_id: str = Depends(get_session_id),
        idempotency_key: str | None = Depends(get_idempotency_key),
    ) -> Order:
        return store.checkout(session_id, idempotency_key)

    return app


merck_group_app = create_app()
