import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import '../../main.dart' show firebaseAvailable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/services/debug_log_service.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  final _log = DebugLogService.instance;
  LogCategory? _filter;
  Timer? _refreshTimer;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Refresh every 2 seconds to pick up new entries
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        if (mounted) setState(() {});
      },
    );
    // Log a memory snapshot when opening the screen
    _log.getMemoryUsage();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _log.entriesForCategory(_filter);
    final physicalMB = _log.lastPhysicalMB;
    final availableMB = _log.lastAvailableMB;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy log',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _log.export()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log copied to clipboard')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: () async {
              await _log.clear();
              setState(() {});
            },
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              if (action == 'test_crash' && firebaseAvailable) {
                // Force a test crash to verify Crashlytics
                FirebaseCrashlytics.instance.crash();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'test_crash',
                child: Text('Test Crash (Crashlytics)'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Memory status bar
          _buildMemoryBar(physicalMB, availableMB),

          // Category filter chips
          _buildFilterRow(),

          // Log entries
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text('No log entries',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true, // newest at bottom, scrolls from bottom
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      // Reverse index so newest is at bottom
                      final entry = entries[entries.length - 1 - index];
                      return _buildLogEntry(entry);
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () async {
          final mem = await _log.getMemoryUsage();
          _log.log(LogCategory.memory,
              '${mem['physicalFootprintMB']}MB used, ${mem['availableMemoryMB']}MB available (manual check)');
          if (mounted) setState(() {});
        },
        tooltip: 'Check memory now',
        child: const Icon(Icons.memory),
      ),
    );
  }

  Widget _buildMemoryBar(int physicalMB, int availableMB) {
    final totalMB = physicalMB + availableMB;
    final usageRatio = totalMB > 0 ? physicalMB / totalMB : 0.0;
    final color = usageRatio > 0.8
        ? Colors.red
        : usageRatio > 0.6
            ? Colors.orange
            : Colors.green;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey[900],
      child: Row(
        children: [
          Icon(Icons.memory, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            '${physicalMB}MB',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'used',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: usageRatio.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Colors.grey[800],
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${availableMB}MB free',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          _filterChip('All', null),
          ...LogCategory.values.map((c) => _filterChip(c.tag, c)),
        ],
      ),
    );
  }

  Widget _filterChip(String label, LogCategory? category) {
    final selected = _filter == category;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        selected: selected,
        onSelected: (_) => setState(() => _filter = category),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildLogEntry(LogEntry entry) {
    final color = _colorForCategory(entry.category);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              entry.timeString,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Colors.grey[600],
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text(
              entry.category.tag,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: entry.isError ? Colors.red[300] : Colors.grey[300],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _colorForCategory(LogCategory category) {
    switch (category) {
      case LogCategory.memory:
        return Colors.cyan;
      case LogCategory.stt:
        return Colors.orange;
      case LogCategory.tts:
        return Colors.green;
      case LogCategory.rehearsal:
        return Colors.purple;
      case LogCategory.network:
        return Colors.blue;
      case LogCategory.general:
        return Colors.grey;
      case LogCategory.error:
        return Colors.red;
    }
  }
}
