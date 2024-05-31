import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/executables/bundletool.dart';
import 'package:shorebird_cli/src/logger.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// Thrown when multiple artifacts are found in the build directory.
class MultipleArtifactsFoundException implements Exception {
  MultipleArtifactsFoundException({
    required this.buildDir,
    required this.foundArtifacts,
  });

  final String buildDir;
  final List<FileSystemEntity> foundArtifacts;

  @override
  String toString() {
    final artifacts = foundArtifacts.sortedBy((e) => e.path);
    return 'Multiple artifacts found in $buildDir: '
        '${artifacts.map((e) => e.path)}';
  }
}

/// Thrown when no artifact is found in the build directory.
class ArtifactNotFoundException implements Exception {
  ArtifactNotFoundException({
    required this.artifactName,
    required this.buildDir,
  });

  final String artifactName;
  final String buildDir;

  @override
  String toString() {
    return 'Artifact $artifactName not found in $buildDir';
  }
}

/// When building android artifacts, gradlew names these artifacts in an
/// inconsistent way.
///
/// Example:
///
///  ## AABs
///  Without flavors
///  ...bundle/release/app-release.aab
///
///  With flavors
///  ...bundle/flavor/app-flavor-release.aab
///
///  With multi dimensional flavors
///  ...bundle/fullFlavorCamelCase/app-flavor1-flavor2-release.aab
///
/// The pattern follows for APKs.
///
/// The only thing that is consistent is the artifactId which is the name of the
/// artifact will follow always the same order of name of the flavors.
///
/// To get around this, we create an identifier for the artifact
/// that is the file name lowercased and without any non-word characters.
/// This allows us to reliably find the artifact generated by the
/// flutter build command.
extension on String {
  String get artifactId => replaceAll(RegExp(r'\W'), '').toLowerCase();
}

final shorebirdAndroidArtifactsRef = create(ShorebirdAndroidArtifacts.new);

ShorebirdAndroidArtifacts get shorebirdAndroidArtifacts =>
    read(shorebirdAndroidArtifactsRef);

/// Mixin on [ShorebirdCommand] which exposes methods
// to find the artifacts generated for android
class ShorebirdAndroidArtifacts {
  /// Find the artifact in the build directory.
  File _findArtifact({
    required String artifactName,
    required Directory directory,
  }) {
    // Remove all non characters and digits from the artifact name.
    final artifactId = artifactName.artifactId;

    if (!directory.existsSync()) {
      throw ArtifactNotFoundException(
        artifactName: artifactName,
        buildDir: directory.path,
      );
    }

    final allFiles = directory.listSync();
    final artifactCandidates = allFiles.whereType<File>().where((file) {
      final fileName = p.basename(file.path);
      return fileName.artifactId == artifactId;
    }).toList();

    if (artifactCandidates.isEmpty) {
      throw ArtifactNotFoundException(
        artifactName: artifactName,
        buildDir: directory.path,
      );
    }

    if (artifactCandidates.length > 1) {
      throw MultipleArtifactsFoundException(
        buildDir: directory.path,
        foundArtifacts: artifactCandidates,
      );
    }

    return artifactCandidates.first;
  }

  /// Find the app bundle in the provided [project] [Directory].
  File findAab({
    required Directory project,
    required String? flavor,
  }) {
    final buildDir = p.join(
      project.path,
      'build',
      'app',
      'outputs',
      'bundle',
      flavor != null ? '${flavor}Release' : 'release',
    );

    final artifactName =
        flavor == null ? 'app-release.aab' : 'app-$flavor-release.aab';

    return _findArtifact(
      directory: Directory(buildDir),
      artifactName: artifactName,
    );
  }

  /// Find the apk in the provided [project] [Directory].
  File findApk({
    required Directory project,
    required String? flavor,
  }) {
    final buildDir = p.join(
      project.path,
      'build',
      'app',
      'outputs',
      'flutter-apk',
    );

    final artifactName =
        flavor == null ? 'app-release.apk' : 'app-$flavor-release.apk';

    return _findArtifact(
      directory: Directory(buildDir),
      artifactName: artifactName,
    );
  }

  static String get aarLibraryPath {
    final projectRoot = shorebirdEnv.getShorebirdProjectRoot()!;
    return p.joinAll([
      projectRoot.path,
      'build',
      'host',
      'outputs',
      'repo',
    ]);
  }

  static String aarArtifactDirectory({
    required String packageName,
    required String buildNumber,
  }) =>
      p.joinAll([
        aarLibraryPath,
        ...packageName.split('.'),
        'flutter_release',
        buildNumber,
      ]);

  static String aarArtifactPath({
    required String packageName,
    required String buildNumber,
  }) =>
      p.join(
        aarArtifactDirectory(
          packageName: packageName,
          buildNumber: buildNumber,
        ),
        'flutter_release-$buildNumber.aar',
      );

  /// Extract the release version from an appbundle.
  Future<String> extractReleaseVersionFromAppBundle(
    String appBundlePath,
  ) async {
    await cache.updateAll();

    final [versionName, versionCode] = await Future.wait([
      bundletool.getVersionName(appBundlePath),
      bundletool.getVersionCode(appBundlePath),
    ]);

    return '$versionName+$versionCode';
  }

  /// Unzips the aar file for the given [packageName] and [buildNumber] to a
  /// temporary directory and returns the directory.
  Future<Directory> extractAar({
    required String packageName,
    required String buildNumber,
    required UnzipFn unzipFn,
  }) async {
    final aarDirectory = aarArtifactDirectory(
      packageName: packageName,
      buildNumber: buildNumber,
    );
    final aarPath = aarArtifactPath(
      packageName: packageName,
      buildNumber: buildNumber,
    );

    final zipDir = Directory.systemTemp.createTempSync();
    final zipPath = p.join(zipDir.path, 'flutter_release-$buildNumber.zip');
    logger.detail('Extracting $aarPath to $zipPath');

    // Copy the .aar file to a .zip file so package:archive knows how to read it
    File(aarPath).copySync(zipPath);
    final extractedZipDir = p.join(
      aarDirectory,
      'flutter_release-$buildNumber',
    );
    // Unzip the .zip file to a directory so we can read the .so files
    await unzipFn(zipPath, extractedZipDir);
    return Directory(extractedZipDir);
  }
}
