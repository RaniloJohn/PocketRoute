import 'package:flutter/material.dart';

import 'src/theme.dart';
import 'src/ui/lab_screen.dart';

void main() => runApp(const PocketRouteApp());

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
