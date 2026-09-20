import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_trade_frontend/features/debug/debug_console_cubit.dart';

/// Every fault button must name a field the backend decodes.
///
/// The console once addressed one path per fault (`…/faults/book-gap`), which the
/// backend has never served — it takes one faults endpoint with the knobs in a JSON
/// body — so all six buttons answered 404 and fault injection was undemonstrable. The
/// field names below are the ones in the backend's `faultRequest`; a rename on either
/// side has to break this test rather than a demo.
void main() {
  test('every fault maps onto a backend knob, and every fault is covered', () {
    expect(faultBodyFor(DebugFault.bookGap), <String, Object?>{
      'skipBookDeltas': bookGapSkipCount,
    });
    expect(faultBodyFor(DebugFault.duplicateDelta), <String, Object?>{
      'duplicateDelta': true,
    });
    expect(faultBodyFor(DebugFault.outOfOrderDelta), <String, Object?>{
      'reverseDeltas': true,
    });
    expect(faultBodyFor(DebugFault.malformed), <String, Object?>{
      'malformedFrames': malformedFrameCount,
    });
    expect(faultBodyFor(DebugFault.staleSnapshot), <String, Object?>{
      'holdWritesMs': staleSnapshotHoldMs,
    });
    expect(faultBodyFor(DebugFault.intervalMismatch), <String, Object?>{
      'skipCandleClosed': true,
    });

    // A new fault without a body would send `{}`, which the backend accepts as "no
    // fault" — a button that silently does nothing, so it is an explicit failure here.
    for (final DebugFault fault in DebugFault.values) {
      expect(
        faultBodyFor(fault),
        isNotEmpty,
        reason: '${fault.label} must name at least one knob',
      );
    }
  });

  test('the knobs are sized to be unmistakable and self-recovering', () {
    // A gap of one delta would be indistinguishable from a normal update, and a hold
    // longer than the client's staleness window would outlast the session's patience.
    expect(bookGapSkipCount, greaterThan(1));
    expect(staleSnapshotHoldMs, greaterThan(1000));
    expect(staleSnapshotHoldMs, lessThan(10000));
  });
}
