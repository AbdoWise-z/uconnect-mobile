// Short, human forms of sizes, rates, durations and times, shared by the
// pages that show what sync is doing.

String formatBytes(num n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String formatRate(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// "4 s", "2 min", "1 h 20 min".
String formatDuration(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}

/// "just now", "5 min ago", "yesterday 14:02", "2026-10-12".
String formatAgo(int ms, {DateTime? now}) {
  if (ms <= 0) return 'never';
  final then = DateTime.fromMillisecondsSinceEpoch(ms);
  final at = now ?? DateTime.now();
  final diff = at.difference(then);
  if (diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24 && at.day == then.day) return 'today ${_hm(then)}';
  if (diff.inHours < 48) return 'yesterday ${_hm(then)}';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  return formatDate(then);
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

String formatDate(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}';

String formatDateTime(DateTime t) => '${formatDate(t)} ${_hm(t)}';

String formatTime(DateTime t) => '${_hm(t)}:${_two(t.second)}';

String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';
