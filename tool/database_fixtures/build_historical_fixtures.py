#!/usr/bin/env python3
"""Build genuine historical SQLite fixtures for the Wholesale POS schema.

Stage 6.0 characterization tooling. This script is deterministic and may be
re-run; every fixture is rebuilt from the historical `local_database.dart`
DDL that is stored in git, never from the current v22 database with columns
removed.

Source of truth per fixture
---------------------------
v2   reconstructed from the v3 initial commit's `_onCreate`, with the
     `sales.payment_method` column removed. That column is the *only* change
     the v3 `_onUpgrade` performs for `oldVersion < 3`, and the v3 schema is
     the first committed schema, so this is an evidence-based reconstruction
     rather than an invention. See docs/architecture/database-migration-log.md.
v3   f644ceb (`_databaseVersion = 3`) `_onCreate`
v4   0d071dd (`_databaseVersion = 4`) `_onCreate`
v5   reconstructed: the v4 `_onCreate` plus the v5 upgrade DDL recorded in
     ea2dc36's `_onUpgrade` (`oldVersion < 5` block). No commit ever stamped
     `schemaVersion = 5`, so — like v2 — this is an evidence-based
     reconstruction, not a verbatim file.
v12  485c96e (`schemaVersion = 12`) `_onCreate`
v19  cc45662 (`schemaVersion = 19`) `_onCreate`
v20  0444604 (`schemaVersion = 20`) `_onCreate`
v21  e82123a (`schemaVersion = 21`) `_onCreate`
v22  a16d7dd (`schemaVersion = 22`) `_onCreate`

For v12 and later the historical `_onCreate` also calls
`_createIndexesAndTriggers`, so that DDL is applied too. The fixtures are
populated with a fixed, representative data set and stamped with the correct
`PRAGMA user_version`.

Usage:
    python tool/database_fixtures/build_historical_fixtures.py
"""

from __future__ import annotations

import json
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DB_RELATIVE_PATH = "app/lib/core/database/local_database.dart"
OUTPUT_ROOT = REPO_ROOT / "frontend/test/fixtures/database"

# version -> (commit, provenance note)
FIXTURE_SOURCES = {
    2: (
        "f644ceb",
        "Reconstructed from the v3 initial commit `_onCreate` with "
        "`sales.payment_method` removed. The v3 `_onUpgrade` block for "
        "`oldVersion < 3` adds exactly that column, and it is the only "
        "difference between v2 and v3.",
    ),
    3: ("f644ceb", "Verbatim `_onCreate` of the first committed schema (v3)."),
    4: ("0d071dd", "Verbatim `_onCreate` of schema v4."),
    5: (
        "0d071dd",
        "Reconstructed: v4 `_onCreate` (0d071dd) plus the v5 upgrade DDL "
        "from ea2dc36's `_onUpgrade` `oldVersion < 5` block (void "
        "attribution columns, cash_movements.user_id, one_open_shift "
        "index, prevent_second_open_shift triggers, sales_shift_id "
        "index). No commit ever set schemaVersion = 5.",
    ),
    12: ("485c96e", "Verbatim `_onCreate` of schema v12."),
    19: ("cc45662", "Verbatim `_onCreate` of schema v19."),
    20: ("0444604", "Verbatim `_onCreate` of schema v20."),
    21: ("e82123a", "Verbatim `_onCreate` of schema v21."),
    22: ("a16d7dd", "Verbatim `_onCreate` of schema v22."),
}


# ---------------------------------------------------------------------------
# Dart source extraction
# ---------------------------------------------------------------------------


def _skip_string(text: str, i: int) -> int:
    """Return the index just past the Dart string literal starting at i."""
    quote = text[i]
    triple = text.startswith(quote * 3, i)
    if triple:
        end = text.find(quote * 3, i + 3)
        return len(text) if end == -1 else end + 3
    j = i + 1
    while j < len(text):
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == quote:
            return j + 1
        j += 1
    return len(text)


