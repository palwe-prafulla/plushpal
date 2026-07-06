import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plushpal_ui/src/backend/backend_client.dart';
import 'package:plushpal_ui/src/backend/backend_client_stub.dart';

class _RealHttpOverrides extends HttpOverrides {}

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
          if (call.method == 'stationClientId') {
            return 'android-123e4567-e89b-12d3-a456-426614174000';
          }
          if (call.method == 'stationClientLabel') {
            return 'Pixel test phone';
          }
          if (call.method == 'pickCharacterPhoto') {
            return <String, Object>{
              'bytes': Uint8List.fromList([1, 2, 3]),
              'filename': 'buddy.png',
              'mime': 'image/png',
            };
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

  test(
    'unpaired external client exposes only Hub-required readiness',
    () async {
      final pairing = await client.stationPairingStatus();
      final readiness = await client.localModelReadiness();
      final provider = await client.reasoningProviderStatus();
      final kids = await client.kids();
      final characters = await client.characters();
      final history = await client.history('4826');
      final voice = await client.voiceStatus(characterAlias: 'Buddy');

      expect(pairing.paired, isFalse);
      expect(pairing.baseUrl, isNull);
      expect(readiness.ready, isFalse);
      expect(readiness.installSupported, isFalse);
      expect(readiness.parentConfigured, isFalse);
      expect(readiness.displayName, 'PlushBuddy Hub');
      expect(provider.configured, isFalse);
      expect(provider.displayName, 'PlushBuddy Hub');
      expect(kids, isEmpty);
      expect(characters, isEmpty);
      expect(history, isEmpty);
      expect(voice.enrolled, isFalse);
      expect(backendCalls(), isEmpty);
    },
  );

  test('stale station pairing without Hub ID is treated as unpaired', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'stationPairingStatus') {
            return <String, Object>{
              'paired': true,
              'baseUrl': 'http://192.168.1.50:50076',
              'cookie': 'pp_session=stale',
              'clientId': 'android-123e4567-e89b-12d3-a456-426614174000',
            };
          }
          return null;
        });

    final pairing = await client.stationPairingStatus();
    final readiness = await client.localModelReadiness();

    expect(pairing.paired, isFalse);
    expect(pairing.baseUrl, isNull);
    expect(readiness.displayName, 'PlushBuddy Hub');
    expect(backendCalls(), isEmpty);
  });

  test(
    'stale station session is cleared when current Hub rejects it',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      unawaited(
        server.listen((request) async {
          expect(request.uri.path, '/api/v1/status');
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'message': 'Session expired. Pair again.'}));
          await request.response.close();
        }).asFuture<void>(),
      );
      final baseUrl = 'http://${server.address.host}:${server.port}';
      var pairingCleared = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'stationPairingStatus') {
              if (pairingCleared) return <String, Object>{'paired': false};
              return <String, Object>{
                'paired': true,
                'baseUrl': baseUrl,
                'cookie': 'pp_session=stale',
                'clientId': 'android-123e4567-e89b-12d3-a456-426614174000',
                'hubId': 'hub-123e4567-e89b-12d3-a456-426614174001',
              };
            }
            if (call.method == 'clearStationPairing') {
              pairingCleared = true;
              return null;
            }
            return null;
          });

      late final StationPairingStatus pairing;
      await HttpOverrides.runWithHttpOverrides(() async {
        pairing = await client.stationPairingStatus();
      }, _RealHttpOverrides());

      expect(pairing.paired, isFalse);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder(['stationPairingStatus', 'clearStationPairing']),
      );
    },
  );

  test(
    'transient Hub startup failure keeps existing station pairing',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'stationPairingStatus') {
              return <String, Object>{
                'paired': true,
                'baseUrl': 'http://127.0.0.1:9',
                'cookie': 'pp_session=current',
                'clientId': 'android-123e4567-e89b-12d3-a456-426614174000',
                'hubId': 'hub-123e4567-e89b-12d3-a456-426614174001',
              };
            }
            if (call.method == 'stationClientLabel') {
              return 'Pixel test phone';
            }
            if (call.method == 'clearStationPairing') return null;
            return null;
          });

      late final StationPairingStatus pairing;
      await HttpOverrides.runWithHttpOverrides(() async {
        pairing = await client.stationPairingStatus();
      }, _RealHttpOverrides());

      expect(pairing.paired, isTrue);
      expect(pairing.baseUrl, 'http://127.0.0.1:9');
      expect(
        calls.map((call) => call.method),
        isNot(contains('clearStationPairing')),
      );
    },
  );

  test('paired Hub readiness GET sends Hub origin header', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final baseUrl = 'http://${server.address.host}:${server.port}';
    final observedPaths = <String>[];
    final observedOrigins = <String?>[];
    final observedLabels = <String?>[];
    unawaited(
      server.listen((request) async {
        observedPaths.add(request.uri.path);
        observedOrigins.add(request.headers.value('origin'));
        observedLabels.add(request.headers.value('x-plushbuddy-client-label'));
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'model_id': 'hub',
              'display_name': 'PlushBuddy Hub',
              'model_ready': true,
              'model_install_supported': true,
              'model_installing': false,
              'runtime_mode': 'cloud_llm',
              'parent_configured': true,
              'age_band': '4-5',
              'character_alias': 'Buddy',
              'character_traits': ['gentle'],
              'retention_days': null,
            }),
          );
        await request.response.close();
      }).asFuture<void>(),
    );
    await Future<void>.delayed(Duration.zero);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'stationPairingStatus') {
            return <String, Object>{
              'paired': true,
              'baseUrl': baseUrl,
              'cookie': 'pp_session=current',
              'clientId': 'android-123e4567-e89b-12d3-a456-426614174000',
              'hubId': 'hub-123e4567-e89b-12d3-a456-426614174001',
            };
          }
          if (call.method == 'stationClientLabel') {
            return 'Pixel test phone';
          }
          return null;
        });

    late final StationPairingStatus pairing;
    late final LocalModelReadiness readiness;
    await HttpOverrides.runWithHttpOverrides(() async {
      try {
        pairing = await client.stationPairingStatus();
        readiness = await client.localModelReadiness();
      } catch (error) {
        fail(
          'Hub readiness request failed: $error; '
          'paths=$observedPaths origins=$observedOrigins baseUrl=$baseUrl',
        );
      }
    }, _RealHttpOverrides());

    expect(pairing.paired, isTrue);
    expect(readiness.ready, isTrue);
    expect(observedPaths, isNotEmpty);
    expect(observedPaths.every((path) => path == '/api/v1/status'), isTrue);
    expect(observedOrigins, isNotEmpty);
    expect(observedOrigins.every((origin) => origin == baseUrl), isTrue);
    expect(observedLabels, isNotEmpty);
    expect(
      observedLabels.every((label) => label == 'Pixel test phone'),
      isTrue,
    );
    expect(
      calls.map((call) => call.method),
      isNot(contains('clearStationPairing')),
    );
  });

  test('unpaired family, voice, and conversation writes require Hub', () async {
    expect(
      () => client.beginLocalTurn(
        ageBand: '6-8',
        characterAlias: 'Buddy',
        text: 'Hello',
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => client.configureGeminiApiKey('gemini-test-fixture-key'),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => client.configureParentPin(
        pin: '4826',
        ageBand: '6-8',
        characterAlias: 'Buddy',
        characterTraits: const ['gentle'],
        parentGuidance: null,
        retentionDays: 1,
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => client.saveKid(
        pin: '4826',
        kidId: 'kid-1',
        name: 'Test kid',
        birthdateIso: '2021-01-01',
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => client.saveCharacter(
        pin: '4826',
        characterAlias: 'Buddy',
        characterTraits: const ['gentle'],
        parentGuidance: null,
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => client.enrollVoiceSample(
        pin: '4826',
        adultAuthorized: true,
        characterAlias: 'Buddy',
        wavBytes: Uint8List.fromList([1, 2, 3]),
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => client.speakWithVoice('Hello', characterAlias: 'Buddy'),
      throwsA(isA<UnsupportedError>()),
    );
    expect(backendCalls(), isEmpty);
  });

  test('local-only platform helpers remain available to UI shell', () async {
    final picked = await client.pickCharacterPhoto();
    await client.cancelTurn();
    await client.endSession();
    await client.cancelModelInstall();

    expect(picked.filename, 'buddy.png');
    expect(picked.bytes, Uint8List.fromList([1, 2, 3]));
    expect(backendCalls().map((call) => call.method), ['pickCharacterPhoto']);
  });
}
