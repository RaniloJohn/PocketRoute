import 'package:flutter/material.dart';

import 'src/settings.dart';
import 'src/theme.dart';
import 'src/ui/lab_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Landscape unless the user picked otherwise in View › Screen: the canvas
  // and an 80-column console like width.
  final settings = await AppSettings.load();
  await settings.applyOrientation();
  runApp(PocketRouteApp(settings: settings));
}

class PocketRouteApp extends StatelessWidget {
  const PocketRouteApp({super.key, this.settings});

  final AppSettings? settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketRoute',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: LabScreen(settings: settings ?? AppSettings()),
    );
  }
}
