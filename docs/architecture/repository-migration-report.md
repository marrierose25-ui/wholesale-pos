# Stage 4 — Repository Responsibility Separation: Migration Report

## Statement on business logic

**No existing business logic was modified.** Every moved method body is
verbatim (SQL strings, filters, demo-operator exclusions, permission gates,
aggregation, rounding, API action names and payload shapes, response key
mapping). The only code changes are: method relocation, a shared
`requireFeature` guard extracted verbatim from `SqfliteSaleRepository`,
thin delegation overrides, constructor wiring, and two test fakes gaining a
`reporting` stub.

## What was extracted

- `core/repositories/reporting_repository.dart` — `ReportingRepository`
  contract + `SqfliteReportingRepository` with the six reporting methods
  moved verbatim from `SqfliteSaleRepository`.
- `core/cloud/cloud_reporting_repository.dart` — `CloudReportingRepository`
  with the same six methods moved verbatim from `CloudSaleRepository`.
- `core/repositories/feature_gate.dart` — `requireFeature`, the permission
  gate previously private to `SqfliteSaleRepository`, now shared with the
  reporting repository (identical body).

## What was deliberately NOT split

- ShiftRepository — expected-cash math, movements, photos and outbox share
  transactions; cohesive.
- UserRepository — credential hashing is coupled to credential-migration
  writes and login-guard persistence; postponed (see responsibility map).
- FinanceRepository — category and entry ops share transaction helpers,
  audit and register-movement writes; splitting would fragment atomic units.
- PicklistRepository, ProductRepository — already cohesive.

## Compatibility façades

`SaleRepository` retains the six reporting signatures; `SqfliteSaleRepository`
and `CloudSaleRepository` delegate to the reporting repositories. Screens
(dashboard, reports, audit, sales) and ~15 test call sites are unchanged.
`AppBackend.reporting` is the preferred contract for new consumers; façade
removal is scheduled for the consumer-migration stage.

## Transactions / infra

No schema, migration, trigger, constraint, sync entity/payload, outbox,
API action, receipt, license or JWT change. `saveSale`+outbox,
finance completion+movement, deletion+reversal, shift ops and void ops keep
their exact transaction boundaries (untouched files).

## Verification

See migration-log.md for the final test/build results of this stage.
