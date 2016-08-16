class Term {
  final bool negative;

  bool get positive => !negative;

  final PackageDep dep;

  Term.positive(this.dep) : negative = false;

  Term.negative(this.dep) : negative = true;

  int get hashCode => negative.hashCode ^ dep.hashCode;

  bool operator ==(other) =>
      other is Term &&
      other.negative == negative &&
      other.dep == dep;
}