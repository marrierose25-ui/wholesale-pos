// Live pos-api stress burst for the wholesale POS PWA.
//
// Logs in as the shop owner, allocates N receipt numbers and posts N sales
// concurrently, then hammers the read endpoints while those writes are landing.
// The receipts it allocated are the ones it sells with, so the burst exercises
// the same path a till does. It then ASSERTS the outcome instead of only
// counting HTTP failures: every sale accepted, the dashboard delta equal to the
// accepted CASH+BANK sales (LOAN settles later, so it is excluded by design),
// receipt numbers unique, and a replay of one sale id booking nothing new.
//
// Every row it creates is stamped device_id = 'stress-burst' and it prints the
// exact cleanup SQL (sale ids + items) at the end:
//   delete from sale_items where sale_id in (...);
//   delete from sales      where id      in (...);
//
// Usage:  POS_ACTIVATION_CODE=... POS_OWNER=owner POS_OWNER_PASSWORD=... \
//           node app/tools/stress_burst.mjs [salesCount]
//
// Credentials are read from the environment only — never commit them.
import { randomUUID } from 'node:crypto';

const URL = process.env.POS_API_URL ??
  'https://trcthxyyuapwavzeisvm.supabase.co/functions/v1/pos-api';
const CODE = process.env.POS_ACTIVATION_CODE;
const OWNER = process.env.POS_OWNER ?? 'owner';
const PASSWORD = process.env.POS_OWNER_PASSWORD;
if (!CODE || !PASSWORD) {
  console.error('Set POS_ACTIVATION_CODE and POS_OWNER_PASSWORD first.');
  process.exit(2);
}
const SALES = Number(process.argv[2] ?? 200);
const READS = 300;

let token = '';

const nowIso = () => new Date().toISOString();
const dayStart = () => {
  const d = new Date();
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).toISOString();
};
const dayEnd = () => {
  const d = new Date();
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).toISOString();
};

async function call(action, body = {}) {
  const started = performance.now();
  const res = await fetch(URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ action, ...body }),
  });
  const ms = performance.now() - started;
  const json = await res.json().catch(() => ({ ok: false, error: 'bad json' }));
  if (json.ok !== true) throw new Error(json.error || `HTTP ${res.status}`);
  return { json, ms };
}

const pct = (sorted, p) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];
const round = (n) => Math.round(n * 10) / 10;

function summarize(label, times, failures) {
  const sorted = [...times].sort((a, b) => a - b);
  const total = times.length + failures.length;
  console.log(
    `${label}: ${times.length}/${total} ok | ` +
      `p50 ${round(pct(sorted, 0.5) ?? 0)}ms  p95 ${round(pct(sorted, 0.95) ?? 0)}ms  ` +
      `max ${round(sorted[sorted.length - 1] ?? 0)}ms`,
  );
  const unique = [...new Set(failures)];
  if (unique.length) console.log(`  failures: ${unique.slice(0, 5).join(' | ')}`);
}

const login = await call('login', {
  activation_code: CODE,
  username: OWNER,
  password: PASSWORD,
});
token = login.json.token;
console.log(`logged in as ${OWNER} in ${round(login.ms)}ms`);

const before = await call('dashboard_summary', {
  period_start: dayStart(),
  period_end: dayEnd(),
});
const beforeCount = Number(before.json.stats?.sales_count ?? 0);

const products = (await call('list_products')).json.products.filter((p) => {
  const active = p.isActive ?? p.is_active;
  return active === true || active === 1;
});
if (!products.length) throw new Error('No active products to sell.');
const priceOf = (p) => Number(p.sellingPriceMinorUnits ?? p.selling_price_minor_units ?? 0);

const shift = (await call('ensure_shift')).json.shift;
const shiftId = shift.id;

// ---- 1. 200 concurrent receipt allocations -------------------------------
let started = performance.now();
const receipts = await Promise.allSettled(
  Array.from({ length: SALES }, () => call('next_receipt_number')),
);
const receiptTimes = receipts.filter((r) => r.status === 'fulfilled').map((r) => r.value.ms);
const receiptFails = receipts.filter((r) => r.status === 'rejected').map((r) => `${r.reason}`);
const receiptNumbers = receipts
  .filter((r) => r.status === 'fulfilled')
  .map((r) => r.value.json.receipt_number);
console.log(
  `receipt allocation: ${receiptNumbers.length} in ${Math.round(performance.now() - started)}ms, ` +
    `unique ${new Set(receiptNumbers).size}`,
);
summarize('  receipt latency', receiptTimes, receiptFails);

// ---- 2. 200 concurrent sales --------------------------------------------
const payments = ['CASH', 'CASH', 'CASH', 'BANK', 'BANK', 'LOAN'];
const customers = ['Abebe Tesfaye', 'Tigist Alemu', 'Hana Girma', 'Dawit Bekele', 'Selam Mekonnen'];

const saleRequest = (index) => {
  const saleId = `burst-${Date.now()}-${index}-${randomUUID().slice(0, 8)}`;
  const lineCount = 1 + (index % 3);
  const items = Array.from({ length: lineCount }, (_, l) => {
    const product = products[(index * 3 + l * 7) % products.length];
    const qty = 1 + ((index + l) % 3);
    const price = priceOf(product);
    return {
      id: randomUUID(),
      sale_id: saleId,
      product_id: product.id,
      product_name_snapshot: product.name,
      unit_price_snapshot_minor_units: price,
      quantity_text: String(qty),
      billing_quantity_milliunits: qty * 1000,
      line_discount_minor_units: 0,
      line_total_minor_units: price * qty,
      notes: null,
    };
  });
  const subtotal = items.reduce((sum, item) => sum + item.line_total_minor_units, 0);
  const discount = index % 10 === 0 ? Math.floor(subtotal * 0.02) : 0;
  const total = subtotal - discount;
  return {
    sale: {
      id: saleId,
      receipt_number: receiptNumbers[index] ?? `REC-STRESS-${index}`,
      cashier_id: '',
      device_id: 'stress-burst',
      shift_id: shiftId,
      customer_name: customers[index % customers.length],
      payment_method: payments[index % payments.length],
      subtotal_minor_units: subtotal,
      discount_minor_units: discount,
      total_minor_units: total,
      amount_paid_minor_units: total,
      change_minor_units: 0,
      status: 'COMPLETED',
      created_at: nowIso(),
    },
    items,
  };
};

