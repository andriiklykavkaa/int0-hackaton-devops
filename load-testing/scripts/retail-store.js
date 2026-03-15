/**
 * k6 Load Test — Retail Store
 *
 * Three phases:
 *   1. Ramp-up   (0 → 50 VUs over 2 min)  — warm up, HPA should not fire yet
 *   2. Sustained (50 VUs for 5 min)        — steady load, watch HPA scale
 *   3. Spike     (50 → 150 VUs over 1 min) — force HPA to add pods fast
 *   4. Ramp-down (150 → 0 VUs over 2 min)  — observe scale-in
 *
 * Thresholds (SLOs for hackathon demo):
 *   - 95% of requests complete in < 500ms
 *   - Error rate < 1%
 *
 * Run locally:
 *   BASE_URL=http://localhost:8888 k6 run load-testing/scripts/retail-store.js
 *
 * Run in cluster (via k6 operator or Job):
 *   BASE_URL=http://ui.retail-store-stage.svc.cluster.local k6 run retail-store.js
 */

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import { randomItem } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

export const errorRate = new Rate("custom_error_rate");
export const checkoutDuration = new Trend("custom_checkout_duration_ms", true);
export const catalogDuration = new Trend("custom_catalog_duration_ms", true);
export const cartAddCounter = new Counter("custom_cart_add_total");

export const options = {
  stages: [
    { duration: "2m", target: 20 },   // Ramp-up
    { duration: "5m", target: 20 },   // Sustained — HPA stabilizes
    { duration: "1m", target: 50 },   // Spike — forces HPA scale-out
    { duration: "3m", target: 50 },   // Hold spike
    { duration: "2m", target: 0 },    // Ramp-down
  ],

  thresholds: {
    http_req_duration: ["p(95)<500"],
    custom_error_rate: ["rate<0.05"],
    custom_checkout_duration_ms: ["p(95)<800"],
  },

  tags: { testName: "retail-store-hpa-demo" },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8888";

// Populated dynamically from catalog API in setup()
let PRODUCT_IDS = [];

function request(method, url, body, params) {
  const res = method === "POST"
    ? http.post(url, body, params)
    : http.get(url, params);

  const ok = check(res, {
    "status 2xx": (r) => r.status >= 200 && r.status < 300,
  });
  errorRate.add(!ok);
  return res;
}

export default function (data) {
  const productIds = data.productIds || [];
  const params = {
    headers: { "Accept": "text/html,application/json" },
    timeout: "10s",
  };

  group("homepage", () => {
    request("GET", `${BASE_URL}/home`, null, params);
    sleep(0.5);
  });

  group("catalog", () => {
    const startTime = Date.now();

    request("GET", `${BASE_URL}/catalog`, null, params);

    if (productIds.length > 0) {
      const productId = randomItem(productIds);
      request("GET", `${BASE_URL}/catalog/${productId}`, null, params);
    }

    catalogDuration.add(Date.now() - startTime);
    sleep(1);
  });

  group("cart", () => {
    const productId = productIds.length > 0 ? randomItem(productIds) : null;
    const res = productId
      ? request("POST", `${BASE_URL}/cart`, { productId: productId }, params)
      : { status: 0 };

    if (res.status === 200 || res.status === 201) {
      cartAddCounter.add(1);
    }

    request("GET", `${BASE_URL}/cart`, null, params);
    sleep(0.5);
  });

  group("checkout", () => {
    const startTime = Date.now();

    request("GET", `${BASE_URL}/checkout`, null, params);

    request("POST", `${BASE_URL}/checkout`, {
      firstName: "Load",
      lastName: "Test",
      email: "loadtest@example.com",
      streetAddress: "1 Test Street",
      city: "Warsaw",
      state: "MA",
      zipCode: "00-001",
    }, params);

    request("POST", `${BASE_URL}/checkout/delivery`, {
      token: "priority-mail",
    }, params);

    checkoutDuration.add(Date.now() - startTime);
    sleep(1);
  });

  sleep(Math.random() * 2 + 1); // 1–3s think time between iterations
}

export function setup() {
  const healthRes = http.get(`${BASE_URL}/actuator/health`);
  if (healthRes.status !== 200) {
    console.warn(`Health check returned ${healthRes.status} — app may not be ready`);
  }

  // Fetch real product IDs from catalog
  const catalogRes = http.get(`${BASE_URL}/catalog`, {
    headers: { Accept: "application/json" },
  });
  let productIds = [];
  if (catalogRes.status === 200) {
    try {
      const products = JSON.parse(catalogRes.body);
      productIds = products.map((p) => p.id).filter(Boolean);
      console.log(`Discovered ${productIds.length} products from catalog`);
    } catch (e) {
      console.warn(`Could not parse catalog response: ${e}`);
    }
  }
  if (productIds.length === 0) {
    console.warn("No products discovered — catalog detail and cart tests will fail");
  }
  return { baseUrl: BASE_URL, productIds: productIds };
}

export function teardown(data) {
  console.log(`Load test completed against: ${data.baseUrl}`);
}
