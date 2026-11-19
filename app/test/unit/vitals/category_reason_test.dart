import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/features/vitals/presentation/bp_widgets.dart';

// D-121: say which number set the AHA category when the two numbers disagree.
void main() {
  test('120/80 is Stage 1 because of the bottom number', () {
    final r = categoryReason(120, 80)!;
    expect(r, contains('bottom number (80)'));
    expect(r, contains('High — Stage 1'));
  });

  test('a high top number with a normal bottom number', () {
    expect(categoryReason(145, 75), contains('top number (145)'));
  });

  test('nothing to explain when both numbers agree or the reading is normal', () {
    expect(categoryReason(135, 85), isNull); // both Stage 1
    expect(categoryReason(115, 75), isNull); // normal
    expect(categoryReason(125, 75), isNull); // elevated by systolic only, as the label says
  });

  test('D-122 the heart rate says where it came from', () {
    expect(heartRateSourceLabel(HeartRateSource.camera), 'Camera estimate');
    expect(heartRateSourceLabel(HeartRateSource.manual), 'Entered by you');
    expect(heartRateSourceLabel(null), isNull); // older readings
    expect(HeartRateSource.tryValue('camera'), HeartRateSource.camera);
    expect(HeartRateSource.tryValue('watch'), isNull);
  });
}
