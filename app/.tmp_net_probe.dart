// Temporary diagnostic: where does Dart's outbound HTTPS actually stall?
import 'dart:io';

Future<void> main(List<String> args) async {
  final uri = Uri.parse(
    args.isEmpty
        ? 'https://trcthxyyuapwavzeisvm.supabase.co/auth/v1/health'
        : args.first,
  );
  final sw = Stopwatch()..start();
  void log(String s) => stdout.writeln('${sw.elapsedMilliseconds}ms  $s');

  log('target ${uri.host}');
  try {
    final addrs = await InternetAddress.lookup(uri.host)
        .timeout(const Duration(seconds: 10));
    log('dns ok: ${addrs.map((a) => a.address).join(", ")}');
  } catch (e) {
    log('dns FAILED: ${e.runtimeType} $e');
    exit(1);
  }

  try {
    final socket = await Socket.connect(
      uri.host,
      443,
      timeout: const Duration(seconds: 10),
    );
    log('tcp 443 ok');
    socket.destroy();
  } catch (e) {
    log('tcp FAILED: ${e.runtimeType} $e');
    exit(1);
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    log('GET $uri');
    final req = await client.getUrl(uri);
    log('request object created');
    final res = await req.close();
    log('status ${res.statusCode}');
    await res.drain<void>();
    log('body drained');
  } catch (e, st) {
    log('http FAILED: ${e.runtimeType} $e');
    log(st.toString().split('\n').take(5).join(' | '));
  } finally {
    client.close(force: true);
  }
  exit(0);
}
