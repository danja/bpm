import 'package:bpm/src/app.dart';
import 'package:bpm/src/utils/app_logger.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final logger = AppLogger();
  logger.info('BPM Detector app starting', source: 'App');

  runApp(const BpmApp());
}
