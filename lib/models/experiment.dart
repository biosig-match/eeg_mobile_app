class Experiment {
  final String id;
  final String name;
  final String description;

  Experiment({required this.id, required this.name, required this.description});

  factory Experiment.fromJson(Map<String, dynamic> json) {
    return Experiment(
      id: json['experiment_id'] ?? '',
      name: json['name'] ?? 'No Name',
      description: json['description'] ?? '',
    );
  }

  factory Experiment.empty() {
    return Experiment(id: '', name: '未選択', description: '');
  }
}