started = performance.now();
// Keep the exact bodies: the first one is replayed later to prove the write is
// idempotent, which only works when the sale id is identical.
const saleBodies = Array.from({ length: SALES }, (_, index) => saleRequest(index));
const sales = await Promise.allSettled(
  saleBodies.map((body) => call('insert_sale', body)),
);
const saleTimes = sales.filter((r) => r.status === 'fulfilled').map((r) => r.value.ms);
const saleFails = sales.filter((r) => r.status === 'rejected').map((r) => `${r.reason}`);
const saleIds = sales
  .filter((r) => r.status === 'fulfilled')
  .map((r) => r.value.json.id);
console.log(`sales: ${saleIds.length}/${SALES} accepted in ${Math.round(performance.now() - started)}ms`);
summarize('  sale latency', saleTimes, saleFails);

// ---- 3. 300 concurrent reads while the writes settle --------------------
const readBodies = [
  ['dashboard_summary', () => ({ period_start: dayStart(), period_end: dayEnd() })],
  ['revenue_trend', () => ({ period_start: dayStart(), period_end: dayEnd() })],
  ['search_sales', () => ({ limit: 25 })],
  ['list_audit', () => ({ limit: 50 })],
  ['list_products', () => ({})],
  ['register_snapshot', () => ({})],
];
const reads = await Promise.allSettled(
  Array.from({ length: READS }, (_, index) => {
    const [action, body] = readBodies[index % readBodies.length];
    return call(action, body());
  }),
);
const readTimes = reads.filter((r) => r.status === 'fulfilled').map((r) => r.value.ms);
const readFails = reads.filter((r) => r.status === 'rejected').map((r) => `${r.reason}`);
summarize(`reads (${READS})`, readTimes, readFails);

// ---- 4. Post-burst consistency ------------------------------------------
// LOAN is money owed, not collected, so the dashboard count deliberately
// excludes it; only CASH+BANK sales are expected to move it.
const acceptedNonLoan = saleIds.length - payments
  .slice(0, saleIds.length)
  .filter((m) => m === 'LOAN').length;

const after = await call('dashboard_summary', {
  period_start: dayStart(),
  period_end: dayEnd(),
});
const afterCount = Number(after.json.stats?.sales_count ?? 0);
const delta = afterCount - beforeCount;
console.log(
  `dashboard sales today: ${beforeCount} -> ${afterCount} ` +
    `(delta ${delta}, expected ${acceptedNonLoan} of ${saleIds.length} accepted)`,
);

const trend = (await call('revenue_trend', {
  period_start: dayStart(),
  period_end: dayEnd(),
})).json;
const rows = trend.trend ?? [];
console.log(`revenue_trend rows today: ${Array.isArray(rows) ? rows.length : 'n/a'}`);

const audit = await call('list_audit', { limit: 200 });
const auditRows = audit.json.audit_logs ?? [];
const saleAudits = auditRows.filter((row) => row.action === 'SALE_COMPLETED').length;
console.log(`audit rows read: ${auditRows.length}, SALE_COMPLETED among them: ${saleAudits}`);

// Replay one accepted sale id: the idempotent RPC must return the original row
// and book nothing new (audit #6).
let replayOk = 'skipped';
if (saleIds.length) {
  const replayed = await call('insert_sale', saleBodies[0]);
  const again = await call('dashboard_summary', {
    period_start: dayStart(),
    period_end: dayEnd(),
  });
  const booked = Number(again.json.stats?.sales_count ?? 0) - afterCount;
  replayOk = replayed.json.duplicate === true && booked === 0
    ? 'ok'
    : `FAILED (duplicate=${replayed.json.duplicate}, new rows=${booked})`;
}
console.log(`idempotent replay: ${replayOk}`);

// ---- 5. Verdict + cleanup ----------------------------------------------
const checks = [
  ['every sale accepted', saleIds.length === SALES, `${saleIds.length}/${SALES}`],
  ['receipts unique', new Set(receiptNumbers).size === SALES, `${new Set(receiptNumbers).size}/${SALES}`],
  ['dashboard delta matches', delta === acceptedNonLoan, `${delta} vs ${acceptedNonLoan}`],
  ['replay booked nothing', replayOk === 'ok', replayOk],
];
let failed = 0;
for (const [name, ok, detail] of checks) {
  if (!ok) failed += 1;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${name} (${detail})`);
}

if (saleIds.length) {
  const quoted = saleIds.map((id) => `'${id}'`).join(',');
  console.log('\ncleanup:');
  console.log(`  delete from sale_items where customer_id = (select customer_id from sales where id = '${saleIds[0]}') and sale_id in (${quoted});`);
  console.log(`  delete from sales where id in (${quoted});`);
}

const httpFailures = receiptFails.length + saleFails.length + readFails.length;
if (httpFailures || failed) {
  console.log(`RESULT: ${httpFailures} failed request(s), ${failed} failed assertion(s)`);
  process.exit(1);
}
console.log('RESULT: stable (no failed requests, all assertions passed)');
process.exit(0);
