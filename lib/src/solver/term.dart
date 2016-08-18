import '../package.dart';

class Term {
  final bool isNegative;

  bool get isPositive => !isNegative;

  final PackageDep dep;

  Term.positive(this.dep) : isNegative = false;

  Term.negative(this.dep) : isNegative = true;

  Term or(Term other) {
    if (isPositive) {
      if (other.isPositive) {
        // "a from path || a from hosted" can't be reduced any further. Calling
        // code should never pass it in.
        assert(dep.samePackage(other.dep));
        return new Term.positive(dep.withConstraint(
            dep.constraint.union(other.dep.constraint)));
      } else {
        if (!dep.samePackage(other.dep)) return other;
        var difference = other.dep.constraint.difference(dep.constraint);

        // "a 1.0.0 || !a 2.0.0" is a tautology. Calling code should detect
        // tautologies before it passes them in here.
        assert(!difference.isEmpty);
        return new Term.negative(dep.withConstraint(difference));
      }
    } else {
      if (other.isPositive) {
        if (!dep.samePackage(other.dep)) return this;
        var difference = dep.constraint.difference(other.dep.constraint);

        // "!a 1.0.0 || a 2.0.0" is a tautology. Calling code should detect
        // tautologies before it passes them in here.
        assert(!difference.isEmpty);
        return new Term.negative(dep.withConstraint(difference));
      } else {
        // "!a from path || !a from hosted" is a tautology. Calling code should
        // detect tautologies before it passes them in here.
        assert(dep.samePackage(other.dep));

        // "!a 1.0.0 || !a 2.0.0" is a tautology. Calling code should detect
        // tautologies before it passes them in here.
        var intersection = dep.constraint.intersect(other.dep.constraint);
        assert(!intersection.isEmpty);
        return new Term.negative(dep.withConstraint(intersection));
      }
    }
  }

  int get hashCode => isNegative.hashCode ^ dep.hashCode;

  bool operator ==(other) =>
      other is Term &&
      other.isNegative == isNegative &&
      other.dep == dep;

  String toString() => isNegative ? "not $dep" : dep.toString();
}