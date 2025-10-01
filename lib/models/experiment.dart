class Experiment {
  final String id;
  final String name;
  final String description;
  final String presentationOrder; // ★★★ 提示順を保持するフィールドを追加 ★★★

  Experiment({
    required this.id,
    required this.name,
    required this.description,
    required this.presentationOrder, // ★★★ コンストラクタに追加 ★★★
  });

  factory Experiment.fromJson(Map<String, dynamic> json) {
    return Experiment(
      id: json['experiment_id'] ?? '',
      name: json['name'] ?? 'No Name',
      description: json['description'] ?? '',
      // ★★★ JSONからpresentation_orderを読み込む ★★★
      presentationOrder: json['presentation_order'] ?? 'random',
    );
  }

  factory Experiment.empty() {
    return Experiment(
        id: '', name: '未選択', description: '', presentationOrder: 'random');
  }
}
