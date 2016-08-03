import '../exceptions.dart';
import 'fact.dart';

class DeductionFailure implements ApplicationException {
  final List<Cause> _causes;

  String get message => _ExplanationBuilder.explain(_causes) + "thus, failure";

  DeductionFailure(Iterable<Cause> causes)
      : _causes = new List.unmodifiable(causes);

  String toString() => message;
}

class _ExplanationBuilder {
  final _buffer = new StringBuffer();

  static String explain(List<Cause> causes) {
    var builder = new _ExplanationBuilder();
    builder._explainCauses(causes, 0);
    return builder._buffer.toString();
  }

  void _explainCauses(List<Cause> causes, int indentation) {
    var first = true;
    for (var cause in causes) {
      if (cause is Fact) {
        _explainCauses(cause.causes, indentation + (first ? 0 : 1));
        _indent(indentation);
        _buffer.writeln("thus, $cause");
      } else {
        _indent(indentation);
        _buffer.writeln(cause);
      }
      first = false;
    }
  }

  void _indent(int indentation) => _buffer.write("  " * indentation);
}
