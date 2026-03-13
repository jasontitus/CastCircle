/// A production (show) that a cast is working on.
class Production {
  final String id;
  final String title;
  final String organizerId;
  final DateTime createdAt;
  final ProductionStatus status;
  final String? scriptPath; // local path to original PDF

  const Production({
    required this.id,
    required this.title,
    required this.organizerId,
    required this.createdAt,
    required this.status,
    this.scriptPath,
  });

  Production copyWith({
    String? id,
    String? title,
    String? organizerId,
    DateTime? createdAt,
    ProductionStatus? status,
    String? scriptPath,
  }) {
    return Production(
      id: id ?? this.id,
      title: title ?? this.title,
      organizerId: organizerId ?? this.organizerId,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      scriptPath: scriptPath ?? this.scriptPath,
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
