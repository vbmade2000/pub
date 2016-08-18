// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

import '../exceptions.dart';
import '../flutter.dart' as flutter;
import '../lock_file.dart';
import '../log.dart' as log;
import '../package.dart';
import '../pubspec.dart';
import '../sdk.dart' as sdk;
import '../system_cache.dart';
import '../utils.dart';
import 'clause.dart';
import 'constraint.dart';
import 'term.dart';
import 'version_solver.dart';

final _contradiction = new Object();

class VersionSolver {
  final SolveType type;
  final SystemCache systemCache;
  final Package root;
  final SolverCache cache;

  final _clauses = new Set<Clause>();

  final _clausesByName = <String, Set<Clause>>{};

  final _decisions = <PackageId>[];

  final _decisionsByName = <String, PackageId>{};

  var _constraints = <String, Constraint>{};

  final _constraintsStack = <Map<String, Constraint>>[];

  var _implications = <Term, Set<Term>>{};

  final _implicationsStack = <Map<Term, Set<Term>>>[];

  VersionSolver(SolveType type, SystemCache systemCache, this.root)
      : type = type,
        systemCache = systemCache,
        cache = new SolverCache(type, systemCache);

  Future<SolveResult> solve() async {
    var stopwatch = new Stopwatch()..start();

    for (var dep in root.immediateDependencies) {
      _addClause(new Clause.requirement(dep));
    }

    while (true) {
      // Avoid starving the event queue by waiting for a timer-level event.
      await new Future(() {});

      var id = await _versionToTry();
      if (id == null) break;
      log.solver("Selecting $id");
      await _selectVersion(id);
    }

    var pubspecs = <String, Pubspec>{};
    for (var id in _decisions) {
      pubspecs[id.name] = await _getPubspec(id);
    }

    var buffer = new StringBuffer()
      ..writeln("Version solving took ${stopwatch.elapsed} seconds.")
      ..writeln(cache.describeResults());
    log.solver(buffer);

    return new SolveResult.success(systemCache.sources, root,
        new LockFile.empty(), _decisions, [], pubspecs,
        _getAvailableVersions(_decisions), 1);
  }

  /// Generates a map containing all of the known available versions for each
  /// package in [packages].
  ///
  /// The version list may not always be complete. If the package is the root
  /// root package, or if it's a package that we didn't unlock while solving
  /// because we weren't trying to upgrade it, we will just know the current
  /// version.
  Map<String, List<Version>> _getAvailableVersions(List<PackageId> packages) {
    var availableVersions = <String, List<Version>>{};
    for (var package in packages) {
      var cached = cache.getCachedVersions(package.toRef());
      // If the version list was never requested, just use the one known
      // version.
      var versions = cached == null
          ? [package.version]
          : cached.map((id) => id.version).toList();

      availableVersions[package.name] = versions;
    }

    return availableVersions;
  }

  // Note: this may add additional clauses, which may cause a backtrack or
  // detect a global contradiction.
  Future<PackageId> _versionToTry() {
    // TODO: be more clever about choosing which package to try. The old solver
    // selects packages with fewer versions first. It might be even better to
    // select the least-constrained packages first. We should probably also
    // handle locked packages here.

    // Try picking packages with concrete constraints first. These are packages
    // we know we need to select to satisfy the existing selections.
    var constraint = _constraints.values
        .firstWhere((constraint) => constraint.isPositive, orElse: () => null);

    // TODO: what if a constraint exists with an unsatisfiable dep?
    if (constraint != null) {
      // If there are no versions of [constraint], try selecting a different
      // package. [_bestVersionFor] has added a clause that ensures we don't
      // select the same one.
      return _bestVersionFor(constraint.deps.single) ?? _versionToTry();
    }

    // If there are no (positive) constraints, try a package referred to by the
    // clauses instead.
    PackageDep dep;
    clauses: for (var clause in _clauses) {
      // Look for a satisfiable positive term in an unsatisfied clause.
      Term satisfiable;
      for (var term in clause.terms) {
        var satisfaction = _satisfaction(term);
        // If any term in a clause is satisfied, ignore that clause completely.
        if (satisfaction == _Satisfaction.satisfied) continue clauses;
        if (satisfaction == _Satisfaction.unsatisfiable) continue;
        if (term.isNegative) continue;
        if (dep != null && !term.dep.samePackage(dep)) continue;
        satisfiable = term;
      }
      if (satisfiable == null) continue;

      // Make sure we have the dep that allows the highest max version. This
      // ensures that we don't pick a lower version than absolutely necessary.
      if (dep == null ||
          _compareConstraintMax(
              dep.constraint, satisfiable.dep.constraint) < 0) {
        dep = satisfiable.dep;
      }
    }

    if (dep == null) return null;

    // TODO: what if no versions exist for this dep? can we guarantee that
    // that's not possible elsewhere?
    //
    // If there are no versions of [dep], try selecting a different package.
    // [_bestVersionFor] has added a clause that ensures we don't select the
    // same one.
    return _bestVersionFor(dep) ?? _versionToTry();
  }

