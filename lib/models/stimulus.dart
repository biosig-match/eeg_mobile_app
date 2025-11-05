// サーバーから取得する刺激（Stimulus）の基本モデル
abstract class BaseStimulus {
  final String fileName;
  final String trialType;
  final String? description;

  BaseStimulus({
    required this.fileName,
    required this.trialType,
    this.description,
  });
}

// 実験固有の刺激 (experiment_stimuli)
class Stimulus extends BaseStimulus {
  final int stimulusId;
  final String stimulusType;

  Stimulus({
    required this.stimulusId,
    required String fileName,
    required this.stimulusType,
    required String trialType,
    String? description,
  }) : super(
            fileName: fileName, trialType: trialType, description: description);

  factory Stimulus.fromJson(Map<String, dynamic> json) {
    return Stimulus(
      stimulusId: _parseInt(json['stimulus_id'], 'stimulus_id'),
      fileName: json['file_name'],
      stimulusType: json['stimulus_type'],
      trialType: json['trial_type'],
      description: json['description'],
    );
  }
}

// グローバルなキャリブレーション項目 (calibration_items)
class CalibrationItem extends BaseStimulus {
  final int itemId;

  CalibrationItem({
    required this.itemId,
    required String fileName,
    required String trialType, // item_type in DB
    String? description,
  }) : super(
            fileName: fileName, trialType: trialType, description: description);

  factory CalibrationItem.fromJson(Map<String, dynamic> json) {
    return CalibrationItem(
      itemId: _parseInt(json['item_id'], 'item_id'),
      fileName: json['file_name'],
      trialType: json['item_type'],
      description: json['description'],
    );
  }
}

int _parseInt(dynamic value, String fieldName) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('Invalid value for $fieldName: $value');
}
