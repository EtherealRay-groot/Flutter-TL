import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/scanner_screen.dart';

void main() {
  runApp(const ProviderScope(child: TlApp()));
}

class TlApp extends StatelessWidget {
  const TlApp({super.key});

  /// 与原 Compose `EartagTheme` 的静态回退色一致。
  static const Color _fallbackSeed = Color(0xFF6650A4);

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final lightScheme =
            lightDynamic ?? ColorScheme.fromSeed(seedColor: _fallbackSeed);
        final darkScheme = darkDynamic ??
            ColorScheme.fromSeed(
              seedColor: _fallbackSeed,
              brightness: Brightness.dark,
            );
        return MaterialApp(
          title: 'TL',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorScheme: lightScheme, useMaterial3: true),
          darkTheme: ThemeData(colorScheme: darkScheme, useMaterial3: true),
          themeMode: ThemeMode.system,
          home: const ScannerScreen(),
        );
      },
    );
  }
}