  Future<PackageId> _bestVersionFor(PackageDep dep) async {
    Iterable<PackageId> allowed;
    try {
      allowed = await cache.getVersions(dep.toRef());
    } on PackageNotFoundException {
      _addClause(new Clause.prohibition(
          dep.withConstraint(VersionConstraint.any)));
      return null;
    }

    var id = allowed.firstWhere(dep.allows, orElse: () => null);
    if (id == null) _addClause(new Clause.prohibition(dep));
    return id;
  }

  int _compareConstraintMax(VersionConstraint constraint1,
      VersionConstraint constraint2) {
    var range1 = constraint1 is VersionUnion
        ? constraint1.ranges.last
        : constraint1 as VersionRange;
    var range2 = constraint2 is VersionUnion
        ? constraint2.ranges.last
        : constraint2 as VersionRange;
    return range1.compareTo(range2);
  }

  Future _selectVersion(PackageId id) async {
    if (!await _validateSdkConstraint(id)) return;

    _decisions.add(id);
    _decisionsByName[id.name] = id;
    _constraints = new Map.from(_constraints);
    _constraintsStack.add(_constraints);

    var oldImplications = _implications;
    _implications = {};
    oldImplications.forEach((key, value) {
      _implications[key] = value.toSet();
    });
    _implicationsStack.add(_implications);

    _constraints.remove(id.name);

    for (var clause in _clausesByName[id.name]) {
      var unit = _unitToPropagate(clause);
      assert(unit != _contradiction);
      if (unit is Term && !_propagateUnit(unit)) return;
    }

    var pubspec = await _getPubspec(id);
    for (var target in pubspec.dependencies) {
      // Find every adjacent versions of [id]'s package that depends on the same
      // range or a sub-range of [target].
      var depender = await _depWhere(id, (pubspec) {
        var otherTarget = pubspec.dependencies.firstWhere(
            (dep) => dep.samePackage(target), orElse: () => null);
        if (otherTarget == null) return false;
        return target.constraint.allowsAll(otherTarget.constraint);
      });

      _addClause(new Clause.dependency(depender, target));
    }
  }

  Future<bool> _validateSdkConstraint(PackageId id) async {
    var badDart = await _depWhere(id, (pubspec) =>
        !pubspec.dartSdkConstraint.allows(sdk.version));
    if (badDart != null) _addClause(new Clause.prohibition(badDart));

    var badFlutter = await _depWhere(id, (pubspec) =>
        pubspec.flutterSdkConstraint != null &&
        (!flutter.isAvailable ||
         !pubspec.flutterSdkConstraint.allows(flutter.version)));
    if (badFlutter != null) _addClause(new Clause.prohibition(badFlutter));

    return badDart == null && badFlutter == null;
  }