def _skip_comment(text: str, i: int) -> int:
    if text.startswith("//", i):
        end = text.find("\n", i)
        return len(text) if end == -1 else end + 1
    if text.startswith("/*", i):
        end = text.find("*/", i + 2)
        return len(text) if end == -1 else end + 2
    return i


def extract_function_body(source: str, name: str) -> str:
    marker = f"static Future<void> {name}("
    start = source.find(marker)
    if start == -1:
        raise SystemExit(f"function {name} not found")
    brace = source.find("{", start)
    depth = 0
    i = brace
    while i < len(source):
        c = source[i]
        if c in "'\"":
            i = _skip_string(source, i)
            continue
        if c == "/" and (source.startswith("//", i) or source.startswith("/*", i)):
            i = _skip_comment(source, i)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : i]
        i += 1
    raise SystemExit(f"unterminated function body for {name}")


def _extract_literals(arg: str) -> str:
    """Concatenate every Dart string literal in an argument expression."""
    pieces: list[str] = []
    i = 0
    while i < len(arg):
        c = arg[i]
        if c in "'\"":
            quote = c
            if arg.startswith(quote * 3, i):
                end = arg.find(quote * 3, i + 3)
                if end == -1:
                    raise SystemExit("unterminated triple-quoted literal")
                pieces.append(arg[i + 3 : end])
                i = end + 3
            else:
                j = i + 1
                buf: list[str] = []
                while j < len(arg):
                    if arg[j] == "\\":
                        buf.append(arg[j + 1] if j + 1 < len(arg) else "")
                        j += 2
                        continue
                    if arg[j] == quote:
                        break
                    buf.append(arg[j])
                    j += 1
                pieces.append("".join(buf))
                i = j + 1
            continue
        i += 1
    return "".join(pieces)


def extract_execute_sql(body: str) -> list[str]:
    """Return the SQL of every execute(...) call in a function body."""
    statements: list[str] = []
    i = 0
    while i < len(body):
        c = body[i]
        if c in "'\"":
            i = _skip_string(body, i)
            continue
        if c == "/" and (body.startswith("//", i) or body.startswith("/*", i)):
            i = _skip_comment(body, i)
            continue
        if body.startswith("execute(", i):
            open_paren = i + len("execute")
            j = open_paren + 1
            depth = 1
            while j < len(body) and depth > 0:
                ch = body[j]
                if ch in "'\"":
                    j = _skip_string(body, j)
                    continue
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                j += 1
            arg = body[open_paren + 1 : j - 1]
            sql = _extract_literals(arg).strip()
            if sql:
                statements.append(sql)
            i = j
            continue
        i += 1
    return statements


def collect_function_sql(
    source: str, name: str, seen: set[str] | None = None
) -> list[str]:
    """Collect SQL from a function and any `helper(db)` it calls.

    The historical `_onCreate`/`_createIndexesAndTriggers` bodies delegate part
    of their DDL to other private helpers (for example
    `_createShiftCashierGuards`), so a shallow extraction would miss genuine
    indexes and triggers.
    """
    seen = set() if seen is None else seen
    if name in seen:
        return []
    seen.add(name)
    body = extract_function_body(source, name)
    statements = extract_execute_sql(body)
    for helper in re.findall(r"\b(_[A-Za-z0-9_]+)\(db\)", body):
        if helper == name:
            continue
        if f"static Future<void> {helper}(" not in source:
            continue
        statements.extend(collect_function_sql(source, helper, seen))
    return statements


