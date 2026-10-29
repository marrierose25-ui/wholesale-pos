/// SQL fragments that every report query shares.
///
/// The training account exists to be practised on: a cashier rings up imaginary
/// money all day and none of it belongs to the shop. The outbox now refuses to
/// queue that money (see `SyncOutbox._ledgerOwners`), but rows written before
/// the guard existed are still sitting in this till's SQLite and were still
/// pushed by tills running an older build — so each report has to leave them out
/// by hand. Without this a demo shift's fake takings sit on the owner's
/// dashboard next to the real ones.
library;

/// Predicate that hides rows whose operator is the demo account.
///
/// [column] is the qualified column naming the cashier or owner —
/// `sales.cashier_id`, `cm.user_id`, `vr.requested_by`. `users.id` is the
/// primary key and never null, so a plain `NOT IN` subquery is safe here: an
/// empty demo set (the common case on a fresh till) excludes nothing.
String notDemoOperator(String column) =>
    '$column NOT IN (SELECT id FROM users WHERE is_demo = 1)';
