import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/autostart_service.dart';

final autostartServiceProvider = Provider<AutostartService>(
  (ref) => AutostartService.forPlatform(),
);

/// Whether signing in starts the app. Read from the operating system each time
/// Settings opens, since the user can change it there too.
class AutostartNotifier extends Notifier<bool> {
  AutostartService get _service => ref.read(autostartServiceProvider);

  @override
  bool build() => _current();

  void setEnabled(bool on) {
    try {
      _service.setEnabled(on);
    } catch (_) {
      /* left as it was; the toggle shows what the system has */
    }
    state = _current();
  }

  bool _current() {
    try {
      return _service.supported && _service.isEnabled();
    } catch (_) {
      return false;
    }
  }
}

final autostartProvider = NotifierProvider.autoDispose<AutostartNotifier, bool>(
  AutostartNotifier.new,
);
