import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logger.dart';

/// A reference to a [NetworkChecker] instance.
final networkCheckerRef = create(NetworkChecker.new);

/// The [NetworkChecker] instance available in the current zone.
NetworkChecker get networkChecker => read(networkCheckerRef);

/// {@template network_checker_exception}
/// Thrown when a network check fails.
/// {@endtemplate}
class NetworkCheckerException implements Exception {
  /// {@macro network_checker_exception}
  const NetworkCheckerException(this.message);

  /// The message associated with the exception.
  final String message;
}

/// {@template network_checker}
/// Checks reachability of various Shorebird-related endpoints and logs the
/// results.
/// {@endtemplate}
class NetworkChecker {
  /// The URLs to check for network reachability.
  static final urlsToCheck = [
    'https://api.shorebird.dev',
    'https://console.shorebird.dev',
    'https://oauth2.googleapis.com',
    'https://storage.googleapis.com',
    'https://cdn.shorebird.cloud',
  ].map(Uri.parse).toList();

  /// Verify that each of [urlsToCheck] responds to an HTTP GET request.
  Future<void> checkReachability() async {
    for (final url in urlsToCheck) {
      final progress = logger.progress('Checking reachability of $url');

      try {
        await httpClient.get(url);
        progress.complete('$url OK');
      } catch (e) {
        progress.fail('$url unreachable');
        logger.detail('Failed to reach $url: $e');
      }
    }
  }

  /// Uploads a file to GCP to measure upload speed. Returns the upload rate
  /// in MB/s.
  Future<double> performGCPUploadSpeedTest({
    // If they can't upload the file in two minutes, we can just say it's slow.
    Duration uploadTimeout = const Duration(minutes: 2),
  }) async {
    // Test with a 5MB file.
    const uploadMBs = 5;
    const fileSize = uploadMBs * 1000 * 1000;

    final tempDir = Directory.systemTemp.createTempSync();
    final testFile = File(p.join(tempDir.path, 'speed_test_file'))
      ..writeAsBytesSync(ByteData(fileSize).buffer.asUint8List());
    try {
      final uri = await codePushClientWrapper.getGCPUploadSpeedTestUrl();
      final start = clock.now();
      final file = await http.MultipartFile.fromPath('file', testFile.path);
      final uploadRequest = http.MultipartRequest('POST', uri)..files.add(file);
      final uploadResponse = await httpClient.send(uploadRequest).timeout(
        uploadTimeout,
        onTimeout: () {
          throw const NetworkCheckerException('Upload timed out');
        },
      );
      if (uploadResponse.statusCode != HttpStatus.noContent) {
        final body = await uploadResponse.stream.bytesToString();
        throw NetworkCheckerException(
          'Failed to upload file: $body ${uploadResponse.statusCode}',
        );
      }

      final end = clock.now();
      return fileSize / (end.difference(start).inMilliseconds * 1000);
    } finally {
      testFile.deleteSync();
      tempDir.deleteSync();
    }
  }
}
