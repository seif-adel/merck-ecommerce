// All calls go to /api/..., which nginx forwards to the backend, so the browser never talks to it directly.
const API = "/api";

// The cart is tied to this random id, stored in the browser. Production would use the logged-in session.
function randomId() {
  // crypto.randomUUID() is missing on plain-HTTP pages, getRandomValues() is not.
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function getSessionId() {
  let id = localStorage.getItem("sessionId");
  if (!id) {
    id = randomId();
    localStorage.setItem("sessionId", id);
  }
  return id;
}

// Identifies one checkout attempt; resent on a retry or double click so the order is placed only once.
let checkoutKey = null;

async function api(path, options = {}) {
  const response = await fetch(API + path, {
    ...options,
    headers: { "Content-Type": "application/json", "X-Session-Id": getSessionId(), ...options.headers },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(typeof body.detail === "string" ? body.detail : `Request failed (${response.status})`);
  }
  return body;
}

const money = (cents, currency = "EUR") => `${(cents / 100).toFixed(2)} ${currency}`;

function showMessage(text, isError = false) {
  const el = document.getElementById("message");
  el.textContent = text;
  el.className = isError ? "error" : "ok";
  el.hidden = !text;
}

// textContent (not innerHTML) so product names can never inject HTML or scripts.
function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function renderProducts(products) {
  const list = document.getElementById("products");
  list.replaceChildren(
    ...products.map((p) => {
      const button = el("button", "Add to cart");
      button.type = "button";
      button.addEventListener("click", () => addToCart(p.id));
      const card = el("li", undefined, "card");
      card.append(el("h3", p.name), el("p", p.description), el("p", money(p.price_cents, p.currency), "price"), button);
      return card;
    })
  );
}

function renderCart(cart) {
  checkoutKey = null; // a changed cart is a new purchase
  const list = document.getElementById("cart-items");
  list.replaceChildren(
    ...cart.items.map((item) => {
      const minus = el("button", "-", "qty");
      minus.type = "button";
      minus.title = "One less";
      // At quantity 1 the line is removed instead of going to zero.
      minus.addEventListener("click", () => (item.quantity > 1 ? setQuantity(item.id, item.quantity - 1) : removeFromCart(item.id)));
      const plus = el("button", "+", "qty");
      plus.type = "button";
      plus.title = "One more";
      plus.addEventListener("click", () => addToCart(item.product_id));
      const remove = el("button", "Remove", "link");
      remove.type = "button";
      remove.addEventListener("click", () => removeFromCart(item.id));
      const controls = el("span", undefined, "controls");
      controls.append(minus, plus, remove);
      const row = el("li");
      row.append(el("span", `${item.quantity} x ${item.name}`), el("span", money(item.line_total_cents)), controls);
      return row;
    })
  );
  document.getElementById("cart-total").textContent = money(cart.total_cents, cart.currency);
  document.getElementById("checkout").disabled = cart.items.length === 0;
}

async function run(action) {
  try {
    await action();
  } catch (err) {
    showMessage(err.message, true);
  }
}

const addToCart = (productId) =>
  run(async () => {
    renderCart(await api("/cart/items", { method: "POST", body: JSON.stringify({ product_id: productId, quantity: 1 }) }));
    showMessage("");
  });

const setQuantity = (itemId, quantity) =>
  run(async () => {
    renderCart(await api(`/cart/items/${itemId}`, { method: "PATCH", body: JSON.stringify({ quantity }) }));
    showMessage("");
  });

const removeFromCart = (itemId) =>
  run(async () => {
    renderCart(await api(`/cart/items/${itemId}`, { method: "DELETE" }));
    showMessage("");
  });

const checkout = () =>
  run(async () => {
    checkoutKey ??= randomId();
    const order = await api("/cart/checkout", { method: "POST", headers: { "Idempotency-Key": checkoutKey } });
    renderCart(await api("/cart"));
    showMessage(`Order ${order.order_id} placed. Total ${money(order.total_cents, order.currency)}.`);
  });

document.getElementById("checkout").addEventListener("click", checkout);

run(async () => {
  renderProducts(await api("/products"));
  renderCart(await api("/cart"));
});
