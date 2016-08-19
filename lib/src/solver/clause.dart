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

  String toString() => terms.join(" ${glyph.or} ");
}
