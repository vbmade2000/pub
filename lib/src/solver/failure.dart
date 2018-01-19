// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../exceptions.dart';
import '../log.dart' as log;
import '../package_name.dart';
import '../utils.dart';
import 'incompatibility.dart';
import 'incompatibility_cause.dart';

/// Base class for all failures that can occur while trying to resolve versions.
class SolveFailure implements ApplicationException {
  /// The root incompatibility.
  ///
  /// This will always indicate that the root package is unselectable. That is,
  /// it will have one term, which will be the root package.
  final Incompatibility incompatibility;

  String get message => toString();

  SolveFailure(this.incompatibility) {
    assert(incompatibility.terms.single.package.isRoot);
  }

  /// Describes how [incompatibility] was derived, and thus why version solving
  /// failed.
  ///
  /// See https://github.com/dart-lang/pub/tree/master/doc/solver.md#error-reporting
  /// for details on how this algorithm works.
  String toString() {
    var derivations = _countDerivations();

    // The lines in the proof. Each line is a message/number pair. The message
    // describes a single incompatibility, and why its terms are incompatible.
    // The number is optional and indicates the explicit number that should be
    // associated with the line so it can be referred to later on.
    var lines = <Pair<String, int>>[];

    // A map from incompatibilities to the line numbers that were written for
    // those incompatibilities.
    var lineNumbers = <Incompatibility, int>{};

    // Writes [message] to [lines].
    //
    // The [message] should describe [incompatibility] and how it was derived
    // (if applicable). If [numbered] is true, this will associate a line number
    // with [incompatibility] and [message] so that the message can be easily
    // referred to later.
    void write(Incompatibility incompatibility, String message,
        {bool numbered: false}) {
      if (numbered) {
        var number = lineNumbers.length + 1;
        lineNumbers[incompatibility] = number;
        lines.add(new Pair(message, number));
      } else {
        lines.add(new Pair(message, null));
      }
    }

    /// Returns whether we can collapse the derivation of [incompatibility].
    ///
    /// If [incompatibility] is only used to derive one other incompatibility,
    /// it may make sense to skip that derivation and just derive the second
    /// incompatibility directly from three causes. This is usually clear enough
    /// to the user, and makes the proof much terser.
    ///
    /// If this returns `true`, [incompatibility] has one external predecessor
    /// and one derived predecessor.
    bool isCollapsible(Incompatibility incompatibility) {
      // If [incompatibility] is used for multiple derivations, it will need a
      // line number and so will need to be written explicitly.
      if (derivations[incompatibility] > 1) return false;

      var cause = incompatibility.cause as ConflictCause;
      // If [incompatibility] is derived from two derived incompatibilities,
      // there are too many transitive causes to display concisely.
      if (cause.conflict.cause is ConflictCause &&
          cause.other.cause is ConflictCause) {
        return false;
      }

      // If [incompatibility] is derived from two external incompatibilities, it
      // tends to be confusing to collapse it.
      if (cause.conflict.cause is! ConflictCause &&
          cause.other.cause is! ConflictCause) {
        return false;
      }

      // If [incompatibility]'s internal cause is numbered, collapsing it would
      // get too noisy.
      var complex =
          cause.conflict.cause is ConflictCause ? cause.conflict : cause.other;
      return !lineNumbers.containsKey(complex);
    }

    // Returns whether or not [cause]'s incompatibility can be represented in a
    // single line without requiring a multi-line derivation.
    bool isSingleLine(ConflictCause cause) =>
        cause.conflict.cause is! ConflictCause &&
        cause.other.cause is! ConflictCause;

    // Writes a proof of [incompatibility] to [lines].
    //
    // If [conclusion] is `true`, [incompatibility] represents the last of a
    // linear series of derivations. It should be phrased accordingly and given
    // a line number.
    //
    // The [detailsForIncompatibility] controls the amount of detail that should
    // be written for each package when converting [incompatibility] to a
    // string.
    void visit(Incompatibility incompatibility,
        Map<String, PackageDetail> detailsForIncompatibility,
        {bool conclusion: false}) {
      // Add explicit numbers for incompatibilities that are written far away
      // from their successors or that are used for multiple derivations.
      var numbered = conclusion || derivations[incompatibility] > 1;
      var conjunction =
          conclusion || incompatibility == this.incompatibility ? 'So,' : 'And';
      var incompatibilityString =
          log.bold(incompatibility.toString(detailsForIncompatibility));
      if (incompatibility.isFailure) {
        incompatibilityString = log.red(incompatibilityString);
      }

      var cause = incompatibility.cause as ConflictCause;
      var detailsForCause = _detailsForCause(cause);
      if (cause.conflict.cause is ConflictCause &&
          cause.other.cause is ConflictCause) {
        var conflictLine = lineNumbers[cause.conflict];
        var otherLine = lineNumbers[cause.other];
        if (conflictLine != null && otherLine != null) {
          write(
              incompatibility,
              "Because ${cause.conflict.toString(detailsForCause)} "
              "($conflictLine) and ${cause.other.toString(detailsForCause)} "
              "($otherLine), $incompatibilityString.",
              numbered: numbered);
        } else if (conflictLine != null || otherLine != null) {
          Incompatibility withLine;
          Incompatibility withoutLine;
          int line;
          if (conflictLine != null) {
            withLine = cause.conflict;
            withoutLine = cause.other;
            line = conflictLine;
          } else {
            withLine = cause.other;
            withoutLine = cause.conflict;
            line = otherLine;
          }

          visit(withoutLine, detailsForCause);
          write(
              incompatibility,
              "$conjunction because ${withLine.toString(detailsForCause)} "
              "($line), $incompatibilityString.",
              numbered: numbered);
        } else {
          var singleLineConflict = isSingleLine(cause.conflict.cause);
          var singleLineOther = isSingleLine(cause.other.cause);
          if (singleLineOther || singleLineConflict) {
            var first = singleLineOther ? cause.conflict : cause.other;
            var second = singleLineOther ? cause.other : cause.conflict;
            visit(first, detailsForCause);
            visit(second, detailsForCause);
            write(incompatibility, "Thus, $incompatibilityString.",
                numbered: numbered);
          } else {
            visit(cause.conflict, {}, conclusion: true);
            lines.add(new Pair("", null));

            visit(cause.other, detailsForCause);
            write(
                incompatibility,
                "$conjunction because "
                "${cause.conflict.toString(detailsForCause)} "
                "(${lineNumbers[cause.conflict]}), "
                "$incompatibilityString.",
                numbered: numbered);
          }
        }
      } else if (cause.conflict.cause is ConflictCause ||
          cause.other.cause is ConflictCause) {
        var derived = cause.conflict.cause is ConflictCause
            ? cause.conflict
            : cause.other;
        var ext = cause.conflict.cause is ConflictCause
            ? cause.other
            : cause.conflict;

        var derivedLine = lineNumbers[derived];
        if (derivedLine != null) {
          write(
              incompatibility,
              "Because ${ext.andToString(derived, detailsForCause)} "
              "($derivedLine), $incompatibilityString.",
              numbered: numbered);
        } else if (isCollapsible(derived)) {
          var derivedCause = derived.cause as ConflictCause;
          var collapsedDerived = derivedCause.conflict.cause is ConflictCause
              ? derivedCause.conflict
              : derivedCause.other;
          var collapsedExt = derivedCause.conflict.cause is ConflictCause
              ? derivedCause.other
              : derivedCause.conflict;

          visit(collapsedDerived, detailsForCause);
          write(
              incompatibility,
              "$conjunction because "
              "${collapsedExt.andToString(ext, detailsForCause)}, "
              "$incompatibilityString.",
              numbered: numbered);
        } else {
          visit(derived, detailsForCause);
          write(
              incompatibility,
              "$conjunction because ${ext.toString(detailsForCause)}, "
              "$incompatibilityString.",
              numbered: numbered);
        }
      } else {
        write(
            incompatibility,
            "Because "
            "${cause.conflict.andToString(cause.other, detailsForCause)}, "
            "$incompatibilityString.",
            numbered: numbered);
      }
    }

    visit(incompatibility, const {});

    // Only add line numbers if the derivation actually needs to refer to a line
    // by number.
    var padding =
        lineNumbers.isEmpty ? 0 : "(${lineNumbers.values.last}) ".length;

    var buffer = new StringBuffer();
    var lastWasEmpty = false;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var message = line.first;
      if (message.isEmpty) {
        if (!lastWasEmpty) buffer.writeln();
        lastWasEmpty = true;
        continue;
      } else {
        lastWasEmpty = false;
      }

      var number = line.last;
      if (number != null) {
        message = "(${number})".padRight(padding) + message;
      } else {
        message = " " * padding + message;
      }

      buffer.writeln(wordWrap(message, prefix: " " * (padding + 2)));
    }

