import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../providers/session_provider.dart';

class ExperimentEditorScreen extends StatefulWidget {
  const ExperimentEditorScreen({super.key});

  @override
  State<ExperimentEditorScreen> createState() => _ExperimentEditorScreenState();
}

class _ExperimentEditorScreenState extends State<ExperimentEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _presentationOrder = 'sequential';
  bool _isSubmitting = false;

  final List<_StimulusDraft> _stimuli = [];

  @override
  void dispose() {
    for (final stimulus in _stimuli) {
      stimulus.dispose();
    }
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickStimuli() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    setState(() {
      for (final platformFile in result.files) {
        // Skip duplicates by file name to avoid upload conflicts.
        if (_stimuli.any((s) => s.fileName == platformFile.name)) {
          continue;
        }
        _stimuli.add(_StimulusDraft(platformFile));
      }
    });
  }

  void _removeStimulus(int index) {
    if (index < 0 || index >= _stimuli.length) return;
    final removed = _stimuli.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  void _shuffleStimuli() {
    if (_stimuli.length < 2) return;
    setState(() {
      _stimuli.shuffle(Random());
    });
  }

  Future<void> _submit() async {
    final sessionProvider = context.read<SessionProvider>();
    if (!_formKey.currentState!.validate()) return;
    if (_stimuli.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('少なくとも1枚の刺激画像を追加してください。')),
      );
      return;
    }

    final isTrialTypeMissing = _stimuli
        .any((stimulus) => stimulus.trialTypeController.text.trim().isEmpty);
    if (isTrialTypeMissing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('全ての刺激でtrial_typeを入力してください。')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final tempDir = await Directory.systemTemp.createTemp(
          'experiment_upload_${DateTime.now().millisecondsSinceEpoch}');

      final csvPath = p.join(tempDir.path, 'stimuli_definition.csv');
      final csvFile = File(csvPath);
      final csvBuffer = StringBuffer()
        ..writeln('trial_type,file_name,description');

      final List<File> imageFiles = [];
      final Set<String> usedFileNames = {};

      for (final stimulus in _stimuli) {
        final trialType = stimulus.trialTypeController.text.trim();
        final description = stimulus.descriptionController.text.trim();
        String sanitizedFileName = _sanitizeFileName(stimulus.fileName);

        if (usedFileNames.contains(sanitizedFileName)) {
          final baseName = p.basenameWithoutExtension(sanitizedFileName);
          final extension = p.extension(sanitizedFileName);
          var suffix = 1;
          while (usedFileNames.contains('${baseName}_$suffix$extension')) {
            suffix++;
          }
          sanitizedFileName = '${baseName}_$suffix$extension';
        }
        usedFileNames.add(sanitizedFileName);

        final localFile = await stimulus.ensureLocalFile(tempDir.path);
        if (localFile == null) {
          throw Exception('ファイル ${stimulus.fileName} を一時保存できませんでした。');
        }

        // Rename file if sanitized name differs to keep CSV and upload consistent.
        File preparedFile = localFile;
        if (p.basename(localFile.path) != sanitizedFileName) {
          preparedFile =
              await localFile.copy(p.join(tempDir.path, sanitizedFileName));
        }

        imageFiles.add(preparedFile);

        csvBuffer.writeln(
          '"${_escapeCsv(trialType)}","${_escapeCsv(sanitizedFileName)}","${_escapeCsv(description)}"',
        );
      }

      await csvFile.writeAsString(csvBuffer.toString());

      await sessionProvider.createExperiment(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        presentationOrder: _presentationOrder,
        stimuliCsvFile: csvFile,
        stimuliImageFiles: imageFiles,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('実験の作成リクエストを送信しました。')),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('実験の作成に失敗しました: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('新しい実験を作成'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: '実験名',
                          hintText: '例: ブランド認知度テスト',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return '実験名を入力してください。';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _descriptionController,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '説明 (任意)',
                          hintText: '例: 2025年10月のプロモーション調査',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _presentationOrder,
                        decoration: const InputDecoration(
                          labelText: '刺激提示順',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'sequential',
                            child: Text('並び順どおりに提示'),
                          ),
                          DropdownMenuItem(
                            value: 'random',
                            child: Text('提示時にランダム化'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _presentationOrder = value);
                          }
                        },
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _isSubmitting ? null : _pickStimuli,
                            icon:
                                const Icon(Icons.add_photo_alternate_outlined),
                            label: const Text('画像を追加'),
                          ),
                          const SizedBox(width: 12),
                          if (_stimuli.length >= 2)
                            OutlinedButton.icon(
                              onPressed: _isSubmitting ? null : _shuffleStimuli,
                              icon: const Icon(Icons.shuffle),
                              label: const Text('順番をランダム化'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_stimuli.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color:
                                    theme.colorScheme.outline.withOpacity(0.4)),
                          ),
                          child: Column(
                            children: const [
                              Icon(Icons.collections_outlined, size: 48),
                              SizedBox(height: 12),
                              Text('選択した画像がここに表示されます。\nドラッグして順番を変更できます。'),
                            ],
                          ),
                        )
                      else
                        ReorderableListView.builder(
                          key: ValueKey(_stimuli.length),
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              if (newIndex > oldIndex) newIndex -= 1;
                              final item = _stimuli.removeAt(oldIndex);
                              _stimuli.insert(newIndex, item);
                            });
                          },
                          itemBuilder: (context, index) {
                            final stimulus = _stimuli[index];
                            return Card(
                              key: ValueKey(stimulus.id),
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 72,
                                      height: 72,
                                      child:
                                          _StimulusPreview(stimulus: stimulus),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            stimulus.fileName,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.bold),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 8),
                                          TextFormField(
                                            controller:
                                                stimulus.trialTypeController,
                                            decoration: const InputDecoration(
                                              labelText: 'trial_type',
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          TextFormField(
                                            controller:
                                                stimulus.descriptionController,
                                            decoration: const InputDecoration(
                                              labelText: '説明 (任意)',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _isSubmitting
                                          ? null
                                          : () => _removeStimulus(index),
                                      icon: const Icon(Icons.delete_outline),
                                      tooltip: 'この画像を削除',
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                          itemCount: _stimuli.length,
                        ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: Text(_isSubmitting ? '送信中...' : '実験を作成してアップロード'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StimulusDraft {
  _StimulusDraft(this.platformFile)
      : id =
            '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 16)}',
        trialTypeController = TextEditingController(
          text: _defaultTrialType(platformFile.name),
        ),
        descriptionController = TextEditingController();

  final PlatformFile platformFile;
  final String id;
  final TextEditingController trialTypeController;
  final TextEditingController descriptionController;

  String get fileName => platformFile.name;

  Future<File?> ensureLocalFile(String tempDirPath) async {
    if (platformFile.path != null) {
      final sourceFile = File(platformFile.path!);
      if (await sourceFile.exists()) {
        return sourceFile;
      }
    }
    if (platformFile.bytes != null) {
      final target = File(p.join(tempDirPath, fileName));
      await target.create(recursive: true);
      await target.writeAsBytes(platformFile.bytes!);
      return target;
    }
    return null;
  }

  void dispose() {
    trialTypeController.dispose();
    descriptionController.dispose();
  }
}

class _StimulusPreview extends StatelessWidget {
  const _StimulusPreview({required this.stimulus});

  final _StimulusDraft stimulus;

  @override
  Widget build(BuildContext context) {
    if (stimulus.platformFile.path != null) {
      final file = File(stimulus.platformFile.path!);
      if (file.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(file, fit: BoxFit.cover),
        );
      }
    }
    if (stimulus.platformFile.bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(stimulus.platformFile.bytes!, fit: BoxFit.cover),
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.2),
      ),
      child: const Icon(Icons.photo_size_select_actual_outlined),
    );
  }
}

String _escapeCsv(String input) {
  final escaped = input.replaceAll('"', '""');
  return escaped;
}

String _sanitizeFileName(String fileName) {
  final sanitized = fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');
  return sanitized;
}

String _defaultTrialType(String fileName) {
  final withoutExtension = fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;
  return withoutExtension.replaceAll(RegExp(r'\s+'), '_');
}
