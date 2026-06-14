String fmtBytes(int n, {int dp = 1}) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = n.toDouble();
  int i = -1;
  do {
    v /= 1024;
    i++;
  } while (v >= 1024 && i < units.length - 1);
  final precision = v >= 100 ? 0 : dp;
  return '${v.toStringAsFixed(precision)} ${units[i]}';
}

String fmtSpeed(int bps) {
  if (bps <= 0) return '0 KB/s';
  return '${fmtBytes(bps)}/s';
}

String fmtEta(int seconds) {
  if (seconds <= 0) return '—';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m}m ${s}s';
  }
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return '${h}h ${m}m';
}

String fmtPct(double p) {
  final pct = (p * 100);
  return '${pct >= 99.95 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1)}%';
}

String timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} d ago';
}
