// In-memory PostgREST-style mock for pos-api handler tests.
//
// Implements the subset of the supabase-js query builder the pos-api modules
// actually use: select/insert/update/delete/upsert with eq/neq/is/not/in/ilike/
// or/gte/lt filters, order/limit, maybeSingle/single, head-count selects, and
// rpc(). Rows are plain objects; tenant scoping is exercised by seeding rows
// for multiple customer_id values and letting the real `.eq('customer_id', ...)`
// filters do the isolation.

export type Row = Record<string, unknown>;
export interface DbError {
  message: string;
}
export interface QueryResult {
  data: unknown;
  error: DbError | null;
  count?: number;
}
export type RpcParams = Record<string, unknown>;
export type RpcHandler = (params: RpcParams, db: MockDb) => unknown;

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

const Q = (s: string) => `"${String(s).replace(/"/g, '\\"')}"`;

function parseInList(raw: string): string[] {
  // raw looks like: ("a","b") or (a,b)
  const inner = raw.trim().replace(/^\(/, "").replace(/\)$/, "");
  if (!inner) return [];
  return inner.split(",").map((p) => {
    const t = p.trim();
    return t.startsWith('"') && t.endsWith('"') ? t.slice(1, -1) : t;
  });
}

function ilikeToRegex(pattern: string): RegExp {
  // PostgREST/SQL LIKE: % any run, _ single char; case-insensitive.
  let out = "";
  for (const ch of pattern) {
    if (ch === "%") out += ".*";
    else if (ch === "_") out += ".";
    else out += ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${out}$`, "i");
}

function parseOr(expr: string): ((row: Row) => boolean)[] {
  // Split on commas that are not inside parentheses, e.g.
  // 'a.ilike.%x%,b.in.("1","2"),c.eq.v'
  const terms: string[] = [];
  let depth = 0;
  let cur = "";
  for (const ch of expr) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      terms.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur) terms.push(cur);
  return terms.map((t) => {
    const m = t.trim().match(/^([A-Za-z0-9_]+)\.([a-z]+)\.(.*)$/s);
    if (!m) return () => false;
    const [, col, op, rawVal] = m;
    const val = rawVal ?? "";
    switch (op) {
      case "ilike": {
        const re = ilikeToRegex(val);
        return (row) => re.test(String(row[col] ?? ""));
      }
      case "eq":
        return (row) => String(row[col] ?? "") === val;
      case "in":
        return (row) => parseInList(val).includes(String(row[col]));
      case "gte":
        return (row) => String(row[col] ?? "") >= val;
      case "lt":
        return (row) => String(row[col] ?? "") < val;
      case "is":
        return (row) => val === "null" ? row[col] == null : row[col] === val;
      default:
        return () => false;
    }
  });
}

type Filter = (row: Row) => boolean;

class MockQuery implements PromiseLike<QueryResult> {
  private db: MockDb;
  private table: string;
  private filters: Filter[] = [];
  private mode: "select" | "insert" | "update" | "delete" | "upsert" = "select";
  private payload: Row | Row[] | null = null;
  private upsertOpts: { onConflict?: string } | null = null;
  private orderCol: string | null = null;
  private orderAsc = true;
  private limitN: number | null = null;
  private wantRows = false;
  private headCount = false;

  constructor(db: MockDb, table: string) {
    this.db = db;
    this.table = table;
  }

  select(
    _cols?: unknown,
    opts?: { head?: boolean; [key: string]: unknown } | null,
  ): this {
    this.wantRows = true; // select, or insert/update returning representation
    if (opts?.head) this.headCount = true;
    return this;
  }

  insert(rows: Row | Row[]): this {
    this.mode = "insert";
    this.payload = rows;
    return this;
  }

  update(patch: Row): this {
    this.mode = "update";
    this.payload = patch;
    return this;
  }

  delete(): this {
    this.mode = "delete";
    return this;
  }

  upsert(row: Row, opts?: { onConflict?: string } | null): this {
    this.mode = "upsert";
    this.payload = row;
    this.upsertOpts = opts ?? null;
    return this;
  }

  eq(col: string, val: unknown): this {
    this.filters.push((r) => r[col] === val);
    return this;
  }
  neq(col: string, val: unknown): this {
    this.filters.push((r) => r[col] !== val);
    return this;
  }
  is(col: string, val: unknown): this {
    this.filters.push((r) => val === null ? r[col] == null : r[col] === val);
    return this;
  }
  not(col: string, op: string, val: unknown): this {
    if (op === "is") {
      this.filters.push((r) => val === null ? r[col] != null : r[col] !== val);
    } else if (op === "in") {
      const set = new Set(parseInList(String(val)));
      this.filters.push((r) => !set.has(String(r[col])));
    } else {
      this.filters.push(() => true);
    }
    return this;
  }
  in(col: string, vals: readonly unknown[]): this {
    const set = new Set((vals ?? []).map(String));
    this.filters.push((r) => set.has(String(r[col])));
    return this;
  }
  ilike(col: string, pattern: string): this {
    const re = ilikeToRegex(String(pattern));
    this.filters.push((r) => re.test(String(r[col] ?? "")));
    return this;
  }
  or(expr: string): this {
    const terms = parseOr(expr);
    this.filters.push((r) => terms.some((t) => t(r)));
    return this;
  }
  gte(col: string, val: unknown): this {
    this.filters.push((r) => String(r[col] ?? "") >= String(val));
    return this;
  }
  lt(col: string, val: unknown): this {
    this.filters.push((r) => String(r[col] ?? "") < String(val));
    return this;
  }
  gt(col: string, val: unknown): this {
    this.filters.push((r) => String(r[col] ?? "") > String(val));
    return this;
  }
  order(col: string, opts?: { ascending?: boolean } | null): this {
    this.orderCol = col;
    this.orderAsc = opts?.ascending !== false;
    return this;
  }
  limit(n: number): this {
    this.limitN = n;
    return this;
  }

  private matched(): Row[] {
    let rows = this.db.table(this.table).filter((r) =>
      this.filters.every((f) => f(r))
    );
    if (this.orderCol) {
      const col = this.orderCol;
      const dir = this.orderAsc ? 1 : -1;
      rows = [...rows].sort((a, b) => {
        const av = String(a[col] ?? "");
        const bv = String(b[col] ?? "");
        return av < bv ? -dir : av > bv ? dir : 0;
      });
    }
    if (this.limitN != null) rows = rows.slice(0, this.limitN);
    return rows;
  }

  private execute(): QueryResult {
    const table = this.db.table(this.table);
    try {
      if (this.mode === "insert") {
        const rows = (Array.isArray(this.payload)
          ? this.payload
          : [this.payload]) as Row[];
        const copies = rows.map((r) => ({ ...r }));
        table.push(...copies);
        return { data: this.wantRows ? copies : null, error: null };
      }
      if (this.mode === "update") {
        const matched = this.matched();
        for (const row of matched) Object.assign(row, this.payload);
        return {
          data: this.wantRows ? matched.map((r) => ({ ...r })) : null,
          error: null,
        };
      }
      if (this.mode === "delete") {
        const matched = new Set(this.matched());
        const keep = table.filter((r) => !matched.has(r));
        this.db.replaceTable(this.table, keep);
        return { data: this.wantRows ? [...matched] : null, error: null };
      }
      if (this.mode === "upsert") {
        const row = { ...(this.payload as Row) };
        const onConflict = String(this.upsertOpts?.onConflict ?? "")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        const existing = onConflict.length
          ? table.find((r) => onConflict.every((c) => r[c] === row[c]))
          : undefined;
        if (existing) Object.assign(existing, row);
        else table.push(row);
        return { data: this.wantRows ? [row] : null, error: null };
      }
      // select
      const rows = this.matched();
      if (this.headCount) {
        return { data: null, error: null, count: rows.length };
      }
      return { data: rows.map((r) => ({ ...r })), error: null };
    } catch (e) {
      return { data: null, error: { message: errorMessage(e) } };
    }
  }

  maybeSingle(): Promise<{ data: Row | null; error: DbError | null }> {
    const res = this.execute();
    if (res.error) {
      return Promise.resolve({ data: null, error: res.error });
    }
    const rows =
      (Array.isArray(res.data)
        ? res.data
        : res.data == null
        ? []
        : [res.data]) as Row[];
    if (rows.length > 1) {
      return Promise.resolve({
        data: null,
        error: { message: "JSON object requested, multiple rows returned" },
      });
    }
    return Promise.resolve({ data: rows[0] ?? null, error: null });
  }

  single(): Promise<{ data: Row | null; error: DbError | null }> {
    const res = this.execute();
    if (res.error) {
      return Promise.resolve({ data: null, error: res.error });
    }
    const rows =
      (Array.isArray(res.data)
        ? res.data
        : res.data == null
        ? []
        : [res.data]) as Row[];
    if (rows.length !== 1) {
      return Promise.resolve({
        data: null,
        error: { message: "JSON object requested, single row expected" },
      });
    }
    return Promise.resolve({ data: rows[0], error: null });
  }

  then<TResult1 = QueryResult, TResult2 = never>(
    onfulfilled?:
      | ((value: QueryResult) => TResult1 | PromiseLike<TResult1>)
      | null,
    onrejected?:
      | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
      | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.execute()).then(onfulfilled, onrejected);
  }
}

const DEFAULT_RPC: Record<string, RpcHandler> = {
  pos_next_receipt: () => "0001",
  pos_expected_cash: () => 0,
  pos_shift_counters: () => ({}),
  pos_shift_summary: () => ({}),
  pos_sales_totals: () => ({}),
  pos_revenue_trend: () => [],
  pos_product_summary: () => [],
  pos_cashier_performance: () => [],
  pos_setup_owner: (p, db) => {
    db.table("pos_users").push({
      id: p.p_id,
      customer_id: p.p_customer,
      username: p.p_username,
      role: "OWNER",
      pw_salt: p.p_pw_salt,
      pw_hash: p.p_pw_hash,
      active: true,
      permissions: [],
      token_version: 0,
      is_demo: false,
      created_at: new Date().toISOString(),
    });
    return null;
  },
  pos_ensure_shift: (p, db) => {
    const existing = db.table("shifts").find((r) =>
      r.customer_id === p.p_customer && r.status === "OPEN"
    );
    if (existing) return existing.id;
    const id = crypto.randomUUID();
    db.table("shifts").push({
      id,
      customer_id: p.p_customer,
      cashier_id: p.p_user,
      device_id: p.p_device || null,
      status: "OPEN",
      opened_at: new Date().toISOString(),
    });
    return id;
  },
  pos_open_shift: (p, db) => {
    const id = crypto.randomUUID();
    db.table("shifts").push({
      id,
      customer_id: p.p_customer,
      cashier_id: p.p_user,
      device_id: p.p_device || null,
      status: "OPEN",
      opening_cash_minor_units: p.p_opening,
      opened_at: new Date().toISOString(),
    });
    return id;
  },
  pos_close_shift: (p, db) => {
    const shift = db.table("shifts").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_shift_id
    );
    if (!shift || shift.status !== "OPEN") {
      return { __error: "Shift is no longer open." };
    }
    shift.status = "CLOSED";
    return 0;
  },
  pos_create_sale: (p, db) => {
    if (p.p_sale_id && db.table("sales").some((r) => r.id === p.p_sale_id)) {
      return {
        id: p.p_sale_id,
        receipt_number: p.p_receipt,
        subtotal_minor_units: 0,
        total_minor_units: 0,
        duplicate: true,
      };
    }
    const id = p.p_sale_id || crypto.randomUUID();
    db.table("sales").push({
      id,
      customer_id: p.p_customer,
      cashier_id: p.p_cashier,
      receipt_number: p.p_receipt,
      status: "COMPLETED",
      payment_method: p.p_payment,
      customer_name: p.p_customer_name ?? null,
      created_at: new Date().toISOString(),
    });
    return {
      id,
      receipt_number: p.p_receipt,
      subtotal_minor_units: 0,
      total_minor_units: 0,
      duplicate: false,
    };
  },
  pos_void_sale: (p, db) => {
    const sale = db.table("sales").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_sale_id
    );
    if (!sale) return { __error: "Sale not found." };
    sale.status = "VOIDED";
    sale.void_reason = p.p_reason;
    return null;
  },
  pos_approve_void: (p, db) => {
    const req = db.table("void_requests").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_request_id
    );
    if (!req || req.status !== "PENDING") {
      return { __error: "Request not found." };
    }
    req.status = "APPROVED";
    const sale = db.table("sales").find((r) => r.id === req.sale_id);
    if (sale) sale.status = "VOIDED";
    return null;
  },
  pos_reject_void: (p, db) => {
    const req = db.table("void_requests").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_request_id
    );
    if (!req || req.status !== "PENDING") {
      return { __error: "Request not found." };
    }
    req.status = "REJECTED";
    return null;
  },
  pos_add_cash_movement: (p, db) => {
    const id = crypto.randomUUID();
    db.table("cash_movements").push({
      id,
      customer_id: p.p_customer,
      shift_id: p.p_shift_id,
      user_id: p.p_user,
      type: p.p_type,
      amount_minor_units: p.p_amount,
      reason: p.p_reason,
      photo: p.p_photo ?? null,
      created_at: new Date().toISOString(),
    });
    return { id };
  },
  pos_complete_finance: (p, db) => {
    const e = db.table("pos_finance_entries").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_entry_id
    );
    if (!e || e.status !== "PENDING") {
      return { __error: "Entry is not pending." };
    }
    e.status = "COMPLETED";
    e.completed_by = p.p_user;
    return null;
  },
  pos_delete_finance_entry: (p, db) => {
    const e = db.table("pos_finance_entries").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_entry_id
    );
    if (!e) return { __error: "Entry not found." };
    e.status = "DELETED";
    return null;
  },
  pos_delete_finance_category: (p, db) => {
    const c = db.table("pos_finance_categories").find((r) =>
      r.customer_id === p.p_customer && r.id === p.p_id
    );
    if (!c || !c.deleted_at) return { __error: "Person not found." };
    for (const e of db.table("pos_finance_entries")) {
      if (e.category_id === c.id) e.status = "DELETED";
    }
    db.replaceTable(
      "pos_finance_categories",
      db.table("pos_finance_categories").filter((r) => r !== c),
    );
    return null;
  },
  pos_finance_person_totals: (p, db) => {
    let pending = 0;
    let completed = 0;
    for (const e of db.table("pos_finance_entries")) {
      if (e.customer_id !== p.p_customer || e.category_id !== p.p_category_id) {
        continue;
      }
      if (e.status === "PENDING") pending += Number(e.amount_minor_units ?? 0);
      if (e.status === "COMPLETED") {
        completed += Number(e.amount_minor_units ?? 0);
      }
    }
    return { pending_total: pending, completed_total: completed };
  },
};

export class MockDb {
  private tables = new Map<string, Row[]>();
  private rpcHandlers: Record<string, RpcHandler>;
  readonly rpcCalls: { name: string; params: RpcParams }[] = [];

  constructor(
    seed: Record<string, Row[]> = {},
    rpc?: Record<string, RpcHandler>,
  ) {
    for (const [t, rows] of Object.entries(seed)) {
      this.tables.set(t, rows.map((r) => ({ ...r })));
    }
    this.rpcHandlers = { ...DEFAULT_RPC, ...(rpc ?? {}) };
  }

  table(name: string): Row[] {
    if (!this.tables.has(name)) this.tables.set(name, []);
    return this.tables.get(name)!;
  }

  replaceTable(name: string, rows: Row[]) {
    this.tables.set(name, rows);
  }

  from(table: string): MockQuery {
    return new MockQuery(this, table);
  }

  rpc(name: string, params: RpcParams): Promise<QueryResult> {
    this.rpcCalls.push({ name, params });
    const handler = this.rpcHandlers[name];
    if (!handler) {
      return Promise.resolve({
        data: null,
        error: { message: `unimplemented rpc: ${name}` },
      });
    }
    try {
      const out = handler(params ?? {}, this);
      if (
        typeof out === "object" && out !== null && "__error" in out
      ) {
        return Promise.resolve({
          data: null,
          error: {
            message: String((out as Record<string, unknown>).__error),
          },
        });
      }
      return Promise.resolve({ data: out ?? null, error: null });
    } catch (e) {
      return Promise.resolve({
        data: null,
        error: { message: errorMessage(e) },
      });
    }
  }
}

export function createMockDb(
  seed: Record<string, Row[]> = {},
  rpc?: Record<string, RpcHandler>,
): MockDb {
  return new MockDb(seed, rpc);
}

export { Q as quote };
