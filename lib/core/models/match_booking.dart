import '../enums/enums.dart';
import 'team.dart';

/// A match from the Club Owner's side (Match Management). Booking details
/// live in [Booking], keyed by the same match id.
class ClubMatch {
  const ClubMatch({
    required this.id,
    required this.opponentClubId,
    required this.status,
    this.format,
    this.customOvers,
    this.city,
    this.groundId,
    this.startsAt,
    this.lineup,
    this.resultText,
  });

  final String id;
  final String opponentClubId;
  final MatchStatus status;
  final MatchFormat? format;
  final int? customOvers;
  final String? city;
  final String? groundId;
  final DateTime? startsAt;
  final Lineup? lineup;
  final String? resultText;

  ClubMatch copyWith({
    MatchStatus? status,
    MatchFormat? format,
    int? customOvers,
    String? city,
    String? groundId,
    DateTime? startsAt,
    Lineup? lineup,
    String? resultText,
    bool clearSchedule = false,
  }) =>
      ClubMatch(
        id: id,
        opponentClubId: opponentClubId,
        status: status ?? this.status,
        format: format ?? this.format,
        customOvers: customOvers ?? this.customOvers,
        city: city ?? this.city,
        groundId: clearSchedule ? null : (groundId ?? this.groundId),
        startsAt: clearSchedule ? null : (startsAt ?? this.startsAt),
        lineup: lineup ?? this.lineup,
        resultText: resultText ?? this.resultText,
      );
}

class GroundSpecs {
  const GroundSpecs({required this.boundary, required this.radius, required this.nets});
  final String boundary;
  final String radius;
  final String nets;
}

class Ground {
  const Ground({
    required this.id,
    required this.name,
    required this.city,
    required this.pricePerHour,
    required this.rating,
    required this.reviews,
    required this.address,
    required this.specs,
    required this.amenities,
  });

  final String id;
  final String name;
  final String city;
  final int pricePerHour; // Rs
  final String rating;
  final int reviews;
  final String address;
  final GroundSpecs specs;
  final List<String> amenities;

  static const matchBlockHours = 2;
  int get matchCost => pricePerHour * matchBlockHours;
}

/// A bookable two-hour slot. Times are wall-clock hours on the booking date.
class TimeSlot {
  const TimeSlot({required this.startHour, required this.endHour, this.startMinute = 0});
  final int startHour;
  final int startMinute;
  final int endHour;

  DateTime startOn(DateTime date) =>
      DateTime(date.year, date.month, date.day, startHour, startMinute);
  DateTime endOn(DateTime date) => DateTime(date.year, date.month, date.day, endHour);

  static String _h(int h) => '${h % 12 == 0 ? 12 : h % 12}${h < 12 ? 'am' : 'pm'}';

  /// "8am – 10am"
  String get label => '${_h(startHour)} – ${_h(endHour)}';

  @override
  bool operator ==(Object other) =>
      other is TimeSlot &&
      other.startHour == startHour &&
      other.startMinute == startMinute &&
      other.endHour == endHour;
  @override
  int get hashCode => Object.hash(startHour, startMinute, endHour);

  /// Prototype `wfSlots` / `availSlotTimes`.
  static const standard = [
    TimeSlot(startHour: 6, endHour: 8),
    TimeSlot(startHour: 8, endHour: 10),
    TimeSlot(startHour: 14, endHour: 16),
    TimeSlot(startHour: 16, endHour: 18),
    TimeSlot(startHour: 18, endHour: 20),
  ];
}

class ReservationHold {
  const ReservationHold({
    required this.id,
    required this.matchId,
    required this.groundId,
    required this.slotStart,
    required this.slotEnd,
    required this.reservedAt,
    required this.expiresAt,
    this.status = HoldStatus.active,
  });

  static const holdDuration = Duration(minutes: 30);

  final String id;
  final String matchId;
  final String groundId;
  final DateTime slotStart;
  final DateTime slotEnd;
  final DateTime reservedAt;
  final DateTime expiresAt;
  final HoldStatus status;

  bool blocksSlot(DateTime now) =>
      status == HoldStatus.confirmed ||
      (status == HoldStatus.active && now.isBefore(expiresAt));

