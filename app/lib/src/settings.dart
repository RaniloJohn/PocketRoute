import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ScreenOrientation {
  landscape('Landscape'),
  portrait('Portrait'),
  auto('Auto-rotate');

  const ScreenOrientation(this.label);
  final String label;
}

/// App-wide preferences that outlive a lab, saved between launches.
class AppSettings extends ChangeNotifier {
  AppSettings({this.orientation = ScreenOrientation.landscape});

  static const _orientationKey = 'orientation';

  ScreenOrientation orientation;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_orientationKey);
    return AppSettings(
      orientation:
          ScreenOrientation.values.asNameMap()[saved] ??
          ScreenOrientation.landscape,
    );
  }

  Future<void> setOrientation(ScreenOrientation value) async {
    if (value == orientation) return;
    orientation = value;
    notifyListeners();
    await applyOrientation();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_orientationKey, value.name);
  }

  /// Auto-rotate leaves out upside-down portrait so Android maps it to the
  /// user's rotation lock rather than ignoring it.
  Future<void> applyOrientation() =>
      SystemChrome.setPreferredOrientations(switch (orientation) {
        ScreenOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        ScreenOrientation.portrait => const [DeviceOrientation.portraitUp],
        ScreenOrientation.auto => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      });
}
