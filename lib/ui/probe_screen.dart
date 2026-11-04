import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/probe_controller.dart';

class ProbeScreen extends ConsumerStatefulWidget {
  const ProbeScreen({super.key});

  @override
  ConsumerState<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends ConsumerState<ProbeScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
      () => ref.read(probeControllerProvider.notifier).initialize(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(probeControllerProvider);
    final c = ref.read(probeControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('TL BLE 验证'),
        actions: [
          IconButton(
            tooltip: '清空日志',
            onPressed: c.clearLogs,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _statusCard(context, state),
          const SizedBox(height: 12),
          _actions(context, state, c),
          const SizedBox(height: 12),
          if (state.connectedId != null) _connectedCard(context, state, c),
          const SizedBox(height: 12),
          _devicesSection(context, state, c),
          if (state.records.isNotEmpty) ...[
            const SizedBox(height: 12),
            _recordsSection(context, state),
          ],
          const SizedBox(height: 12),
          _logsSection(context, state),
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context, ProbeState s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  s.bluetoothOn ? Icons.bluetooth : Icons.bluetooth_disabled,
                  color: s.bluetoothOn ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text('蓝牙：${s.bluetoothOn ? "已开启" : "未开启"}'),
                const SizedBox(width: 16),
                Icon(
                  s.permissionGranted ? Icons.check_circle : Icons.lock,
                  color: s.permissionGranted ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text('权限：${s.permissionGranted ? "已授权" : "未授权"}'),
              ],
            ),
            const SizedBox(height: 6),
            Text(s.status),
            if (s.error != null)
              Text(
                s.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actions(
    BuildContext context,
    ProbeState s,
    ProbeController c,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: s.scanning ? c.stopScan : c.startScan,
          icon: Icon(s.scanning ? Icons.stop : Icons.search),
          label: Text(s.scanning ? '停止扫描' : '开始扫描'),
        ),
        OutlinedButton.icon(
          onPressed: s.connectedId == null ? null : c.readDeviceInfo,
          icon: const Icon(Icons.info_outline),
          label: const Text('读设备信息'),
        ),
        OutlinedButton.icon(
          onPressed: s.connectedId == null ? null : c.readAllRecords,
          icon: const Icon(Icons.download),
          label: const Text('读全部记录'),
        ),
        OutlinedButton.icon(
          onPressed: s.connectedId == null ? null : c.readLogistics,
          icon: const Icon(Icons.local_shipping_outlined),
          label: const Text('读物流'),
        ),
        OutlinedButton.icon(
          onPressed: s.connectedId == null ? null : c.verifyDefaultPassword,
          icon: const Icon(Icons.key_outlined),
          label: const Text('验证密码 1234'),
        ),
        OutlinedButton.icon(
          onPressed: s.connectedId == null ? null : c.startRecording,
          icon: const Icon(Icons.fiber_manual_record, color: Colors.red),
          label: const Text('开始记录 1s'),
        ),
        OutlinedButton.icon(
          onPressed: s.connectedId == null ? null : c.stopRecording,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('停止记录'),
        ),
        if (s.connectedId != null)
          OutlinedButton.icon(
            onPressed: c.disconnect,
            icon: const Icon(Icons.link_off),
            label: const Text('断开'),
          ),
      ],
    );
  }

  Widget _connectedCard(
    BuildContext context,
    ProbeState s,
    ProbeController c,
  ) {
    final infoLines = <String>[
      'MTU：${s.mtu ?? "-"}',
      '服务数：${s.services.length}',
      '记录条数：${s.recordCount ?? "-"}',
      '记录间隔：${s.recordInterval ?? "-"} s',
      '记录中：${s.recording ?? "-"}',
      if (s.startTimestamp != null)
        '起始时间：${_time(s.startTimestamp!)}',
      if (s.readProgressTotal > 0)
        '读取进度：${s.readProgressCurrent}/${s.readProgressTotal}',
      if (s.logistics != null)
        '物流：${s.logistics!.hasContent ? s.logistics!.company : "空块"}',
    ];
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已连接：${s.connectedId}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            for (final line in infoLines) Text(line),
          ],
        ),
      ),
    );
  }

  Widget _devicesSection(
    BuildContext context,
    ProbeState s,
    ProbeController c,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '扫描结果（${s.devices.length}）',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        if (s.devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('暂无设备，点击「开始扫描」')),
          ),
        for (final d in s.devices)
          Card(
            child: ListTile(
              leading: Icon(
                d.hasTlData ? Icons.thermostat : Icons.bluetooth,
                color: d.hasTlData ? Colors.deepOrange : Colors.grey,
              ),
              title: Text(d.name ?? d.deviceId),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.deviceId),
                  if (d.sensor != null)
                    Text(
                      '温度 ${d.sensor!.temperature.toStringAsFixed(2)}℃  '
                      '湿度 ${d.sensor!.humidity}%  '
                      '电压 ${d.sensor!.voltage.toStringAsFixed(3)}V  '
                      '条数 ${d.sensor!.recordCount}  '
                      '间隔 ${d.sensor!.recordInterval}s',
                    ),
                  if (d.ibeacon != null)
                    Text(
                      'iBeacon major=${d.ibeacon!.major} minor=${d.ibeacon!.minor} '
                      'rssi@1m=${d.ibeacon!.rssi1m}',
                    ),
                  if (d.manufacturerData.isNotEmpty)
                    Text(
                      '厂商数据：${d.manufacturerData.keys.map((k) => "0x${k.toRadixString(16).padLeft(4, "0").toUpperCase()}").join(", ")}',
                    ),
                  if (d.serviceData.isNotEmpty)
                    Text('Service Data：${d.serviceData.length} 段'),
                  if (d.services.isNotEmpty)
                    Text('广播服务：${d.services.length} 个'),
                ],
              ),
              trailing: s.connectingId == d.deviceId
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : s.connectedId == d.deviceId
                      ? const Icon(Icons.link, color: Colors.green)
                      : Text('${d.rssi} dBm'),
              isThreeLine: true,
              onTap: () => c.connect(d.deviceId),
            ),
          ),
      ],
    );
  }

  Widget _recordsSection(BuildContext context, ProbeState s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '记录（${s.records.length}）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 220,
              child: ListView.builder(
                itemCount: s.records.length,
                itemBuilder: (context, i) {
                  final r = s.records[i];
                  return Text(
                    '${_time(r.timestamp)}   ${r.temperature.toStringAsFixed(2)}℃   ${r.humidity}%',
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logsSection(BuildContext context, ProbeState s) {
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text('日志（${s.logs.length}）'),
      children: [
        Container(
          height: 220,
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.all(8),
          child: ListView.builder(
            reverse: true,
            itemCount: s.logs.length,
            itemBuilder: (context, i) {
              final line = s.logs[s.logs.length - 1 - i];
              return Text(
                line,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              );
            },
          ),
        ),
      ],
    );
  }

  String _time(int epochSec) =>
      DateFormat('MM-dd HH:mm:ss').format(
        DateTime.fromMillisecondsSinceEpoch(epochSec * 1000),
      );
}
