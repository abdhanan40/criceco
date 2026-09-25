import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A single selected value (tab, filter chip, search query) kept in Riverpod
/// so it survives branch switches, like the prototype's screen globals.
class SelectionController<T> extends Notifier<T> {
  SelectionController(this._initial);
  final T _initial;

  @override
  T build() => _initial;

  void select(T value) => state = value;
}
