import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/protocol/ibeacon_codec.dart';
import '../../state/app_controller.dart';
import 'dialog_style.dart';

class ParamDialog extends ConsumerStatefulWidget {
  const ParamDialog({super.key});

  @override
  ConsumerState<ParamDialog> createState() => _ParamDialogState();
}

class _ParamDialogState extends ConsumerState<ParamDialog> {
  late int _intervalCode;
  late int _txPower;
  late final TextEditingController _name;
  late final TextEditingController _uuid;
  late final TextEditingController _major;
  late final TextEditingController _minor;
  late final TextEditingController _company;
  late final TextEditingController _rssi;
  final _scroll = ScrollController();

  static const _intervalOptions = <int, String>{
    1: '100ms',
    2: '200ms',
    3: '300ms',
    4: '400ms',
    5: '500ms',
    6: '600ms',
    7: '700ms',
    8: '800ms',
    9: '900ms',
    10: '1000ms',
    11: '1500ms',
    12: '2000ms',
    13: '2500ms',
    14: '3000ms',
    15: '5000ms',
    16: '10000ms',
  };

  static const _txPowerOptions = <int, String>{
    0x7F: 'Auto (~0 dBm)',
    0x09: '+9.5 dBm',
    0x08: '+8.5 dBm',
    0x07: '+7.5 dBm',
    0x06: '+6.5 dBm',
    0x05: '+5.5 dBm',
    0x04: '+4.5 dBm',
    0x03: '+3.5 dBm',
    0x02: '+2.5 dBm',
    0x01: '+1.5 dBm',
    0x00: '0 dBm',
    0xFF: '-0.5~-1 dBm',
    0xFB: '-5 dBm',
    0xF7: '-9 dBm',
    0xEE: '-18 dBm',
    0xD1: '-47 dBm',
  };

  @override
  void initState() {
    super.initState();
    final s = ref.read(appControllerProvider);
    _intervalCode = s.currentIntervalCode;
    _txPower = s.currentTxPower;
    _name = TextEditingController(text: s.beaconName);
    _uuid = TextEditingController(
      text: IBeaconCodec.formatUuidHex(s.beaconUuidHex),
    );
    _major = TextEditingController(text: s.beaconMajor.toString());
    _minor = TextEditingController(text: s.beaconMinor.toString());
    _company = TextEditingController(
      text: IBeaconCodec.companyToHex(s.beaconCompany),
    );
    _rssi = TextEditingController(text: s.beaconRssi1m.toString());
  }

  @override
  void dispose() {
    for (final c in [_name, _uuid, _major, _minor, _company, _rssi]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final c = ref.read(appControllerProvider.notifier);
    final theme = Theme.of(context);
    final nameBytes = utf8.encode(_name.text.trim()).length;

    // 紧凑输入框：与原 Compose 一样单行，但压掉多余的内边距，
    // 让 9 个字段在 460dp 的滚动区里尽量多显示几行。
    InputDecoration deco(
      String label, {
      String? hint,
      String? errorText,
      String? helperText,
    }) => InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: errorText,
      helperText: helperText,
      border: const OutlineInputBorder(),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );

    return AlertDialog(
      // 参数表单较宽：水平只留 8dp，并保证至少 320dp，
      // 让 UUID 等长文本有足够横向空间。
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 560),
      title: const Text('设备参数'),
      content: DialogContent(
        // 原 Compose 弹窗是内容自适应高度；这里压到 440dp，
        // 避免在手机上占满整屏，其余内容用滚动 + 可见滚动条。
        maxHeightOverride: 460,
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 给首个 OutlinedTextField 的浮动 label 留出空间，
                // 否则内容贴顶时 label 会被裁掉半截。
                const SizedBox(height: 6),
                if (state.editResult != null) ...[
                  Text(
                    state.editResult!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: state.editResult!.contains('❌')
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                DropdownButtonFormField<int>(
                  initialValue: _intervalCode,
                  decoration: deco('广播间隔'),
                  items: _intervalOptions.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: state.paramBusy
                      ? null
                      : (v) =>
                            setState(() => _intervalCode = v ?? _intervalCode),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<int>(
                  initialValue: _txPower,
                  decoration: deco('发射功率'),
                  items: _txPowerOptions.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: state.paramBusy
                      ? null
                      : (v) => setState(() => _txPower = v ?? _txPower),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  decoration: deco(
                    '设备名称（$nameBytes/${IBeaconCodec.deviceNameMaxBytes} 字节）',
                    errorText: nameBytes > IBeaconCodec.deviceNameMaxBytes
                        ? '超出 ${IBeaconCodec.deviceNameMaxBytes} 字节，需缩短（中文 3 字节/字）'
                        : null,
                    helperText: '写入后需断开重连才扫描得到',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: state.paramBusy
                        ? null
                        : () {
                            final id = state.activeDeviceId;
                            if (id == null) return;
                            final isMac = RegExp(r'^[0-9a-fA-F:]{17}$')
                                .hasMatch(id);
                            if (!isMac) return;
                            final def = IBeaconCodec.defaultDeviceName(id);
                            if (def != null) {
                              setState(() => _name.text = def);
                            }
                          },
                    child: const Text('恢复默认名（TL + MAC 后 3 字节）'),
                  ),
                ),
                const SizedBox(height: 4),
                Text('iBeacon 参数', style: theme.textTheme.titleSmall),
                if (!state.beaconParsed) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⚠️ 广播中未检测到 iBeacon 段，以下为固件默认值，请谨慎覆盖',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                TextField(
                  controller: _uuid,
                  // 36 位 UUID 在手机宽度下单行放不下；两行完整显示。
                  maxLines: 2,
                  minLines: 1,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  decoration: deco(
                    'iBeacon UUID',
                    hint: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _major,
                        keyboardType: TextInputType.number,
                        decoration: deco('Major', hint: '0-65535'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _minor,
                        keyboardType: TextInputType.number,
                        decoration: deco('Minor', hint: '0-65535'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _company,
                        decoration: deco('Company ID', hint: '如 0x004C'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _rssi,
                        keyboardType: const TextInputType.numberWithOptions(
                          signed: true,
                        ),
                        decoration: deco('RSSI@1m', hint: '-128..127 dBm'),
                      ),
                    ),
                  ],
                ),
                if (state.paramFieldResults.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final r in state.paramFieldResults)
                    Text(
                      '${r.ok ? "✅" : "❌"} ${r.title}: ${r.detail}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: r.ok
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: c.dismissParamDialog, child: const Text('关闭')),
        FilledButton(
          onPressed: state.paramBusy
              ? null
              : () => c.writeAllParams(
                  intervalCode: _intervalCode,
                  txPower: _txPower,
                  nameInput: _name.text,
                  uuidInput: _uuid.text,
                  majorInput: _major.text,
                  minorInput: _minor.text,
                  companyInput: _company.text,
                  rssiInput: _rssi.text,
                ),
          child: Text(state.paramBusy ? '写入中…' : '确认修改'),
        ),
      ],
    );
  }
}
