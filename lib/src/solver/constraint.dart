import '../package.dart';
import 'term.dart';

class Constraint {
  final bool isNegative;

  bool get isPositive => !isNegative;

  final List<PackageDep> deps;

  Constraint.positive(PackageDep dep)
      : deps = new List.unmodifiable([dep]),
        isNegative = false;

  Constraint.negative(Iterable<PackageDep> deps)
      : deps = new List.unmodifiable(deps),
        isNegative = true {
    assert(deps.isNotEmpty);
    assert(deps.skip(1).every((dep) => dep.name == deps.first.name));
  }

  factory Constraint.fromTerm(Term term) => term.isNegative
      ? new Constraint.negative([term.dep])
      : new Constraint.positive(term.dep);

  Constraint withTerm(Term term) {
    assert(term.dep.name == deps.first.name);

    if (isPositive) {
      if (term.isPositive) {
        assert(term.dep.samePackage(deps.single));
        var newConstraint =
            term.dep.constraint.intersect(deps.single.constraint);
        if (newConstraint == deps.single.constraint) return this;
        return new Constraint.positive(term.dep.withConstraint(newConstraint));
      } else if (term.dep.samePackage(deps.single)) {
        var newConstraint =
            deps.single.constraint.difference(term.dep.constraint);
        if (newConstraint == deps.single.constraint) return this;
        return new Constraint.positive(term.dep.withConstraint(newConstraint));
      } else {
        return this;
      }
    } else if (term.isPositive) {
      var match = deps.firstWhere((dep) => dep.samePackage(term.dep),
          orElse: () => null);
      if (match == null) return new Constraint.positive(term.dep);
      return new Constraint.positive(term.dep.withConstraint(
          term.dep.constraint.difference(match.constraint)));
    } else {
      var newDeps = <PackageDep>[];
      var foundMatch = false;
      for (var dep in deps) {
        if (!dep.samePackage(term.dep)) {
          newDeps.add(dep);
          continue;
        }

        foundMatch = true;
        var newConstraint = dep.constraint.union(term.dep.constraint);
        if (newConstraint == dep.constraint) return this;
        newDeps.add(term.dep.withConstraint(newConstraint));
      }

      if (!foundMatch) newDeps.add(term.dep);
      return new Constraint.negative(newDeps);
    }
  }
}