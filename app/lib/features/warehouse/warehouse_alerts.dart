import 'package:audioplayers/audioplayers.dart';

/// The short chime the warehouse queue plays when the shop sends a new list.
///
/// Kept as one lazily-created player so repeated alerts never stack players or
/// leak native handles. Every failure (autoplay blocked before the first tap,
/// a device without an audio output, a test host with no plugin) is swallowed:
/// the sound is a convenience, and the in-app notification must still appear.
class WarehouseAlerts {
  WarehouseAlerts._();

  static AudioPlayer? _player;

  static Future<void> playNewList() async {
    try {
      final player = _player ??= AudioPlayer();
      await player.stop();
      await player.play(AssetSource(kNewListSound), volume: 0.85);
    } catch (_) {
      // Visual notification is the source of truth; sound is best-effort.
    }
  }
}

/// Path inside `assets/`, as expected by [AssetSource].
const String kNewListSound = 'sounds/warehouse_alert.wav';
