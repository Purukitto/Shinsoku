import 'package:flutter/services.dart';

/// What the clipboard holds, read without reading it: Android 12 and later tell
/// the user each time an app reads the clipboard, so its text is read only when
/// this says something new might be a link.
class ClipInfo {
  const ClipInfo({required this.stamp, required this.text, required this.noLink});

  /// When it was copied; the same clip keeps the same stamp.
  final int stamp;

  /// Holds text (or a link), rather than an image or nothing.
  final bool text;

  /// Android has looked and found no link in it (Android 12 and later).
  final bool noLink;
}

/// Links other apps hand to Shinsoku on Android (`MainActivity.kt`): shared from
/// their share sheet, or opened with it as a download. Each arrives as the raw
/// text or link the other app sent.
class LinkService {
  LinkService._();

  static const _channel = MethodChannel('shinsoku/links');

  /// Calls [onText] for whatever is waiting now and for each one that arrives
  /// later. One listener at a time; [stop] removes it.
  static void listen(void Function(String text) onText) {
    Future<void> take() async {
      final text = await _call<String>('take');
      if (text != null && text.isNotEmpty) onText(text);
    }

    // The activity sends "ready" when it has one; asking at once covers a link
    // that came in before this listener did.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'ready') await take();
    });
    take();
  }

  static void stop() => _channel.setMethodCallHandler(null);

  /// Null when there is no clip, or no activity to ask.
  static Future<ClipInfo?> clip() async {
    final m = await _call<Map<Object?, Object?>>('clip');
    if (m == null) return null;
    return ClipInfo(
      stamp: (m['stamp'] as num?)?.toInt() ?? 0,
      text: m['text'] == true,
      noLink: m['noLink'] == true,
    );
  }

  /// No activity to talk to is not an error here.
  static Future<T?> _call<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