def git_show(commit: str) -> str:
    result = subprocess.run(
        ["git", "show", f"{commit}:{DB_RELATIVE_PATH}"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"git show {commit}:{DB_RELATIVE_PATH} failed: {result.stderr}"
        )
    return result.stdout


# ---------------------------------------------------------------------------
# Representative historical data
# ---------------------------------------------------------------------------

USERS = [
    {
        "id": "U-owner",
        "username": "owner",
        "password_hash": "pbkdf2-sha256$owner",
        "salt": "salt-owner",
        "cloud_pw_hash": None,
        "cloud_pw_salt": None,
        "role": "OWNER",
        "is_active": 1,
        "permissions": "[]",
        "is_demo": 0,
        "deleted_at": None,
        "created_at": "2024-01-01T08:00:00.000Z",
        "updated_at": "2024-01-01T08:00:00.000Z",
    },
    {
        "id": "U-cashier",
        "username": "cashier",
        "password_hash": "pbkdf2-sha256$cashier",
        "salt": "salt-cashier",
        "cloud_pw_hash": None,
        "cloud_pw_salt": None,
        "role": "CASHIER",
        "is_active": 1,
        "permissions": '["pos","register","reports"]',
        "is_demo": 0,
        "deleted_at": None,
        "created_at": "2024-01-02T08:00:00.000Z",
        "updated_at": "2024-01-02T08:00:00.000Z",
    },
]

PRODUCTS = [
    {
        "id": "P-sugar",
        "name": "Sugar 1kg",
        "code": "SKU-001",
        "category": "Grocery",
        "unit": "kg",
        "selling_price_minor_units": 12000,
        "is_active": 1,
        "created_at": "2024-01-01T08:00:00.000Z",
        "updated_at": "2024-01-01T08:00:00.000Z",
    },
    {
        "id": "P-soap",
        "name": "Soap Bar",
        "code": "SKU-002",
        "category": "Household",
        "unit": "pcs",
        "selling_price_minor_units": 3500,
        "is_active": 0,
        "created_at": "2024-01-01T08:05:00.000Z",
        "updated_at": "2024-02-01T09:00:00.000Z",
    },
]

DEVICES = [
    {
        "id": "D-till-1",
        "name": "Till 1 Register",
        "platform": "windows",
        "license_key": "LEGACY-DEVICE-LICENSE",
        "last_sync_at": "2024-02-02T18:00:00.000Z",
    }
]

SHIFTS = [
    {
        "id": "S-closed",
        "cashier_id": "U-cashier",
        "opening_cash_minor_units": 40000,
        "closing_cash_minor_units": 90000,
        "expected_cash_minor_units": 88000,
        "status": "CLOSED",
        "opened_at": "2024-02-01T08:00:00.000Z",
        "closed_at": "2024-02-01T18:00:00.000Z",
    },
    {
        "id": "S-open",
        "cashier_id": "U-cashier",
        "opening_cash_minor_units": 50000,
        "closing_cash_minor_units": None,
        "expected_cash_minor_units": None,
        "status": "OPEN",
        "opened_at": "2024-02-02T08:00:00.000Z",
        "closed_at": None,
    },
]

SALES = [
    {
        "id": "SALE-1",
        "receipt_number": "R-1001",
        "cashier_id": "U-cashier",
        "device_id": "D-till-1",
        "shift_id": "S-closed",
        "customer_name": "Walk-in",
        "payment_method": "CASH",
        "subtotal_minor_units": 24000,
        "discount_minor_units": 0,
        "total_minor_units": 24000,
        "amount_paid_minor_units": 25000,
        "change_minor_units": 1000,
        "status": "COMPLETED",
        "void_reason": None,
        "voided_at": None,
        "voided_by": None,
        "voided_shift_id": None,
        "created_at": "2024-02-01T10:00:00.000Z",
        "synced_at": "2024-02-01T10:01:00.000Z",
    },
    {
        "id": "SALE-2",
        "receipt_number": "R-1002",
        "cashier_id": "U-cashier",
        "device_id": "D-till-1",
        "shift_id": "S-closed",
        "customer_name": "Abebe",
        "payment_method": "BANK",
        "subtotal_minor_units": 3500,
        "discount_minor_units": 0,
        "total_minor_units": 3500,
        "amount_paid_minor_units": 3500,
        "change_minor_units": 0,
        "status": "VOIDED",
        "void_reason": "Customer changed mind",
        "voided_at": "2024-02-01T11:00:00.000Z",
        "voided_by": "U-owner",
        "voided_shift_id": "S-closed",
        "created_at": "2024-02-01T10:30:00.000Z",
        "synced_at": None,
    },
]

SALE_ITEMS = [
    {
        "id": "ITEM-1",
        "sale_id": "SALE-1",
        "product_id": "P-sugar",
        "product_name_snapshot": "Sugar 1kg",
        "unit_price_snapshot_minor_units": 12000,
        "quantity": 2,
        "quantity_text": "2",
        "billing_quantity_milliunits": 2000,
        "line_discount_minor_units": 0,
        "line_total_minor_units": 24000,
        "notes": None,
    },
    {
        "id": "ITEM-2",
        "sale_id": "SALE-2",
        "product_id": "P-soap",
        "product_name_snapshot": "Soap Bar",
        "unit_price_snapshot_minor_units": 3500,
        "quantity": 1,
        "quantity_text": "1 box",
        "billing_quantity_milliunits": 1000,
        "line_discount_minor_units": 0,
        "line_total_minor_units": 3500,
        "notes": "historic descriptive quantity",
    },
]

AUDIT_LOGS = [
    {
        "id": "A-1",
        "user_id": "U-cashier",
        "action": "SALE_CREATED",
        "details": '{"sale_id":"SALE-1"}',
        "created_at": "2024-02-01T10:00:01.000Z",
    },
    {
        "id": "A-2",
        "user_id": "U-owner",
        "action": "SALE_VOIDED",
        "details": '{"sale_id":"SALE-2"}',
        "created_at": "2024-02-01T11:00:01.000Z",
    },
]

CASH_MOVEMENTS = [
    {
        "id": "CM-1",
        "shift_id": "S-open",
        "type": "DEPOSIT",
        "amount_minor_units": 10000,
        "reason": "Float top-up",
        "created_at": "2024-02-02T09:00:00.000Z",
        "user_id": "U-cashier",
        "photo": None,
        "source_finance_entry_id": None,
    },
    {
        "id": "CM-2",
        "shift_id": "S-open",
        "type": "EXPENSE",
        "amount_minor_units": 2500,
        "reason": "Cleaning supplies",
        "created_at": "2024-02-02T09:30:00.000Z",
        "user_id": "U-owner",
        "photo": None,
        "source_finance_entry_id": "FE-2",
    },
]

CASH_MOVEMENT_PHOTOS = [
    {
        "movement_id": "CM-2",
        "jpeg_bytes": b"\xff\xd8\xff\xe0historic-jpeg",
        "created_at": "2024-02-02T09:30:00.000Z",
    }
]

FINANCE_CATEGORIES = [
    {
        "id": "FC-1",
        "name": "Rent",
        "created_at": "2024-01-01T08:00:00.000Z",
        "updated_at": "2024-01-01T08:00:00.000Z",
        "deleted_at": None,
    },
    {
        "id": "FC-2",
        "name": "Old Supplier",
        "created_at": "2024-01-01T08:00:00.000Z",
        "updated_at": "2024-01-01T08:00:00.000Z",
        "deleted_at": "2024-02-01T00:00:00.000Z",
    },
]

FINANCE_ENTRIES = [
    {
        "id": "FE-1",
        "category_id": "FC-1",
        "source": "Cash drawer",
        "amount_minor_units": 100000,
        "description": "February rent",
        "status": "PENDING",
        "entry_date": "2024-02-01",
        "created_at": "2024-02-01T08:00:00.000Z",
        "created_by": "U-owner",
        "completed_at": None,
        "completed_by": None,
        "updated_at": "2024-02-01T08:00:00.000Z",
        "payment_method": None,
    },
    {
        "id": "FE-2",
        "category_id": "FC-2",
        "source": "Bank transfer",
        "amount_minor_units": 2500,
        "description": "Paid supplier",
        "status": "COMPLETED",
        "entry_date": "2024-02-02",
        "created_at": "2024-02-02T08:00:00.000Z",
        "created_by": "U-owner",
        "completed_at": "2024-02-02T09:30:00.000Z",
        "completed_by": "U-owner",
        "updated_at": "2024-02-02T09:30:00.000Z",
        "payment_method": "CASH",
    },
]

VOID_REQUESTS = [
    {
        "id": "VR-1",
        "sale_id": "SALE-2",
        "requested_by": "U-cashier",
        "reason": "Customer changed mind",
        "status": "APPROVED",
        "created_at": "2024-02-01T10:40:00.000Z",
        "decided_by": "U-owner",
        "decided_at": "2024-02-01T10:55:00.000Z",
    }
]

SYNC_OUTBOX = [
    {
        "id": "OB-1",
        "entity_type": "sale",
        "entity_id": "SALE-1",
        "operation": "CREATE",
        "payload": '{"id":"SALE-1"}',
        "created_at": "2024-02-01T10:00:02.000Z",
        "synced_at": "2024-02-01T10:01:00.000Z",
    },
    {
        "id": "OB-2",
        "entity_type": "finance_entry",
        "entity_id": "FE-2",
        "operation": "UPDATE",
        "payload": '{"id":"FE-2","status":"COMPLETED"}',
        "created_at": "2024-02-02T09:30:01.000Z",
        "synced_at": None,
    },
]

PICKLISTS = [
    {
        "id": "PL-1",
        "customer_name": "Acme Traders",
        "status": "PENDING",
        "created_by": "U-owner",
        "created_at": "2024-02-03T08:00:00.000Z",
        "updated_at": "2024-02-03T08:00:00.000Z",
        "deleted_at": None,
    }
]

PICKLIST_ITEMS = [
    {
        "id": "PLI-1",
        "picklist_id": "PL-1",
        "product_name": "Sugar 1kg",
        "requested_qty": 5,
        "taken_qty": 2,
        "unit": "kg",
        "unit_price_minor_units": 12000,
        "line_total_minor_units": 24000,
        "updated_at": "2024-02-03T09:00:00.000Z",
        "deleted_at": None,
    }
]

PICKLIST_CUSTOMERS = [
    {
        "id": "PC-1",
        "name": "Acme Traders",
        "phone": "+251900000000",
        "created_at": "2024-02-03T08:00:00.000Z",
    }
]

COUNTERS = [{"name": "receipt_number", "value": 1002}]

SETTINGS = [
    {"key": "theme_mode", "value": "dark"},
    {"key": "remember_login", "value": "true"},
    {"key": "license_code", "value": "LEGACY-LICENSE-CODE"},
    {"key": "legacy_probe", "value": "preserved-through-migration"},
]


def rows_for(version: int) -> dict[str, list[dict]]:
    """Return the data set a fixture of `version` can carry.

    Rows are written with every key; the writer filters to the columns the
    historical table actually has, so this single set works for every version.
    """
    data: dict[str, list[dict]] = {
        "users": USERS,
        "products": PRODUCTS,
        "devices": DEVICES,
        "shifts": SHIFTS,
        "sales": SALES,
        "sale_items": SALE_ITEMS,
        "audit_logs": AUDIT_LOGS,
        "counters": COUNTERS,
        "settings": SETTINGS,
        "sync_outbox": SYNC_OUTBOX,
        "finance_categories": FINANCE_CATEGORIES,
        "finance_entries": FINANCE_ENTRIES,
        "void_requests": VOID_REQUESTS,
        "cash_movements": CASH_MOVEMENTS,
        "cash_movement_photos": CASH_MOVEMENT_PHOTOS,
        "picklists": PICKLISTS,
        "picklist_items": PICKLIST_ITEMS,
        "picklist_customers": PICKLIST_CUSTOMERS,
    }
    return data


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table,),
    ).fetchone()
    return row is not None