  /// Returns a dep describing the range of versions adjacent to [id] for which
  /// [test] returns `true`.
  ///
  /// If [test] returns false for [id]'s pubspec, this returns `null`.
  Future<PackageDep> _depWhere(PackageId id, bool test(Pubspec pubspec)) async {
    var pubspec = await _getPubspec(id);
    if (!test(pubspec)) return null;

    var ids = await cache.getVersions(id.toRef());
    var index = binarySearch(ids, id, compare: type == SolveType.DOWNGRADE
        ? (id1, id2) => Version.antiprioritize(id2.version, id1.version)
        : (id1, id2) => Version.prioritize(id2.version, id1.version));
    assert(index != -1);

    // Find the smallest index contiguous with [index] that passes [test].
    var minIndex = index;
    while (minIndex > 0 && test(await _getPubspec(ids[minIndex - 1]))) {
      minIndex--;
    }

    // Find the first index above [index] that doesn't pass [test].
    var indexAbove = index + 1;
    while (indexAbove < ids.length &&
        test(await _getPubspec(ids[indexAbove]))) {
      indexAbove++;
    }

    if (minIndex + 1 == indexAbove) {
      return id.withConstraint(id.version);
    } else if (indexAbove == ids.length) {
      if (minIndex == 0) return id.withConstraint(VersionConstraint.any);
      return id.withConstraint(new VersionRange(
          min: ids[minIndex].version, includeMin: true));
    } else if (minIndex == 0) {
      return id.withConstraint(new VersionRange(max: ids[indexAbove].version));
    } else if (ids[minIndex].version.nextBreaking == ids[indexAbove].version) {
      return id.withConstraint(
          new VersionConstraint.compatibleWith(ids[minIndex].version));
    } else {
      return id.withConstraint(new VersionRange(
          min: ids[minIndex].version, includeMin: true,
          max: ids[indexAbove].version));
    }
  }

  /// Loads and returns the pubspec for [id].
  Future<Pubspec> _getPubspec(PackageId id) =>
      systemCache.source(id.source).describe(id);

  /// Adds a new clause to the deducer and propagates any new information it
  /// adds.
  ///
  /// Returns `false` if adding the clause caused the solver to backjump.
  bool _addClause(Clause clause) {
    log.solver("Adding clause $clause");
    _clauses.add(clause);

    for (var term in clause.terms) {
      _clausesByName.putIfAbsent(term.dep.name, () => new Set())
          .add(clause);
    }

    var unit = _unitToPropagate(clause);
    if (unit == _contradiction) {
      // Backjump to the first explicitly-selected package that (transitively)
      // led to this contradiction.
      var transitiveImplicators = _transitiveImplicators(clause.terms);
      if (!_backjumpTo((id) => transitiveImplicators.contains(id.toRef()))) {
        throw "Contradiction!";
      }
      return false;
    }
    if (unit is Term) return _propagateUnit(unit);
    return true;
  }

  // Returns `null`, a [Term], or `_contradiction`.
  _unitToPropagate(Clause clause) {
    Term satisfiable;
    for (var term in clause.terms) {
      var satisfaction = _satisfaction(term);
      // If this term is satisfied, then the clause is already satisfied and we
      // can't derive anything new from it.
      if (satisfaction == _Satisfaction.satisfied) return null;
      if (satisfaction != _Satisfaction.satisfiable) continue;

      // If there are multiple satisfiable terms, we can't derive any new
      // information from this clause.
      if (satisfiable != null) return null;
      satisfiable = term;
    }

    if (satisfiable == null) {
      log.solver("  new clause is unsatisfiable");
      // If none of the terms in the clause are satisfiable, we've found a
      // contradiction and we need to backtrack.
      return _contradiction;
    } else {
      _implications.putIfAbsent(satisfiable, () => new Set())
          .addAll(clause.terms.where((term) => term != satisfiable));

      // If there's only one clause that doesn't have a selection, and all the
      // other clauses are unsatisfied, unit propagation means we have to select
      // a version for the remaining clause.
      return satisfiable;
    }
  }

