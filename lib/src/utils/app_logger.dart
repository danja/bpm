import 'dart:async';
import 'dart:developer' as dev;

/// Log level for categorizing messages
enum LogLevel {
  debug,
  info,
  warning,
  error,
}

/// A single log entry
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final String? source;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.source,
  });

  String get levelName {
    switch (level) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  String get formattedTime {
    final time = timestamp;
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${(time.millisecond ~/ 10).toString().padLeft(2, '0')}';
  }
}

/// In-app logger that captures logs for display in UI
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  final _logs = <LogEntry>[];
  final _controller = StreamController<List<LogEntry>>.broadcast();

  static const int _maxLogs = 500; // Keep last 500 logs

  /// Stream of log entries
  Stream<List<LogEntry>> get logStream => _controller.stream;

  /// Current log entries
  List<LogEntry> get logs => List.unmodifiable(_logs);

  /// Add a log entry
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? source,
  }) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      source: source,
    );

    _logs.add(entry);

    // Trim old logs if needed
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    // Also log to developer console
    dev.log(
      message,
      name: source ?? 'BPM',
      level: _levelToDevLevel(level),
    );

    // Notify listeners
    _controller.add(List.unmodifiable(_logs));
  }

  /// Clear all logs
  void clear() {
    _logs.clear();
    _controller.add(List.unmodifiable(_logs));
  }

  /// Convenience methods
  void debug(String message, {String? source}) =>
      log(message, level: LogLevel.debug, source: source);

  void info(String message, {String? source}) =>
      log(message, level: LogLevel.info, source: source);

  void warning(String message, {String? source}) =>
      log(message, level: LogLevel.warning, source: source);

  void error(String message, {String? source}) =>
      log(message, level: LogLevel.error, source: source);

  int _levelToDevLevel(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warning:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }

  void dispose() {
    _controller.close();
  }
}
