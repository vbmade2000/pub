// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'package:pub/src/solver/constraint_maximizer.dart';

final v001 = new Version.parse("0.0.1");
final v002 = new Version.parse("0.0.2");
final v003 = new Version.parse("0.0.3");
final v010 = new Version.parse("0.1.0");
final v020 = new Version.parse("0.2.0");

void main() {
  ConstraintMaximizer maximizer;
  setUp(() {
    maximizer = new ConstraintMaximizer([v001, v010, v020]);
  });

  group("normalizing", () {
    test("makes a version into a range less than the next concrete "
        "version", () {
      expect(maximizer.maximize([v001]),
          equals(new VersionRange(min: v001, max: v010, includeMin: true)));
      expect(maximizer.maximize([v002]),
          equals(new VersionRange(min: v002, max: v010, includeMin: true)));
    });

    test("makes a version into an unbounded range if it's the last concrete "
        "version", () {
      expect(maximizer.maximize([v020]),
          equals(new VersionRange(min: v020, includeMin: true)));
    });

    test("makes a range's upper bound less than the next concrete version", () {
      expect(maximizer.maximize([new VersionRange(min: v002, max: v003)]),
          equals(new VersionRange(min: v002, max: v010)));
      expect(
          maximizer.maximize(
              [new VersionRange(min: v002, max: v010, includeMax: true)]),
          equals(new VersionRange(min: v002, max: v020)));
      expect(
          maximizer.maximize([new VersionRange(min: v002, max: v010)]),
          equals(new VersionRange(min: v002, max: v010)));
    });

    test("makes a range unbounded if there is no next concrete version", () {
      expect(
          maximizer.maximize(
              [new VersionRange(min: v002, max: v020, includeMax: true)]),
          equals(new VersionRange(min: v002)));
    });

    test("doesn't modify a range with an unbounded max", () {
      expect(maximizer.maximize([new VersionRange(min: v002)]),
          equals(new VersionRange(min: v002)));
    });
  });

  test("merges adjacent versions", () {
    expect(maximizer.maximize([v001, v010]),
        equals(new VersionRange(min: v001, max: v020, includeMin: true)));
  });

  test("doesn't merge versions if there's one in between", () {
    expect(
        maximizer.maximize([v001, v020]),
        equals(new VersionConstraint.unionOf([
          new VersionRange(min: v001, max: v010, includeMin: true),
          new VersionRange(min: v020, includeMin: true)
        ])));
  });

  test("merges adjacent ranges", () {
    expect(
        maximizer.maximize([
          new VersionRange(min: v001, max: v002, includeMin: true),
          new VersionRange(min: v010, max: v020, includeMin: true)
        ]),
        equals(new VersionRange(min: v001, max: v020, includeMin: true)));
  });

  test("doesn't merges ranges if there's a version in between", () {
    expect(
        maximizer.maximize([
          new VersionRange(min: v001, max: v002, includeMin: true),
          new VersionRange(min: v020, includeMin: true)
        ]),
        equals(new VersionConstraint.unionOf([
          new VersionRange(min: v001, max: v010, includeMin: true),
          new VersionRange(min: v020, includeMin: true)
        ])));
  });

  test("flattens unions", () {
    expect(maximizer.maximize([new VersionConstraint.unionOf([v001, v010])]),
        equals(new VersionRange(min: v001, max: v020, includeMin: true)));
  });
}
