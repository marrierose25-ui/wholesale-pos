# Final Architecture Overview — Wholesale POS

**Date:** 2026-11-21
**Version:** Stage 10 completion (FINAL ARCHITECTURE ENFORCEMENT, VERIFICATION AND DOCUMENTATION)
**Scope:** Unified view of the entire Wholesale POS architecture across all repositories and platforms.

---

## 1. Full Repository Architecture

```mermaid
graph TD
    subgraph "Repository"
        direction TB
        
        subgraph "app/ [Flutter Application]"
            direction TB
            A_MAIN[main.dart<br/>Native entry ~512 lines]
            A_MAIN_WEB[main_web.dart<br/>PWA entry ~55 lines]
            A_SHELL[app_shell.dart<br/>Shared shell ~1026 lines]
            A_FEATURES[features/<br/>UI screens]
            A_CORE[core/<br/>Auth, sync, themes]
        end
        
        subgraph "backend/dart/ [Dart Packages]"
            direction TB
            
            subgraph "pos_core [Pure Dart Entities]"
                C_ENTITIES[Domain entities<br/>Sale, Product, User, etc.]
            end
            
            subgraph "pos_contracts [Interfaces]"
                C_CONTRACTS[AppBackend interface<br/>Repository contracts]
            end
            
            subgraph "pos_local_engine [SQLite Implementation]"
                L_DB[LocalDatabase v22]
                L_REPOS[SQLite repos<br/>SqfliteSaleRepository,<br/>SqfliteShiftRepository, etc.]
            end
            
            subgraph "pos_cloud_engine [HTTP Implementation]"
                C_CLIENTS[Cloud API clients]
                C_REPOS[Cloud repos<br/>CloudSaleRepository, etc.]
            end
        end
        
        subgraph "supabase/functions/ [Edge Functions]"
            direction TB
            S_API[pos-api/index.ts<br/>Router 434 lines]
            S_MODULES[28 module files<br/>auth, catalog, sales,<br/>register, finance,<br/>warehouse, reporting,<br/>users]
            LICENSING[licensing/Ed25519<br/>license verification]
        end
        
        subgraph "supabase/migrations/ [Schema]"
            MIGS[10 migration files<br/>Latest: 20261111000000]
        end
    end
    
    %% Dependencies
    A_MAIN --> A_SHELL
    A_MAIN_WEB --> A_SHELL
    A_SHELL --> A_FEATURES
    A_SHELL --> A_CORE
    A_SHELL --> C_CONTRACTS
    
    A_MAIN --> L_REPOS
    A_MAIN --> L_DB
    
    A_MAIN_WEB --> S_API
    
    C_CONTRACTS <--> C_ENTITIES
    L_REPOS --> C_CONTRACTS
    L_REPOS --> L_DB
    L_REPOS --> C_ENTITIES
    C_REPOS --> C_CONTRACTS
    C_REPOS --> C_ENTITIES
    
    S_API --> S_MODULES
    S_API --> LICENSING
    S_MODULES --> MIGS
    
    A_CORE --> C_CONTRACTS
    A_FEATURES --> C_CONTRACTS
    A_FEATURES --> C_ENTITIES
```

### Key Repository Modules

| Module | Purpose | Location |
| -------- | --------- | ---------- |
| **pos_core** | Pure Dart domain entities | `backend/dart/pos_core/` |
| **pos_contracts** | Abstract interfaces and contracts | `backend/dart/pos_contracts/` |
| **pos_local_engine** | SQLite implementations | `backend/dart/pos_local_engine/` |
| **pos_cloud_engine** | HTTP clients and cloud repos | `backend/dart/pos_cloud_engine/` |
| **pos-api** | Supabase Edge Functions | `supabase/functions/pos-api/` |
| **licensing** | Ed25519 license verification | `supabase/functions/licensing/` |

---

## 2. Native App Dependency Flow

