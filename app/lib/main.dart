import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/theme.dart';
import 'src/ui/lab_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Landscape everywhere: the canvas and an 80-column console need width.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const PocketRouteApp());
}

class PocketRouteApp extends StatelessWidget {
  const PocketRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketRoute',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const LabScreen(),
    );
  }
}