  _Satisfaction _satisfaction(Term term) {
    var selected = _decisionsByName[term.dep.name];
    if (selected != null) {
      return term.dep.allows(selected) == term.isPositive
          ? _Satisfaction.satisfied
          : _Satisfaction.unsatisfiable;
    }

    var constraint = _constraints[term.dep.name];
    if (constraint == null) return _Satisfaction.satisfiable;

    if (constraint.isPositive) {
      var constraintDep = constraint.deps.single;
      if (term.isPositive) {
        if (term.dep.allowsAll(constraintDep)) return _Satisfaction.satisfied;
        if (term.dep.allowsAny(constraintDep)) return _Satisfaction.satisfiable;
        return _Satisfaction.unsatisfiable;
      } else {
        return constraintDep.allowsAll(term.dep)
            ? _Satisfaction.unsatisfiable
            : _Satisfaction.satisfiable;
      }
    } else {
      for (var dep in constraint.deps) {
        if (dep.allowsAll(term.dep)) {
          return term.isPositive
              ? _Satisfaction.unsatisfiable
              : _Satisfaction.satisfied;
        }
      }
      return _Satisfaction.satisfiable;
    }
  }

  // Returns whether propagation was successful without backjumping
  bool _propagateUnit(Term unit) {
    var toPropagate = new Set.from([unit]);
    while (!toPropagate.isEmpty) {
      var term = toPropagate.first;
      toPropagate.remove(term);

      var oldConstraint = _constraints[term.dep.name];
      var constraint = oldConstraint == null
          ? new Constraint.fromTerm(term)
          : oldConstraint.withTerm(term);

      // If the new unit doesn't add any additional information to the constraint,
      // there's nothing new to propagate.
      if (constraint == oldConstraint) return true;
      log.solver("  adding constraint $constraint");
      _constraints[term.dep.name] = constraint;

      for (var clause in _clausesByName[term.dep.name]) {
        var newUnit = _unitToPropagate(clause);
        if (newUnit == null) continue;
        if (newUnit is Term) {
          toPropagate.add(newUnit);
          continue;
        }

        assert(newUnit == _contradiction);
        // TODO: is selecting based on name right here? what about multiple
        // negations?
        var implicators = _implications[term] ?? new Set();
        implicators.addAll(clause.terms.where(
            (clauseTerm) => clauseTerm.dep.name != unit.dep.name));

        var transitiveImplicators = _transitiveImplicators(implicators);
        if (!_backjumpTo((id) => transitiveImplicators.contains(id.toRef()))) {
          throw "Contradiction!";
        }
        _addClause(new Clause(implicators));
        return false;
      }
    }

    return true;
  }

  // Returns whether or not a global contradiction has been found.
  bool _backjumpTo(bool test(PackageId id)) {
    var i = lastIndexWhere(_decisions, test);
    if (i == null) return false;

    for (var id in _decisions.skip(i)) {
      _decisionsByName.remove(id.name);
    }

    log.solver("Backjumping past ${_decisions[i]}");

    _constraints = _constraintsStack[i];
    _implications = _implicationsStack[i];
    _decisions.removeRange(i, _decisions.length);
    _constraintsStack.removeRange(i, _constraintsStack.length);
    _implicationsStack.removeRange(i, _implicationsStack.length);

    return true;
  }

  Set<PackageRef> _transitiveImplicators(Iterable<Term> terms) {
    var implicators = new Set<PackageRef>();
    var toCheck = terms.toSet();
    while (!toCheck.isEmpty) {
      var term = toCheck.first;
      toCheck.remove(term);
      if (!implicators.add(term.dep.toRef())) continue;

      toCheck.addAll(_implications[term] ?? const [] as Iterable<Term>);
    }
    return implicators;
  }
}

class _Satisfaction {
  static const satisfied = const _Satisfaction._("satisfied");
  static const satisfiable = const _Satisfaction._("satisfiable");
  static const unsatisfiable = const _Satisfaction._("unsatisfiable");

  final String _name;

  const _Satisfaction._(this._name);

  String toStriong() => _name;
}
