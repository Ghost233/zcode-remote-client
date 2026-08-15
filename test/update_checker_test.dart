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

  test('按设备 ABI 优先级选 APK', () {
    final rel = AppRelease(
      tagName: 'v1.2.0',
      htmlUrl: 'u',
      notes: '',
      assets: [
        const ReleaseAsset(
          name: 'app-android-arm64-v8a.apk',
          url: 'a',
          size: 1,
        ),
        const ReleaseAsset(
          name: 'app-android-armeabi-v7a.apk',
          url: 'b',
          size: 1,
        ),
        const ReleaseAsset(name: 'app-android-x86_64.apk', url: 'c', size: 1),
        const ReleaseAsset(name: 'app-macos.zip', url: 'd', size: 1),
      ],
    );
    // arm64 设备
    expect(rel.androidApkFor(['arm64-v8a'])?.url, 'a');
    // 32 位设备按第二优先级命中
    expect(rel.androidApkFor(['armeabi-v7a'])?.url, 'b');
    // 模拟器
    expect(rel.androidApkFor(['x86_64', 'armeabi-v7a'])?.url, 'c');
    // 无匹配 → 兜底第一个 apk
    expect(rel.androidApkFor(['riscv64'])?.url, 'a');
    // 无 apk → null
    expect(
      AppRelease(
        tagName: 'v',
        htmlUrl: 'u',
        notes: '',
        assets: const [ReleaseAsset(name: 'x.zip', url: 'z', size: 1)],
      ).androidApkFor(['arm64-v8a']),
      isNull,
    );
  });
}
