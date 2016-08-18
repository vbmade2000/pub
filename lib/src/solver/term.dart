import '../package.dart';

class Term {
  final bool isNegative;

  bool get isPositive => !isNegative;

  final PackageDep dep;

  Term.positive(this.dep) : isNegative = false;

  Term.negative(this.dep) : isNegative = true;

  int get hashCode => isNegative.hashCode ^ dep.hashCode;

  bool operator ==(other) =>
      other is Term &&
      other.isNegative == isNegative &&
      other.dep == dep;
}