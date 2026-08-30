import 'dart:async';

import 'package:castcircle/data/database/app_database.dart' hide Production;
import 'package:castcircle/data/models/cast_member_model.dart';
import 'package:castcircle/data/models/production_models.dart';
import 'package:castcircle/data/repositories/production_repository.dart';
import 'package:castcircle/providers/production_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ProductionRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = ProductionRepository(database);
    await repository.saveProduction(
      Production(
        id: 'production-1',
        title: 'The Play',
        organizerId: 'organizer-1',
        createdAt: DateTime.utc(2026),
        status: ProductionStatus.castAssigned,
      ),
    );
  });

  tearDown(() => database.close());

  CastMemberModel member(String id, String character) => CastMemberModel(
    id: id,
    productionId: 'production-1',
    characterName: character,
    displayName: 'Actor $character',
    role: CastRole.primary,
    invitedAt: DateTime.utc(2026, 1, 2),
  );

  test(
    'failed bulk invitations survive restart and reconcile without duplicates',
    () async {
      final hamlet = member('stable-hamlet', 'HAMLET');
      final horatio = member('stable-horatio', 'HORATIO');
      await repository.savePendingCastInvitations([hamlet, horatio]);
      await repository.markCastInvitationFailed(
        hamlet.id,
        StateError('retry_pending'),
      );

      // A fresh repository represents provider/app restart over the same Drift DB.
      repository = ProductionRepository(database);
      var pending = await repository.getPendingCastInvitations(
        productionId: 'production-1',
      );
      expect(pending.map((row) => row.localMemberId).toSet(), {
        hamlet.id,
        horatio.id,
      });
      expect(
        pending
            .singleWhere((row) => row.localMemberId == hamlet.id)
            .attemptCount,
        1,
      );

      await repository.reconcileCastInvitation(hamlet.id, hamlet);
      pending = await repository.getPendingCastInvitations(
        productionId: 'production-1',
      );
      expect(pending.map((row) => row.localMemberId), [horatio.id]);

      await repository.reconcileCastInvitation(horatio.id, horatio);
      expect(
        await repository.getPendingCastInvitations(
          productionId: 'production-1',
        ),
        isEmpty,
      );
      final cast = await repository.getCastMembers('production-1');
      expect(cast, hasLength(2));
      expect(cast.map((actor) => actor.id).toSet(), {hamlet.id, horatio.id});
    },
  );

  test('retryAll drains work queued during an active retry pass', () async {
    final hamlet = member('stable-hamlet', 'HAMLET');
    final horatio = member('stable-horatio', 'HORATIO');
    await repository.savePendingCastInvitations([hamlet]);

    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final sent = <String>[];
    final notifier = PendingCastInvitationNotifier(
      repository,
      const Stream.empty(),
      isSignedIn: () => true,
      sendInvitation: (invitation) async {
        if (invitation.localMemberId == hamlet.id &&
            !firstStarted.isCompleted) {
          firstStarted.complete();
          await releaseFirst.future;
        }
        sent.add(invitation.localMemberId);
        final cloudMember = invitation.localMemberId == hamlet.id
            ? hamlet
            : horatio;
        return (
          localMemberId: invitation.localMemberId,
          cloudMember: cloudMember,
        );
      },
    );
    addTearDown(notifier.dispose);

    await firstStarted.future;
    await repository.savePendingCastInvitations([horatio]);
    await notifier.reload();
    final drained = notifier.retryAll();
    releaseFirst.complete();
    await drained;

    expect(sent, [hamlet.id, horatio.id]);
    expect(await repository.getPendingCastInvitations(), isEmpty);
  });
}
