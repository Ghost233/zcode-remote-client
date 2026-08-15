import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_remote_client/services/update_checker.dart';

void main() {
  group('UpdateChecker.isNewer', () {
    test('常规语义化版本比较', () {
      expect(UpdateChecker.isNewer('1.1.0', '1.0.0'), isTrue);
      expect(UpdateChecker.isNewer('1.0.1', '1.0.0'), isTrue);
      expect(UpdateChecker.isNewer('2.0.0', '1.9.9'), isTrue);
      expect(UpdateChecker.isNewer('1.0.0', '1.0.0'), isFalse);
      expect(UpdateChecker.isNewer('1.0.0', '1.1.0'), isFalse);
    });

    test('容忍 v 前缀、build 号与缺失位', () {
      expect(UpdateChecker.isNewer('v1.1.0', '1.0.0'), isTrue);
      expect(UpdateChecker.isNewer('1.1.0+3', '1.0.0+2'), isTrue);
      expect(UpdateChecker.isNewer('1.2', '1.1.9'), isTrue);
      expect(UpdateChecker.isNewer('1.0', '1.0.0'), isFalse);
    });

    test('解析异常输入不抛错', () {
      expect(UpdateChecker.isNewer('', '1.0.0'), isFalse);
      expect(UpdateChecker.isNewer('x.y.z', '1.0.0'), isFalse);
    });
  });
}
