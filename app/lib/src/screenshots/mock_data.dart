// Deterministic mock dataset for the screenshot harness (lib/main_screenshots.dart).
// Not referenced by the real entry point (main.dart), so it is tree-shaken out of
// normal release builds. Numbers are frozen — no live ticking — so every capture
// is pixel-identical and the speed graphs/segment maps stay populated.
import 'dart:math' as math;

import '../models/download_item.dart';
import '../providers/capture_provider.dart';
import '../rust/api.dart' as rust;
import '../services/settings_service.dart';

/// Pleasant, deterministic throughput waveform around [base] bytes/s.
List<int> _wave(int base, {int n = 60, double amp = 0.24, double phase = 0}) =>
    List<int>.generate(n, (i) {
      final t = (i + phase) / n * 2 * math.pi;
      final w = 1 + amp * (math.sin(t * 2.3) * 0.6 + math.sin(t * 0.7 + 1.1) * 0.4);
      // gentle ramp-in over the first sixth so the line rises into frame
      final ramp = i < n / 6 ? i / (n / 6) : 1.0;
      final v = (base * w * ramp).round();
      return v < 0 ? 0 : v;
    });

/// `count` per-connection bars jittered around overall progress [p] for a
/// realistic segment map.
List<SegmentInfo> _segs(int count, double p) => List<SegmentInfo>.generate(count, (i) {
  final j = (((i * 53) % 31) - 15) / 60.0; // ~ -0.25..0.25
  return SegmentInfo(index: i, progress: (p + j).clamp(0.04, 1.0));
});

DateTime _ago(Duration d) => DateTime.now().subtract(d);

const _kb = 1024;
const _mb = 1024 * _kb;
const _gb = 1024 * _mb;

/// Active queue — varied protocols/states so the list, hero and detail screens
/// all read as a busy, real session. Order here is preserved within a status
/// bucket by `visibleDownloadIdsProvider` (downloading first, then paused, then
/// queued).
final List<DownloadItem> mockDownloads = [
  // ── rich multi-segment HTTP download; the natural hero/detail subject ──
  DownloadItem(
    id: 'dl-ubuntu',
    name: 'ubuntu-24.04.1-desktop-amd64.iso',
    host: 'releases.ubuntu.com',
    fileType: FileType.iso,
    totalBytes: (5.7 * _gb).round(),
    downloadedBytes: (5.7 * _gb * 0.62).round(),
    speedBps: 29800000,
    peakBps: 34600000,
    status: DownloadStatus.downloading,
    connections: 16,
    segments: _segs(16, 0.62),
    speedHistory: _wave(29800000),
    addedAt: _ago(const Duration(minutes: 4)),
    checksum: 'e240e4b801f7bb68c20d1356b60968ad0903e2c5f1a47b9d63e08f1c2a4b7d9e',
    checksumAlgo: 'sha256',
    checksumVerified: true,
  ),
  DownloadItem(
    id: 'dl-cyberpunk',
    name: 'Cyberpunk_Cinematic_4K_HDR.mp4',
    host: 'cdn.media-vault.io',
    fileType: FileType.video,
    totalBytes: (1.72 * _gb).round(),
    downloadedBytes: (1.72 * _gb * 0.75).round(),
    speedBps: 18900000,
    peakBps: 22100000,
    status: DownloadStatus.downloading,
    connections: 12,
    segments: _segs(12, 0.75),
    speedHistory: _wave(18900000, phase: 9),
    addedAt: _ago(const Duration(minutes: 7)),
    checksum: 'd41d8cd98f00b204e9800998ecf8427e',
    checksumAlgo: 'md5',
    checksumVerified: true,
  ),
  DownloadItem(
    id: 'dl-blender',
    name: 'blender-4.2.0-windows-x64.msi',
    host: 'download.blender.org',
    fileType: FileType.app,
    totalBytes: (312 * _mb).round(),
    downloadedBytes: (312 * _mb * 0.41).round(),
    speedBps: 12600000,
    peakBps: 15400000,
    status: DownloadStatus.downloading,
    connections: 8,
    segments: _segs(8, 0.41),
    speedHistory: _wave(12600000, phase: 21),
    addedAt: _ago(const Duration(minutes: 2)),
  ),
  // ── HLS (M3U8) stream — segment-count progress, engine-chosen parallelism ──
  DownloadItem(
    id: 'dl-keynote',
    name: 'Keynote_2025_Livestream.ts',
    host: 'live.streamhost.tv',
    fileType: FileType.video,
    totalBytes: (2.4 * _gb).round(),
    downloadedBytes: (2.4 * _gb * 132 / 240).round(),
    speedBps: 9400000,
    peakBps: 13800000,
    status: DownloadStatus.downloading,
    connections: 6,
    segments: const [],
    speedHistory: _wave(9400000, phase: 33),
    addedAt: _ago(const Duration(minutes: 11)),
    isHls: true,
    segmentTotal: 240,
    segmentDone: 132,
  ),
  // ── paused ──
  DownloadItem(
    id: 'dl-design',
    name: 'DesignSystem_Assets_v3.zip',
    host: 'files.studio-aurora.com',
    fileType: FileType.archive,
    totalBytes: (740 * _mb).round(),
    downloadedBytes: (740 * _mb * 0.56).round(),
    speedBps: 0,
    peakBps: 19200000,
    status: DownloadStatus.paused,
    connections: 8,
    segments: _segs(8, 0.56),
    speedHistory: _wave(19200000, phase: 5),
    addedAt: _ago(const Duration(minutes: 14)),
  ),
  // ── queued ──
  DownloadItem(
    id: 'dl-album',
    name: 'Live_Set_Master_Lossless.flac',
    host: 'dropbox-cdn.com',
    fileType: FileType.audio,
    totalBytes: (180 * _mb).round(),
    downloadedBytes: 0,
    speedBps: 0,
    peakBps: 0,
    status: DownloadStatus.queued,
    connections: 8,
    segments: const [],
    speedHistory: const [],
    addedAt: _ago(const Duration(minutes: 1)),
  ),
];

