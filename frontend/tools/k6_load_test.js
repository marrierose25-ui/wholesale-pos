// Load test for the deployed Wholesale POS surface.
//
//   k6 run app/tools/k6_load_test.js
//   k6 run -e PWA=https://web-xi-seven-15.vercel.app app/tools/k6_load_test.js
//
// What is exercised (all read-only; nothing is written to the tenant):
//   * pwa_assets  - the Vercel CDN serving index.html and the 3 MB
//                   main.dart.js a cold browser must download (937 kB on the
//                   wire, brotli). Thresholded on time-to-first-byte, not on
//                   total duration: the body is bandwidth-bound to whatever
//                   link the till is on, so total time says nothing about the
//                   CDN. Two virtual users, because a higher count would just
//                   divide this machine's uplink further.
//   * api_gate    - the pos-api Edge Function refusing an unknown activation
//                   code. This is a real round trip: licence lookup in
//                   Postgres, then the 403. It measures function start-up,
//                   the service-role query and the JSON hop.
//   * sync_gate   - the sync gateway refusing a request with no licence, i.e.
//                   the cost of the cheapest possible invocation.
//
// Deliberately NOT load tested here: authenticated sale writes. That path was
// measured in Phase 21 with app/tools/stress_burst.mjs (200 concurrent receipt
// allocations stayed unique, 300 concurrent reads clean, 50-way writes + 300
// reads with sale p95 776 ms) and it mutates real money rows, so it is not
// something to re-run casually against the live tenant.

import http from 'k6/http';
import { check, sleep } from 'k6';

const PWA = __ENV.PWA || 'https://web-xi-seven-15.vercel.app';
const API = __ENV.API || 'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1/pos-api';
const SYNC = __ENV.SYNC || 'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1/sync';

// An activation code-shaped string that resolves to no tenant. It is not a
// credential and must stay that way.
const BOGUS_CODE = 'AAAA-AAAA-AAAA-AAAA-AA';

// The gate answers 403/401 by design, so those are "expected", not failures.
const EXPECT_403 = http.expectedStatuses(403);
const EXPECT_401 = http.expectedStatuses(401);

export const options = {
  scenarios: {
    pwa_assets: {
      executor: 'constant-vus',
      vus: 2,
      duration: '30s',
      exec: 'pwaAssets',
    },
    api_gate: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '15s', target: 10 },
        { duration: '30s', target: 20 },
        { duration: '10s', target: 0 },
      ],
      exec: 'apiGate',
    },
    sync_gate: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      exec: 'syncGate',
    },
  },
  thresholds: {
    'http_req_failed{scenario:pwa_assets}': ['rate<0.01'],
    'http_req_failed{scenario:api_gate}': ['rate<0.01'],
    'http_req_failed{scenario:sync_gate}': ['rate<0.01'],
    // CDN responsiveness: how long Vercel takes to start answering.
    'http_req_waiting{scenario:pwa_assets}': ['p(95)<1500'],
    'http_req_duration{scenario:api_gate}': ['p(95)<2000'],
    'http_req_duration{scenario:sync_gate}': ['p(95)<2000'],
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function pwaAssets() {
  const shell = http.get(`${PWA}/`, { tags: { asset: 'index' } });
  check(shell, { 'shell 200': (r) => r.status === 200 });

  const bundle = http.get(`${PWA}/main.dart.js`, { tags: { asset: 'bundle' } });
  check(bundle, {
    'bundle 200': (r) => r.status === 200,
    'bundle is the app': (r) => r.body !== null && r.body.length > 1000000,
  });

  sleep(1);
}

export function apiGate() {
  const res = http.post(
    API,
    JSON.stringify({
      action: 'has_users',
      activation_code: BOGUS_CODE,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      responseCallback: EXPECT_403,
      tags: { name: 'pos-api/has_users' },
    },
  );
  check(res, {
    'unknown code refused': (r) => r.status === 403,
    'refusal is clean json': (r) => {
      try {
        return JSON.parse(r.body).ok === false;
      } catch {
        return false;
      }
    },
  });
  sleep(0.5);
}

export function syncGate() {
  const res = http.post(
    SYNC,
    JSON.stringify({ action: 'ping' }),
    {
      headers: { 'Content-Type': 'application/json' },
      responseCallback: EXPECT_401,
      tags: { name: 'sync/ping-no-licence' },
    },
  );
  check(res, { 'licence required': (r) => r.status === 401 });
  sleep(0.5);
}
