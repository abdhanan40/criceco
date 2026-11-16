import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/providers/core_providers.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// A join request that can't be sent; [message] says why (shown inline).
class JoinBlockedException implements Exception {
  const JoinBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Outgoing join-by-code request (membership onboarding). Kept separate from
/// club setup so a Player-side entry can reuse it later (approved decision 14).
class JoinClubController extends Notifier<ClubJoinRequest?> {
  @override
  ClubJoinRequest? build() {
    final accountId = ref.watch(sessionProvider.select((s) => s.account?.id)); // reset on logout
    // Stored requests: load the database's latest one right away, so the
    // join screens and their rules (one pending request) reflect it after a
    // restart too. A failure leaves `null`; the screens refresh again.
    if (accountId != null && _stored) {
      Future.microtask(() async {
        try {
          await refresh();
        } catch (_) {
          // Offline or signed out meanwhile: nothing to show yet.
        }
      });
    }
    return null;
  }

  /// The club behind [code] (Join Club sheet preview), or `null` if unknown.
  Future<ClubCodePreview?> lookup(String code) => ref.read(clubRepositoryProvider).findClubByCode(code);

  /// Why a request for [code] can't be sent, or `null` when it can: a
  /// request is already pending, the code is unknown, the player is already a
  /// member, or it's their own club. Shared by the Join a Club sheet and screen.
  Future<String?> blockReason(String code) async {
    final pending = state;
    if (pending != null && pending.status == JoinRequestStatus.pending) {
      return 'You already have a pending request to ${pending.clubName}.';
    }
    final club = await lookup(code);
    if (club == null) return 'No club found with code ${code.trim().toUpperCase()}. Check the code and try again.';
    final upper = club.code.toUpperCase();
    final account = ref.read(currentAccountProvider);
    if (account?.memberships.any((m) => m.clubCode.toUpperCase() == upper) ?? false) {
      return 'You’re already a member of ${club.name}.';
    }
    if (ref.read(currentClubProvider)?.code.toUpperCase() == upper) return 'You own ${club.name} — no request needed.';
    return null;
  }

  /// Sends the request; throws [JoinBlockedException] when [blockReason]
  /// says it can't be sent (the same rules as the screens).
  Future<ClubJoinRequest> send(String code) async {
    final reason = await blockReason(code);
    if (reason != null) throw JoinBlockedException(reason);
    final request = await ref.read(clubRepositoryProvider).requestToJoin(code);
    state = request;
    return request;
  }

  /// Stored requests (Supabase with the memberships switch, migration 11):
  /// the database decides and remembers; the demo keeps the run's request.
  bool get _stored {
    final modules = ref.read(backendModulesProvider);
    return !modules.isDemo && modules.has(BackendModule.memberships);
  }

  /// Withdraws a pending request (stored: in the database first — if that
  /// fails, the request stays and the error is thrown). A decided request is
  /// only cleared from the screen.
  Future<void> cancel() async {
    final request = state;
    if (_stored && request != null && request.status == JoinRequestStatus.pending) {
      await ref.read(clubRepositoryProvider).cancelJoinRequest(request);
    }
    state = null;
  }

  /// Stored requests: re-reads the latest one (pending or decided) from the
  /// database. Approved → the session's memberships are re-read too. The
  /// demo answers with what it has (approval is simulated there).
  Future<ClubJoinRequest?> refresh() async {
    if (!_stored) return state;
    final latest = await ref.read(clubRepositoryProvider).myJoinRequest();
    if (!ref.mounted) return latest; // signed out / disposed meanwhile
    state = latest;
    if (latest?.status == JoinRequestStatus.approved) {
      await ref.read(sessionProvider.notifier).refreshMemberships();
    }
    return latest;
  }

  /// Owner approval (arrives from the owner side; simulated in Demo Mode).
  /// Adds a club membership only — never the account-level Club Owner role.
  Future<void> approve(MemberRole role) async {
    final request = state;
    if (request == null) return;
    await ref.read(sessionProvider.notifier).addMembership(ClubMembership(
          clubId: 'club_${request.clubCode.toLowerCase()}',
          clubName: request.clubName,
          clubCode: request.clubCode,
          role: role,
        ));
    state = request.copyWith(status: JoinRequestStatus.approved, approvedRole: role);
  }

  /// "Continue to Dashboard" after approval: the Player context.
  void enterPlayerContext() => ref.read(roleControllerProvider.notifier).enterPlayerContext();
}

final joinClubProvider = NotifierProvider<JoinClubController, ClubJoinRequest?>(JoinClubController.new);

/// A club's public details by code (Club sheet: the club a player joined).
final clubPreviewProvider = FutureProvider.family<ClubCodePreview?, String>(
  (ref, code) => ref.read(clubRepositoryProvider).findClubByCode(code),
);
