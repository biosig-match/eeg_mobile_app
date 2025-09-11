import 'dart:typed_data';
import 'package:flutter/material.dart';

class AnalysisImageViewer extends StatelessWidget {
  final Uint8List? imageData;
  const AnalysisImageViewer({super.key, this.imageData});

  @override
  Widget build(BuildContext context) {
    if (imageData == null) {
      return const Center(child: Text("表示するデータがありません。"));
    }
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Image.memory(
        imageData!,
        gaplessPlayback: true, // 画像更新時にちらつきを抑える
        fit: BoxFit.contain,
      ),
    );
  }
}
