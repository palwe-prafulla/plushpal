import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plushpal_ui/src/backend/backend_client_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.plushpal/test-backend');
  const client = MethodChannelBackendClient(channel: channel);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'stationPairingStatus') {
            return <String, Object>{'paired': false};
          }
          if (call.method == 'generateLocal') {
            return <String, Object>{
              'speech': 'Hello from native core.',
              'suggestTrustedAdult': false,
            };
          }
          if (call.method == 'modelStatus') {
            return <String, Object>{
              'modelId': 'fixture-model',
              'displayName': 'Fixture model',
              'ready': true,
              'installSupported': true,
              'installing': false,
            };
          }
          if (call.method == 'authorizeParentPin') return true;
          if (call.method == 'voiceStatus') {
            return <String, Object>{
              'enrolled': true,
              'approved': true,
              'runtimeReady': true,
              'durationMilliseconds': 20000,
            };
          }
          if (call.method == 'history') {
            return <Map<String, Object>>[
              {
                'childText': 'Why is the sky blue?',
                'characterText': 'Blue light scatters.',
                'completedAt': 100,
              },
            ];
          }
          return null;
        });
  });

  Iterable<MethodCall> backendCalls() =>
      calls.where((call) => call.method != 'stationPairingStatus');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('mobile conversation sends only bounded turn fields', () async {
    final response = await client.beginLocalTurn(
      ageBand: '6-8',
      characterAlias: 'Teddy',
      text: 'Hello',
    );
    expect(response.speech, 'Hello from native core.');
    expect(backendCalls().single.arguments, {
      'ageBand': '6-8',
      'characterAlias': 'Teddy',
      'text': 'Hello',
      'kidId': null,
      'kidName': null,
      'childAgeYears': null,
      'childAgeMonths': null,
      'characterPlayAgeYears': null,
    });
  });

  test('cancel is delegated to native core', () async {
    await client.cancelTurn();
    expect(backendCalls().single.method, 'cancelTurn');
  });

  test('model readiness comes from the native host', () async {
    final status = await client.localModelReadiness();
    expect(status.ready, isTrue);
    expect(status.modelId, 'fixture-model');
    expect(status.installSupported, isTrue);
    expect(backendCalls().single.method, 'modelStatus');
  });

  test('Gemini key is delegated to encrypted native storage', () async {
    await client.configureGeminiApiKey('gemini-test-fixture-key');
    expect(backendCalls().single.method, 'saveProviderApiKey');
    expect(backendCalls().single.arguments, {
      'provider': 'gemini',
      'apiKey': 'gemini-test-fixture-key',
    });
  });

  test('session cleanup is delegated to native core', () async {
    await client.endSession();
    expect(backendCalls().single.method, 'endSession');
  });

  test('model install and cancellation are delegated to native core', () async {
    await client.installLocalModel();
    await client.cancelModelInstall();
    expect(backendCalls().map((call) => call.method), [
      'installLocalModel',
      'cancelModelInstall',
    ]);
  });

  test('parent PIN never enters ordinary backend state', () async {
    await client.configureParentPin(
      pin: '4826',
      ageBand: '6-8',
      characterAlias: 'Teddy',
      characterTraits: const ['gentle'],
      parentGuidance: 'Likes science.',
      retentionDays: 7,
    );
    expect(await client.authorizeParentPin('4826'), isTrue);
    expect(backendCalls().map((call) => call.method), [
      'configureParentPin',
      'authorizeParentPin',
    ]);
    expect(backendCalls().first.arguments, {
      'pin': '4826',
      'ageBand': '6-8',
      'characterAlias': 'Teddy',
      'characterTraits': ['gentle'],
      'parentGuidance': 'Likes science.',
      'retentionDays': 7,
      'kidId': null,
    });
  });

  test('local data deletion is delegated with parent authorization', () async {
    await client.deleteAllLocalData('4826');
    expect(backendCalls().single.method, 'deleteAllLocalData');
    expect(backendCalls().single.arguments, {'pin': '4826'});
  });

  test(
    'history review and deletion remain behind native parent boundary',
    () async {
      final history = await client.history('4826');
      expect(history.single.childText, 'Why is the sky blue?');
      await client.deleteHistory('4826');
      expect(backendCalls().map((call) => call.method), [
        'history',
        'deleteHistory',
      ]);
    },
  );

  test('voice lifecycle is delegated across the native boundary', () async {
    final status = await client.voiceStatus();
    expect(status.enrolled, isTrue);
    expect(status.approved, isTrue);
    expect(status.runtimeReady, isTrue);
    expect(status.durationMilliseconds, 20000);

    await client.enrollVoiceSample(
      pin: '4826',
      adultAuthorized: true,
      characterAlias: 'Buddy',
      wavBytes: Uint8List.fromList([1, 2, 3]),
    );
    await client.previewVoice('4826', characterAlias: 'Buddy');
    await client.approveVoice('4826', characterAlias: 'Buddy');
    await client.speakWithVoice('Hello from Teddy.', characterAlias: 'Buddy');
    await client.deleteVoice('4826', characterAlias: 'Buddy');

    expect(backendCalls().map((call) => call.method), [
      'voiceStatus',
      'enrollVoice',
      'previewVoice',
      'approveVoice',
      'speakWithVoice',
      'deleteVoice',
    ]);
    final delegated = backendCalls().toList();
    expect(delegated[1].arguments['pin'], '4826');
    expect(delegated[1].arguments['adultAuthorized'], isTrue);
    expect(delegated[1].arguments['characterAlias'], 'Buddy');
    expect((delegated[1].arguments['wavBytes'] as Uint8List).toList(), [
      1,
      2,
      3,
    ]);
    expect(delegated[4].arguments, {
      'text': 'Hello from Teddy.',
      'characterAlias': 'Buddy',
    });
  });
}