```mermaid
graph LR
    A[main.dart<br/>Native entry] --> B[NativeBackend<br/>SQLite repos]
    B --> C[pos_local_engine<br/>Sqflite repositories]
    C --> D[pos_contracts<br/>AppBackend interface]
    C --> E[pos_core<br/>Domain entities]
    D --> F[pos_contracts<br/>Contracts]
    E --> F
    
    B --> G[LocalDatabase<br/>Schema v22]
    C --> G
    
    H[Sqflite] --> C
    I[path_provider] --> G
    J[device_info_plus] --> K[device_activation]
    
    style A fill:#e1f5fe
    style B fill:#f3e5f5
    style C fill:#e8f5e8
    style D fill:#fff3e0
    style E fill:#fce4ec
```

### Native Entry Point Flow

1. `main.dart` (~512 lines) initializes:
   - `LocalDatabase` (SQLite, schema v22)
   - Repository implementations from `pos_local_engine`
   - `NativeBackend` wrapping repositories
   - `WholesalePosApp` with `PosRoot` shell

2. **Key imports:** `sqflite`, `pos_local_engine`, `pos_contracts`, `app_shell.dart`

3. **No HTTP dependencies** — fully offline capable

---

## 3. Web App Dependency Flow

```mermaid
graph LR
    A[main_web.dart<br/>PWA entry] --> B[CloudBackend]
    B --> C[pos_cloud_engine<br/>HTTP clients]
    C --> D[pos_api index.ts<br/>Edge Function]
    C --> E[pos_contracts<br/>AppBackend interface]
    
    D --> F[supabase<br/>PostgreSQL]
    D --> G[Ed25519<br/>License verification]
    
    F --> H[10 migrations<br/>schema v22]
    
    style A fill:#e1f5fe
    style B fill:#f3e5f5
    style C fill:#e8f5e8
    style D fill:#fff3e0
    style F fill:#e1f5fe
```

### Web Entry Point Flow

1. `main_web.dart` (~55 lines) initializes:
   - `CloudApiClient` with activation code
   - `CloudBackend` wrapping HTTP repos
   - `PosRoot` shell with `WebActivationGate`

2. **Key imports:** `pos_cloud_engine`, `pos_contracts`, `app_shell.dart`

3. **All data access** goes through `pos-api` Edge Function via REST

---

## 4. Local Persistence (SQLite)

