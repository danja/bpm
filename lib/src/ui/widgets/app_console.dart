import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/app_logger.dart';

/// In-app console widget that displays log messages
class AppConsole extends StatefulWidget {
  final bool initiallyExpanded;
  final double collapsedHeight;
  final double expandedHeight;

  const AppConsole({
    super.key,
    this.initiallyExpanded = false,
    this.collapsedHeight = 34,
    this.expandedHeight = 210,
  });

  @override
  State<AppConsole> createState() => _AppConsoleState();
}

class _AppConsoleState extends State<AppConsole> {
  final _logger = AppLogger();
  final _scrollController = ScrollController();
  bool _isExpanded = false;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = _isExpanded ? widget.expandedHeight : widget.collapsedHeight;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            child: Container(
              height: widget.collapsedHeight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    _isExpanded ? Icons.expand_more : Icons.expand_less,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Console',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  StreamBuilder<List<LogEntry>>(
                    stream: _logger.logStream,
                    initialData: _logger.logs,
                    builder: (context, snapshot) {
                      final count = snapshot.data?.length ?? 0;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$count',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    },
                  ),
                  const Spacer(),
                  if (_isExpanded) ...[
                    // Auto-scroll toggle
                    Tooltip(
                      message: 'Auto-scroll',
                      child: IconButton(
                        icon: Icon(
                          _autoScroll ? Icons.arrow_downward : Icons.pause,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() {
                            _autoScroll = !_autoScroll;
                          });
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                    ),
                    // Clear button
                    Tooltip(
                      message: 'Clear console',
                      child: IconButton(
                        icon: const Icon(Icons.clear_all, size: 18),
                        onPressed: () {
                          _logger.clear();
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Log content
          if (_isExpanded)
            Expanded(
              child: StreamBuilder<List<LogEntry>>(
                stream: _logger.logStream,
                initialData: _logger.logs,
                builder: (context, snapshot) {
                  final logs = snapshot.data ?? [];

                  if (logs.isEmpty) {
                    return Center(
                      child: Text(
                        'No logs yet',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }

                  _scrollToBottom();

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      return InkWell(
                        onLongPress: () {
                          // Copy log message to clipboard
                          Clipboard.setData(
                            ClipboardData(text: log.message),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Log copied to clipboard'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Timestamp
                              Text(
                                log.formattedTime,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 10,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Level badge
                              Container(
                                width: 5,
                                height: 14,
                                margin: const EdgeInsets.only(top: 2),
                                decoration: BoxDecoration(
                                  color: _levelColor(log.level),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Source (if present)
                              if (log.source != null) ...[
                                Text(
                                  '[${log.source}]',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                    color: theme.colorScheme.primary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              // Message
                              Expanded(
                                child: Text(
                                  log.message,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
