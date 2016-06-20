// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'io.dart';
import 'io.dart' as io show createTempDir;
import 'log.dart' as log;
import 'package.dart';
import 'source/cached.dart';
import 'source/git.dart';
import 'source/hosted.dart';
import 'source/path.dart';
import 'source/unknown.dart';
import 'source.dart';
import 'source_registry.dart';

/// The system-wide cache of downloaded packages.
///
/// This cache contains all packages that are downloaded from the internet.
/// Packages that are available locally (e.g. path dependencies) don't use this
/// cache.
class SystemCache {
  /// The root directory where this package cache is located.
  final String rootDir;

  String get tempDir => p.join(rootDir, '_temp');

  static String defaultDir = (() {
    if (Platform.environment.containsKey('PUB_CACHE')) {
      return Platform.environment['PUB_CACHE'];
    } else if (Platform.operatingSystem == 'windows') {
      var appData = Platform.environment['APPDATA'];
      return p.join(appData, 'Pub', 'Cache');
    } else {
      return '${Platform.environment['HOME']}/.pub-cache';
    }
  })();

  /// The registry for sources used by this system cache.
  ///
  /// New sources registered here will be available through [liveSources] and
  /// [liveSource].
  final sources = new SourceRegistry();

  /// The live sources bound to this cache.
  final _liveSources = <String, LiveSource>{};

  /// The live sources bound to this cache, in name order.
  List<LiveSource> get liveSources {
    return sources.all.map((source) {
      return _liveSources.putIfAbsent(source.name, () => source.bind(this));
    }).toList();
  }

  /// The built-in live Git source bound to this cache.
  LiveGitSource get git => _liveSources["git"] as LiveGitSource;

  /// The built-in live hosted source bound to this cache.
  LiveHostedSource get hosted => _liveSources["hosted"] as LiveHostedSource;

  /// The built-in live path source bound to this cache.
  LivePathSource get path => _liveSources["path"] as LivePathSource;

  /// The default source bound to this cache.
  LiveSource get defaultSource => liveSource(null);

  /// Creates a system cache and registers all sources in [sources].
  ///
  /// If [isOffline] is `true`, then the offline hosted source will be used.
  /// Defaults to `false`.
  SystemCache({String rootDir, bool isOffline: false})
      : rootDir = rootDir == null ? SystemCache.defaultDir : rootDir {
    for (var source in sources.all) {
      if (source is HostedSource) {
        _liveSources[source.name] = source.bind(this, isOffline: isOffline);
      } else {
        _liveSources[source.name] = source.bind(this);
      }
    }
  }

  /// Returns the live source bound to this cache named [name].
  ///
  /// Returns a live [UnknownSource] if no source with that name has been
  /// registered. If [name] is null, returns the default source.
  LiveSource liveSource(String name) =>
      _liveSources.putIfAbsent(name, () => sources[name].bind(this));

  /// Loads the package identified by [id].
  ///
  /// Throws an [ArgumentError] if [id] has an invalid source.
  Package load(PackageId id) {
    var source = liveSource(id.source);
    if (source.source is UnknownSource) {
      throw new ArgumentError("Unknown source ${id.source}.");
    }

    var dir = source.getDirectory(id);
    return new Package.load(id.name, dir, sources);
  }

  /// Determines if the system cache contains the package identified by [id].
  bool contains(PackageId id) {
    var source = liveSource(id.source);

    if (source is! CachedSource) {
      throw new ArgumentError("Package $id is not cacheable.");
    }

    return source.isInSystemCache(id);
  }

  /// Create a new temporary directory within the system cache.
  ///
  /// The system cache maintains its own temporary directory that it uses to
  /// stage packages into while downloading. It uses this instead of the OS's
  /// system temp directory to ensure that it's on the same volume as the pub
  /// system cache so that it can move the directory from it.
  String createTempDir() {
    var temp = ensureDir(tempDir);
    return io.createTempDir(temp, 'dir');
  }

  /// Deletes the system cache's internal temp directory.
  void deleteTempDir() {
    log.fine('Clean up system cache temp directory $tempDir.');
    if (dirExists(tempDir)) deleteEntry(tempDir);
  }
}
