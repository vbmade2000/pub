// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

class ConstraintNormalizer {
  /// The set of concrete versions of the package that actually exist.
  ///
  /// This is the base relative to which maximality is defined.
  final List<Version> _versions;

  // Indices of the least upper bound in [_versions] for version numbers we've
  // encountered.
  //
  // Caching these allows us to avoid doing a binary search through a
  // potentially-large version list when re-processing the same constraints. The
  // index `_versions.length` indicates that a version is greater than or equal
  // to all versions in [_versions].
  final _leastUpperBounds = <Version, int>{};

  /// An expando tracking [VersionRange]s that have been normalized using
  /// [_normalize].
  final _normalized = new Expando<bool>();

  ConstraintNormalizer(Iterable<Version> base)
      : _versions = base.toList();

  VersionConstraint normalize(VersionConstraint constraint) {
    if (constraint is VersionRange) return _normalizeRange(constraint);
    return new VersionConstraint.unionOf(
        (constraint as VersionUnion).ranges.expand(_normalizeRange));
  }

  /// Normalize [range] so that it encodes the next upper bound.
  ///
  /// If [range] has an upper bound, this adjusts it so that it's of the form
  /// `<V` where `V` is a version in the base. The returned range is equivalent
  /// to [range].
  VersionRange _normalizeRange(VersionRange range) {
    if (_normalized[range] ?? false) return range;
    if (range.max == null) {
      _normalized[range] = true;
      return range;
    }

    // TODO(nweiz): It may be more user-friendly to avoid normalizing individual
    // versions here, so the user sees messages about "foo 1.2.3" rather than
    // "foo >=1.2.3 <1.2.4". That would require more logic when unioning
    // normalized versions, though.

    // This makes the range look more like a caret-style version range and
    // implicitly tracks the upper bound.
    var result = new VersionRange(
        min: range.min, max: _strictLeastUpperBound(range),
        includeMin: range.includeMin, includeMax: false);
    _normalized[result] = true;
    return result;
  }

  /// Returns the lowest version in [_versions] that's strictly greater than all
  /// versions in [range].
  Version _strictLeastUpperBound(VersionRange range) {
    var index = _leastUpperBoundIndex(range.max);
    if (index == _versions.length) return null;

    var bound = _versions[index];
    if (!range.includeMax || bound != range.max) return bound;
    if (index + 1 == _versions.length) return null;
    return _versions[index + 1];
  }

  /// Returns the index of the least version in [_versions] that's greater than
  /// or equal to [version].
  ///
  /// If [version] is greater than all versions in [_versions], returns
  /// `_versions.length`.
  int _leastUpperBoundIndex(Version version) {
    // TODO(nweiz): tweak the binary search to favor the latter end of
    // [_versions]?
    return _leastUpperBounds.putIfAbsent(version,
        () => lowerBound(_versions, version));
  }
}
