import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/version_service.dart';

/// Running app version (e.g. "0.1.0"), read from the bundle.
final appVersionProvider = FutureProvider<String>((ref) => VersionService.current());

/// Non-null only when a newer GitHub release exists; checked once per launch and
/// silent on error/offline. Watched by the sidebar footer.
final updateProvider = FutureProvider<UpdateInfo?>((ref) async {
  final current = await ref.watch(appVersionProvider.future);
  return VersionService.checkForUpdate(current);
});
