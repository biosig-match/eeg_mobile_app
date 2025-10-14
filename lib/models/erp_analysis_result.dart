import 'package:intl/intl.dart';

class ErpRecommendation {
  final String fileName;
  final String? itemName;
  final String? brandName;
  final String? description;
  final String? category;
  final String? gender;

  ErpRecommendation({
    required this.fileName,
    this.itemName,
    this.brandName,
    this.description,
    this.category,
    this.gender,
  });

  factory ErpRecommendation.fromJson(Map<String, dynamic> json) {
    return ErpRecommendation(
      fileName: json['file_name'] ?? '',
      itemName: json['item_name'] as String?,
      brandName: json['brand_name'] as String?,
      description: json['description'] as String?,
      category: json['category'] as String?,
      gender: json['gender'] as String?,
    );
  }
}

class ErpAnalysisResult {
  final int analysisId;
  final String experimentId;
  final String summary;
  final List<ErpRecommendation> recommendations;
  final DateTime? generatedAt;
  final String requestedBy;

  ErpAnalysisResult({
    required this.analysisId,
    required this.experimentId,
    required this.summary,
    required this.recommendations,
    required this.generatedAt,
    required this.requestedBy,
  });

  factory ErpAnalysisResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> recs = json['recommendations'] as List<dynamic>? ?? [];
    return ErpAnalysisResult(
      analysisId: json['analysis_id'] is int
          ? json['analysis_id'] as int
          : int.tryParse('${json['analysis_id']}') ?? -1,
      experimentId: json['experiment_id']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      recommendations:
          recs.map((item) => ErpRecommendation.fromJson(item as Map<String, dynamic>)).toList(),
      generatedAt: json['generated_at'] != null
          ? DateTime.tryParse(json['generated_at'].toString())
          : null,
      requestedBy: json['requested_by_user_id']?.toString() ?? '',
    );
  }

  String get formattedGeneratedAt {
    if (generatedAt == null) return '-';
    return DateFormat('yyyy/MM/dd HH:mm').format(generatedAt!.toLocal());
  }
}
