// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ProductionsTable extends Productions
    with TableInfo<$ProductionsTable, Production> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProductionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _organizerIdMeta = const VerificationMeta(
    'organizerId',
  );
  @override
  late final GeneratedColumn<String> organizerId = GeneratedColumn<String>(
    'organizer_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('draft'),
  );
  static const VerificationMeta _scriptPathMeta = const VerificationMeta(
    'scriptPath',
  );
  @override
  late final GeneratedColumn<String> scriptPath = GeneratedColumn<String>(
    'script_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localeMeta = const VerificationMeta('locale');
  @override
  late final GeneratedColumn<String> locale = GeneratedColumn<String>(
    'locale',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('en-US'),
  );
  static const VerificationMeta _joinCodeMeta = const VerificationMeta(
    'joinCode',
  );
  @override
  late final GeneratedColumn<String> joinCode = GeneratedColumn<String>(
    'join_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    organizerId,
    status,
    scriptPath,
    locale,
    joinCode,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'productions';
  @override
  VerificationContext validateIntegrity(
    Insertable<Production> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('organizer_id')) {
      context.handle(
        _organizerIdMeta,
        organizerId.isAcceptableOrUnknown(
          data['organizer_id']!,
          _organizerIdMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('script_path')) {
      context.handle(
        _scriptPathMeta,
        scriptPath.isAcceptableOrUnknown(data['script_path']!, _scriptPathMeta),
      );
    }
    if (data.containsKey('locale')) {
      context.handle(
        _localeMeta,
        locale.isAcceptableOrUnknown(data['locale']!, _localeMeta),
      );
    }
    if (data.containsKey('join_code')) {
      context.handle(
        _joinCodeMeta,
        joinCode.isAcceptableOrUnknown(data['join_code']!, _joinCodeMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Production map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Production(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      organizerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}organizer_id'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      scriptPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}script_path'],
      ),
      locale: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}locale'],
      )!,
      joinCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}join_code'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $ProductionsTable createAlias(String alias) {
    return $ProductionsTable(attachedDatabase, alias);
  }
}

