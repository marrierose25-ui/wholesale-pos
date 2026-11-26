import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static guard for the production deploy workflow (Request 3 §6).
///
/// `.github/workflows/deploy-web.yml` builds the SELECTED ref and publishes it
/// with `wrangler pages deploy --branch=main` — i.e. whatever a manual
/// `workflow_dispatch` picks lands on the production domain. These checks pin
/// the main-only contract so a future edit cannot silently reopen the hole:
/// the job must be gated on `refs/heads/main`, bound to the protected
/// `production` environment, and the push trigger must stay main-only.
void main() {
  final workflow = File(
    '../.github/workflows/deploy-web.yml',
  ).readAsStringSync();

  test('push trigger stays limited to main', () {
    expect(
      workflow.contains('branches: [main]'),
      isTrue,
      reason: 'deploy-web.yml must only auto-deploy pushes to main',
    );
  });

  test('deploy job is gated to refs/heads/main for every event', () {
    // The ref check must be the WHOLE condition: an `||` escape hatch for
    // push events would let a widened push trigger deploy a feature branch.
    expect(
      workflow.contains("if: github.ref == 'refs/heads/main'"),
      isTrue,
      reason:
          'the deploy job must require refs/heads/main unconditionally so a '
          'workflow_dispatch (or a future widened push trigger) on any other '
          'ref is skipped',
    );
    expect(
      workflow.contains("github.event_name == 'push'"),
      isFalse,
      reason:
          'no OR-condition may bypass the main-only ref check — a push from '
          'a non-main branch must never reach the production Pages deploy',
    );
  });

  test('deploy job binds the protected production environment', () {
    expect(
      // Accepts both `environment: production` and the object form
      // `environment:\n  name: production`.
      RegExp(
        r"environment:\s*(\{?\s*)?(name:\s*)?'?production'?",
      ).hasMatch(workflow),
      isTrue,
      reason:
          'the deploy job must route through the protected `production` '
          'environment so required reviewers can gate publication',
    );
  });

  test('production publish still targets the main Pages branch', () {
    expect(
      workflow.contains('--branch=main'),
      isTrue,
      reason: 'the wrangler deploy must keep publishing to --branch=main',
    );
  });
}
