import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plushpal_ui/src/platform/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.plushpal/test-platform');
  const bridge = MethodChannelPlatformBridge(channel: channel);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'deviceProfile' => <String, Object>{
              'platform': 'test',
              'memoryBytes': 8 * 1024 * 1024 * 1024,
              'logicalProcessors': 8,
            },
            'storeSecret' => 'opaque-reference',
            'listen' => 'hello teddy',
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'device profile and speech use the versioned platform boundary',
    () async {
      final profile = await bridge.deviceProfile();
      expect(profile.platform, 'test');
      expect(profile.logicalProcessors, 8);
      expect(await bridge.listen(), 'hello teddy');
      await bridge.speak('hello');
      await bridge.cancelSpeech();
      expect(calls.map((call) => call.method), [
        'deviceProfile',
        'listen',
        'speak',
        'cancelSpeech',
      ]);
    },
  );

  test(
    'secret value is sent once and only opaque reference is returned',
    () async {
      expect(
        await bridge.storeSecret('openai', 'secret-value'),
        'opaque-reference',
      );
      expect(calls.single.arguments, {
        'label': 'openai',
        'value': 'secret-value',
      });
      await bridge.deleteSecret('opaque-reference');
      expect(calls.last.arguments, {'reference': 'opaque-reference'});
    },
  );

  test('empty secrets fail before crossing the native bridge', () async {
    await expectLater(
      bridge.storeSecret('openai', ''),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, isEmpty);
  });
}
