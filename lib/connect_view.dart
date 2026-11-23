import 'dart:async';

import 'package:flutter/material.dart';

import 'about.dart';
import 'main.dart';
import 'pairing.dart';

class ConnectView extends StatefulWidget {
  const ConnectView({
    super.key,
    required this.onConnect,
    this.error,
  });

  final ValueChanged<PairingPayload> onConnect;
  final String? error;

  @override
  State<ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends State<ConnectView> {
  bool _autoConnect = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    if (_autoConnect) {
      _startAutoConnect();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startAutoConnect() {
    _pollTimer?.cancel();
    // Prompt connect right away
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.error == null) {
        widget.onConnect(PairingPayload.usb);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BeamCam (USB)'),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (context, mode, _) => PopupMenuButton<ThemeMode>(
              icon: Icon(mode.icon),
              tooltip: 'Appearance',
              initialValue: mode,
              onSelected: (m) => unawaited(setThemeMode(m)),
              itemBuilder: (context) => [
                for (final m in ThemeMode.values)
                  PopupMenuItem(
                    value: m,
                    child: Row(
                      children: [
                        Icon(m.icon, size: 18),
                        const SizedBox(width: 12),
                        Text(m.label),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About',
            onPressed: () => unawaited(showAboutSheet(context)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          if (widget.error != null) ...[
            Card(
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: scheme.onErrorContainer,
                ),
                title: Text(
                  widget.error!,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          Card(
            color: scheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.usb, size: 32, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Direct USB Connection',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Zero Wi-Fi, zero internet. Video & audio stream directly through the USB cable into your Mac with minimal latency.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onPrimaryContainer.withOpacity(0.9),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                      ),
                      onPressed: () => widget.onConnect(PairingPayload.usb),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text(
                        'Start USB Streaming',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          Text(
            'Quick Setup Instructions',
            style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _StepTile(
                    number: '1',
                    title: 'Plug USB cable',
                    description: 'Connect your phone to your MacBook Pro using a USB-C cable.',
                  ),
                  const Divider(height: 20),
                  _StepTile(
                    number: '2',
                    title: 'Enable USB Debugging',
                    description: 'In Android Settings › Developer options › USB debugging (ON).',
                  ),
                  const Divider(height: 20),
                  _StepTile(
                    number: '3',
                    title: 'Open Mac App or run bridge',
                    description: 'Open BeamCam on Mac, or run in Terminal:\nadb reverse tcp:8787 tcp:8787',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.autorenew),
              title: const Text('Auto-connect on launch'),
              subtitle: const Text('Automatically connects when app is opened'),
              value: _autoConnect,
              onChanged: (v) {
                setState(() => _autoConnect = v);
                if (v) _startAutoConnect();
              },
            ),
          ),
          const SizedBox(height: 28),
          const AboutFooter(),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.number,
    required this.title,
    required this.description,
  });

  final String number;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
          child: Text(
            number,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