```mermaid
erDiagram
    %% Table definitions with primary keys and relationships
    USERS {
        TEXT id PK "UUID"
        TEXT username UK "PBKDF2 hash"
        TEXT password_hash 
        TEXT salt 
        TEXT role 
        INTEGER is_active 
        INTEGER is_demo 
        TEXT permissions 
    }
    
    PRODUCTS {
        TEXT id PK 
        TEXT code UK 
        TEXT name 
        INTEGER selling_price_minor_units 
        TEXT category 
    }
    
    DEVICES {
        TEXT id PK 
        TEXT name 
        TEXT platform 
        TEXT license_key 
        TEXT last_sync_at 
    }
    
    SHIFTS {
        TEXT id PK 
        TEXT cashier_id FK "users.id"
        INTEGER opening_cash_minor_units 
        INTEGER closing_cash_minor_units 
        INTEGER expected_cash_minor_units 
        TEXT status 
    }
    
    CASH_MOVEMENTS {
        TEXT id PK 
        TEXT shift_id FK "shifts.id"
        TEXT user_id FK "users.id"
        TEXT type 
        INTEGER amount_minor_units 
    }
    
    SALES {
        TEXT id PK 
        TEXT receipt_number UK 
        TEXT cashier_id FK "users.id"
        TEXT device_id FK "devices.id"
        TEXT shift_id FK "shifts.id"
        TEXT customer_name 
        TEXT payment_method 
        INTEGER subtotal_minor_units 
        INTEGER total_minor_units 
        INTEGER amount_paid_minor_units 
        INTEGER change_minor_units 
        TEXT status 
    }
    
    SALE_ITEMS {
        TEXT id PK 
        TEXT sale_id FK "sales.id" 
        TEXT product_id 
        INTEGER billing_quantity_milliunits 
        INTEGER line_total_minor_units 
    }
    
    FINANCE_CATEGORIES {
        TEXT id PK 
        TEXT name 
    }
    
    FINANCE_ENTRIES {
        TEXT id PK 
        TEXT category_id FK "finance_categories.id"
        INTEGER amount_minor_units 
        TEXT status 
    }
    
    PICKLISTS {
        TEXT id PK 
        TEXT name 
        TEXT status 
    }
    
    PICKLIST_ITEMS {
        TEXT id PK 
        TEXT picklist_id FK "picklists.id"
        INTEGER requested_qty 
        INTEGER taken_qty 
    }
    
    PICKLIST_CUSTOMERS {
        TEXT id PK 
        TEXT name 
    }
    
    VOID_REQUESTS {
        TEXT id PK 
        TEXT sale_id FK "sales.id"
        TEXT requested_by FK "users.id"
        TEXT reason 
        TEXT status 
    }
    
    AUDIT_LOGS {
        TEXT id PK 
        TEXT user_id 
        TEXT action 
        TEXT details 
    }
    
    COUNTERS {
        TEXT name PK 
        INTEGER value 
    }
    
    SETTINGS {
        TEXT key PK 
        TEXT value 
    }
    
    SYNC_OUTBOX {
        TEXT id PK 
        TEXT entity_type 
        TEXT entity_id 
        TEXT operation 
        TEXT payload 
        TEXT created_at 
        TEXT synced_at 
    }
    
    %% Relationships
    USERS ||--o{ SHIFTS : "creates"
    USERS ||--o{ SALES : "makes"
    USERS ||--o{ CASH_MOVEMENTS : "records"
    USERS ||--o{ VOID_REQUESTS : "requests"
    DEVICES ||--o{ SALES : "records on"
    SHIFTS ||--o{ SALES : "belongs to"
    SHIFTS ||--o{ CASH_MOVEMENTS : "tracks"
    SALES ||--o{ SALE_ITEMS : "contains"
    FINANCE_CATEGORIES ||--o{ FINANCE_ENTRIES : "categorizes"
    PICKLISTS ||--o{ PICKLIST_ITEMS : "contains"
    VOID_REQUESTS }|--|| SALES : "voids"

    %% Style the diagram
    classDef table fill:#f0f0f0,stroke:#333,stroke-width:1px;
    class USERS,PRODUCTS,DEVICES,SHIFTS,CASH_MOVEMENTS,SALES,SALE_ITEMS,FINANCE_CATEGORIES,FINANCE_ENTRIES,PICKLISTS,PICKLIST_ITEMS,PICKLIST_CUSTOMERS,VOID_REQUESTS,AUDIT_LOGS,COUNTERS,SETTINGS,SYNC_OUTBOX table;
```

### Local Database Schema v22

| Table | Purpose | Sync | Export |
| ------- | --------- | ------ | -------- |
| `users` | Auth, roles | ✅ | ✅ (strips pw_hash/salt) |
| `products` | Catalog | ✅ | ✅ |
| `devices` | Device identity | ✅ (id only) | ✅ |
| `shifts` | Register | ✅ | ✅ |
| `cash_movements` | Deposits/expenses | ✅ | ✅ |
| `sales` | Transactions | ✅ | ✅ |
| `sale_items` | Sale lines | ✅ | ✅ (cascades) |
| `finance_categories` | Money tracking | ✅ | ✅ |
| `finance_entries` | Money tracking | ✅ | ✅ |
| `picklists` | Warehouse | ✅ | ✅ |
| `picklist_items` | Warehouse | ✅ | ✅ |
| `picklist_customers` | Warehouse | ✅ | ✅ |
| `void_requests` | Void workflow | ✅ | ✅ |
| `audit_logs` | Audit trail | ✅ | ✅ |
| `counters` | Sequential IDs | ❌ | ❌ |
| `settings` | App settings | ❌ | Partial (5 keys stripped) |
| `sync_outbox` | Transactional queue | ✅ | ❌ (plumbing) |

---

## 5. Cloud Backend (Supabase)

