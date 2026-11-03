import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 模型目录：只读浏览 `COLANAS_MODEL_DIR`（缺省 `vendor/models`）。
class PhotoModelsPage extends StatefulWidget {
  const PhotoModelsPage({super.key});

  @override
  State<PhotoModelsPage> createState() => _PhotoModelsPageState();
}

class _PhotoModelsPageState extends State<PhotoModelsPage> {
  bool _loading = true;
  String? _error;
  PhotoModelList? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoModels();
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceLg,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.dir,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                data.exists
                    ? tr('photo.models.found').replaceAll('{n}', '${data.items.length}')
                    : tr('photo.models.empty'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: data.items.isEmpty
              ? ListView(
                  children: [
                    NasEmptyState(
                      title: tr('photo.models.empty'),
                      icon: Icons.memory,
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NasTokens.spaceSm,
                    vertical: NasTokens.spaceSm,
                  ),
                  itemCount: data.items.length,
                  itemBuilder: (context, i) {
                    final m = data.items[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(m.name),
                      trailing: Text(
                        _size(m.size),
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}