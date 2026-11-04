import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_controller.dart';
import '../state/app_state.dart';
import 'dialogs/logistics_dialog.dart';
import 'dialogs/param_dialog.dart';
import 'dialogs/password_dialog.dart';
import 'dialogs/record_dialog.dart';
import 'dialogs/start_confirm_dialog.dart';
import 'widgets/device_card.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
      () => ref.read(appControllerProvider.notifier).initialize(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final c = ref.read(appControllerProvider.notifier);

    return Stack(
      children: [
        Scaffold(
          key: _scaffoldKey,
          drawer: _SettingsDrawer(
            onSaved: () => _scaffoldKey.currentState?.closeDrawer(),
          ),
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            title: const Text(
              'Temperature logger v1.0',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 19),
            ),
            leading: IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            actions: [
              if (state.isScanning)
                IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: c.stopScan,
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    if (state.permissionGranted) {
                      c.startScan();
                    } else {
                      c.initialize();
                    }
                  },
                ),
            ],
          ),
          body: _body(context, state, c),
        ),
        if (state.showPasswordDialog)
          _overlay(c.dismissPasswordDialog, const PasswordDialog()),
        if (state.showStartConfirmDialog)
          _overlay(c.dismissStartConfirmDialog, const StartConfirmDialog()),
        if (state.showLogisticsDialog)
          _overlay(c.dismissLogisticsDialog, const LogisticsDialog()),
        if (state.showParamDialog)
          _overlay(c.dismissParamDialog, const ParamDialog()),
        if (state.showRecordDialog)
          _overlay(c.dismissRecordDialog, const RecordDialog()),
      ],
    );
  }

  Widget _overlay(VoidCallback onDismiss, Widget dialog) {
    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            onTap: onDismiss,
            child: Container(color: Colors.black54),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: dialog,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppState state,
    AppController c,
  ) {
    if (!state.bluetoothLeSupported) {
      return _StatusCard(
        icon: Icons.bluetooth_disabled,
        title: 'BLE Not Supported',
        message: 'This device does not support Bluetooth Low Energy.',
      );
    }
    if (!state.bluetoothEnabled) {
      return _StatusCard(
        icon: Icons.bluetooth_disabled,
        title: 'Bluetooth Disabled',
        message: 'Please enable Bluetooth to scan for devices.',
        buttonLabel: 'Enable',
        onPressed: c.enableBluetooth,
      );
    }
    if (!state.permissionGranted) {
      return _StatusCard(
        icon: Icons.bluetooth,
        title: 'Permission Required',
        message: 'Please grant Bluetooth permissions to scan for devices.',
        buttonLabel: 'Grant',
        onPressed: c.initialize,
      );
    }

    if (state.isScanning && state.devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Scanning for BLE devices...'),
          ],
        ),
      );
    }

    final connected = <DeviceState>[];
    final scanned = <DeviceState>[];
    for (final id in state.deviceOrder) {
      final d = state.devices[id];
      if (d == null) continue;
      (d.connected ? connected : scanned).add(d);
    }

    return Column(
      children: [
        if (state.errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              state.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final d in [...connected, ...scanned])
                DeviceCard(
                  key: ValueKey(d.deviceId),
                  device: d,
                  expanded: state.selectedDeviceId == d.deviceId,
                  onTap: () => c.onDeviceSelected(d.deviceId),
                  onConnect: () => c.connect(d.deviceId),
                  onDisconnect: () => c.disconnect(d.deviceId),
                  onEditParams: () => c.showParamEditor(d.deviceId),
                  onRecord: () => c.showRecordDialog(d.deviceId),
                ),
              if (scanned.isEmpty && connected.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: Text('No devices found. Tap scan.')),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.message,
    this.buttonLabel,
    this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              if (buttonLabel != null && onPressed != null) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onPressed,
                  child: Text(buttonLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsDrawer extends ConsumerStatefulWidget {
  const _SettingsDrawer({required this.onSaved});

  final VoidCallback onSaved;

  @override
  ConsumerState<_SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends ConsumerState<_SettingsDrawer> {
  late final TextEditingController _low;
  late final TextEditingController _high;
  late TemperatureUnit _unit;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appControllerProvider);
    _unit = s.temperatureUnit;
    _low = TextEditingController(text: s.alarmThresholdLow);
    _high = TextEditingController(text: s.alarmThresholdHigh);
  }

  @override
  void dispose() {
    _low.dispose();
    _high.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = ref.read(appControllerProvider.notifier);
    final current = ref.watch(appControllerProvider);

    return Drawer(
      width: 280,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Text('温度单位', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _unitButton(
                      '℃',
                      _unit == TemperatureUnit.celsius,
                      () => setState(() => _unit = TemperatureUnit.celsius),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _unitButton(
                      '℉',
                      _unit == TemperatureUnit.fahrenheit,
                      () => setState(() => _unit = TemperatureUnit.fahrenheit),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('报警阈值', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              TextField(
                controller: _low,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '下限 (${_unit.symbol})',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _high,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '上限 (${_unit.symbol})',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  if (_unit != current.temperatureUnit) c.toggleTemperatureUnit();
                  c.updateAlarmThresholdLow(_low.text);
                  c.updateAlarmThresholdHigh(_high.text);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('保存成功')),
                  );
                  widget.onSaved();
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unitButton(String label, bool selected, VoidCallback onTap) {
    final theme = Theme.of(context);
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHighest,
        foregroundColor: selected
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurfaceVariant,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: onTap,
      child: Text(label),
    );
  }
}
