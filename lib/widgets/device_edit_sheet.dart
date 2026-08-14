import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import 'glass.dart';

/// 添加 / 编辑设备的玻璃面板。
///
/// 备注可选：不填时依次尝试 URL 的 name 参数 → mid 短码 → 页面标题（运行时补）
/// → host 兜底，全部尽力而为、不做强制。
class DeviceEditSheet extends StatefulWidget {
  const DeviceEditSheet({super.key, this.editing});

  /// 传入表示编辑/替换该设备，否则为新增。
  final RemoteDevice? editing;

  static Future<void> show(BuildContext context, {RemoteDevice? editing}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DeviceEditSheet(editing: editing),
    );
  }

  @override
  State<DeviceEditSheet> createState() => _DeviceEditSheetState();
}

class _DeviceEditSheetState extends State<DeviceEditSheet> {
  late final TextEditingController _urlController;
  late final TextEditingController _remarkController;
  String? _parsedName;

  @override
  void initState() {
    super.initState();
    _urlController =
        TextEditingController(text: widget.editing?.url ?? '');
    _remarkController =
        TextEditingController(text: widget.editing?.remark ?? '');
    _parsedName = _derive(_urlController.text);
    _urlController.addListener(() {
      setState(() => _parsedName = _derive(_urlController.text));
    });
  }

  String? _derive(String url) {
    if (url.trim().isEmpty) return null;
    return RemoteDevice.nameFromUrl(url);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _urlController.text = text;
      _urlController.selection =
          TextSelection.collapsed(offset: text.length);
    }
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请填写连接地址')));
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('地址格式不正确，需要完整的 http(s) 链接')));
      return;
    }
    final store = context.read<DeviceStore>();
    final remark = _remarkController.text.trim();
    if (widget.editing == null) {
      await store.addDevice(url, remark: remark);
    } else {
      await store.updateDevice(widget.editing!.id,
          url: url, remark: remark);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.editing != null;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + bottomInset),
      child: GlassContainer(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(isEdit ? '编辑设备' : '添加设备',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              maxLines: 3,
              minLines: 1,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: '连接地址',
                hintText: 'https://zcode.z.ai/remote/v4?...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: '从剪贴板粘贴',
                  onPressed: _pasteFromClipboard,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _remarkController,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                hintText: '例如：家里的 Mac mini',
                border: OutlineInputBorder(),
              ),
            ),
            if (_parsedName != null &&
                _remarkController.text.trim().isEmpty) ...[
              const SizedBox(height: 8),
              ActionChip(
                avatar: const Icon(Icons.auto_awesome, size: 16),
                label: Text('从地址解析到：$_parsedName'),
                onPressed: () => _remarkController.text = _parsedName!,
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                '不填备注时会自动尝试从地址 name 参数、页面标题读取',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(isEdit ? '保存' : '添加'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
