import 'package:flutter/services.dart' show appFlavor;

/// Where this build is published, from the Android flavor it was built as
/// (android/app/build.gradle.kts). Desktop builds have no flavor and are [foss].
enum Store {
  /// GitHub releases, F-Droid and builds from source, with no Google code.
  foss,

  /// Google Play, which updates the app itself. Play Billing goes only here.
  play,
}

const Store store = appFlavor == 'play' ? Store.play : Store.foss;
