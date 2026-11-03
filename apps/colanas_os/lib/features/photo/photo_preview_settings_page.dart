import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/settings_store.dart';

/// 预览设置：缩略图尺寸与分页数量（本地设置，Web 写 localStorage）。
class PhotoPreviewSettingsPage extends StatefulWidget {
  const PhotoPreviewSettingsPage({super.key});

  @override
  State<PhotoPreviewSettingsPage> createState() =>
      _PhotoPreviewSettingsPageState();
}

class _PhotoPreviewSettingsPageState extends State<PhotoPreviewSettingsPage> {
  double _extent =
      (SettingsStore.instance.getInt('photo.grid.extent') ?? 160).toDouble();
  double _pageSize =
      (SettingsStore.instance.getInt('photo.page.size') ?? 120).toDouble();

  Future<void> _save() async {
    await SettingsStore.instance.setInt('photo.grid.extent', _extent.round());
    await SettingsStore.instance.setInt('photo.page.size', _pageSize.round());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('photo.preview.saved'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('photo.preview.hint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        Text(tr('photo.preview.extent')),
        Slider(
          value: _extent,
          min: 100,
          max: 320,
          divisions: 11,
          label: '${_extent.round()} px',
          onChanged: (v) => setState(() => _extent = v),
        ),
        Text(tr('photo.preview.pageSize')),
        Slider(
          value: _pageSize,
          min: 20,
          max: 200,
          divisions: 9,
          label: '${_pageSize.round()}',
          onChanged: (v) => setState(() => _pageSize = v),
        ),
        const SizedBox(height: NasTokens.spaceMd),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _save,
            child: Text(tr('photo.preview.save')),
          ),
        ),
      ],
    );
  }
}