class Production extends DataClass implements Insertable<Production> {
  final String id;
  final String title;
  final String? organizerId;
  final String status;
  final String? scriptPath;
  final String locale;
  final String? joinCode;
  final DateTime createdAt;
  const Production({
    required this.id,
    required this.title,
    this.organizerId,
    required this.status,
    this.scriptPath,
    required this.locale,
    this.joinCode,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || organizerId != null) {
      map['organizer_id'] = Variable<String>(organizerId);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || scriptPath != null) {
      map['script_path'] = Variable<String>(scriptPath);
    }
    map['locale'] = Variable<String>(locale);
    if (!nullToAbsent || joinCode != null) {
      map['join_code'] = Variable<String>(joinCode);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  ProductionsCompanion toCompanion(bool nullToAbsent) {
    return ProductionsCompanion(
      id: Value(id),
      title: Value(title),
      organizerId: organizerId == null && nullToAbsent
          ? const Value.absent()
          : Value(organizerId),
      status: Value(status),
      scriptPath: scriptPath == null && nullToAbsent
          ? const Value.absent()
          : Value(scriptPath),
      locale: Value(locale),
      joinCode: joinCode == null && nullToAbsent
          ? const Value.absent()
          : Value(joinCode),
      createdAt: Value(createdAt),
    );
  }

  factory Production.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Production(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      organizerId: serializer.fromJson<String?>(json['organizerId']),
      status: serializer.fromJson<String>(json['status']),
      scriptPath: serializer.fromJson<String?>(json['scriptPath']),
      locale: serializer.fromJson<String>(json['locale']),
      joinCode: serializer.fromJson<String?>(json['joinCode']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'organizerId': serializer.toJson<String?>(organizerId),
      'status': serializer.toJson<String>(status),
      'scriptPath': serializer.toJson<String?>(scriptPath),
      'locale': serializer.toJson<String>(locale),
      'joinCode': serializer.toJson<String?>(joinCode),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  Production copyWith({
    String? id,
    String? title,
    Value<String?> organizerId = const Value.absent(),
    String? status,
    Value<String?> scriptPath = const Value.absent(),
    String? locale,
    Value<String?> joinCode = const Value.absent(),
    DateTime? createdAt,
  }) => Production(
    id: id ?? this.id,
    title: title ?? this.title,
    organizerId: organizerId.present ? organizerId.value : this.organizerId,
    status: status ?? this.status,
    scriptPath: scriptPath.present ? scriptPath.value : this.scriptPath,
    locale: locale ?? this.locale,
    joinCode: joinCode.present ? joinCode.value : this.joinCode,
    createdAt: createdAt ?? this.createdAt,
  );
  Production copyWithCompanion(ProductionsCompanion data) {
    return Production(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      organizerId: data.organizerId.present
          ? data.organizerId.value
          : this.organizerId,
      status: data.status.present ? data.status.value : this.status,
      scriptPath: data.scriptPath.present
          ? data.scriptPath.value
          : this.scriptPath,
      locale: data.locale.present ? data.locale.value : this.locale,
      joinCode: data.joinCode.present ? data.joinCode.value : this.joinCode,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Production(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('organizerId: $organizerId, ')
          ..write('status: $status, ')
          ..write('scriptPath: $scriptPath, ')
          ..write('locale: $locale, ')
          ..write('joinCode: $joinCode, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    organizerId,
    status,
    scriptPath,
    locale,
    joinCode,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Production &&
          other.id == this.id &&
          other.title == this.title &&
          other.organizerId == this.organizerId &&
          other.status == this.status &&
          other.scriptPath == this.scriptPath &&
          other.locale == this.locale &&
          other.joinCode == this.joinCode &&
          other.createdAt == this.createdAt);
}

class ProductionsCompanion extends UpdateCompanion<Production> {
  final Value<String> id;
  final Value<String> title;
  final Value<String?> organizerId;
  final Value<String> status;
  final Value<String?> scriptPath;
  final Value<String> locale;
  final Value<String?> joinCode;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const ProductionsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.organizerId = const Value.absent(),
    this.status = const Value.absent(),
    this.scriptPath = const Value.absent(),
    this.locale = const Value.absent(),
    this.joinCode = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProductionsCompanion.insert({
    required String id,
    required String title,
    this.organizerId = const Value.absent(),
    this.status = const Value.absent(),
    this.scriptPath = const Value.absent(),
    this.locale = const Value.absent(),
    this.joinCode = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title);
  static Insertable<Production> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? organizerId,
    Expression<String>? status,
    Expression<String>? scriptPath,
    Expression<String>? locale,
    Expression<String>? joinCode,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (organizerId != null) 'organizer_id': organizerId,
      if (status != null) 'status': status,
      if (scriptPath != null) 'script_path': scriptPath,
      if (locale != null) 'locale': locale,
      if (joinCode != null) 'join_code': joinCode,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProductionsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String?>? organizerId,
    Value<String>? status,
    Value<String?>? scriptPath,
    Value<String>? locale,
    Value<String?>? joinCode,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return ProductionsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      organizerId: organizerId ?? this.organizerId,
      status: status ?? this.status,
      scriptPath: scriptPath ?? this.scriptPath,
      locale: locale ?? this.locale,
      joinCode: joinCode ?? this.joinCode,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (organizerId.present) {
      map['organizer_id'] = Variable<String>(organizerId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (scriptPath.present) {
      map['script_path'] = Variable<String>(scriptPath.value);
    }
    if (locale.present) {
      map['locale'] = Variable<String>(locale.value);
    }
    if (joinCode.present) {
      map['join_code'] = Variable<String>(joinCode.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProductionsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('organizerId: $organizerId, ')
          ..write('status: $status, ')
          ..write('scriptPath: $scriptPath, ')
          ..write('locale: $locale, ')
          ..write('joinCode: $joinCode, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScriptLinesTable extends ScriptLines
    with TableInfo<$ScriptLinesTable, ScriptLine> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScriptLinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productionIdMeta = const VerificationMeta(
    'productionId',
  );
  @override
  late final GeneratedColumn<String> productionId = GeneratedColumn<String>(
    'production_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES productions (id)',
    ),
  );
  static const VerificationMeta _actMeta = const VerificationMeta('act');
  @override
  late final GeneratedColumn<String> act = GeneratedColumn<String>(
    'act',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sceneMeta = const VerificationMeta('scene');
  @override
  late final GeneratedColumn<String> scene = GeneratedColumn<String>(
    'scene',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lineNumberMeta = const VerificationMeta(
    'lineNumber',
  );
  @override
  late final GeneratedColumn<int> lineNumber = GeneratedColumn<int>(
    'line_number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _orderIndexMeta = const VerificationMeta(
    'orderIndex',
  );
  @override
  late final GeneratedColumn<int> orderIndex = GeneratedColumn<int>(
    'order_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _characterMeta = const VerificationMeta(
    'character',
  );
  @override
  late final GeneratedColumn<String> character = GeneratedColumn<String>(
    'character',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lineTextMeta = const VerificationMeta(
    'lineText',
  );
  @override
  late final GeneratedColumn<String> lineText = GeneratedColumn<String>(
    'line_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lineTypeMeta = const VerificationMeta(
    'lineType',
  );
  @override
  late final GeneratedColumn<String> lineType = GeneratedColumn<String>(
    'line_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stageDirectionMeta = const VerificationMeta(
    'stageDirection',
  );
  @override
  late final GeneratedColumn<String> stageDirection = GeneratedColumn<String>(
    'stage_direction',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _ocrConfidenceMeta = const VerificationMeta(
    'ocrConfidence',
  );
  @override
  late final GeneratedColumn<double> ocrConfidence = GeneratedColumn<double>(
    'ocr_confidence',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourcePageMeta = const VerificationMeta(
    'sourcePage',
  );
  @override
  late final GeneratedColumn<int> sourcePage = GeneratedColumn<int>(
    'source_page',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceLineOnPageMeta = const VerificationMeta(
    'sourceLineOnPage',
  );
  @override
  late final GeneratedColumn<int> sourceLineOnPage = GeneratedColumn<int>(
    'source_line_on_page',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productionId,
    act,
    scene,
    lineNumber,
    orderIndex,
    character,
    lineText,
    lineType,
    stageDirection,
    ocrConfidence,
    sourcePage,
    sourceLineOnPage,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'script_lines';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScriptLine> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('production_id')) {
      context.handle(
        _productionIdMeta,
        productionId.isAcceptableOrUnknown(
          data['production_id']!,
          _productionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_productionIdMeta);
    }
    if (data.containsKey('act')) {
      context.handle(
        _actMeta,
        act.isAcceptableOrUnknown(data['act']!, _actMeta),
      );
    }
    if (data.containsKey('scene')) {
      context.handle(
        _sceneMeta,
        scene.isAcceptableOrUnknown(data['scene']!, _sceneMeta),
      );
    }
    if (data.containsKey('line_number')) {
      context.handle(
        _lineNumberMeta,
        lineNumber.isAcceptableOrUnknown(data['line_number']!, _lineNumberMeta),
      );
    } else if (isInserting) {
      context.missing(_lineNumberMeta);
    }
    if (data.containsKey('order_index')) {
      context.handle(
        _orderIndexMeta,
        orderIndex.isAcceptableOrUnknown(data['order_index']!, _orderIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_orderIndexMeta);
    }
    if (data.containsKey('character')) {
      context.handle(
        _characterMeta,
        character.isAcceptableOrUnknown(data['character']!, _characterMeta),
      );
    }
    if (data.containsKey('line_text')) {
      context.handle(
        _lineTextMeta,
        lineText.isAcceptableOrUnknown(data['line_text']!, _lineTextMeta),
      );
    } else if (isInserting) {
      context.missing(_lineTextMeta);
    }
    if (data.containsKey('line_type')) {
      context.handle(
        _lineTypeMeta,
        lineType.isAcceptableOrUnknown(data['line_type']!, _lineTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_lineTypeMeta);
    }
    if (data.containsKey('stage_direction')) {
      context.handle(
        _stageDirectionMeta,
        stageDirection.isAcceptableOrUnknown(
          data['stage_direction']!,
          _stageDirectionMeta,
        ),
      );
    }
    if (data.containsKey('ocr_confidence')) {
      context.handle(
        _ocrConfidenceMeta,
        ocrConfidence.isAcceptableOrUnknown(
          data['ocr_confidence']!,
          _ocrConfidenceMeta,
        ),
      );
    }
    if (data.containsKey('source_page')) {
      context.handle(
        _sourcePageMeta,
        sourcePage.isAcceptableOrUnknown(data['source_page']!, _sourcePageMeta),
      );
    }
    if (data.containsKey('source_line_on_page')) {
      context.handle(
        _sourceLineOnPageMeta,
        sourceLineOnPage.isAcceptableOrUnknown(
          data['source_line_on_page']!,
          _sourceLineOnPageMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ScriptLine map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScriptLine(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}production_id'],
      )!,
      act: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}act'],
      )!,
      scene: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scene'],
      )!,
      lineNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}line_number'],
      )!,
      orderIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}order_index'],
      )!,
      character: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}character'],
      )!,
      lineText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}line_text'],
      )!,
      lineType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}line_type'],
      )!,
      stageDirection: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage_direction'],
      )!,
      ocrConfidence: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}ocr_confidence'],
      ),
      sourcePage: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_page'],
      ),
      sourceLineOnPage: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_line_on_page'],
      ),
    );
  }

  @override
  $ScriptLinesTable createAlias(String alias) {
    return $ScriptLinesTable(attachedDatabase, alias);
  }
}

class ScriptLine extends DataClass implements Insertable<ScriptLine> {
  final String id;
  final String productionId;
  final String act;
  final String scene;
  final int lineNumber;
  final int orderIndex;
  final String character;
  final String lineText;
  final String lineType;
  final String stageDirection;
  final double? ocrConfidence;
  final int? sourcePage;
  final int? sourceLineOnPage;
  const ScriptLine({
    required this.id,
    required this.productionId,
    required this.act,
    required this.scene,
    required this.lineNumber,
    required this.orderIndex,
    required this.character,
    required this.lineText,
    required this.lineType,
    required this.stageDirection,
    this.ocrConfidence,
    this.sourcePage,
    this.sourceLineOnPage,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['production_id'] = Variable<String>(productionId);
    map['act'] = Variable<String>(act);
    map['scene'] = Variable<String>(scene);
    map['line_number'] = Variable<int>(lineNumber);
    map['order_index'] = Variable<int>(orderIndex);
    map['character'] = Variable<String>(character);
    map['line_text'] = Variable<String>(lineText);
    map['line_type'] = Variable<String>(lineType);
    map['stage_direction'] = Variable<String>(stageDirection);
    if (!nullToAbsent || ocrConfidence != null) {
      map['ocr_confidence'] = Variable<double>(ocrConfidence);
    }
    if (!nullToAbsent || sourcePage != null) {
      map['source_page'] = Variable<int>(sourcePage);
    }
    if (!nullToAbsent || sourceLineOnPage != null) {
      map['source_line_on_page'] = Variable<int>(sourceLineOnPage);
    }
    return map;
  }

  ScriptLinesCompanion toCompanion(bool nullToAbsent) {
    return ScriptLinesCompanion(
      id: Value(id),
      productionId: Value(productionId),
      act: Value(act),
      scene: Value(scene),
      lineNumber: Value(lineNumber),
      orderIndex: Value(orderIndex),
      character: Value(character),
      lineText: Value(lineText),
      lineType: Value(lineType),
      stageDirection: Value(stageDirection),
      ocrConfidence: ocrConfidence == null && nullToAbsent
          ? const Value.absent()
          : Value(ocrConfidence),
      sourcePage: sourcePage == null && nullToAbsent
          ? const Value.absent()
          : Value(sourcePage),
      sourceLineOnPage: sourceLineOnPage == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceLineOnPage),
    );
  }

  factory ScriptLine.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScriptLine(
      id: serializer.fromJson<String>(json['id']),
      productionId: serializer.fromJson<String>(json['productionId']),
      act: serializer.fromJson<String>(json['act']),
      scene: serializer.fromJson<String>(json['scene']),
      lineNumber: serializer.fromJson<int>(json['lineNumber']),
      orderIndex: serializer.fromJson<int>(json['orderIndex']),
      character: serializer.fromJson<String>(json['character']),
      lineText: serializer.fromJson<String>(json['lineText']),
      lineType: serializer.fromJson<String>(json['lineType']),
      stageDirection: serializer.fromJson<String>(json['stageDirection']),
      ocrConfidence: serializer.fromJson<double?>(json['ocrConfidence']),
      sourcePage: serializer.fromJson<int?>(json['sourcePage']),
      sourceLineOnPage: serializer.fromJson<int?>(json['sourceLineOnPage']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productionId': serializer.toJson<String>(productionId),
      'act': serializer.toJson<String>(act),
      'scene': serializer.toJson<String>(scene),
      'lineNumber': serializer.toJson<int>(lineNumber),
      'orderIndex': serializer.toJson<int>(orderIndex),
      'character': serializer.toJson<String>(character),
      'lineText': serializer.toJson<String>(lineText),
      'lineType': serializer.toJson<String>(lineType),
      'stageDirection': serializer.toJson<String>(stageDirection),
      'ocrConfidence': serializer.toJson<double?>(ocrConfidence),
      'sourcePage': serializer.toJson<int?>(sourcePage),
      'sourceLineOnPage': serializer.toJson<int?>(sourceLineOnPage),
    };
  }

  ScriptLine copyWith({
    String? id,
    String? productionId,
    String? act,
    String? scene,
    int? lineNumber,
    int? orderIndex,
    String? character,
    String? lineText,
    String? lineType,
    String? stageDirection,
    Value<double?> ocrConfidence = const Value.absent(),
    Value<int?> sourcePage = const Value.absent(),
    Value<int?> sourceLineOnPage = const Value.absent(),
  }) => ScriptLine(
    id: id ?? this.id,
    productionId: productionId ?? this.productionId,
    act: act ?? this.act,
    scene: scene ?? this.scene,
    lineNumber: lineNumber ?? this.lineNumber,
    orderIndex: orderIndex ?? this.orderIndex,
    character: character ?? this.character,
    lineText: lineText ?? this.lineText,
    lineType: lineType ?? this.lineType,
    stageDirection: stageDirection ?? this.stageDirection,
    ocrConfidence: ocrConfidence.present
        ? ocrConfidence.value
        : this.ocrConfidence,
    sourcePage: sourcePage.present ? sourcePage.value : this.sourcePage,
    sourceLineOnPage: sourceLineOnPage.present
        ? sourceLineOnPage.value
        : this.sourceLineOnPage,
  );
  ScriptLine copyWithCompanion(ScriptLinesCompanion data) {
    return ScriptLine(
      id: data.id.present ? data.id.value : this.id,
      productionId: data.productionId.present
          ? data.productionId.value
          : this.productionId,
      act: data.act.present ? data.act.value : this.act,
      scene: data.scene.present ? data.scene.value : this.scene,
      lineNumber: data.lineNumber.present
          ? data.lineNumber.value
          : this.lineNumber,
      orderIndex: data.orderIndex.present
          ? data.orderIndex.value
          : this.orderIndex,
      character: data.character.present ? data.character.value : this.character,
      lineText: data.lineText.present ? data.lineText.value : this.lineText,
      lineType: data.lineType.present ? data.lineType.value : this.lineType,
      stageDirection: data.stageDirection.present
          ? data.stageDirection.value
          : this.stageDirection,
      ocrConfidence: data.ocrConfidence.present
          ? data.ocrConfidence.value
          : this.ocrConfidence,
      sourcePage: data.sourcePage.present
          ? data.sourcePage.value
          : this.sourcePage,
      sourceLineOnPage: data.sourceLineOnPage.present
          ? data.sourceLineOnPage.value
          : this.sourceLineOnPage,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScriptLine(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('act: $act, ')
          ..write('scene: $scene, ')
          ..write('lineNumber: $lineNumber, ')
          ..write('orderIndex: $orderIndex, ')
          ..write('character: $character, ')
          ..write('lineText: $lineText, ')
          ..write('lineType: $lineType, ')
          ..write('stageDirection: $stageDirection, ')
          ..write('ocrConfidence: $ocrConfidence, ')
          ..write('sourcePage: $sourcePage, ')
          ..write('sourceLineOnPage: $sourceLineOnPage')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productionId,
    act,
    scene,
    lineNumber,
    orderIndex,
    character,
    lineText,
    lineType,
    stageDirection,
    ocrConfidence,
    sourcePage,
    sourceLineOnPage,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScriptLine &&
          other.id == this.id &&
          other.productionId == this.productionId &&
          other.act == this.act &&
          other.scene == this.scene &&
          other.lineNumber == this.lineNumber &&
          other.orderIndex == this.orderIndex &&
          other.character == this.character &&
          other.lineText == this.lineText &&
          other.lineType == this.lineType &&
          other.stageDirection == this.stageDirection &&
          other.ocrConfidence == this.ocrConfidence &&
          other.sourcePage == this.sourcePage &&
          other.sourceLineOnPage == this.sourceLineOnPage);
}

class ScriptLinesCompanion extends UpdateCompanion<ScriptLine> {
  final Value<String> id;
  final Value<String> productionId;
  final Value<String> act;
  final Value<String> scene;
  final Value<int> lineNumber;
  final Value<int> orderIndex;
  final Value<String> character;
  final Value<String> lineText;
  final Value<String> lineType;
  final Value<String> stageDirection;
  final Value<double?> ocrConfidence;
  final Value<int?> sourcePage;
  final Value<int?> sourceLineOnPage;
  final Value<int> rowid;
  const ScriptLinesCompanion({
    this.id = const Value.absent(),
    this.productionId = const Value.absent(),
    this.act = const Value.absent(),
    this.scene = const Value.absent(),
    this.lineNumber = const Value.absent(),
    this.orderIndex = const Value.absent(),
    this.character = const Value.absent(),
    this.lineText = const Value.absent(),
    this.lineType = const Value.absent(),
    this.stageDirection = const Value.absent(),
    this.ocrConfidence = const Value.absent(),
    this.sourcePage = const Value.absent(),
    this.sourceLineOnPage = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScriptLinesCompanion.insert({
    required String id,
    required String productionId,
    this.act = const Value.absent(),
    this.scene = const Value.absent(),
    required int lineNumber,
    required int orderIndex,
    this.character = const Value.absent(),
    required String lineText,
    required String lineType,
    this.stageDirection = const Value.absent(),
    this.ocrConfidence = const Value.absent(),
    this.sourcePage = const Value.absent(),
    this.sourceLineOnPage = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productionId = Value(productionId),
       lineNumber = Value(lineNumber),
       orderIndex = Value(orderIndex),
       lineText = Value(lineText),
       lineType = Value(lineType);
  static Insertable<ScriptLine> custom({
    Expression<String>? id,
    Expression<String>? productionId,
    Expression<String>? act,
    Expression<String>? scene,
    Expression<int>? lineNumber,
    Expression<int>? orderIndex,
    Expression<String>? character,
    Expression<String>? lineText,
    Expression<String>? lineType,
    Expression<String>? stageDirection,
    Expression<double>? ocrConfidence,
    Expression<int>? sourcePage,
    Expression<int>? sourceLineOnPage,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productionId != null) 'production_id': productionId,
      if (act != null) 'act': act,
      if (scene != null) 'scene': scene,
      if (lineNumber != null) 'line_number': lineNumber,
      if (orderIndex != null) 'order_index': orderIndex,
      if (character != null) 'character': character,
      if (lineText != null) 'line_text': lineText,
      if (lineType != null) 'line_type': lineType,
      if (stageDirection != null) 'stage_direction': stageDirection,
      if (ocrConfidence != null) 'ocr_confidence': ocrConfidence,
      if (sourcePage != null) 'source_page': sourcePage,
      if (sourceLineOnPage != null) 'source_line_on_page': sourceLineOnPage,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScriptLinesCompanion copyWith({
    Value<String>? id,
    Value<String>? productionId,
    Value<String>? act,
    Value<String>? scene,
    Value<int>? lineNumber,
    Value<int>? orderIndex,
    Value<String>? character,
    Value<String>? lineText,
    Value<String>? lineType,
    Value<String>? stageDirection,
    Value<double?>? ocrConfidence,
    Value<int?>? sourcePage,
    Value<int?>? sourceLineOnPage,
    Value<int>? rowid,
  }) {
    return ScriptLinesCompanion(
      id: id ?? this.id,
      productionId: productionId ?? this.productionId,
      act: act ?? this.act,
      scene: scene ?? this.scene,
      lineNumber: lineNumber ?? this.lineNumber,
      orderIndex: orderIndex ?? this.orderIndex,
      character: character ?? this.character,
      lineText: lineText ?? this.lineText,
      lineType: lineType ?? this.lineType,
      stageDirection: stageDirection ?? this.stageDirection,
      ocrConfidence: ocrConfidence ?? this.ocrConfidence,
      sourcePage: sourcePage ?? this.sourcePage,
      sourceLineOnPage: sourceLineOnPage ?? this.sourceLineOnPage,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productionId.present) {
      map['production_id'] = Variable<String>(productionId.value);
    }
    if (act.present) {
      map['act'] = Variable<String>(act.value);
    }
    if (scene.present) {
      map['scene'] = Variable<String>(scene.value);
    }
    if (lineNumber.present) {
      map['line_number'] = Variable<int>(lineNumber.value);
    }
    if (orderIndex.present) {
      map['order_index'] = Variable<int>(orderIndex.value);
    }
    if (character.present) {
      map['character'] = Variable<String>(character.value);
    }
    if (lineText.present) {
      map['line_text'] = Variable<String>(lineText.value);
    }
    if (lineType.present) {
      map['line_type'] = Variable<String>(lineType.value);
    }
    if (stageDirection.present) {
      map['stage_direction'] = Variable<String>(stageDirection.value);
    }
    if (ocrConfidence.present) {
      map['ocr_confidence'] = Variable<double>(ocrConfidence.value);
    }
    if (sourcePage.present) {
      map['source_page'] = Variable<int>(sourcePage.value);
    }
    if (sourceLineOnPage.present) {
      map['source_line_on_page'] = Variable<int>(sourceLineOnPage.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScriptLinesCompanion(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('act: $act, ')
          ..write('scene: $scene, ')
          ..write('lineNumber: $lineNumber, ')
          ..write('orderIndex: $orderIndex, ')
          ..write('character: $character, ')
          ..write('lineText: $lineText, ')
          ..write('lineType: $lineType, ')
          ..write('stageDirection: $stageDirection, ')
          ..write('ocrConfidence: $ocrConfidence, ')
          ..write('sourcePage: $sourcePage, ')
          ..write('sourceLineOnPage: $sourceLineOnPage, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScenesTable extends Scenes with TableInfo<$ScenesTable, Scene> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScenesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productionIdMeta = const VerificationMeta(
    'productionId',
  );
  @override
  late final GeneratedColumn<String> productionId = GeneratedColumn<String>(
    'production_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES productions (id)',
    ),
  );
  static const VerificationMeta _sceneNameMeta = const VerificationMeta(
    'sceneName',
  );
  @override
  late final GeneratedColumn<String> sceneName = GeneratedColumn<String>(
    'scene_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actMeta = const VerificationMeta('act');
  @override
  late final GeneratedColumn<String> act = GeneratedColumn<String>(
    'act',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _locationMeta = const VerificationMeta(
    'location',
  );
  @override
  late final GeneratedColumn<String> location = GeneratedColumn<String>(
    'location',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _startLineIndexMeta = const VerificationMeta(
    'startLineIndex',
  );
  @override
  late final GeneratedColumn<int> startLineIndex = GeneratedColumn<int>(
    'start_line_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endLineIndexMeta = const VerificationMeta(
    'endLineIndex',
  );
  @override
  late final GeneratedColumn<int> endLineIndex = GeneratedColumn<int>(
    'end_line_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _charactersMeta = const VerificationMeta(
    'characters',
  );
  @override
  late final GeneratedColumn<String> characters = GeneratedColumn<String>(
    'characters',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productionId,
    sceneName,
    act,
    location,
    description,
    startLineIndex,
    endLineIndex,
    sortOrder,
    characters,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scenes';
  @override
  VerificationContext validateIntegrity(
    Insertable<Scene> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('production_id')) {
      context.handle(
        _productionIdMeta,
        productionId.isAcceptableOrUnknown(
          data['production_id']!,
          _productionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_productionIdMeta);
    }
    if (data.containsKey('scene_name')) {
      context.handle(
        _sceneNameMeta,
        sceneName.isAcceptableOrUnknown(data['scene_name']!, _sceneNameMeta),
      );
    } else if (isInserting) {
      context.missing(_sceneNameMeta);
    }
    if (data.containsKey('act')) {
      context.handle(
        _actMeta,
        act.isAcceptableOrUnknown(data['act']!, _actMeta),
      );
    }
    if (data.containsKey('location')) {
      context.handle(
        _locationMeta,
        location.isAcceptableOrUnknown(data['location']!, _locationMeta),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('start_line_index')) {
      context.handle(
        _startLineIndexMeta,
        startLineIndex.isAcceptableOrUnknown(
          data['start_line_index']!,
          _startLineIndexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startLineIndexMeta);
    }
    if (data.containsKey('end_line_index')) {
      context.handle(
        _endLineIndexMeta,
        endLineIndex.isAcceptableOrUnknown(
          data['end_line_index']!,
          _endLineIndexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_endLineIndexMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('characters')) {
      context.handle(
        _charactersMeta,
        characters.isAcceptableOrUnknown(data['characters']!, _charactersMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Scene map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Scene(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}production_id'],
      )!,
      sceneName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scene_name'],
      )!,
      act: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}act'],
      )!,
      location: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      startLineIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_line_index'],
      )!,
      endLineIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_line_index'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      characters: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}characters'],
      )!,
    );
  }

  @override
  $ScenesTable createAlias(String alias) {
    return $ScenesTable(attachedDatabase, alias);
  }
}

class Scene extends DataClass implements Insertable<Scene> {
  final String id;
  final String productionId;
  final String sceneName;
  final String act;
  final String location;
  final String description;
  final int startLineIndex;
  final int endLineIndex;
  final int sortOrder;
  final String characters;
  const Scene({
    required this.id,
    required this.productionId,
    required this.sceneName,
    required this.act,
    required this.location,
    required this.description,
    required this.startLineIndex,
    required this.endLineIndex,
    required this.sortOrder,
    required this.characters,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['production_id'] = Variable<String>(productionId);
    map['scene_name'] = Variable<String>(sceneName);
    map['act'] = Variable<String>(act);
    map['location'] = Variable<String>(location);
    map['description'] = Variable<String>(description);
    map['start_line_index'] = Variable<int>(startLineIndex);
    map['end_line_index'] = Variable<int>(endLineIndex);
    map['sort_order'] = Variable<int>(sortOrder);
    map['characters'] = Variable<String>(characters);
    return map;
  }

  ScenesCompanion toCompanion(bool nullToAbsent) {
    return ScenesCompanion(
      id: Value(id),
      productionId: Value(productionId),
      sceneName: Value(sceneName),
      act: Value(act),
      location: Value(location),
      description: Value(description),
      startLineIndex: Value(startLineIndex),
      endLineIndex: Value(endLineIndex),
      sortOrder: Value(sortOrder),
      characters: Value(characters),
    );
  }

  factory Scene.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Scene(
      id: serializer.fromJson<String>(json['id']),
      productionId: serializer.fromJson<String>(json['productionId']),
      sceneName: serializer.fromJson<String>(json['sceneName']),
      act: serializer.fromJson<String>(json['act']),
      location: serializer.fromJson<String>(json['location']),
      description: serializer.fromJson<String>(json['description']),
      startLineIndex: serializer.fromJson<int>(json['startLineIndex']),
      endLineIndex: serializer.fromJson<int>(json['endLineIndex']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      characters: serializer.fromJson<String>(json['characters']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productionId': serializer.toJson<String>(productionId),
      'sceneName': serializer.toJson<String>(sceneName),
      'act': serializer.toJson<String>(act),
      'location': serializer.toJson<String>(location),
      'description': serializer.toJson<String>(description),
      'startLineIndex': serializer.toJson<int>(startLineIndex),
      'endLineIndex': serializer.toJson<int>(endLineIndex),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'characters': serializer.toJson<String>(characters),
    };
  }

  Scene copyWith({
    String? id,
    String? productionId,
    String? sceneName,
    String? act,
    String? location,
    String? description,
    int? startLineIndex,
    int? endLineIndex,
    int? sortOrder,
    String? characters,
  }) => Scene(
    id: id ?? this.id,
    productionId: productionId ?? this.productionId,
    sceneName: sceneName ?? this.sceneName,
    act: act ?? this.act,
    location: location ?? this.location,
    description: description ?? this.description,
    startLineIndex: startLineIndex ?? this.startLineIndex,
    endLineIndex: endLineIndex ?? this.endLineIndex,
    sortOrder: sortOrder ?? this.sortOrder,
    characters: characters ?? this.characters,
  );
  Scene copyWithCompanion(ScenesCompanion data) {
    return Scene(
      id: data.id.present ? data.id.value : this.id,
      productionId: data.productionId.present
          ? data.productionId.value
          : this.productionId,
      sceneName: data.sceneName.present ? data.sceneName.value : this.sceneName,
      act: data.act.present ? data.act.value : this.act,
      location: data.location.present ? data.location.value : this.location,
      description: data.description.present
          ? data.description.value
          : this.description,
      startLineIndex: data.startLineIndex.present
          ? data.startLineIndex.value
          : this.startLineIndex,
      endLineIndex: data.endLineIndex.present
          ? data.endLineIndex.value
          : this.endLineIndex,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      characters: data.characters.present
          ? data.characters.value
          : this.characters,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Scene(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('sceneName: $sceneName, ')
          ..write('act: $act, ')
          ..write('location: $location, ')
          ..write('description: $description, ')
          ..write('startLineIndex: $startLineIndex, ')
          ..write('endLineIndex: $endLineIndex, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('characters: $characters')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productionId,
    sceneName,
    act,
    location,
    description,
    startLineIndex,
    endLineIndex,
    sortOrder,
    characters,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Scene &&
          other.id == this.id &&
          other.productionId == this.productionId &&
          other.sceneName == this.sceneName &&
          other.act == this.act &&
          other.location == this.location &&
          other.description == this.description &&
          other.startLineIndex == this.startLineIndex &&
          other.endLineIndex == this.endLineIndex &&
          other.sortOrder == this.sortOrder &&
          other.characters == this.characters);
}

class ScenesCompanion extends UpdateCompanion<Scene> {
  final Value<String> id;
  final Value<String> productionId;
  final Value<String> sceneName;
  final Value<String> act;
  final Value<String> location;
  final Value<String> description;
  final Value<int> startLineIndex;
  final Value<int> endLineIndex;
  final Value<int> sortOrder;
  final Value<String> characters;
  final Value<int> rowid;
  const ScenesCompanion({
    this.id = const Value.absent(),
    this.productionId = const Value.absent(),
    this.sceneName = const Value.absent(),
    this.act = const Value.absent(),
    this.location = const Value.absent(),
    this.description = const Value.absent(),
    this.startLineIndex = const Value.absent(),
    this.endLineIndex = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.characters = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScenesCompanion.insert({
    required String id,
    required String productionId,
    required String sceneName,
    this.act = const Value.absent(),
    this.location = const Value.absent(),
    this.description = const Value.absent(),
    required int startLineIndex,
    required int endLineIndex,
    this.sortOrder = const Value.absent(),
    this.characters = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productionId = Value(productionId),
       sceneName = Value(sceneName),
       startLineIndex = Value(startLineIndex),
       endLineIndex = Value(endLineIndex);
  static Insertable<Scene> custom({
    Expression<String>? id,
    Expression<String>? productionId,
    Expression<String>? sceneName,
    Expression<String>? act,
    Expression<String>? location,
    Expression<String>? description,
    Expression<int>? startLineIndex,
    Expression<int>? endLineIndex,
    Expression<int>? sortOrder,
    Expression<String>? characters,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productionId != null) 'production_id': productionId,
      if (sceneName != null) 'scene_name': sceneName,
      if (act != null) 'act': act,
      if (location != null) 'location': location,
      if (description != null) 'description': description,
      if (startLineIndex != null) 'start_line_index': startLineIndex,
      if (endLineIndex != null) 'end_line_index': endLineIndex,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (characters != null) 'characters': characters,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScenesCompanion copyWith({
    Value<String>? id,
    Value<String>? productionId,
    Value<String>? sceneName,
    Value<String>? act,
    Value<String>? location,
    Value<String>? description,
    Value<int>? startLineIndex,
    Value<int>? endLineIndex,
    Value<int>? sortOrder,
    Value<String>? characters,
    Value<int>? rowid,
  }) {
    return ScenesCompanion(
      id: id ?? this.id,
      productionId: productionId ?? this.productionId,
      sceneName: sceneName ?? this.sceneName,
      act: act ?? this.act,
      location: location ?? this.location,
      description: description ?? this.description,
      startLineIndex: startLineIndex ?? this.startLineIndex,
      endLineIndex: endLineIndex ?? this.endLineIndex,
      sortOrder: sortOrder ?? this.sortOrder,
      characters: characters ?? this.characters,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productionId.present) {
      map['production_id'] = Variable<String>(productionId.value);
    }
    if (sceneName.present) {
      map['scene_name'] = Variable<String>(sceneName.value);
    }
    if (act.present) {
      map['act'] = Variable<String>(act.value);
    }
    if (location.present) {
      map['location'] = Variable<String>(location.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (startLineIndex.present) {
      map['start_line_index'] = Variable<int>(startLineIndex.value);
    }
    if (endLineIndex.present) {
      map['end_line_index'] = Variable<int>(endLineIndex.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (characters.present) {
      map['characters'] = Variable<String>(characters.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScenesCompanion(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('sceneName: $sceneName, ')
          ..write('act: $act, ')
          ..write('location: $location, ')
          ..write('description: $description, ')
          ..write('startLineIndex: $startLineIndex, ')
          ..write('endLineIndex: $endLineIndex, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('characters: $characters, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecordingsTable extends Recordings
    with TableInfo<$RecordingsTable, Recording> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productionIdMeta = const VerificationMeta(
    'productionId',
  );
  @override
  late final GeneratedColumn<String> productionId = GeneratedColumn<String>(
    'production_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES productions (id)',
    ),
  );
  static const VerificationMeta _scriptLineIdMeta = const VerificationMeta(
    'scriptLineId',
  );
  @override
  late final GeneratedColumn<String> scriptLineId = GeneratedColumn<String>(
    'script_line_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES script_lines (id)',
    ),
  );
  static const VerificationMeta _characterMeta = const VerificationMeta(
    'character',
  );
  @override
  late final GeneratedColumn<String> character = GeneratedColumn<String>(
    'character',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteUrlMeta = const VerificationMeta(
    'remoteUrl',
  );
  @override
  late final GeneratedColumn<String> remoteUrl = GeneratedColumn<String>(
    'remote_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordedAtMeta = const VerificationMeta(
    'recordedAt',
  );
  @override
  late final GeneratedColumn<DateTime> recordedAt = GeneratedColumn<DateTime>(
    'recorded_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productionId,
    scriptLineId,
    character,
    localPath,
    remoteUrl,
    durationMs,
    recordedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recordings';
  @override
  VerificationContext validateIntegrity(
    Insertable<Recording> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('production_id')) {
      context.handle(
        _productionIdMeta,
        productionId.isAcceptableOrUnknown(
          data['production_id']!,
          _productionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_productionIdMeta);
    }
    if (data.containsKey('script_line_id')) {
      context.handle(
        _scriptLineIdMeta,
        scriptLineId.isAcceptableOrUnknown(
          data['script_line_id']!,
          _scriptLineIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_scriptLineIdMeta);
    }
    if (data.containsKey('character')) {
      context.handle(
        _characterMeta,
        character.isAcceptableOrUnknown(data['character']!, _characterMeta),
      );
    } else if (isInserting) {
      context.missing(_characterMeta);
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    } else if (isInserting) {
      context.missing(_localPathMeta);
    }
    if (data.containsKey('remote_url')) {
      context.handle(
        _remoteUrlMeta,
        remoteUrl.isAcceptableOrUnknown(data['remote_url']!, _remoteUrlMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    } else if (isInserting) {
      context.missing(_durationMsMeta);
    }
    if (data.containsKey('recorded_at')) {
      context.handle(
        _recordedAtMeta,
        recordedAt.isAcceptableOrUnknown(data['recorded_at']!, _recordedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Recording map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Recording(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}production_id'],
      )!,
      scriptLineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}script_line_id'],
      )!,
      character: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}character'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      )!,
      remoteUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_url'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      recordedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}recorded_at'],
      )!,
    );
  }

  @override
  $RecordingsTable createAlias(String alias) {
    return $RecordingsTable(attachedDatabase, alias);
  }
}

class Recording extends DataClass implements Insertable<Recording> {
  final String id;
  final String productionId;
  final String scriptLineId;
  final String character;
  final String localPath;
  final String? remoteUrl;
  final int durationMs;
  final DateTime recordedAt;
  const Recording({
    required this.id,
    required this.productionId,
    required this.scriptLineId,
    required this.character,
    required this.localPath,
    this.remoteUrl,
    required this.durationMs,
    required this.recordedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['production_id'] = Variable<String>(productionId);
    map['script_line_id'] = Variable<String>(scriptLineId);
    map['character'] = Variable<String>(character);
    map['local_path'] = Variable<String>(localPath);
    if (!nullToAbsent || remoteUrl != null) {
      map['remote_url'] = Variable<String>(remoteUrl);
    }
    map['duration_ms'] = Variable<int>(durationMs);
    map['recorded_at'] = Variable<DateTime>(recordedAt);
    return map;
  }

  RecordingsCompanion toCompanion(bool nullToAbsent) {
    return RecordingsCompanion(
      id: Value(id),
      productionId: Value(productionId),
      scriptLineId: Value(scriptLineId),
      character: Value(character),
      localPath: Value(localPath),
      remoteUrl: remoteUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteUrl),
      durationMs: Value(durationMs),
      recordedAt: Value(recordedAt),
    );
  }

  factory Recording.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Recording(
      id: serializer.fromJson<String>(json['id']),
      productionId: serializer.fromJson<String>(json['productionId']),
      scriptLineId: serializer.fromJson<String>(json['scriptLineId']),
      character: serializer.fromJson<String>(json['character']),
      localPath: serializer.fromJson<String>(json['localPath']),
      remoteUrl: serializer.fromJson<String?>(json['remoteUrl']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      recordedAt: serializer.fromJson<DateTime>(json['recordedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productionId': serializer.toJson<String>(productionId),
      'scriptLineId': serializer.toJson<String>(scriptLineId),
      'character': serializer.toJson<String>(character),
      'localPath': serializer.toJson<String>(localPath),
      'remoteUrl': serializer.toJson<String?>(remoteUrl),
      'durationMs': serializer.toJson<int>(durationMs),
      'recordedAt': serializer.toJson<DateTime>(recordedAt),
    };
  }

  Recording copyWith({
    String? id,
    String? productionId,
    String? scriptLineId,
    String? character,
    String? localPath,
    Value<String?> remoteUrl = const Value.absent(),
    int? durationMs,
    DateTime? recordedAt,
  }) => Recording(
    id: id ?? this.id,
    productionId: productionId ?? this.productionId,
    scriptLineId: scriptLineId ?? this.scriptLineId,
    character: character ?? this.character,
    localPath: localPath ?? this.localPath,
    remoteUrl: remoteUrl.present ? remoteUrl.value : this.remoteUrl,
    durationMs: durationMs ?? this.durationMs,
    recordedAt: recordedAt ?? this.recordedAt,
  );
  Recording copyWithCompanion(RecordingsCompanion data) {
    return Recording(
      id: data.id.present ? data.id.value : this.id,
      productionId: data.productionId.present
          ? data.productionId.value
          : this.productionId,
      scriptLineId: data.scriptLineId.present
          ? data.scriptLineId.value
          : this.scriptLineId,
      character: data.character.present ? data.character.value : this.character,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      remoteUrl: data.remoteUrl.present ? data.remoteUrl.value : this.remoteUrl,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      recordedAt: data.recordedAt.present
          ? data.recordedAt.value
          : this.recordedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Recording(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('scriptLineId: $scriptLineId, ')
          ..write('character: $character, ')
          ..write('localPath: $localPath, ')
          ..write('remoteUrl: $remoteUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('recordedAt: $recordedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productionId,
    scriptLineId,
    character,
    localPath,
    remoteUrl,
    durationMs,
    recordedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Recording &&
          other.id == this.id &&
          other.productionId == this.productionId &&
          other.scriptLineId == this.scriptLineId &&
          other.character == this.character &&
          other.localPath == this.localPath &&
          other.remoteUrl == this.remoteUrl &&
          other.durationMs == this.durationMs &&
          other.recordedAt == this.recordedAt);
}

class RecordingsCompanion extends UpdateCompanion<Recording> {
  final Value<String> id;
  final Value<String> productionId;
  final Value<String> scriptLineId;
  final Value<String> character;
  final Value<String> localPath;
  final Value<String?> remoteUrl;
  final Value<int> durationMs;
  final Value<DateTime> recordedAt;
  final Value<int> rowid;
  const RecordingsCompanion({
    this.id = const Value.absent(),
    this.productionId = const Value.absent(),
    this.scriptLineId = const Value.absent(),
    this.character = const Value.absent(),
    this.localPath = const Value.absent(),
    this.remoteUrl = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.recordedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecordingsCompanion.insert({
    required String id,
    required String productionId,
    required String scriptLineId,
    required String character,
    required String localPath,
    this.remoteUrl = const Value.absent(),
    required int durationMs,
    this.recordedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productionId = Value(productionId),
       scriptLineId = Value(scriptLineId),
       character = Value(character),
       localPath = Value(localPath),
       durationMs = Value(durationMs);
  static Insertable<Recording> custom({
    Expression<String>? id,
    Expression<String>? productionId,
    Expression<String>? scriptLineId,
    Expression<String>? character,
    Expression<String>? localPath,
    Expression<String>? remoteUrl,
    Expression<int>? durationMs,
    Expression<DateTime>? recordedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productionId != null) 'production_id': productionId,
      if (scriptLineId != null) 'script_line_id': scriptLineId,
      if (character != null) 'character': character,
      if (localPath != null) 'local_path': localPath,
      if (remoteUrl != null) 'remote_url': remoteUrl,
      if (durationMs != null) 'duration_ms': durationMs,
      if (recordedAt != null) 'recorded_at': recordedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecordingsCompanion copyWith({
    Value<String>? id,
    Value<String>? productionId,
    Value<String>? scriptLineId,
    Value<String>? character,
    Value<String>? localPath,
    Value<String?>? remoteUrl,
    Value<int>? durationMs,
    Value<DateTime>? recordedAt,
    Value<int>? rowid,
  }) {
    return RecordingsCompanion(
      id: id ?? this.id,
      productionId: productionId ?? this.productionId,
      scriptLineId: scriptLineId ?? this.scriptLineId,
      character: character ?? this.character,
      localPath: localPath ?? this.localPath,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      durationMs: durationMs ?? this.durationMs,
      recordedAt: recordedAt ?? this.recordedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productionId.present) {
      map['production_id'] = Variable<String>(productionId.value);
    }
    if (scriptLineId.present) {
      map['script_line_id'] = Variable<String>(scriptLineId.value);
    }
    if (character.present) {
      map['character'] = Variable<String>(character.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (remoteUrl.present) {
      map['remote_url'] = Variable<String>(remoteUrl.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (recordedAt.present) {
      map['recorded_at'] = Variable<DateTime>(recordedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordingsCompanion(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('scriptLineId: $scriptLineId, ')
          ..write('character: $character, ')
          ..write('localPath: $localPath, ')
          ..write('remoteUrl: $remoteUrl, ')
          ..write('durationMs: $durationMs, ')
          ..write('recordedAt: $recordedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CastMembersTable extends CastMembers
    with TableInfo<$CastMembersTable, CastMember> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CastMembersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _productionIdMeta = const VerificationMeta(
    'productionId',
  );
  @override
  late final GeneratedColumn<String> productionId = GeneratedColumn<String>(
    'production_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES productions (id)',
    ),
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _characterNameMeta = const VerificationMeta(
    'characterName',
  );
  @override
  late final GeneratedColumn<String> characterName = GeneratedColumn<String>(
    'character_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _invitedAtMeta = const VerificationMeta(
    'invitedAt',
  );
  @override
  late final GeneratedColumn<DateTime> invitedAt = GeneratedColumn<DateTime>(
    'invited_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _joinedAtMeta = const VerificationMeta(
    'joinedAt',
  );
  @override
  late final GeneratedColumn<DateTime> joinedAt = GeneratedColumn<DateTime>(
    'joined_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    productionId,
    userId,
    characterName,
    displayName,
    role,
    invitedAt,
    joinedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cast_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<CastMember> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('production_id')) {
      context.handle(
        _productionIdMeta,
        productionId.isAcceptableOrUnknown(
          data['production_id']!,
          _productionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_productionIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    }
    if (data.containsKey('character_name')) {
      context.handle(
        _characterNameMeta,
        characterName.isAcceptableOrUnknown(
          data['character_name']!,
          _characterNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_characterNameMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('invited_at')) {
      context.handle(
        _invitedAtMeta,
        invitedAt.isAcceptableOrUnknown(data['invited_at']!, _invitedAtMeta),
      );
    }
    if (data.containsKey('joined_at')) {
      context.handle(
        _joinedAtMeta,
        joinedAt.isAcceptableOrUnknown(data['joined_at']!, _joinedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CastMember map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CastMember(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      productionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}production_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      ),
      characterName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}character_name'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      invitedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}invited_at'],
      )!,
      joinedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}joined_at'],
      ),
    );
  }

  @override
  $CastMembersTable createAlias(String alias) {
    return $CastMembersTable(attachedDatabase, alias);
  }
}

class CastMember extends DataClass implements Insertable<CastMember> {
  final String id;
  final String productionId;
  final String? userId;
  final String characterName;
  final String displayName;
  final String role;
  final DateTime invitedAt;
  final DateTime? joinedAt;
  const CastMember({
    required this.id,
    required this.productionId,
    this.userId,
    required this.characterName,
    required this.displayName,
    required this.role,
    required this.invitedAt,
    this.joinedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['production_id'] = Variable<String>(productionId);
    if (!nullToAbsent || userId != null) {
      map['user_id'] = Variable<String>(userId);
    }
    map['character_name'] = Variable<String>(characterName);
    map['display_name'] = Variable<String>(displayName);
    map['role'] = Variable<String>(role);
    map['invited_at'] = Variable<DateTime>(invitedAt);
    if (!nullToAbsent || joinedAt != null) {
      map['joined_at'] = Variable<DateTime>(joinedAt);
    }
    return map;
  }

  CastMembersCompanion toCompanion(bool nullToAbsent) {
    return CastMembersCompanion(
      id: Value(id),
      productionId: Value(productionId),
      userId: userId == null && nullToAbsent
          ? const Value.absent()
          : Value(userId),
      characterName: Value(characterName),
      displayName: Value(displayName),
      role: Value(role),
      invitedAt: Value(invitedAt),
      joinedAt: joinedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(joinedAt),
    );
  }

  factory CastMember.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CastMember(
      id: serializer.fromJson<String>(json['id']),
      productionId: serializer.fromJson<String>(json['productionId']),
      userId: serializer.fromJson<String?>(json['userId']),
      characterName: serializer.fromJson<String>(json['characterName']),
      displayName: serializer.fromJson<String>(json['displayName']),
      role: serializer.fromJson<String>(json['role']),
      invitedAt: serializer.fromJson<DateTime>(json['invitedAt']),
      joinedAt: serializer.fromJson<DateTime?>(json['joinedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'productionId': serializer.toJson<String>(productionId),
      'userId': serializer.toJson<String?>(userId),
      'characterName': serializer.toJson<String>(characterName),
      'displayName': serializer.toJson<String>(displayName),
      'role': serializer.toJson<String>(role),
      'invitedAt': serializer.toJson<DateTime>(invitedAt),
      'joinedAt': serializer.toJson<DateTime?>(joinedAt),
    };
  }

  CastMember copyWith({
    String? id,
    String? productionId,
    Value<String?> userId = const Value.absent(),
    String? characterName,
    String? displayName,
    String? role,
    DateTime? invitedAt,
    Value<DateTime?> joinedAt = const Value.absent(),
  }) => CastMember(
    id: id ?? this.id,
    productionId: productionId ?? this.productionId,
    userId: userId.present ? userId.value : this.userId,
    characterName: characterName ?? this.characterName,
    displayName: displayName ?? this.displayName,
    role: role ?? this.role,
    invitedAt: invitedAt ?? this.invitedAt,
    joinedAt: joinedAt.present ? joinedAt.value : this.joinedAt,
  );
  CastMember copyWithCompanion(CastMembersCompanion data) {
    return CastMember(
      id: data.id.present ? data.id.value : this.id,
      productionId: data.productionId.present
          ? data.productionId.value
          : this.productionId,
      userId: data.userId.present ? data.userId.value : this.userId,
      characterName: data.characterName.present
          ? data.characterName.value
          : this.characterName,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      role: data.role.present ? data.role.value : this.role,
      invitedAt: data.invitedAt.present ? data.invitedAt.value : this.invitedAt,
      joinedAt: data.joinedAt.present ? data.joinedAt.value : this.joinedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CastMember(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('userId: $userId, ')
          ..write('characterName: $characterName, ')
          ..write('displayName: $displayName, ')
          ..write('role: $role, ')
          ..write('invitedAt: $invitedAt, ')
          ..write('joinedAt: $joinedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    productionId,
    userId,
    characterName,
    displayName,
    role,
    invitedAt,
    joinedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CastMember &&
          other.id == this.id &&
          other.productionId == this.productionId &&
          other.userId == this.userId &&
          other.characterName == this.characterName &&
          other.displayName == this.displayName &&
          other.role == this.role &&
          other.invitedAt == this.invitedAt &&
          other.joinedAt == this.joinedAt);
}

class CastMembersCompanion extends UpdateCompanion<CastMember> {
  final Value<String> id;
  final Value<String> productionId;
  final Value<String?> userId;
  final Value<String> characterName;
  final Value<String> displayName;
  final Value<String> role;
  final Value<DateTime> invitedAt;
  final Value<DateTime?> joinedAt;
  final Value<int> rowid;
  const CastMembersCompanion({
    this.id = const Value.absent(),
    this.productionId = const Value.absent(),
    this.userId = const Value.absent(),
    this.characterName = const Value.absent(),
    this.displayName = const Value.absent(),
    this.role = const Value.absent(),
    this.invitedAt = const Value.absent(),
    this.joinedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CastMembersCompanion.insert({
    required String id,
    required String productionId,
    this.userId = const Value.absent(),
    required String characterName,
    this.displayName = const Value.absent(),
    required String role,
    this.invitedAt = const Value.absent(),
    this.joinedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       productionId = Value(productionId),
       characterName = Value(characterName),
       role = Value(role);
  static Insertable<CastMember> custom({
    Expression<String>? id,
    Expression<String>? productionId,
    Expression<String>? userId,
    Expression<String>? characterName,
    Expression<String>? displayName,
    Expression<String>? role,
    Expression<DateTime>? invitedAt,
    Expression<DateTime>? joinedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (productionId != null) 'production_id': productionId,
      if (userId != null) 'user_id': userId,
      if (characterName != null) 'character_name': characterName,
      if (displayName != null) 'display_name': displayName,
      if (role != null) 'role': role,
      if (invitedAt != null) 'invited_at': invitedAt,
      if (joinedAt != null) 'joined_at': joinedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CastMembersCompanion copyWith({
    Value<String>? id,
    Value<String>? productionId,
    Value<String?>? userId,
    Value<String>? characterName,
    Value<String>? displayName,
    Value<String>? role,
    Value<DateTime>? invitedAt,
    Value<DateTime?>? joinedAt,
    Value<int>? rowid,
  }) {
    return CastMembersCompanion(
      id: id ?? this.id,
      productionId: productionId ?? this.productionId,
      userId: userId ?? this.userId,
      characterName: characterName ?? this.characterName,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      invitedAt: invitedAt ?? this.invitedAt,
      joinedAt: joinedAt ?? this.joinedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (productionId.present) {
      map['production_id'] = Variable<String>(productionId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (characterName.present) {
      map['character_name'] = Variable<String>(characterName.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (invitedAt.present) {
      map['invited_at'] = Variable<DateTime>(invitedAt.value);
    }
    if (joinedAt.present) {
      map['joined_at'] = Variable<DateTime>(joinedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CastMembersCompanion(')
          ..write('id: $id, ')
          ..write('productionId: $productionId, ')
          ..write('userId: $userId, ')
          ..write('characterName: $characterName, ')
          ..write('displayName: $displayName, ')
          ..write('role: $role, ')
          ..write('invitedAt: $invitedAt, ')
          ..write('joinedAt: $joinedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ProductionsTable productions = $ProductionsTable(this);
  late final $ScriptLinesTable scriptLines = $ScriptLinesTable(this);
  late final $ScenesTable scenes = $ScenesTable(this);
  late final $RecordingsTable recordings = $RecordingsTable(this);
  late final $CastMembersTable castMembers = $CastMembersTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    productions,
    scriptLines,
    scenes,
    recordings,
    castMembers,
  ];
}

typedef $$ProductionsTableCreateCompanionBuilder =
    ProductionsCompanion Function({
      required String id,
      required String title,
      Value<String?> organizerId,
      Value<String> status,
      Value<String?> scriptPath,
      Value<String> locale,
      Value<String?> joinCode,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });
typedef $$ProductionsTableUpdateCompanionBuilder =
    ProductionsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String?> organizerId,
      Value<String> status,
      Value<String?> scriptPath,
      Value<String> locale,
      Value<String?> joinCode,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$ProductionsTableReferences
    extends BaseReferences<_$AppDatabase, $ProductionsTable, Production> {
  $$ProductionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ScriptLinesTable, List<ScriptLine>>
  _scriptLinesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.scriptLines,
    aliasName: $_aliasNameGenerator(
      db.productions.id,
      db.scriptLines.productionId,
    ),
  );

  $$ScriptLinesTableProcessedTableManager get scriptLinesRefs {
    final manager = $$ScriptLinesTableTableManager(
      $_db,
      $_db.scriptLines,
    ).filter((f) => f.productionId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_scriptLinesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScenesTable, List<Scene>> _scenesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.scenes,
    aliasName: $_aliasNameGenerator(db.productions.id, db.scenes.productionId),
  );

  $$ScenesTableProcessedTableManager get scenesRefs {
    final manager = $$ScenesTableTableManager(
      $_db,
      $_db.scenes,
    ).filter((f) => f.productionId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_scenesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RecordingsTable, List<Recording>>
  _recordingsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.recordings,
    aliasName: $_aliasNameGenerator(
      db.productions.id,
      db.recordings.productionId,
    ),
  );

  $$RecordingsTableProcessedTableManager get recordingsRefs {
    final manager = $$RecordingsTableTableManager(
      $_db,
      $_db.recordings,
    ).filter((f) => f.productionId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_recordingsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CastMembersTable, List<CastMember>>
  _castMembersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.castMembers,
    aliasName: $_aliasNameGenerator(
      db.productions.id,
      db.castMembers.productionId,
    ),
  );

  $$CastMembersTableProcessedTableManager get castMembersRefs {
    final manager = $$CastMembersTableTableManager(
      $_db,
      $_db.castMembers,
    ).filter((f) => f.productionId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_castMembersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ProductionsTableFilterComposer
    extends Composer<_$AppDatabase, $ProductionsTable> {
  $$ProductionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get organizerId => $composableBuilder(
    column: $table.organizerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scriptPath => $composableBuilder(
    column: $table.scriptPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locale => $composableBuilder(
    column: $table.locale,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get joinCode => $composableBuilder(
    column: $table.joinCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> scriptLinesRefs(
    Expression<bool> Function($$ScriptLinesTableFilterComposer f) f,
  ) {
    final $$ScriptLinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scriptLines,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScriptLinesTableFilterComposer(
            $db: $db,
            $table: $db.scriptLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> scenesRefs(
    Expression<bool> Function($$ScenesTableFilterComposer f) f,
  ) {
    final $$ScenesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scenes,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScenesTableFilterComposer(
            $db: $db,
            $table: $db.scenes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> recordingsRefs(
    Expression<bool> Function($$RecordingsTableFilterComposer f) f,
  ) {
    final $$RecordingsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.recordings,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecordingsTableFilterComposer(
            $db: $db,
            $table: $db.recordings,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> castMembersRefs(
    Expression<bool> Function($$CastMembersTableFilterComposer f) f,
  ) {
    final $$CastMembersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.castMembers,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CastMembersTableFilterComposer(
            $db: $db,
            $table: $db.castMembers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ProductionsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProductionsTable> {
  $$ProductionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get organizerId => $composableBuilder(
    column: $table.organizerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scriptPath => $composableBuilder(
    column: $table.scriptPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locale => $composableBuilder(
    column: $table.locale,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get joinCode => $composableBuilder(
    column: $table.joinCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProductionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProductionsTable> {
  $$ProductionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get organizerId => $composableBuilder(
    column: $table.organizerId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get scriptPath => $composableBuilder(
    column: $table.scriptPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get locale =>
      $composableBuilder(column: $table.locale, builder: (column) => column);

  GeneratedColumn<String> get joinCode =>
      $composableBuilder(column: $table.joinCode, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> scriptLinesRefs<T extends Object>(
    Expression<T> Function($$ScriptLinesTableAnnotationComposer a) f,
  ) {
    final $$ScriptLinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scriptLines,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScriptLinesTableAnnotationComposer(
            $db: $db,
            $table: $db.scriptLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> scenesRefs<T extends Object>(
    Expression<T> Function($$ScenesTableAnnotationComposer a) f,
  ) {
    final $$ScenesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scenes,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScenesTableAnnotationComposer(
            $db: $db,
            $table: $db.scenes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> recordingsRefs<T extends Object>(
    Expression<T> Function($$RecordingsTableAnnotationComposer a) f,
  ) {
    final $$RecordingsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.recordings,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecordingsTableAnnotationComposer(
            $db: $db,
            $table: $db.recordings,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> castMembersRefs<T extends Object>(
    Expression<T> Function($$CastMembersTableAnnotationComposer a) f,
  ) {
    final $$CastMembersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.castMembers,
      getReferencedColumn: (t) => t.productionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CastMembersTableAnnotationComposer(
            $db: $db,
            $table: $db.castMembers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ProductionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProductionsTable,
          Production,
          $$ProductionsTableFilterComposer,
          $$ProductionsTableOrderingComposer,
          $$ProductionsTableAnnotationComposer,
          $$ProductionsTableCreateCompanionBuilder,
          $$ProductionsTableUpdateCompanionBuilder,
          (Production, $$ProductionsTableReferences),
          Production,
          PrefetchHooks Function({
            bool scriptLinesRefs,
            bool scenesRefs,
            bool recordingsRefs,
            bool castMembersRefs,
          })
        > {
  $$ProductionsTableTableManager(_$AppDatabase db, $ProductionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProductionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProductionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProductionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> organizerId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> scriptPath = const Value.absent(),
                Value<String> locale = const Value.absent(),
                Value<String?> joinCode = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProductionsCompanion(
                id: id,
                title: title,
                organizerId: organizerId,
                status: status,
                scriptPath: scriptPath,
                locale: locale,
                joinCode: joinCode,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String?> organizerId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> scriptPath = const Value.absent(),
                Value<String> locale = const Value.absent(),
                Value<String?> joinCode = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProductionsCompanion.insert(
                id: id,
                title: title,
                organizerId: organizerId,
                status: status,
                scriptPath: scriptPath,
                locale: locale,
                joinCode: joinCode,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ProductionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                scriptLinesRefs = false,
                scenesRefs = false,
                recordingsRefs = false,
                castMembersRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (scriptLinesRefs) db.scriptLines,
                    if (scenesRefs) db.scenes,
                    if (recordingsRefs) db.recordings,
                    if (castMembersRefs) db.castMembers,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (scriptLinesRefs)
                        await $_getPrefetchedData<
                          Production,
                          $ProductionsTable,
                          ScriptLine
                        >(
                          currentTable: table,
                          referencedTable: $$ProductionsTableReferences
                              ._scriptLinesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ProductionsTableReferences(
                                db,
                                table,
                                p0,
                              ).scriptLinesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.productionId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (scenesRefs)
                        await $_getPrefetchedData<
                          Production,
                          $ProductionsTable,
                          Scene
                        >(
                          currentTable: table,
                          referencedTable: $$ProductionsTableReferences
                              ._scenesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ProductionsTableReferences(
                                db,
                                table,
                                p0,
                              ).scenesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.productionId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (recordingsRefs)
                        await $_getPrefetchedData<
                          Production,
                          $ProductionsTable,
                          Recording
                        >(
                          currentTable: table,
                          referencedTable: $$ProductionsTableReferences
                              ._recordingsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ProductionsTableReferences(
                                db,
                                table,
                                p0,
                              ).recordingsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.productionId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (castMembersRefs)
                        await $_getPrefetchedData<
                          Production,
                          $ProductionsTable,
                          CastMember
                        >(
                          currentTable: table,
                          referencedTable: $$ProductionsTableReferences
                              ._castMembersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ProductionsTableReferences(
                                db,
                                table,
                                p0,
                              ).castMembersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.productionId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ProductionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProductionsTable,
      Production,
      $$ProductionsTableFilterComposer,
      $$ProductionsTableOrderingComposer,
      $$ProductionsTableAnnotationComposer,
      $$ProductionsTableCreateCompanionBuilder,
      $$ProductionsTableUpdateCompanionBuilder,
      (Production, $$ProductionsTableReferences),
      Production,
      PrefetchHooks Function({
        bool scriptLinesRefs,
        bool scenesRefs,
        bool recordingsRefs,
        bool castMembersRefs,
      })
    >;
typedef $$ScriptLinesTableCreateCompanionBuilder =
    ScriptLinesCompanion Function({
      required String id,
      required String productionId,
      Value<String> act,
      Value<String> scene,
      required int lineNumber,
      required int orderIndex,
      Value<String> character,
      required String lineText,
      required String lineType,
      Value<String> stageDirection,
      Value<double?> ocrConfidence,
      Value<int?> sourcePage,
      Value<int?> sourceLineOnPage,
      Value<int> rowid,
    });
typedef $$ScriptLinesTableUpdateCompanionBuilder =
    ScriptLinesCompanion Function({
      Value<String> id,
      Value<String> productionId,
      Value<String> act,
      Value<String> scene,
      Value<int> lineNumber,
      Value<int> orderIndex,
      Value<String> character,
      Value<String> lineText,
      Value<String> lineType,
      Value<String> stageDirection,
      Value<double?> ocrConfidence,
      Value<int?> sourcePage,
      Value<int?> sourceLineOnPage,
      Value<int> rowid,
    });

final class $$ScriptLinesTableReferences
    extends BaseReferences<_$AppDatabase, $ScriptLinesTable, ScriptLine> {
  $$ScriptLinesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ProductionsTable _productionIdTable(_$AppDatabase db) =>
      db.productions.createAlias(
        $_aliasNameGenerator(db.scriptLines.productionId, db.productions.id),
      );

  $$ProductionsTableProcessedTableManager get productionId {
    final $_column = $_itemColumn<String>('production_id')!;

    final manager = $$ProductionsTableTableManager(
      $_db,
      $_db.productions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_productionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$RecordingsTable, List<Recording>>
  _recordingsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.recordings,
    aliasName: $_aliasNameGenerator(
      db.scriptLines.id,
      db.recordings.scriptLineId,
    ),
  );

  $$RecordingsTableProcessedTableManager get recordingsRefs {
    final manager = $$RecordingsTableTableManager(
      $_db,
      $_db.recordings,
    ).filter((f) => f.scriptLineId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_recordingsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ScriptLinesTableFilterComposer
    extends Composer<_$AppDatabase, $ScriptLinesTable> {
  $$ScriptLinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get act => $composableBuilder(
    column: $table.act,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scene => $composableBuilder(
    column: $table.scene,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lineNumber => $composableBuilder(
    column: $table.lineNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get orderIndex => $composableBuilder(
    column: $table.orderIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get character => $composableBuilder(
    column: $table.character,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lineText => $composableBuilder(
    column: $table.lineText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lineType => $composableBuilder(
    column: $table.lineType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stageDirection => $composableBuilder(
    column: $table.stageDirection,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get ocrConfidence => $composableBuilder(
    column: $table.ocrConfidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourcePage => $composableBuilder(
    column: $table.sourcePage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceLineOnPage => $composableBuilder(
    column: $table.sourceLineOnPage,
    builder: (column) => ColumnFilters(column),
  );

  $$ProductionsTableFilterComposer get productionId {
    final $$ProductionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableFilterComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> recordingsRefs(
    Expression<bool> Function($$RecordingsTableFilterComposer f) f,
  ) {
    final $$RecordingsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.recordings,
      getReferencedColumn: (t) => t.scriptLineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecordingsTableFilterComposer(
            $db: $db,
            $table: $db.recordings,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ScriptLinesTableOrderingComposer
    extends Composer<_$AppDatabase, $ScriptLinesTable> {
  $$ScriptLinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get act => $composableBuilder(
    column: $table.act,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scene => $composableBuilder(
    column: $table.scene,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lineNumber => $composableBuilder(
    column: $table.lineNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get orderIndex => $composableBuilder(
    column: $table.orderIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get character => $composableBuilder(
    column: $table.character,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lineText => $composableBuilder(
    column: $table.lineText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lineType => $composableBuilder(
    column: $table.lineType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stageDirection => $composableBuilder(
    column: $table.stageDirection,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get ocrConfidence => $composableBuilder(
    column: $table.ocrConfidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourcePage => $composableBuilder(
    column: $table.sourcePage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceLineOnPage => $composableBuilder(
    column: $table.sourceLineOnPage,
    builder: (column) => ColumnOrderings(column),
  );

  $$ProductionsTableOrderingComposer get productionId {
    final $$ProductionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableOrderingComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScriptLinesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScriptLinesTable> {
  $$ScriptLinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get act =>
      $composableBuilder(column: $table.act, builder: (column) => column);

  GeneratedColumn<String> get scene =>
      $composableBuilder(column: $table.scene, builder: (column) => column);

  GeneratedColumn<int> get lineNumber => $composableBuilder(
    column: $table.lineNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get orderIndex => $composableBuilder(
    column: $table.orderIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get character =>
      $composableBuilder(column: $table.character, builder: (column) => column);

  GeneratedColumn<String> get lineText =>
      $composableBuilder(column: $table.lineText, builder: (column) => column);

  GeneratedColumn<String> get lineType =>
      $composableBuilder(column: $table.lineType, builder: (column) => column);

  GeneratedColumn<String> get stageDirection => $composableBuilder(
    column: $table.stageDirection,
    builder: (column) => column,
  );

  GeneratedColumn<double> get ocrConfidence => $composableBuilder(
    column: $table.ocrConfidence,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sourcePage => $composableBuilder(
    column: $table.sourcePage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sourceLineOnPage => $composableBuilder(
    column: $table.sourceLineOnPage,
    builder: (column) => column,
  );

  $$ProductionsTableAnnotationComposer get productionId {
    final $$ProductionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableAnnotationComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> recordingsRefs<T extends Object>(
    Expression<T> Function($$RecordingsTableAnnotationComposer a) f,
  ) {
    final $$RecordingsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.recordings,
      getReferencedColumn: (t) => t.scriptLineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecordingsTableAnnotationComposer(
            $db: $db,
            $table: $db.recordings,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ScriptLinesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScriptLinesTable,
          ScriptLine,
          $$ScriptLinesTableFilterComposer,
          $$ScriptLinesTableOrderingComposer,
          $$ScriptLinesTableAnnotationComposer,
          $$ScriptLinesTableCreateCompanionBuilder,
          $$ScriptLinesTableUpdateCompanionBuilder,
          (ScriptLine, $$ScriptLinesTableReferences),
          ScriptLine,
          PrefetchHooks Function({bool productionId, bool recordingsRefs})
        > {
  $$ScriptLinesTableTableManager(_$AppDatabase db, $ScriptLinesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScriptLinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScriptLinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScriptLinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productionId = const Value.absent(),
                Value<String> act = const Value.absent(),
                Value<String> scene = const Value.absent(),
                Value<int> lineNumber = const Value.absent(),
                Value<int> orderIndex = const Value.absent(),
                Value<String> character = const Value.absent(),
                Value<String> lineText = const Value.absent(),
                Value<String> lineType = const Value.absent(),
                Value<String> stageDirection = const Value.absent(),
                Value<double?> ocrConfidence = const Value.absent(),
                Value<int?> sourcePage = const Value.absent(),
                Value<int?> sourceLineOnPage = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScriptLinesCompanion(
                id: id,
                productionId: productionId,
                act: act,
                scene: scene,
                lineNumber: lineNumber,
                orderIndex: orderIndex,
                character: character,
                lineText: lineText,
                lineType: lineType,
                stageDirection: stageDirection,
                ocrConfidence: ocrConfidence,
                sourcePage: sourcePage,
                sourceLineOnPage: sourceLineOnPage,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productionId,
                Value<String> act = const Value.absent(),
                Value<String> scene = const Value.absent(),
                required int lineNumber,
                required int orderIndex,
                Value<String> character = const Value.absent(),
                required String lineText,
                required String lineType,
                Value<String> stageDirection = const Value.absent(),
                Value<double?> ocrConfidence = const Value.absent(),
                Value<int?> sourcePage = const Value.absent(),
                Value<int?> sourceLineOnPage = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScriptLinesCompanion.insert(
                id: id,
                productionId: productionId,
                act: act,
                scene: scene,
                lineNumber: lineNumber,
                orderIndex: orderIndex,
                character: character,
                lineText: lineText,
                lineType: lineType,
                stageDirection: stageDirection,
                ocrConfidence: ocrConfidence,
                sourcePage: sourcePage,
                sourceLineOnPage: sourceLineOnPage,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ScriptLinesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({productionId = false, recordingsRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [if (recordingsRefs) db.recordings],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (productionId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.productionId,
                                    referencedTable:
                                        $$ScriptLinesTableReferences
                                            ._productionIdTable(db),
                                    referencedColumn:
                                        $$ScriptLinesTableReferences
                                            ._productionIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (recordingsRefs)
                        await $_getPrefetchedData<
                          ScriptLine,
                          $ScriptLinesTable,
                          Recording
                        >(
                          currentTable: table,
                          referencedTable: $$ScriptLinesTableReferences
                              ._recordingsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ScriptLinesTableReferences(
                                db,
                                table,
                                p0,
                              ).recordingsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.scriptLineId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ScriptLinesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScriptLinesTable,
      ScriptLine,
      $$ScriptLinesTableFilterComposer,
      $$ScriptLinesTableOrderingComposer,
      $$ScriptLinesTableAnnotationComposer,
      $$ScriptLinesTableCreateCompanionBuilder,
      $$ScriptLinesTableUpdateCompanionBuilder,
      (ScriptLine, $$ScriptLinesTableReferences),
      ScriptLine,
      PrefetchHooks Function({bool productionId, bool recordingsRefs})
    >;
typedef $$ScenesTableCreateCompanionBuilder =
    ScenesCompanion Function({
      required String id,
      required String productionId,
      required String sceneName,
      Value<String> act,
      Value<String> location,
      Value<String> description,
      required int startLineIndex,
      required int endLineIndex,
      Value<int> sortOrder,
      Value<String> characters,
      Value<int> rowid,
    });
typedef $$ScenesTableUpdateCompanionBuilder =
    ScenesCompanion Function({
      Value<String> id,
      Value<String> productionId,
      Value<String> sceneName,
      Value<String> act,
      Value<String> location,
      Value<String> description,
      Value<int> startLineIndex,
      Value<int> endLineIndex,
      Value<int> sortOrder,
      Value<String> characters,
      Value<int> rowid,
    });

final class $$ScenesTableReferences
    extends BaseReferences<_$AppDatabase, $ScenesTable, Scene> {
  $$ScenesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ProductionsTable _productionIdTable(_$AppDatabase db) =>
      db.productions.createAlias(
        $_aliasNameGenerator(db.scenes.productionId, db.productions.id),
      );

  $$ProductionsTableProcessedTableManager get productionId {
    final $_column = $_itemColumn<String>('production_id')!;

    final manager = $$ProductionsTableTableManager(
      $_db,
      $_db.productions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_productionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ScenesTableFilterComposer
    extends Composer<_$AppDatabase, $ScenesTable> {
  $$ScenesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sceneName => $composableBuilder(
    column: $table.sceneName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get act => $composableBuilder(
    column: $table.act,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startLineIndex => $composableBuilder(
    column: $table.startLineIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endLineIndex => $composableBuilder(
    column: $table.endLineIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get characters => $composableBuilder(
    column: $table.characters,
    builder: (column) => ColumnFilters(column),
  );

  $$ProductionsTableFilterComposer get productionId {
    final $$ProductionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableFilterComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScenesTableOrderingComposer
    extends Composer<_$AppDatabase, $ScenesTable> {
  $$ScenesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sceneName => $composableBuilder(
    column: $table.sceneName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get act => $composableBuilder(
    column: $table.act,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startLineIndex => $composableBuilder(
    column: $table.startLineIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endLineIndex => $composableBuilder(
    column: $table.endLineIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get characters => $composableBuilder(
    column: $table.characters,
    builder: (column) => ColumnOrderings(column),
  );

  $$ProductionsTableOrderingComposer get productionId {
    final $$ProductionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableOrderingComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScenesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScenesTable> {
  $$ScenesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sceneName =>
      $composableBuilder(column: $table.sceneName, builder: (column) => column);

  GeneratedColumn<String> get act =>
      $composableBuilder(column: $table.act, builder: (column) => column);

  GeneratedColumn<String> get location =>
      $composableBuilder(column: $table.location, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<int> get startLineIndex => $composableBuilder(
    column: $table.startLineIndex,
    builder: (column) => column,
  );

  GeneratedColumn<int> get endLineIndex => $composableBuilder(
    column: $table.endLineIndex,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get characters => $composableBuilder(
    column: $table.characters,
    builder: (column) => column,
  );

  $$ProductionsTableAnnotationComposer get productionId {
    final $$ProductionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableAnnotationComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScenesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScenesTable,
          Scene,
          $$ScenesTableFilterComposer,
          $$ScenesTableOrderingComposer,
          $$ScenesTableAnnotationComposer,
          $$ScenesTableCreateCompanionBuilder,
          $$ScenesTableUpdateCompanionBuilder,
          (Scene, $$ScenesTableReferences),
          Scene,
          PrefetchHooks Function({bool productionId})
        > {
  $$ScenesTableTableManager(_$AppDatabase db, $ScenesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScenesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScenesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScenesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productionId = const Value.absent(),
                Value<String> sceneName = const Value.absent(),
                Value<String> act = const Value.absent(),
                Value<String> location = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<int> startLineIndex = const Value.absent(),
                Value<int> endLineIndex = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String> characters = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScenesCompanion(
                id: id,
                productionId: productionId,
                sceneName: sceneName,
                act: act,
                location: location,
                description: description,
                startLineIndex: startLineIndex,
                endLineIndex: endLineIndex,
                sortOrder: sortOrder,
                characters: characters,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productionId,
                required String sceneName,
                Value<String> act = const Value.absent(),
                Value<String> location = const Value.absent(),
                Value<String> description = const Value.absent(),
                required int startLineIndex,
                required int endLineIndex,
                Value<int> sortOrder = const Value.absent(),
                Value<String> characters = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScenesCompanion.insert(
                id: id,
                productionId: productionId,
                sceneName: sceneName,
                act: act,
                location: location,
                description: description,
                startLineIndex: startLineIndex,
                endLineIndex: endLineIndex,
                sortOrder: sortOrder,
                characters: characters,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$ScenesTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({productionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (productionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.productionId,
                                referencedTable: $$ScenesTableReferences
                                    ._productionIdTable(db),
                                referencedColumn: $$ScenesTableReferences
                                    ._productionIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ScenesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScenesTable,
      Scene,
      $$ScenesTableFilterComposer,
      $$ScenesTableOrderingComposer,
      $$ScenesTableAnnotationComposer,
      $$ScenesTableCreateCompanionBuilder,
      $$ScenesTableUpdateCompanionBuilder,
      (Scene, $$ScenesTableReferences),
      Scene,
      PrefetchHooks Function({bool productionId})
    >;
typedef $$RecordingsTableCreateCompanionBuilder =
    RecordingsCompanion Function({
      required String id,
      required String productionId,
      required String scriptLineId,
      required String character,
      required String localPath,
      Value<String?> remoteUrl,
      required int durationMs,
      Value<DateTime> recordedAt,
      Value<int> rowid,
    });
typedef $$RecordingsTableUpdateCompanionBuilder =
    RecordingsCompanion Function({
      Value<String> id,
      Value<String> productionId,
      Value<String> scriptLineId,
      Value<String> character,
      Value<String> localPath,
      Value<String?> remoteUrl,
      Value<int> durationMs,
      Value<DateTime> recordedAt,
      Value<int> rowid,
    });

final class $$RecordingsTableReferences
    extends BaseReferences<_$AppDatabase, $RecordingsTable, Recording> {
  $$RecordingsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ProductionsTable _productionIdTable(_$AppDatabase db) =>
      db.productions.createAlias(
        $_aliasNameGenerator(db.recordings.productionId, db.productions.id),
      );

  $$ProductionsTableProcessedTableManager get productionId {
    final $_column = $_itemColumn<String>('production_id')!;

    final manager = $$ProductionsTableTableManager(
      $_db,
      $_db.productions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_productionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $ScriptLinesTable _scriptLineIdTable(_$AppDatabase db) =>
      db.scriptLines.createAlias(
        $_aliasNameGenerator(db.recordings.scriptLineId, db.scriptLines.id),
      );

  $$ScriptLinesTableProcessedTableManager get scriptLineId {
    final $_column = $_itemColumn<String>('script_line_id')!;

    final manager = $$ScriptLinesTableTableManager(
      $_db,
      $_db.scriptLines,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_scriptLineIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$RecordingsTableFilterComposer
    extends Composer<_$AppDatabase, $RecordingsTable> {
  $$RecordingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get character => $composableBuilder(
    column: $table.character,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteUrl => $composableBuilder(
    column: $table.remoteUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get recordedAt => $composableBuilder(
    column: $table.recordedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$ProductionsTableFilterComposer get productionId {
    final $$ProductionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableFilterComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ScriptLinesTableFilterComposer get scriptLineId {
    final $$ScriptLinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.scriptLineId,
      referencedTable: $db.scriptLines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScriptLinesTableFilterComposer(
            $db: $db,
            $table: $db.scriptLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RecordingsTableOrderingComposer
    extends Composer<_$AppDatabase, $RecordingsTable> {
  $$RecordingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get character => $composableBuilder(
    column: $table.character,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteUrl => $composableBuilder(
    column: $table.remoteUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get recordedAt => $composableBuilder(
    column: $table.recordedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$ProductionsTableOrderingComposer get productionId {
    final $$ProductionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableOrderingComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ScriptLinesTableOrderingComposer get scriptLineId {
    final $$ScriptLinesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.scriptLineId,
      referencedTable: $db.scriptLines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScriptLinesTableOrderingComposer(
            $db: $db,
            $table: $db.scriptLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RecordingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecordingsTable> {
  $$RecordingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get character =>
      $composableBuilder(column: $table.character, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get remoteUrl =>
      $composableBuilder(column: $table.remoteUrl, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get recordedAt => $composableBuilder(
    column: $table.recordedAt,
    builder: (column) => column,
  );

  $$ProductionsTableAnnotationComposer get productionId {
    final $$ProductionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableAnnotationComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ScriptLinesTableAnnotationComposer get scriptLineId {
    final $$ScriptLinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.scriptLineId,
      referencedTable: $db.scriptLines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScriptLinesTableAnnotationComposer(
            $db: $db,
            $table: $db.scriptLines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RecordingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecordingsTable,
          Recording,
          $$RecordingsTableFilterComposer,
          $$RecordingsTableOrderingComposer,
          $$RecordingsTableAnnotationComposer,
          $$RecordingsTableCreateCompanionBuilder,
          $$RecordingsTableUpdateCompanionBuilder,
          (Recording, $$RecordingsTableReferences),
          Recording,
          PrefetchHooks Function({bool productionId, bool scriptLineId})
        > {
  $$RecordingsTableTableManager(_$AppDatabase db, $RecordingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productionId = const Value.absent(),
                Value<String> scriptLineId = const Value.absent(),
                Value<String> character = const Value.absent(),
                Value<String> localPath = const Value.absent(),
                Value<String?> remoteUrl = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<DateTime> recordedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecordingsCompanion(
                id: id,
                productionId: productionId,
                scriptLineId: scriptLineId,
                character: character,
                localPath: localPath,
                remoteUrl: remoteUrl,
                durationMs: durationMs,
                recordedAt: recordedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productionId,
                required String scriptLineId,
                required String character,
                required String localPath,
                Value<String?> remoteUrl = const Value.absent(),
                required int durationMs,
                Value<DateTime> recordedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecordingsCompanion.insert(
                id: id,
                productionId: productionId,
                scriptLineId: scriptLineId,
                character: character,
                localPath: localPath,
                remoteUrl: remoteUrl,
                durationMs: durationMs,
                recordedAt: recordedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RecordingsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({productionId = false, scriptLineId = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (productionId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.productionId,
                                    referencedTable: $$RecordingsTableReferences
                                        ._productionIdTable(db),
                                    referencedColumn:
                                        $$RecordingsTableReferences
                                            ._productionIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (scriptLineId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.scriptLineId,
                                    referencedTable: $$RecordingsTableReferences
                                        ._scriptLineIdTable(db),
                                    referencedColumn:
                                        $$RecordingsTableReferences
                                            ._scriptLineIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [];
                  },
                );
              },
        ),
      );
}

typedef $$RecordingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecordingsTable,
      Recording,
      $$RecordingsTableFilterComposer,
      $$RecordingsTableOrderingComposer,
      $$RecordingsTableAnnotationComposer,
      $$RecordingsTableCreateCompanionBuilder,
      $$RecordingsTableUpdateCompanionBuilder,
      (Recording, $$RecordingsTableReferences),
      Recording,
      PrefetchHooks Function({bool productionId, bool scriptLineId})
    >;
typedef $$CastMembersTableCreateCompanionBuilder =
    CastMembersCompanion Function({
      required String id,
      required String productionId,
      Value<String?> userId,
      required String characterName,
      Value<String> displayName,
      required String role,
      Value<DateTime> invitedAt,
      Value<DateTime?> joinedAt,
      Value<int> rowid,
    });
typedef $$CastMembersTableUpdateCompanionBuilder =
    CastMembersCompanion Function({
      Value<String> id,
      Value<String> productionId,
      Value<String?> userId,
      Value<String> characterName,
      Value<String> displayName,
      Value<String> role,
      Value<DateTime> invitedAt,
      Value<DateTime?> joinedAt,
      Value<int> rowid,
    });

final class $$CastMembersTableReferences
    extends BaseReferences<_$AppDatabase, $CastMembersTable, CastMember> {
  $$CastMembersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ProductionsTable _productionIdTable(_$AppDatabase db) =>
      db.productions.createAlias(
        $_aliasNameGenerator(db.castMembers.productionId, db.productions.id),
      );

  $$ProductionsTableProcessedTableManager get productionId {
    final $_column = $_itemColumn<String>('production_id')!;

    final manager = $$ProductionsTableTableManager(
      $_db,
      $_db.productions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_productionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CastMembersTableFilterComposer
    extends Composer<_$AppDatabase, $CastMembersTable> {
  $$CastMembersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get characterName => $composableBuilder(
    column: $table.characterName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get invitedAt => $composableBuilder(
    column: $table.invitedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get joinedAt => $composableBuilder(
    column: $table.joinedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$ProductionsTableFilterComposer get productionId {
    final $$ProductionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableFilterComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CastMembersTableOrderingComposer
    extends Composer<_$AppDatabase, $CastMembersTable> {
  $$CastMembersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get characterName => $composableBuilder(
    column: $table.characterName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get invitedAt => $composableBuilder(
    column: $table.invitedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get joinedAt => $composableBuilder(
    column: $table.joinedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$ProductionsTableOrderingComposer get productionId {
    final $$ProductionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableOrderingComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CastMembersTableAnnotationComposer
    extends Composer<_$AppDatabase, $CastMembersTable> {
  $$CastMembersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get characterName => $composableBuilder(
    column: $table.characterName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<DateTime> get invitedAt =>
      $composableBuilder(column: $table.invitedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get joinedAt =>
      $composableBuilder(column: $table.joinedAt, builder: (column) => column);

  $$ProductionsTableAnnotationComposer get productionId {
    final $$ProductionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.productionId,
      referencedTable: $db.productions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProductionsTableAnnotationComposer(
            $db: $db,
            $table: $db.productions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CastMembersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CastMembersTable,
          CastMember,
          $$CastMembersTableFilterComposer,
          $$CastMembersTableOrderingComposer,
          $$CastMembersTableAnnotationComposer,
          $$CastMembersTableCreateCompanionBuilder,
          $$CastMembersTableUpdateCompanionBuilder,
          (CastMember, $$CastMembersTableReferences),
          CastMember,
          PrefetchHooks Function({bool productionId})
        > {
  $$CastMembersTableTableManager(_$AppDatabase db, $CastMembersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CastMembersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CastMembersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CastMembersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> productionId = const Value.absent(),
                Value<String?> userId = const Value.absent(),
                Value<String> characterName = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<DateTime> invitedAt = const Value.absent(),
                Value<DateTime?> joinedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CastMembersCompanion(
                id: id,
                productionId: productionId,
                userId: userId,
                characterName: characterName,
                displayName: displayName,
                role: role,
                invitedAt: invitedAt,
                joinedAt: joinedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String productionId,
                Value<String?> userId = const Value.absent(),
                required String characterName,
                Value<String> displayName = const Value.absent(),
                required String role,
                Value<DateTime> invitedAt = const Value.absent(),
                Value<DateTime?> joinedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CastMembersCompanion.insert(
                id: id,
                productionId: productionId,
                userId: userId,
                characterName: characterName,
                displayName: displayName,
                role: role,
                invitedAt: invitedAt,
                joinedAt: joinedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CastMembersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({productionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (productionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.productionId,
                                referencedTable: $$CastMembersTableReferences
                                    ._productionIdTable(db),
                                referencedColumn: $$CastMembersTableReferences
                                    ._productionIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CastMembersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CastMembersTable,
      CastMember,
      $$CastMembersTableFilterComposer,
      $$CastMembersTableOrderingComposer,
      $$CastMembersTableAnnotationComposer,
      $$CastMembersTableCreateCompanionBuilder,
      $$CastMembersTableUpdateCompanionBuilder,
      (CastMember, $$CastMembersTableReferences),
      CastMember,
      PrefetchHooks Function({bool productionId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ProductionsTableTableManager get productions =>
      $$ProductionsTableTableManager(_db, _db.productions);
  $$ScriptLinesTableTableManager get scriptLines =>
      $$ScriptLinesTableTableManager(_db, _db.scriptLines);
  $$ScenesTableTableManager get scenes =>
      $$ScenesTableTableManager(_db, _db.scenes);
  $$RecordingsTableTableManager get recordings =>
      $$RecordingsTableTableManager(_db, _db.recordings);
  $$CastMembersTableTableManager get castMembers =>
      $$CastMembersTableTableManager(_db, _db.castMembers);
}
