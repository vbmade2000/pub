import '../glyph.dart' as glyph;
import '../package.dart';
import 'term.dart';

class Clause {
  final List<Term> terms;

  Clause(Iterable<Term> terms) : terms = new List.unmodifiable(terms);

  Clause.requirement(PackageDep dep) : this([new Term.positive(dep)]);

  Clause.prohibition(PackageDep dep) : this([new Term.negative(dep)]);

  Clause.dependency(PackageDep depender, PackageDep target)
      : this([new Term.negative(depender), new Term.positive(target)]);

  String toString() {
    var positives = terms.where((term) => term.isPositive).toList();
    if (terms.length == 1 || positives.length != 1) {
      return terms.join(" ${glyph.or} ");
    }

    if (terms.length == 2) {
      var condition = terms.where((term) => term.isNegative).single.dep;
      return "$condition ${glyph.arrow} ${positives.single}";
    }

    var conditions = terms.where((term) => term.isNegative)
        .map((term) => term.dep).join(" ${glyph.and} ");
    return "($conditions) ${glyph.arrow} ${positives.single}";
  }
}