```mermaid
graph TD
    subgraph "Supabase Cloud Backend"
        direction TB
        
        subgraph "pos-api Edge Function"
            ROUTER[index.ts<br/>Router 434 lines]
            MODS[28 module files<br/>modules/*]
        end
        
        subgraph "Database"
            DB[(PostgreSQL<br/>10 migrations)]
            MIGS[Migrations]
            RPC[Stored Procedures<br/>pos_* functions]
            VIEWS[Views]
            TRIGGERS[Triggers]
        end
        
        subgraph "Licensing Function"
            LIC[licensing/index.ts<br/>Ed25519 verify]
        end
        
        subgraph "Tables by Module"
            USERS[users<br/>pos_users]
            PRODUCTS[products<br/>pos_products]
            SALES[sales<br/>sale_items]
            SHIFTS[shifts]
            CASH[cash_movements]
            FINANCE[finance_categories<br/>finance_entries]
            PICKLISTS[picklists<br/>picklist_items<br/>picklist_customers]
            AUDIT[audit_logs]
            SETTINGS[settings]
            OUTBOX[sync_outbox]
            CUSTOMERS[customers<br/>licenses<br/>device_registrations]
        end
    end
    
    CLIENT[Client Apps] --> ROUTER
    ROUTER --> MODS
    ROUTER --> DB
    LIC --> DB
    MIGS --> DB
    RPC --> DB
    VIEWS --> DB
    TRIGGERS --> DB
    DB --> USERS
    DB --> PRODUCTS
    DB --> SALES
    DB --> SHIFTS
    DB --> CASH
    DB --> FINANCE
    DB --> PICKLISTS
    DB --> AUDIT
    DB --> SETTINGS
    DB --> OUTBOX
    DB --> CUSTOMERS
    
    style ROUTER fill:#fff3e0
    style LIC fill:#f3e5f5
    style DB fill:#e1f5fe
    style MIGS fill:#e8f5e8
```

### Supabase Architecture

**Edge Functions:** Two functions deployed

- `pos-api`: Primary API handler (router + 28 modules)
- `licensing`: Ed25519 license verification

**Database:** Postgres with Supabase extensions

- Schema managed via `supabase/migrations/` (10 files, v22)
- Row Level Security (RLS) enabled
- Service role bypasses RLS for edge functions

**Sync Gateway:** `sync/index.ts` (Phase 18)

- Authenticates via Ed25519 license
- Idempotent push via outbox
- Tenant isolation via `customer_id`

---

## 6. Synchronization Architecture

```mermaid
sequenceDiagram
    participant Native as Native App<br/>SQLite
    participant Outbox as sync_outbox<br/>(transactional)
    participant Gateway as Sync Gateway<br/>(Edge Function)
    participant Cloud as Supabase<br/>PostgreSQL

    Note over Native,Outbox: 1. Business write in transaction
    
    Native->>Outbox: Enqueue change (same txn)
    Native->>Native: Commit transaction
    
    rect rgb(240, 248, 255)
        Note over Native,Outbox: 2. Background sync cycle
        loop Every 3-60s
            Native->>Outbox: poll pending()
            alt Has outbox rows
                Outbox->>Gateway: POST batch with JWT
                Gateway->>Cloud: Verify license<br/>Upsert rows
                Cloud->>Gateway: Return results
                Gateway->>Outbox: markSynced(ids)
            else Empty
                Outbox-->>Native: idle
            end
        end
    end
    
    rect rgb(248, 245, 255)
        Note over Gateway,Cloud: 3. Push API (client→gateway)
        Gateway->>Cloud: Upsert via RPC pos_*  
        Cloud->>Cloud: Enforce RLS<br/>Stamp customer_id
    end
    
    rect rgb(255, 243, 243)
        Note over Native,Cloud: 4. Pull API (gateway→client)
        Cloud->>Native: GET /sync/pull?customer_id=...
        Native->>Native: Reconcile received rows
        Native->>Outbox: enqueue CRUD changes
    end
```

### Sync Components