def insert_rows(conn: sqlite3.Connection, table: str, rows: list[dict]) -> None:
    if not table_exists(conn, table):
        return
    columns = table_columns(conn, table)
    for row in rows:
        usable = [key for key in row if key in columns]
        sql = (
            f"INSERT INTO {table} ({', '.join(usable)}) "
            f"VALUES ({', '.join('?' for _ in usable)})"
        )
        conn.execute(sql, [row[key] for key in usable])


# The v5 schema was never committed as an `_onCreate`: the release line went
# from `_databaseVersion = 4` (0d071dd) straight to `schemaVersion = 6`
# (ea2dc36). A v5-stamped database is what the `oldVersion < 5` upgrade block
# in ea2dc36 produces on top of the v4 schema, so the fixture applies exactly
# those statements after the v4 `_onCreate`. The representative data set has
# a single OPEN shift, so `one_open_shift` is created — matching what the
# historical block did when it found at most one open shift.
V5_POST_DDL = [
    "ALTER TABLE sales ADD COLUMN voided_at TEXT",
    "ALTER TABLE sales ADD COLUMN voided_by TEXT",
    "ALTER TABLE sales ADD COLUMN voided_shift_id TEXT",
    "ALTER TABLE cash_movements ADD COLUMN user_id TEXT",
    "CREATE UNIQUE INDEX one_open_shift ON shifts(status) "
    "WHERE status = 'OPEN'",
    """
        CREATE TRIGGER prevent_second_open_shift_insert
        BEFORE INSERT ON shifts WHEN NEW.status = 'OPEN'
        AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN')
        BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
    """,
    """
        CREATE TRIGGER prevent_second_open_shift_update
        BEFORE UPDATE OF status ON shifts WHEN NEW.status = 'OPEN'
        AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN' AND id != NEW.id)
        BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
    """,
    "CREATE INDEX sales_shift_id ON sales(shift_id)",
]


