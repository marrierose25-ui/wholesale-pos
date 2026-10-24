import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/sync/supabase_sync_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_backend.dart';

/// Guards the safety rule for baked-in Supabase credentials: a phone build
/// refuses the secret key unless the operator explicitly opts in with the
/// UNSAFE_EMBED flag, so a distributable APK cannot accidentally ship live
/// credentials. Desktop behaviour is unchanged.
void main() {
  const url = 'https://example.supabase.co';
  const key = 'sb_secret_test';

  group('selectBackend', () {
    test('missing url or key -> Noop (offline release), any platform', () {
      expect(
        SupabaseSyncBackend.selectBackend(
          url: '',
          key: key,
          unsafeAllowEmbed: false,
          isMobile: false,
        ),
        isA<NoopSyncBackend>(),
      );
      expect(
        SupabaseSyncBackend.selectBackend(
          url: url,
          key: '',
          unsafeAllowEmbed: true,
          isMobile: true,
        ),
        isA<NoopSyncBackend>(),
      );
    });

    test('desktop with keys -> live backend (unchanged behaviour)', () {
      final backend = SupabaseSyncBackend.selectBackend(
        url: url,
        key: key,
        unsafeAllowEmbed: false,
        isMobile: false,
      );
      expect(backend, isA<SupabaseSyncBackend>());
      expect(backend.isConfigured, isTrue);
    });

    test('phone with keys but no opt-in flag -> Noop (safe default)', () {
      final backend = SupabaseSyncBackend.selectBackend(
        url: url,
        key: key,
        unsafeAllowEmbed: false,
        isMobile: true,
      );
      expect(backend, isA<NoopSyncBackend>());
      expect(backend.isConfigured, isFalse);
    });

    test('phone with keys AND opt-in flag -> live (private-use path)', () {
      final backend = SupabaseSyncBackend.selectBackend(
        url: url,
        key: key,
        unsafeAllowEmbed: true,
        isMobile: true,
      );
      expect(backend, isA<SupabaseSyncBackend>());
      expect(backend.isConfigured, isTrue);
    });
  });
}
