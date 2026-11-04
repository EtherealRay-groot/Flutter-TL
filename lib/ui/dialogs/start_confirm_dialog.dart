import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_controller.dart';
import 'dialog_style.dart';

class StartConfirmDialog extends ConsumerWidget {
  const StartConfirmDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(appControllerProvider.notifier);
    return AlertDialog(
      insetPadding: kDialogInsetPadding,
      title: const Text('开始记录'),
      content: const Text('是否清除设备旧数据？'),
      actions: [
        TextButton(
          onPressed: c.onRejectClearAndStart,
          child: const Text('否，保留数据'),
        ),
        TextButton(
          onPressed: c.dismissStartConfirmDialog,
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: c.onConfirmClearAndStart,
          child: const Text('是，清除并重新开始'),
        ),
      ],
    );
  }
}
