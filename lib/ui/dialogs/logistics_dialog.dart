import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/protocol/logistics_info.dart';
import '../../state/app_controller.dart';
import 'dialog_style.dart';

class LogisticsDialog extends ConsumerStatefulWidget {
  const LogisticsDialog({super.key});

  @override
  ConsumerState<LogisticsDialog> createState() => _LogisticsDialogState();
}

class _LogisticsDialogState extends ConsumerState<LogisticsDialog> {
  final _company = TextEditingController();
  final _goodsNo = TextEditingController();
  final _boxNo = TextEditingController();
  final _goodsDesc = TextEditingController();
  final _shipper = TextEditingController();
  final _consignee = TextEditingController();
  final _shipAddr = TextEditingController();
  final _recvAddr = TextEditingController();
  final _remark = TextEditingController();
  final _quantity = TextEditingController();
  final _unit = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _company,
      _goodsNo,
      _boxNo,
      _goodsDesc,
      _shipper,
      _consignee,
      _shipAddr,
      _recvAddr,
      _remark,
      _quantity,
      _unit,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int _slot(int fid) => LogisticsInfo.slotSize(fid);

  @override
  Widget build(BuildContext context) {
    final c = ref.read(appControllerProvider.notifier);
    final theme = Theme.of(context);

    Widget groupTitle(String text) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    Widget field(
      TextEditingController controller,
      String label,
      int slot, {
      bool singleLine = true,
      TextInputType? keyboardType,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            minLines: singleLine ? 1 : 2,
            maxLines: singleLine ? 1 : null,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              if (utf8.encode(value).length > slot - 1) {
                // 超出槽长：按字符回退，直到 UTF-8 字节数回到预算内。
                final runes = value.runes.toList();
                var text = value;
                while (runes.isNotEmpty &&
                    utf8.encode(text).length > slot - 1) {
                  runes.removeLast();
                  text = String.fromCharCodes(runes);
                }
                controller.text = text;
                controller.selection = TextSelection.collapsed(
                  offset: controller.text.length,
                );
              }
              setState(() {});
            },
          ),
          const SizedBox(height: 2),
          Text(
            '${utf8.encode(controller.text).length} / ${slot - 1} 字节',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      );
    }

    return AlertDialog(
      insetPadding: kDialogInsetPadding,
      title: const Text('填写货物信息'),
      content: DialogContent(
        maxHeightOverride: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              groupTitle('基本信息'),
              field(_company, '公司名称', _slot(0x01)),
              const SizedBox(height: 8),
              field(_goodsNo, '货物单号', _slot(0x02)),
              const SizedBox(height: 8),
              field(_boxNo, '货物箱号', _slot(0x03)),
              const SizedBox(height: 8),
              field(_goodsDesc, '货物描述', _slot(0x04), singleLine: false),
              const SizedBox(height: 12),
              groupTitle('收发货'),
              field(_shipper, '发货人', _slot(0x05)),
              const SizedBox(height: 8),
              field(_consignee, '收货人', _slot(0x06)),
              const SizedBox(height: 8),
              field(_shipAddr, '发货地址', _slot(0x07), singleLine: false),
              const SizedBox(height: 8),
              field(_recvAddr, '收货地址', _slot(0x08), singleLine: false),
              const SizedBox(height: 12),
              groupTitle('其他'),
              field(_remark, '备注', _slot(0x09), singleLine: false),
              const SizedBox(height: 8),
              field(
                _quantity,
                '数量',
                LogisticsInfo.slotSize(0x0A),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              const SizedBox(height: 8),
              field(_unit, '单位（如：箱、件、吨）', _slot(0x0B)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: c.skipLogisticsDialog, child: const Text('跳过')),
        TextButton(
          onPressed: c.dismissLogisticsDialog,
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _company.text.trim().isEmpty
              ? null
              : () => c.onSubmitLogisticsInfo(
                  LogisticsInfo(
                    company: _company.text.trim(),
                    goodsNo: _goodsNo.text.trim(),
                    boxNo: _boxNo.text.trim(),
                    goodsDesc: _goodsDesc.text.trim(),
                    shipper: _shipper.text.trim(),
                    consignee: _consignee.text.trim(),
                    shipAddr: _shipAddr.text.trim(),
                    recvAddr: _recvAddr.text.trim(),
                    remark: _remark.text.trim(),
                    quantity: double.tryParse(_quantity.text.trim()) ?? 0.0,
                    unit: _unit.text.trim(),
                  ),
                ),
          child: const Text('确认开始记录'),
        ),
      ],
    );
  }
}
