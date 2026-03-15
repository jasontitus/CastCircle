/// A production (show) that a cast is working on.
class Production {
  final String id;
  final String title;
  final String organizerId;
  final DateTime createdAt;
  final ProductionStatus status;
  final String? scriptPath; // local path to original PDF
  final String locale; // BCP-47 locale for STT (e.g. 'en-US', 'en-GB')

  const Production({
    required this.id,
    required this.title,
    required this.organizerId,
    required this.createdAt,
    required this.status,
    this.scriptPath,
    this.locale = 'en-US',
  });

  Production copyWith({
    String? id,
    String? title,
    String? organizerId,
    DateTime? createdAt,
    ProductionStatus? status,
    String? scriptPath,
    String? locale,
  }) {
    return Production(
      id: id ?? this.id,
      title: title ?? this.title,
      organizerId: organizerId ?? this.organizerId,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      scriptPath: scriptPath ?? this.scriptPath,
      locale: locale ?? this.locale,
    );
  }
}

enum ProductionStatus {
  draft,
  scriptImported,
  scriptApproved,
  castAssigned,
  recording,
  ready,
}