| Component | Location | Purpose |
| ------------- | ---------- | --------- |
| `SyncOutbox` | `frontend/lib/core/sync/` | Transactional queue |
| `SyncService` | `frontend/lib/core/sync/` | Background sync loop |
| `SyncPullApplier` | `pos_local_engine/` | Cloud→local reconciliation |
| `SyncGatewayBackend` | `pos_cloud_engine/` | HTTP push client |
| `SyncOutboxRepository` | `pos_local_engine/` | Queue management |

### Sync Invariant

Every business write enqueues to `sync_outbox` **in the same transaction**. This guarantees atomicity between business state and sync queue.

---

## 7. Supabase API Modules

```mermaid
graph TD
    subgraph "pos-api Module Structure"
        AUTH[modules/auth/]
        CATALOG[modules/catalog/]
        SALES[modules/sales/]
        REGISTER[modules/register/]
        FINANCE[modules/finance/]
        WAREHOUSE[modules/warehouse/]
        REPORTING[modules/reporting/]
        USERS[modules/users/]
        
        AUTH --> AUTH_IDX[(index.ts<br/>exports)]
        CATALOG --> AUTH_IDX
        SALES --> AUTH_IDX
        REGISTER --> AUTH_IDX
        FINANCE --> AUTH_IDX
        WAREHOUSE --> AUTH_IDX
        REPORTING --> AUTH_IDX
        USERS --> AUTH_IDX
    end
    
    subgraph "Index Routing"
        ROUTER[supabase/functions/pos-api/index.ts<br/>434 lines]
        ROUTER -->|switch action| AUTH_IDX
        ROUTER -->|switch action| CATALOG_IDX[catalog/index.ts]
        ROUTER -->|switch action| SALES_IDX[sales/index.ts]
        ROUTER -->|switch action| REGISTER_IDX[register/index.ts]
        ROUTER -->|switch action| FINANCE_IDX[finance/index.ts]
        ROUTER -->|switch action| WAREHOUSE_IDX[warehouse/index.ts]
        ROUTER -->|switch action| REPORTING_IDX[reporting/index.ts]
        ROUTER -->|switch action| USERS_IDX[users/index.ts]
    end
    
    AUTH_IDX --> AUTH
    CATALOG_IDX --> CATALOG
    SALES_IDX --> SALES
    REGISTER_IDX --> REGISTER
    FINANCE_IDX --> FINANCE
    WAREHOUSE_IDX --> WAREHOUSE
    REPORTING_IDX --> REPORTING
    USERS_IDX --> USERS
```

### API Modules

#### modules/auth/

- `login` - Authenticate user, return JWT
- `setup_owner` - Bootstrap owner account
- `has_users` - Check if tenant has users

#### modules/catalog/

- `list_products` - Product catalog
- `save_product` - Create/update product
- `update_product` - Partial update
- `setProductActive` - Activate/deactivate

#### modules/sales/

- `insert_sale` - Record sale
- `search_sales` - History search
- `next_receipt_number` - Get counter
- `voidSale` / `requestVoid` / `listVoidRequests` / `decideVoid` - Void workflow

#### modules/register/

- `openShift` / `closeShift` / `getActiveShift` / `ensureShift` - Shift management
- `addCashMovement` / `listCashMovements` - Cash tracking
- `registerSnapshot` / `shiftSummary` - Reporting

#### modules/finance/

- Category CRUD + recycle bin
- Entry CRUD + status lifecycle
- Financial summaries

#### modules/warehouse/

- Picklist CRUD
- Picklist item management
- Customer/supplier management
- Status derivation (`derivePicklistStatus`)

#### modules/reporting/

- `dashboardSummary` - KPIs
- `revenueTrend` - Time series
- `reportSummary` - Detailed report
- `listAudit` - Audit log

#### modules/users/

- User CRUD (OWNER_ONLY for mutations)
- Permission management
- Phone updates

---

## 8. Cross-Module Business Communication

