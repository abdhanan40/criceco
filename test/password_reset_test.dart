import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final _now = DateTime(2026, 10, 5, 9);
const _phone = '0312-9020000'; // the seed account (stored as "0312 9020000")

Future<(ProviderContainer, TestClock)> _container() async {
  final clock = TestClock(_now);
  return (await makeContainer(clock: clock), clock);
}

SessionController _s(ProviderContainer c) => c.read(sessionProvider.notifier);

void main() {
  group('Forgot password', () {
    test('no account for the phone number or email → no code', () async {
      final (c, _) = await _container();
      expect(await _s(c).requestPasswordReset('0300-1112223'), isNull);
      expect(await _s(c).requestPasswordReset('nobody@example.com'), isNull);
      expect(await _s(c).requestPasswordReset('not a number'), isNull);
    });

    test('a code goes to the account (any phone format), masked, valid for 10 minutes', () async {
      final (c, _) = await _container();
      for (final format in [_phone, '03129020000', '+92 312 9020000']) {
        final t = (await _s(c).requestPasswordReset(format))!;
        expect(t.destination, '0312 ••••• 00');
        expect(t.expiresAt, _now.add(InMemoryAccountRepository.resetCodeLifetime));
        expect(t.demoCode, matches(RegExp(r'^\d{6}$')));
      }
    });

    test('reset: wrong code refused; right code sets the password; only the new one signs in', () async {
      final (c, _) = await _container();
      // Before: the demo account signs in (prototype parity).
      expect(await _s(c).signIn(identifier: _phone, password: 'old-pass'), isTrue);
      _s(c).logout();

      final code = (await _s(c).requestPasswordReset(_phone))!.demoCode!;
      final wrong = code == '000000' ? '111111' : '000000';
      expect(await _s(c).verifyResetCode(_phone, wrong), ResetCodeCheck.wrong);
      expect(await _s(c).verifyResetCode(_phone, code), ResetCodeCheck.ok);
      expect(await _s(c).resetPassword(_phone, code, 'Brand-New1'), ResetCodeCheck.ok);

      expect(await _s(c).signIn(identifier: _phone, password: 'old-pass'), isFalse);
      expect(await _s(c).signIn(identifier: _phone, password: 'Brand-New1'), isTrue);
      expect(c.read(sessionProvider).account!.settings.passwordChangedAt, _now, reason: 'shown in Password & security');
      // The code is used up.
      expect(await _s(c).resetPassword(_phone, code, 'Again@123'), ResetCodeCheck.noRequest);
    });

    test('codes expire after 10 minutes; a new request replaces the old code', () async {
      final (c, clock) = await _container();
      final first = (await _s(c).requestPasswordReset(_phone))!.demoCode!;
      clock.advance(const Duration(minutes: 10));
      expect(await _s(c).verifyResetCode(_phone, first), ResetCodeCheck.expired);
      expect(await _s(c).resetPassword(_phone, first, 'Secret@99'), ResetCodeCheck.expired);

      final second = (await _s(c).requestPasswordReset(_phone))!.demoCode!;
      if (second != first) {
        expect(await _s(c).verifyResetCode(_phone, first), ResetCodeCheck.wrong, reason: 'old code replaced');
      }
      expect(await _s(c).verifyResetCode(_phone, second), ResetCodeCheck.ok);
    });

    test('five wrong codes lock the code until a new one is sent', () async {
      final (c, _) = await _container();
      final code = (await _s(c).requestPasswordReset(_phone))!.demoCode!;
      final wrong = code == '000000' ? '111111' : '000000';
      final results = [for (var i = 0; i < InMemoryAccountRepository.resetMaxAttempts; i++) await _s(c).verifyResetCode(_phone, wrong)];
      expect(results.last, ResetCodeCheck.tooManyAttempts);
      expect(results.take(results.length - 1), everyElement(ResetCodeCheck.wrong));
      expect(await _s(c).verifyResetCode(_phone, code), ResetCodeCheck.tooManyAttempts, reason: 'even the right code');
      final fresh = (await _s(c).requestPasswordReset(_phone))!.demoCode!;
      expect(await _s(c).verifyResetCode(_phone, fresh), ResetCodeCheck.ok);
    });

    test('an account created with an email resets by email', () async {
      final (c, _) = await _container();
      await _s(c).signUp(fullName: '', method: ContactMethod.email, identifier: 'Hamza@Example.com', password: 'First@123');
      _s(c).logout();
      final t = (await _s(c).requestPasswordReset('hamza@example.com'))!;
      expect(t.destination, 'h•••@example.com');
      expect(await _s(c).resetPassword('HAMZA@example.com', t.demoCode!, 'Second@22'), ResetCodeCheck.ok);
      expect(await _s(c).signIn(identifier: 'x', password: 'First@123'), isFalse);
      expect(await _s(c).signIn(identifier: 'x', password: 'Second@22'), isTrue);
    });
  });
}