    return buffer.toString();
  }

  /// Returns a map indicating the number of times each [Incompatibility]
  /// appears in [cause]'s derivation tree.
  ///
  /// When an [Incompatibility] is used in multiple derivations, we need to give
  /// it a number so we can refer back to it later on.
  Map<Incompatibility, int> _countDerivations() {
    var derivations = <Incompatibility, int>{};

    void visit(Incompatibility incompatibility) {
      if (derivations.containsKey(incompatibility)) {
        derivations[incompatibility]++;
      } else {
        derivations[incompatibility] = 1;
        var cause = incompatibility.cause;
        if (cause is ConflictCause) {
          visit(cause.conflict);
          visit(cause.other);
        }
      }
    }

    visit(incompatibility);
    return derivations;
  }

  /// Returns the amount of detail needed for each package to accurately
  /// describe [cause].
  ///
  /// If the same package name appears in both of [cause]'s incompatibilities
  /// but each has a different source, those incompatibilities should explicitly
  /// print their sources, and similarly for differing descriptions.
  Map<String, PackageDetail> _detailsForCause(ConflictCause cause) {
    var conflictPackages = <String, PackageName>{};
    for (var term in cause.conflict.terms) {
      conflictPackages[term.package.name] = term.package;
    }

    var details = <String, PackageDetail>{};
    for (var term in cause.other.terms) {
      var conflictPackage = conflictPackages[term.package.name];
      if (conflictPackage == null) continue;
      if (conflictPackage.source != term.package.source) {
        details[term.package.name] = PackageDetail.source;
      } else if (!conflictPackage.samePackage(term.package)) {
        details[term.package.name] = PackageDetail.description;
      }
    }

    return details;
  }
}
