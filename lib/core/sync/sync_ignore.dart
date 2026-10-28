// .gitignore-style patterns, for .syncignore (shared by every member) and
// .syncskip (this device only). A port of uconnect-desktop's SyncIgnore:
//
//   # comment           lines starting with # are skipped
//   *.tmp               a name anywhere in the tree; * and ? stay within one
//                       name, [abc] is a set of characters
//   /build              anchored: only at the top of the synced folder
//   docs/*.pdf          a pattern with a slash is anchored too
//   cache/              a trailing slash matches folders only
//   **/logs, a/**/b     ** spans any number of folders
//   !keep.tmp           a later ! pattern brings a match back
//
// As in git, nothing inside an excluded folder can be brought back. Matching
// ignores case where the file system does (Windows, macOS).

import 'sync_model.dart';

class _Rule {
  _Rule(this.regex, this.negate, this.dirOnly, this.line, this.pattern);
  final RegExp regex;
  final bool negate;
  final bool dirOnly;
  final int line; // 1-based line in the text
  final String pattern; // the line as written
}

/// The rule that decided a path: the last one matching it (or a folder above
/// it, named in [via]), [negate] when that rule brought it back. [line] is 0
/// when no rule matches, so the path is not excluded.
class RuleMatch {
  const RuleMatch({this.line = 0, this.pattern = '', this.negate = false, this.via = ''});
  final int line;
  final String pattern;
  final bool negate;
  final String via;
  bool get excluded => line > 0 && !negate;

  Map<String, Object?> toJson() =>
      {'line': line, 'pattern': pattern, 'negate': negate, 'via': via};
}

/// A line that is not a usable pattern, and is skipped.
class RuleProblem {
  const RuleProblem(this.line, this.pattern);
  final int line;
  final String pattern;
  Map<String, Object?> toJson() => {'line': line, 'pattern': pattern};
}

// A glob, translated to a regular expression over a whole relative path.
String _globToRegex(String glob) {
  final out = StringBuffer();
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        final slashAfter = i + 2 < glob.length && glob[i + 2] == '/';
        if (slashAfter) {
          out.write('(?:.*/)?'); // "**/": any number of folders
          i += 2;
        } else {
          out.write('.*'); // "**" elsewhere: anything
          i += 1;
        }
      } else {
        out.write('[^/]*');
      }
    } else if (c == '?') {
      out.write('[^/]');
    } else if (c == '[') {
      final close = glob.indexOf(']', i + 1);
      if (close < 0) {
        out.write(r'\[');
        continue;
      }
      var set = glob.substring(i + 1, close);
      if (set.startsWith('!')) set = '^${set.substring(1)}';
      set = set.replaceAll(r'\', r'\\');
      out.write('[$set]');
      i = close;
    } else if (c == r'\' && i + 1 < glob.length) {
      out.write(RegExp.escape(glob[++i]));
    } else {
      out.write(RegExp.escape(c));
    }
  }
  return out.toString();
}

class IgnoreRules {
  IgnoreRules([this.text = '']) {
    var lineNo = 0;
    for (var line in text.split('\n')) {
      lineNo++;
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final pattern = line;
      var negate = false, dirOnly = false;
      if (line.startsWith('!')) {
        negate = true;
        line = line.substring(1);
      }
      if (line.endsWith('/')) {
        dirOnly = true;
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) {
        problems.add(RuleProblem(lineNo, pattern));
        continue;
      }
      // A slash before the end anchors the pattern at the top.
      final anchored = line.contains('/');
      if (line.startsWith('/')) line = line.substring(1);
      final body = _globToRegex(line);
      try {
        final regex = RegExp('^${anchored ? '' : '(?:.*/)?'}$body\$',
            caseSensitive: !pathsIgnoreCase);
        _rules.add(_Rule(regex, negate, dirOnly, lineNo, pattern));
      } on FormatException {
        problems.add(RuleProblem(lineNo, pattern)); // skipped, as the desktop does
      }
    }
  }

  final String text;
  final _rules = <_Rule>[];

  /// Lines that are not usable patterns.
  final problems = <RuleProblem>[];

  bool get isEmpty => _rules.isEmpty;

  _Rule? _lastMatching(String path, bool isDir) {
    _Rule? last;
    for (final rule in _rules) {
      if (rule.dirOnly && !isDir) continue;
      if (rule.regex.hasMatch(path)) last = rule;
    }
    return last;
  }

  bool _matchesItself(String path, bool isDir) {
    final last = _lastMatching(path, isDir);
    return last != null && !last.negate;
  }

  /// The rule that decided `path`; see [RuleMatch].
  RuleMatch explain(String path, bool isDir) {
    if (_rules.isEmpty) return const RuleMatch();
    // A folder above it that is excluded decides, whatever the rules say
    // about the path itself.
    for (var slash = path.indexOf('/');
        slash >= 0;
        slash = path.indexOf('/', slash + 1)) {
      final parent = path.substring(0, slash);
      final rule = _lastMatching(parent, true);
      if (rule != null && !rule.negate) {
        return RuleMatch(
            line: rule.line, pattern: rule.pattern, negate: false, via: parent);
      }
    }
    final rule = _lastMatching(path, isDir);
    if (rule == null) return const RuleMatch();
    return RuleMatch(line: rule.line, pattern: rule.pattern, negate: rule.negate);
  }

  /// Whether `path` (relative, '/'-separated) or a folder above it matches.
  bool matches(String path, bool isDir) {
    if (_rules.isEmpty) return false;
    for (var slash = path.indexOf('/');
        slash >= 0;
        slash = path.indexOf('/', slash + 1)) {
      if (_matchesItself(path.substring(0, slash), true)) return true;
    }
    return _matchesItself(path, isDir);
  }
}

/// A pattern matching exactly `path`, for adding one file to .syncskip.
String exactPattern(String path) {
  final out = StringBuffer('/');
  for (final c in path.split('')) {
    if ('*?[\\!#'.contains(c)) out.write(r'\');
    out.write(c);
  }
  return out.toString();
}
