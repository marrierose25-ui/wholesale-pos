# Feature Development

Authoritative source: `docs/architecture/feature-ownership.md` (table ownership
map, feature-gate matrix, owner-only actions) and
`docs/architecture/architecture-rules.md`. This file summarizes.

## Ownership

- Every feature lives under `frontend/lib/features/<feature>/` and depends on
  repositories/contracts — never on another feature's internals or on raw
  `Database` handles in widgets.
- Domain types come from `pos_core`; repository interfaces from
  `pos_contracts`; concrete implementations are injected via `AppBackend`.
- Server-side feature authorization is per-action in the Edge Functions;
  client-side feature gates use `core/auth/features.dart` (`FeatureDef`,
  `kFeatures`). Do not change permission semantics without updating both.

## Contract-first workflow

1. Define/extend the contract in `pos_contracts` (or `pos_core` for pure
   domain types) before implementing.
2. Implement against the contract; keep platform specifics in the correct
   engine package.
3. Wire through `AppBackend` (frontend seam) so native and web shells share
   the feature.

## Completion rule

No feature is complete until it is: owned by the correct module, tested,
secured (permissions + tenant isolation), integrated on both native and web
surfaces where applicable, and documented (`feature-ownership.md`,
`docs/DATABASE.md`, API docs as affected).

## Protected areas

Do not modify without explicit authorization: sync semantics, licensing,
schema/migrations, production business logic, UI layout/styling of shipped
screens, and the duplicated shell implementations in `main.dart` /
`app_shell.dart`.