def build_fixture(version: int, commit: str) -> Path:
    source = git_show(commit)
    statements = collect_function_sql(source, "_onCreate")

    if version == 2:
        # v2 predates the first commit. The v3 migration declares the only
        # difference: sales.payment_method. Build the v3 schema, then drop it.
        statements.append("ALTER TABLE sales DROP COLUMN payment_method")

    tmp_dir = Path(tempfile.mkdtemp(prefix=f"wholesale_pos_v{version}_"))
    db_path = tmp_dir / "wholesale_pos.db"
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        for sql in statements:
            conn.execute(sql)
        if version == 5:
            # Apply the v4 -> v5 upgrade DDL *before* seeding so the new
            # columns (sales.voided_*, cash_movements.user_id) receive the
            # representative values a real v5 till would have written.
            for sql in V5_POST_DDL:
                conn.execute(sql)
        for table, rows in rows_for(version).items():
            insert_rows(conn, table, rows)
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()

        violations = list(conn.execute("PRAGMA foreign_key_check"))
        if violations:
            raise SystemExit(
                f"v{version} fixture has foreign-key violations: {violations}"
            )
        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise SystemExit(f"v{version} fixture failed integrity_check: {integrity}")
    finally:
        conn.close()

    target_dir = OUTPUT_ROOT / f"v{version}"
    target_dir.mkdir(parents=True, exist_ok=True)
    target_path = target_dir / "wholesale_pos.db"
    shutil.copyfile(db_path, target_path)
    shutil.rmtree(tmp_dir, ignore_errors=True)

    meta = {
        "schema_version": version,
        "source_commit": commit,
        "source_path": DB_RELATIVE_PATH,
        "provenance": FIXTURE_SOURCES[version][1],
        "tables": sorted(
            row[0]
            for row in sqlite3.connect(target_path).execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' "
                "AND name NOT LIKE 'sqlite_%'"
            )
        ),
    }
    (target_dir / "fixture.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )
    return target_path


def main() -> int:
    missing = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if missing.returncode != 0:
        print("error: must be run inside the repository", file=sys.stderr)
        return 1

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    for version in sorted(FIXTURE_SOURCES):
        commit, _ = FIXTURE_SOURCES[version]
        path = build_fixture(version, commit)
        size = path.stat().st_size
        print(f"built v{version:<2} from {commit} -> {path} ({size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