```mermaid
graph LR
    subgraph "Core Domain Entities (pos_core)"
        SALE[Sale<br/>+SaleItem]
        SHIFT[Shift]
        PRODUCT[Product]
        USER[User]
        CASH[ CashMovement]
        FINANCE[ FinanceEntry<br/>FinanceCategory]
        PICKLIST[ Picklist<br/>+PicklistItem<br/>+PicklistCustomer]
        VOID[VoidRequest]
    end
    
    subgraph "Native Repositories (pos_local_engine)"
        SALE_REPO[SqfliteSaleRepository]
        SHIFT_REPO[SqfliteShiftRepository]
        PRODUCT_REPO[SqfliteProductRepository]
        USER_REPO[SqfliteUserRepository]
        FINANCE_REPO[SqfliteFinanceRepository]
        PICKLIST_REPO[SqflitePicklistRepository]
    end
    
    subgraph "Cloud Repositories (pos_cloud_engine)"
        CLOUD_SALE[CloudSaleRepository]
        CLOUD_SHIFT[CloudShiftRepository]
        CLOUD_PRODUCT[CloudProductRepository]
        CLOUD_USER[CloudUserRepository]
    end
    
    subgraph "Feature Screens (app/features)"
        POS_Screen[pos.dart]
        REGISTER_Screen[register.dart]
        PRODUCTS_Screen[products.dart]
        USERS_Screen[users.dart]
        FINANCE_Screen[finance.dart]
        WAREHOUSE_Screen[picklists.dart]
    end
    
    %% Repository relationships
    SALE_REPO --> SALE
    SALE_REPO --> SHIFT
    SALE_REPO --> USER
    SALE_REPO --> PRODUCT
    SHIFT_REPO --> SHIFT
    SHIFT_REPO --> USER
    SHIFT_REPO --> SALE
    FINANCE_REPO --> FINANCE
    PICKLIST_REPO --> PICKLIST
    
    %% Feature relationships
    POS_Screen --> SALE_REPO
    POS_Screen --> SHIFT_REPO
    POS_Screen --> USER_REPO
    REGISTER_Screen --> SHIFT_REPO
    PRODUCTS_Screen --> PRODUCT_REPO
    FINANCE_Screen --> FINANCE_REPO
    WAREHOUSE_Screen --> PICKLIST_REPO
    
    %% Cross-reference relationships
    SALE -.->|summarizes| SHIFT
    SALE -.->|financials| FINANCE
    SHIFT -.->|cash movements| CASH
    
    classDef entity fill:#fce4ec,stroke:#333
    classDef repo fill:#e8f5e8,stroke:#333
    classDef feature fill:#e1f5fe,stroke:#333
    class SALE,SHIFT,PRODUCT,USER,CASH,FINANCE,PICKLIST,VOID entity
    class SALE_REPO,SHIFT_REPO,PRODUCT_REPO,USER_REPO,FINANCE_REPO,PICKLIST_REPO repo
    class POS_Screen,REGISTER_Screen,PRODUCTS_Screen,USERS_Screen,FINANCE_Screen,WAREHOUSE_Screen feature
```

### Business Flow Patterns

**Sale Completion Flow:**

1. `insert_sale` (POS screen) → `SqfliteSaleRepository.saveSale()`
2. Creates sale row + sale_items in transaction
3. Enqueues `sync_outbox` entry
4. Cloud: `pos_create_sale` RPC applies with `customer_id` stamp

**Shift Close Flow:**

1. Cashier enters `closingCash`
2. `closeShift` computes `expectedCashMinorUnits`
3. Records `SHIFT_CLOSED` audit log
4. Enqueues shift for sync

**Void Request Flow:**

1. Cashier calls `requestVoid`
2. Creates `VOID_REQUEST` with `PENDING` status
3. Owner calls `approveVoid` or `rejectVoid`
4. `approveVoid` runs normal void (sale marked VOIDED)

**Finance Entry Flow:**

1. Create `FINANCE_ENTRY` with `PENDING` status
2. Call `markCompleted` moves to `COMPLETED`
3. Never affects revenue reports

**Picklist Status Derivation:**

- `PENDING`: no items taken
- `PARTIAL`: some items taken
- `COMPLETED`: all items fully taken
- Recalculated on every update via `derivePicklistStatus()`

---

## 9. Documentation Ecosystem (Stage 10)

