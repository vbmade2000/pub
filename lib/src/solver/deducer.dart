// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

import '../package.dart';
import 'constraint_normalizer.dart';
import 'deduction_failure.dart';
import 'fact.dart';

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

  final _constraintsStack = [_constraints];

  var _implications = <Term, Set<Term>>{};

  final _implicationsStack = [_implications];

  VersionSolver(SolveType type, SystemCache systemCache, this.root)
      : type = type,
        systemCache = systemCache,
        cache = new SolverCache(type, systemCache);

  Future<SolveResult> solve() async {
    var stopwatch = new Stopwatch..start();

    for (var dep in root.immediateDependencies) {
      _addClause(new Clause.requirement(dep));
    }

    while (true) {
      // Avoid starving the event queue by waiting for a timer-level event.
      await new Future(() {});

      var id = await _versionToTry();
      if (id == null) break;
      _selectVersion(id);
    }
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
        .firstWhere((constraint) => constraint.positive, orElse: () => null);

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
        if (satisfaction == _Satisfaction.unsatisfied) continue;
        if (term.negative) continue;
        if (dep != null && !term.dep.samePackage(dep)) continue;
        satisfiable = term;
      }
      if (satisfiable == null) continue;

      // Make sure we have the dep that allows the highest max version. This
      // ensures that we don't pick a lower version than absolutely necessary.
      if (dep == null || _compareConstraintMax(dep, satisfiable.dep) < 0) {
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
      allowed = await cache.getVersions(dep.asRef());
    } on PackageNotFoundException catch (error) {
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

  void _selectVersion(PackageId id) {
    if (!_validateSdkConstraint(id)) return;

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

    // TODO: add clauses based on ID's dependencies
  }

  bool _validateSdkConstraint(PackageId id) {
    var badDart = _depWhere(id, (pubspec) =>
        !pubspec.dartSdkConstraint.allows(sdk.version));
    if (badDart != null) _addClause(new Clause.negative(badDart));

    var badFlutter = _depWhere(id, flutter.isAvailable
        ? (pubspec) => pubspec.flutterSdkConstraint != null
        : (pubspec) => !pubspec.flutterSdkConstraint.allows(flutter.version))
    if (badFlutter != null) _addClause(new Clause.negative(badFlutter));

    return badDart == null && badFlutter == null;
  }

  /// Returns a dep describing the range of versions adjacent to [id] for which
  /// [test] returns `true`.
  ///
  /// If [test] returns false for [id]'s pubspec, this returns `null`.
  PackageDep _depWhere(PackageId id, bool test(Pubspec pubspec)) {
    var pubspec = _getPubspec(id);
    if (!test(pubspec)) return null;

    var ids = await cache.getVersions(id.asRef());
    var index = binarySearch(ids, id, compare: type == SolveType.DOWNGRADE
        ? (id1, id2) => Version.antiprioritize(id2.version, id1.version)
        : (id1, id2) => Version.prioritize(id2.version, id1.version));
    assert(index != -1);

    // Find the smallest index contiguous with [index] that passes [test].
    var minIndex = index;
    while (minIndex > 0 && test(_getPubspec(ids[minIndex - 1]))) {
      minIndex--;
    }

    // Find the first index above [index] that doesn't pass [test].
    var indexAbove = index + 1;
    while (indexAbove < ids.length && test(_getPubspec(ids[indexAbove]))) {
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

  /// Adds a new clause to the deducer and propagates any new information it
  /// adds.
  ///
  /// Returns `false` if adding the clause caused the solver to backjump.
  bool _addClause(Clause clause) {
    _clauses.add(clause);

    for (var term in clause.terms) {
      _clausesByPackage.putIfAbsent(term.dep.toRef(), () => new Set())
          .add(clause);
    }

    var unit = _unitToPropagate(clause);
    if (unit == _contradiction) {
      var transitiveImplicators = _transitiveImplicators(implicators);
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
      if (satisfaction == _Satisfaction.satisfiable) satisfiable = term;
    }

    if (satisfiable == null) {
      // If none of the terms in the clause are satisfiable, we've found a
      // contradiction and we need to backtrack.
      return _contradiction;
    } else {
      _implications.putIfAbsent(unselected, () => new Set())
          .addAll(clause.terms.where((term) => term != unselected));

      // If there's only one clause that doesn't have a selection, and all the
      // other clauses are unsatisfied, unit propagation means we have to select
      // a version for the remaining clause.
      return satisfiable;
    }
  }

  _Satisfaction _satisfaction(Term term) {
    var selected = _decisionsByName[term.name];
    if (selected != null) {
      return term.allows(selected) == term.positive
          ? _Satisfaction.satisfied
          : _Satisfaction.unsatisfiable;
    }

    var constraint = _constraints[term.name];
    if (constraint == null) return _Satisfaction.satisfiable;

    if (constraint.positive) {
      var constraintDep = constraint.deps.single;
      if (term.positive) {
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
        if (constraint.dep.allowsAll(term.dep)) {
          return term.positive
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
      var term = toPropagate.remove(toPropagate.first);
      var oldConstraint = _constraints[term];
      var constraint = oldConstraint == null
          ? new Constraint.fromTerm(term)
          : oldConstraint.withTerm(term);

      // If the new unit doesn't add any additional information to the constraint,
      // there's nothing new to propagate.
      if (constraint == oldConstraint) return;
      _constraints[term] = constraint;

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
        implicators.addAll(
            clause.terms.where((clauseTerm) => clauseTerm.name != unit.name));

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
  bool _backjumpTo(bool selector(PackageId id)) {
    var i = lastIndexWhere(_decisions, selector);
    if (i == null) return false;

    for (var id in _decisions.skip(i)) {
      _decisionsByName.remove(id.name);
    }

    _decisions.removeRange(i, _decisions.length);
    _constraintsStack.removeRange(i + 1, _constraintsStack.length);
    _implicationsStack.removeRange(i + 1, _implicationsStack.length);

    _constraints = _constraintsStack.last;
    _implications = _implicationsStack.last;

    return true;
  }

  Set<PackageRef> _transitiveImplicators(Iterable<Term> terms) {
    var implicators = new Set<PackageRef>();
    var toCheck = terms.toSet();
    while (!toCheck.isEmpty) {
      var term = toCheck.removeLast();
      if (!implicators.add(term.dep.toRef())) continue;

      toCheck.addAll(_implications[term] ?? const []);
    }
    return implicators;
  }
}

class _Satisfaction {
  static const satisfied = const _Satisfaction._(this("satisfied");
  static const satisfiable = const _Satisfaction._(this("satisfiable");
  static const unsatisfiable = const _Satisfaction._(this("unsatisfiable");

  final String _name;

  const _Satisfaction._(this._name);

  String toStriong() => _name;
}
