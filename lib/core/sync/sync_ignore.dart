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
  _Rule(this.regex, this.negate, this.dirOnly);
  final RegExp regex;
  final bool negate;
  final bool dirOnly;
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
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      var negate = false, dirOnly = false;
      if (line.startsWith('!')) {
        negate = true;
        line = line.substring(1);
      }
      if (line.endsWith('/')) {
        dirOnly = true;
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) continue;
      // A slash before the end anchors the pattern at the top.
      final anchored = line.contains('/');
      if (line.startsWith('/')) line = line.substring(1);
      final body = _globToRegex(line);
      try {
        final regex = RegExp('^${anchored ? '' : '(?:.*/)?'}$body\$',
            caseSensitive: !pathsIgnoreCase);
        _rules.add(_Rule(regex, negate, dirOnly));
      } on FormatException {
        // not a usable pattern: skipped, as the desktop does
      }
    }
  }

  final String text;
  final _rules = <_Rule>[];

  bool get isEmpty => _rules.isEmpty;

  bool _matchesItself(String path, bool isDir) {
    var result = false;
    for (final rule in _rules) {
      if (rule.dirOnly && !isDir) continue;
      if (rule.regex.hasMatch(path)) result = !rule.negate;
    }
    return result;
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