  Duration remaining(DateTime now) {
    final r = expiresAt.difference(now);
    return r.isNegative ? Duration.zero : r;
  }

  ReservationHold copyWith({HoldStatus? status, DateTime? expiresAt}) => ReservationHold(
        id: id,
        matchId: matchId,
        groundId: groundId,
        slotStart: slotStart,
        slotEnd: slotEnd,
        reservedAt: reservedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        status: status ?? this.status,
      );
}

/// Editable booking inputs, Match Setup → Booking Summary.
class BookingDraft {
  const BookingDraft({
    this.format,
    this.customOvers,
    this.city,
    this.groundId,
    this.date,
    this.slot,
  });

  final MatchFormat? format;
  final int? customOvers;
  final String? city;
  final String? groundId;
  final DateTime? date; // local midnight
  final TimeSlot? slot;

  DateTime? get slotStart => (date != null && slot != null) ? slot!.startOn(date!) : null;

  BookingDraft copyWith({
    MatchFormat? format,
    int? customOvers,
    String? city,
    String? groundId,
    DateTime? date,
    TimeSlot? slot,
    bool clearSlot = false,
  }) =>
      BookingDraft(
        format: format ?? this.format,
        customOvers: customOvers ?? this.customOvers,
        city: city ?? this.city,
        groundId: groundId ?? this.groundId,
        date: date ?? this.date,
        slot: clearSlot ? null : (slot ?? this.slot),
      );
}

class PaymentRecord {
  const PaymentRecord({
    required this.method,
    required this.amount,
    required this.status,
    this.at,
  });
  final PaymentMethodType? method; // null for the opponent's payment
  final int amount;
  final PaymentStatus status;
  final DateTime? at;

  PaymentRecord copyWith({PaymentStatus? status, DateTime? at}) => PaymentRecord(
        method: method,
        amount: amount,
        status: status ?? this.status,
        at: at ?? this.at,
      );
}

class Settlement {
  const Settlement({required this.commission, required this.toGround});
  final int commission;
  final int toGround;

  static const commissionRate = 0.05;

  factory Settlement.forCost(int groundCost) {
    final commission = (groundCost * commissionRate).round();
    return Settlement(commission: commission, toGround: groundCost - commission);
  }
}

/// All booking state for one match. Owned by `bookingProvider(matchId)`.
class Booking {
  const Booking({
    required this.matchId,
    required this.opponentClubId,
    this.draft = const BookingDraft(),
    this.hold,
    this.groundCost = 0,
    this.myPayment,
    this.opponentPayment,
    this.settlement,
    this.status = BookingStatus.draft,
  });

  final String matchId;
  final String opponentClubId;
  final BookingDraft draft;
  final ReservationHold? hold;
  final int groundCost;
  final PaymentRecord? myPayment;
  final PaymentRecord? opponentPayment;
  final Settlement? settlement;
  final BookingStatus status;

  int get shareAmount => (groundCost / 2).round();
  bool get myShareSettled => myPayment?.status == PaymentStatus.paid;

  Booking copyWith({
    BookingDraft? draft,
    ReservationHold? hold,
    int? groundCost,
    PaymentRecord? myPayment,
    PaymentRecord? opponentPayment,
    Settlement? settlement,
    BookingStatus? status,
    bool clearHold = false,
    bool clearPayments = false,
  }) =>
      Booking(
        matchId: matchId,
        opponentClubId: opponentClubId,
        draft: draft ?? this.draft,
        hold: clearHold ? null : (hold ?? this.hold),
        groundCost: groundCost ?? this.groundCost,
        myPayment: clearPayments ? null : (myPayment ?? this.myPayment),
        opponentPayment: clearPayments ? null : (opponentPayment ?? this.opponentPayment),
        settlement: settlement ?? this.settlement,
        status: status ?? this.status,
      );
}

class LedgerEntry {
  const LedgerEntry({
    required this.type,
    required this.matchId,
    required this.amount,
    required this.at,
    this.from,
    this.method,
  });
  final LedgerType type;
  final String matchId;
  final int amount;
  final DateTime at;
  final String? from;
  final PaymentMethodType? method;
}
