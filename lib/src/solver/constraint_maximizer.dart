// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

/// Merges constraints such that they fully cover actual available versions.
///
/// Thoroughly explaining what this means will require a bit of jargon, so bear
/// with me. I promise not to use any technical terms without defining them
/// first.
///
/// Suppose we're given a set of known [Version]s, which we'll call a **base**.
/// We define two [VersionConstraint]s to be **equivalent** relative to a base
/// if they cover exactly the same versions in the base. For example, if the
/// base is `[1.0.0, 2.0.0, 3.0.0]`, then the ranges `^1.0.0` and `>=1.0.0
/// <1.5.0` are equivalent.
///
/// We'll also define a version constraint to be **maximal** relative to a base
/// if there are no equivalent constraints with fewer ranges. [Version]s and
/// [VersionRange]s have only one range (themselves); a [VersionUnion] has
/// `ranges.length` ranges. So for example, `^1.0.0` is maximal relative to the
/// base above, but `">=1.0.0 <1.5.0" or ">=1.6.0 <2.0.0"` is not because it
/// contains more ranges than necessary.
///
/// This class finds maximal equivalents for sets of [VersionConstraint]s. This
/// is important for version solving because it means that we can safely take
/// the difference of two version constraints without having useless gaps left
/// over. It also makes the output more human-friendly, since we can talk about
/// adjacent versions as ranges instead of individual versions.
///
/// Each [ConstraintMaximizer] maximizes constraints for one particular package
/// and its set of versions.
class ConstraintMaximizer {
  /// The set of concrete versions of the package that actually exist.
  ///
  /// This is the base relative to which maximality is defined.
  final List<Version> _versions;

  // Indices
  final _leastUpperBounds = <Version, int>{};

  final _normalized = new Expando<bool>();

  ConstraintMaximizer(Iterable<Version> versions)
      : _versions = versions.toList();

  VersionConstraint maximize(Iterable<VersionConstraint> constraints) {
    // TODO(nweiz): if there end up being a lot of constraints per union, we can
    // avoid re-sorting them using [this algorithm][].
    //
    // [this algorithm]: https://gist.github.com/nex3/f4d0e2a9267d1b8cfdb5132b760d0111#gistcomment-1782883
    var flattened = <VersionRange>[];
    for (var constraint in constraints) {
      if (constraint is VersionUnion) {
        flattened.addAll(constraint.ranges.map(_normalize));
      } else {
        flattened.add(_normalize(constraint as VersionRange));
      }
    }

    return new VersionConstraint.unionOf(flattened);
  }

  /// Normalize [range] so that it encodes the next upper bound.
  VersionRange _normalize(VersionRange range) {
    if (_normalized[range] ?? false) return range;
    if (range.max == null) {
      _normalized[range] = true;
      return range;
    }

    // TODO(nweiz): It may be more user-friendly to avoid normalizing individual
    // versions here, so the user sees messages about "foo 1.2.3" rather than
    // "foo >=1.2.3 <1.2.4". That would require more logic in [maximize] to
    // merge those versions, though.

    // Convert the upper bound to `<V`, where V is in [_versions]. This makes
    // the range look more like a caret-style version range and implicitly
    // tracks the upper bound.
    var result = new VersionRange(
        min: range.min, max: _strictLeastUpperBound(range),
        includeMin: range.includeMin, includeMax: false);
    _normalized[result] = true;
    return result;
  }

  // Strictly greater than
  Version _strictLeastUpperBound(VersionRange range) {
    var index = _leastUpperBoundIndex(range.max);
    if (index == _versions.length) return null;

    var bound = _versions[index];
    if (!range.includeMax || bound != range.max) return bound;
    if (index + 1 == _versions.length) return null;
    return _versions[index + 1];
  }

  // Greater than or equal to, `versions.length` if none
  int _leastUpperBoundIndex(Version version) {
    // TODO(nweiz): tweak the binary search to favor the latter end of
    // [_versions]?
    return _leastUpperBounds.putIfAbsent(version,
        () => lowerBound(_versions, version));
  }
}