```mermaid
graph LR
    subgraph "Architecture Docs"
        A1[overview]
        A2[rules]
        A3[integrity audit]
        A4[sync report]
        A5[commercial readiness]
        A6[verification history]
    end

    subgraph "User Guides"
        U1[Getting Started]
        U2[Owner Guide]
        U3[Cashier Guide]
        U4[Finance Guide]
        U5[Warehouse Guide]
        U6[Troubleshooting]
    end

    subgraph "API Reference"
        AP1[README]
        AP2[Auth API]
        AP3[pos-api endpoints]
        AP4[sync API]
        AP5[licensing API]
        AP6[error handling]
    end

    A1 --> A2
    A2 --> A3
    A3 --> A4
    A4 --> A5
    A5 --> A6

    U1 --> U2
    U2 --> U3
    U3 --> U4
    U4 --> U5
    U5 --> U6

    AP1 --> AP2
    AP2 --> AP3
    AP3 --> AP4
    AP4 --> AP5
    AP5 --> AP6
```

### Architecture Documents

| Document | Purpose |
| ---------- | --------- |
| `final-architecture-overview.md` | Unified view of all components, dependency flows, schema, sync, API modules |
| `architecture-rules.md` | Enforceable layering rules, sync invariants, security policies, verification checklist |
| `final-integrity-audit.md` | Deep-dive audit of schema v22, transaction sites, F-series known behaviors, commercial acceptance criteria |
| `synchronization-integrity-report.md` | Push/pull protocol detail, outbox enqueue points, conflict resolution, cross-device behavior |
| `commercial-readiness-report.md` | 9 quality gates evaluated, overall verdict (CONDITIONALLY COMMERCIAL READY), deployment risk table |
| `verification-history.md` | Exact test counts per stage, commands used, evidence trail across Stages 1–10 |

### User Guide Documents

| Document | Audience |
| ---------- | ---------- |
| `user-guide/README.md` | Index / quick-start pointer |
| `user-guide/getting-started.md` | Install, activate license, create owner account, import data |
| `user-guide/owner-guide.md` | Users, reports, sync config, licensing, backups |
| `user-guide/cashier-guide.md` | Shifts, sales, voids, shortcuts |
| `user-guide/finance-guide.md` | Categories, entries, reversals, reports |
| `user-guide/warehouse-guide.md` | Picklists, stock receiving, offline behavior |
| `user-guide/troubleshooting.md` | Connection issues, data restore, licensing, known behaviors |

### API Reference Documents

| Document | Content |
| ---------- | --------- |
| `api/README.md` | Base URL, request/response shape, auth header, rate limits |
| `api/authentication.md` | `login`, `setup_owner`, `has_users`, token revocation, password policy |
| `api/pos-api.md` | Full action inventory: 61 actions across 9 modules with auth requirements |
| `api/synchronization-api.md` | Outbox schema, push/pull endpoints, backoff algorithm, cursor keys, conflict resolution |
| `api/licensing-api.md` | Ed25519 activation flow, payload shape, seat management, transfer process |
| `api/error-handling.md` | Error codes, HTTP status mapping, retry strategies, null-safety convention |

---

## Appendix: Mermaid Diagram Index

| Diagram | File | Description |
| --------- | ------ | ------------- |
| 1. Full Repository Architecture | `final-architecture-overview.md` | All components and their relationships |
| 2. Native App Dependency Flow | `final-architecture-overview.md` | How native app initializes and depends |
| 3. Web App Dependency Flow | `final-architecture-overview.md` | How PWA initializes and depends |
| 4. Local Persistence | `final-architecture-overview.md` | SQLite schema ERD and table ownership |
| 5. Cloud Backend | `final-architecture-overview.md` | Supabase structure and Edge Functions |
| 6. Synchronization | `final-architecture-overview.md` | Sync-outbox pattern and sync cycles |
| 7. Supabase API Modules | `final-architecture-overview.md` | Modular API action organization |
| 8. Cross-Module Business Communication | `final-architecture-overview.md` | Entity relationships and flow patterns |
| 9. Documentation Ecosystem | `final-architecture-overview.md` | Stage 10 docs structure and interconnections |
