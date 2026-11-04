import 'package:flutter/material.dart';

import '../../state/app_state.dart';

/// 设备卡片：广播温湿度/电量、连接状态、参数/记录入口。
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.expanded,
    required this.onTap,
    required this.onConnect,
    required this.onDisconnect,
    required this.onEditParams,
    required this.onRecord,
  });

  final DeviceState device;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onEditParams;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sensor = device.sensor;
    final highlight = device.connected || expanded;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: highlight ? const Color(0xFF81D4FA) : theme.colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      device.displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${device.rssi} dBm',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              ),
              Text(
                device.deviceId,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (sensor != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Text(
                        '${sensor.voltage.toStringAsFixed(3)}V',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${sensor.temperature.toStringAsFixed(1)}°C',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${sensor.humidity}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (device.connected && device.authenticated) ...[
                    FilledButton.tonal(
                      onPressed: onEditParams,
                      child: const Text('修改参数'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.tonal(
                      onPressed: onRecord,
                      child: const Text('记录'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: onDisconnect,
                      child: const Text('断开'),
                    ),
                  ] else if (device.connected) ...[
                    FilledButton(
                      onPressed: onDisconnect,
                      child: const Text('断开'),
                    ),
                  ] else if (device.connecting)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    FilledButton(
                      onPressed: onConnect,
                      child: const Text('连接'),
                    ),
                ],
              ),
              if (expanded && sensor != null) ...[
                const SizedBox(height: 8),
                const _DividerText('Sensor Data'),
                const SizedBox(height: 4),
                _DetailRow(
                  'Broadcast Interval',
                  '${SensorDataInterval.ms(sensor.intervalCode)} ms',
                ),
                _DetailRow('Record Interval', '${sensor.recordInterval}s'),
                _DetailRow('Tx Power', '${sensor.txPowerLevel} dBm'),
                _DetailRow('Records', '${sensor.recordCount}'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SensorDataInterval {
  const SensorDataInterval._();

  static int ms(int code) {
    const map = {
      0x01: 100,
      0x02: 200,
      0x03: 300,
      0x04: 400,
      0x05: 500,
      0x06: 600,
      0x07: 700,
      0x08: 800,
      0x09: 900,
      0x0A: 1000,
      0x0B: 1500,
      0x0C: 2000,
      0x0D: 2500,
      0x0E: 3000,
      0x0F: 5000,
      0x10: 10000,
    };
    return map[code] ?? code * 100;
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

class _DividerText extends StatelessWidget {
  const _DividerText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
