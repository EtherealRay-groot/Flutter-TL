import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_controller.dart';
import 'dialog_style.dart';

class PasswordDialog extends ConsumerStatefulWidget {
  const PasswordDialog({super.key});

  @override
  ConsumerState<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final c = ref.read(appControllerProvider.notifier);
    return AlertDialog(
      insetPadding: kDialogInsetPadding,
      title: const Text('密码验证'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.passwordError != null) ...[
              Text(
                state.passwordError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _controller,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '请输入密码'),
              onSubmitted: (v) => c.verifyPassword(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: c.dismissPasswordDialog, child: const Text('取消')),
        FilledButton(
          onPressed: () => c.verifyPassword(_controller.text),
          child: const Text('验证'),
        ),
      ],
    );
  }
}