DownloadItem? mockDownloadById(String id) {
  for (final d in mockDownloads) {
    if (d.id == id) return d;
  }
  return null;
}

/// Finished history for the Completed tab (newest first).
final List<CompletedDownload> mockCompleted = [
  CompletedDownload(
    name: 'Annual_Report_2025.pdf',
    host: 'reports.company.com',
    fileType: FileType.doc,
    totalBytes: (48 * _mb).round(),
    avgSpeedBps: 12400000,
    completedAt: _ago(const Duration(seconds: 40)),
  ),
  CompletedDownload(
    name: 'Lossless_Discography_FLAC.zip',
    host: 'bandcamp-dl.com',
    fileType: FileType.audio,
    totalBytes: (2.1 * _gb).round(),
    avgSpeedBps: 28600000,
    completedAt: _ago(const Duration(minutes: 20)),
  ),
  CompletedDownload(
    name: 'Sample_Pack_Vol3_96k.zip',
    host: 'files.studio-aurora.com',
    fileType: FileType.archive,
    totalBytes: (1.3 * _gb).round(),
    avgSpeedBps: 31200000,
    completedAt: _ago(const Duration(hours: 3)),
  ),
  CompletedDownload(
    name: 'Final_Render_8K.mp4',
    host: 'cdn.media-vault.io',
    fileType: FileType.video,
    totalBytes: (6.8 * _gb).round(),
    avgSpeedBps: 52800000,
    completedAt: _ago(const Duration(hours: 5)),
  ),
  CompletedDownload(
    name: 'Wallpapers_5K_Bundle.zip',
    host: 'unsplash-mirror.net',
    fileType: FileType.image,
    totalBytes: (880 * _mb).round(),
    avgSpeedBps: 35100000,
    completedAt: _ago(const Duration(hours: 6)),
  ),
  CompletedDownload(
    name: 'JetBrains_Toolbox.exe',
    host: 'download.jetbrains.com',
    fileType: FileType.app,
    totalBytes: (240 * _mb).round(),
    avgSpeedBps: 22300000,
    completedAt: _ago(const Duration(days: 1)),
  ),
  CompletedDownload(
    name: 'ubuntu-22.04.4-desktop-amd64.iso',
    host: 'releases.ubuntu.com',
    fileType: FileType.iso,
    totalBytes: (4.1 * _gb).round(),
    avgSpeedBps: 41700000,
    completedAt: _ago(const Duration(days: 2)),
  ),
  CompletedDownload(
    name: 'node-v18.20.0-x64.msi',
    host: 'nodejs.org',
    fileType: FileType.app,
    totalBytes: (95 * _mb).round(),
    avgSpeedBps: 18900000,
    completedAt: _ago(const Duration(days: 4)),
  ),
];

/// Settings tuned to show every panel meaningfully. Clipboard monitor is left
/// off so the capture banner never pops in mid-screenshot.
const AppSettings mockSettings = AppSettings(
  maxConnections: 16,
  maxSimultaneous: 3,
  downloadLimitMbps: 0,
  categorize: true,
  clipboardMonitor: false,
  uploadCap: false,
  uploadLimitMbps: 20,
  offPeakFullSpeed: true,
  offPeakStartMin: 23 * 60,
  offPeakEndMin: 7 * 60,
);

/// Browser-capture: paired + listening, with a stable token so the pairing code
/// renders identically every run.
const String _mockToken = '7f3a9c1e5b2d8f40a6e1b9c4d7a2e5b0';
const int _mockPort = 7878;

const CaptureState mockCapture = CaptureState(
  enabled: true,
  running: true,
  port: _mockPort,
  token: _mockToken,
);

/// "Browser connected · 12 captured" — a recent last-seen makes the status green.
final rust.CaptureStatus mockCaptureStatus = rust.CaptureStatus(
  running: true,
  port: _mockPort,
  lastSeenMs: DateTime.now().millisecondsSinceEpoch - 30000,
  captures: 12,
);

/// Hero sparkline; peaks near the summed live throughput.
final List<int> mockGlobalSpeed = _wave(70700000);
