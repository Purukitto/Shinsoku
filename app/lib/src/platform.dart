import 'dart:io';

import 'package:flutter/widgets.dart';

/// Windows, Linux and macOS: a window, a tray and the browser extension. Phones
/// get the mobile shell instead.
final bool isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Below this width, screens stack into a single column.
const double compactWidth = 600;

bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidth;
