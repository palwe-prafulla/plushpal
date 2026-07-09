import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toytalk_ui/src/app.dart';
import 'package:toytalk_ui/src/backend/backend_client.dart';
import 'package:toytalk_ui/src/platform/platform_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtureWav = <int>[
  82,
  73,
  70,
  70,
  36,
  0,
  0,
  0,
  87,
  65,
  86,
  69,
  102,
  109,
  116,
  32,
  16,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  128,
  62,
  0,
  0,
  0,
  125,
  0,
  0,
  2,
  0,
  16,
  0,
  100,
  97,
  116,
  97,
  0,
  0,
  0,
  0,
];

class FakeBackend implements BackendClient {
  FakeBackend({
    this.modelReady = true,
    this.parentConfigured = true,
    this.restoredAgeBand,
    this.restoredCharacterAlias,
    this.restoredTraits = const [],
    this.restoredGuidance,
    this.restoredRetentionDays,
    this.runtimeMode = 'cloud_llm',
    this.seedFixtureKid = true,
  }) : configuredPin = parentConfigured ? '4826' : null,
       configuredCharacterAlias = restoredCharacterAlias ?? 'Teddy',
       configuredTraits = restoredTraits;

  bool modelReady;
  final bool parentConfigured;
  final String? restoredAgeBand;
  final String? restoredCharacterAlias;
  final List<String> restoredTraits;
  final String? restoredGuidance;
  final int? restoredRetentionDays;
  final String runtimeMode;
  final bool seedFixtureKid;
  String? receivedText;
  bool sessionEnded = false;
  bool localDataDeleted = false;
  final savedHistory = <ConversationHistoryEntry>[];
  bool voiceEnrolled = true;
  bool voiceApproved = true;
  bool voiceRuntimeReady = true;
  bool webSearchEnabled = false;
  bool? lastWebSearchEnabled;
  String? clonedSpeech;
  Completer<void>? enrollCompleter;
  Completer<void>? previewCompleter;
  Completer<void>? synthesizeCompleter;
  int enrollVoiceCalls = 0;
  int previewVoiceCalls = 0;
  String? lastEnrolledAlias;
  String? lastPreviewedAlias;
  String? lastApprovedAlias;
  String? lastDeletedVoiceAlias;
  int? receivedCharacterPlayAgeYears;
  bool stationPaired = true;
  String? stationBaseUrl = 'http://127.0.0.1:3210';
  final savedKids = <KidProfile>[];
  final additionalCharacters = <CharacterConfiguration>[];
  final characterVoices = <String, VoiceProfileStatus>{};
  String sttTranscript = 'Fallback transcript from Hub';
  Uint8List? transcribedWavBytes;

  @override
  Future<StationPairingStatus> stationPairingStatus() async =>
      StationPairingStatus(paired: stationPaired, baseUrl: stationBaseUrl);

  @override
  Future<void> pairStation(String pairingUrl) async {
    stationPaired = true;
    stationBaseUrl = 'http://192.168.1.50:3210';
  }

  @override
  Future<void> clearStationPairing() async {
    stationPaired = false;
    stationBaseUrl = null;
  }

  @override
  Future<List<PairedClientInfo>> pairedClients(String pin) async {
    if (configuredPin != null && pin != configuredPin) {
      throw StateError('unauthorized');
    }
    return const [
      PairedClientInfo(
        clientId: 'android-123e4567-e89b-12d3-a456-426614174000',
        platform: 'Android',
        label: 'Google Pixel Test',
        createdAt: 100,
        lastSeenAt: 200,
        lastSeenIp: '192.168.1.42',
      ),
    ];
  }

  @override
  Future<void> revokePairedClient({
    required String pin,
    required String clientId,
  }) async {
    if (configuredPin != null && pin != configuredPin) {
      throw StateError('unauthorized');
    }
  }

  @override
  Future<ReasoningProviderStatus> reasoningProviderStatus() async =>
      ReasoningProviderStatus(
        provider: 'gemini',
        configured: modelReady,
        displayName: 'Gemini',
        webSearchEnabled: webSearchEnabled,
      );

  @override
  Future<void> configureApiKey({
    required String pin,
    required String provider,
    required String apiKey,
  }) async {
    modelReady = true;
  }

  @override
  Future<void> configureGeminiApiKey(String apiKey) async {
    modelReady = true;
  }

  @override
  Future<void> setWebSearchEnabled({
    required String pin,
    required bool enabled,
  }) async {
    if (configuredPin != null && pin != configuredPin) {
      throw StateError('unauthorized');
    }
    webSearchEnabled = enabled;
    lastWebSearchEnabled = enabled;
  }

  @override
  Future<List<KidProfile>> kids() async => savedKids.isEmpty && seedFixtureKid
      ? [
          const KidProfile(
            id: 'kid-fixture',
            name: 'Inaaya',
            birthdateIso: '2021-01-01',
          ),
        ]
      : List.of(savedKids);

  @override
  Future<void> saveKid({
    required String pin,
    required String? kidId,
    required String name,
    required String birthdateIso,
    Uint8List? photoBytes,
    String? photoMime,
  }) async {
    if (configuredPin == null || pin != configuredPin) {
      throw StateError('unauthorized');
    }
    savedKids.removeWhere((kid) => kid.id == (kidId ?? 'kid-fixture'));
    savedKids.add(
      KidProfile(
        id: kidId ?? 'kid-fixture',
        name: name,
        birthdateIso: birthdateIso,
        photoBytes: photoBytes,
        photoMime: photoMime,
      ),
    );
  }

  @override
  Future<void> deleteKid({required String pin, required String kidId}) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    savedKids.removeWhere((kid) => kid.id == kidId);
  }

  @override
  Future<BackendResponse> beginLocalTurn({
    required String ageBand,
    required String characterAlias,
    required String text,
    String? kidId,
    String? kidName,
    int? childAgeYears,
    int? childAgeMonths,
    int? characterPlayAgeYears,
  }) async {
    receivedText = text;
    receivedCharacterPlayAgeYears = characterPlayAgeYears;
    return const BackendResponse(
      speech: 'Blue light scatters more in the sky.',
      suggestTrustedAdult: false,
    );
  }

  @override
  Future<String> transcribeSpeech(Uint8List wavBytes) async {
    transcribedWavBytes = wavBytes;
    return sttTranscript;
  }

  @override
  Future<void> cancelTurn() async {}

  @override
  Future<void> endSession() async => sessionEnded = true;

  @override
  Future<void> installLocalModel() async => modelReady = true;

  @override
  Future<void> cancelModelInstall() async {}

  String? configuredPin;
  String configuredCharacterAlias;
  List<String> configuredTraits;
  String? configuredGuidance;
  int? configuredPersonaAgeYears;
  int? configuredRetentionDays;
  int configureParentPinCalls = 0;

  @override
  Future<void> configureParentPin({
    required String pin,
    required String ageBand,
    required String characterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    required int? retentionDays,
    String? kidId,
  }) async {
    if (configuredPin != null && configuredPin != pin) {
      throw StateError('unauthorized');
    }
    configureParentPinCalls += 1;
    configuredPin = pin;
    configuredCharacterAlias = characterAlias;
    configuredTraits = List.of(characterTraits);
    configuredGuidance = parentGuidance;
    configuredRetentionDays = retentionDays;
  }

  @override
  Future<bool> authorizeParentPin(String pin) async => pin == configuredPin;

  @override
  Future<void> deleteAllLocalData(String pin) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    configuredPin = null;
    localDataDeleted = true;
  }

  @override
  Future<HubBackup> exportBackup(String pin) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    return const HubBackup(
      backupBase64: 'encrypted-widget-backup',
      exportedAt: 1234,
    );
  }

  @override
  Future<void> importBackup({
    required String pin,
    required String backupBase64,
  }) async {
    if (pin != configuredPin || backupBase64.isEmpty) {
      throw StateError('unauthorized');
    }
  }

  @override
  Future<List<ConversationHistoryEntry>> history(String pin) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    return List.of(savedHistory);
  }

  @override
  Future<List<ConversationHistoryEntry>> scopedHistory(
    String pin, {
    String? kidId,
    String? characterAlias,
  }) => history(pin);

  @override
  Future<void> deleteHistory(String pin) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    savedHistory.clear();
  }

  @override
  Future<List<CharacterConfiguration>> characters() async => [
    CharacterConfiguration(
      alias: configuredCharacterAlias,
      traits: configuredTraits,
      parentGuidance: configuredGuidance,
      voice: await voiceStatus(characterAlias: configuredCharacterAlias),
      personaAgeYears: configuredPersonaAgeYears,
      kidId: 'kid-fixture',
    ),
    ...additionalCharacters,
  ];

  @override
  Future<void> saveCharacter({
    required String pin,
    required String characterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    String? kidId,
    int? personaAgeYears,
  }) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    configuredCharacterAlias = characterAlias;
    configuredTraits = List.of(characterTraits);
    configuredGuidance = parentGuidance;
    configuredPersonaAgeYears = personaAgeYears;
  }

  @override
  Future<void> renameCharacter({
    required String pin,
    required String currentCharacterAlias,
    required String newCharacterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    String? kidId,
    int? personaAgeYears,
  }) async {
    if (pin != configuredPin) {
      throw StateError('unauthorized');
    }
    final voice = characterVoices.remove(currentCharacterAlias);
    if (voice != null) {
      characterVoices[newCharacterAlias] = voice;
    }
    configuredCharacterAlias = newCharacterAlias;
    configuredTraits = List.of(characterTraits);
    configuredGuidance = parentGuidance;
    configuredPersonaAgeYears = personaAgeYears;
  }

  @override
  Future<PickedCharacterPhoto> pickCharacterPhoto() async =>
      PickedCharacterPhoto(
        bytes: Uint8List.fromList(const [1, 2, 3]),
        filename: 'toy.png',
        mime: 'image/png',
      );

  @override
  Future<void> saveCharacterPhoto({
    required String pin,
    required String characterAlias,
    required Uint8List photoBytes,
    required String? photoMime,
  }) async {
    if (pin != configuredPin) throw StateError('unauthorized');
  }

  @override
  Future<void> deleteCharacter({
    required String pin,
    required String characterAlias,
    String? kidId,
  }) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    if (characterAlias == configuredCharacterAlias) {
      configuredCharacterAlias = restoredCharacterAlias ?? 'Teddy';
      configuredTraits = restoredTraits;
      configuredGuidance = restoredGuidance;
    }
  }

  @override
  Future<VoiceProfileStatus> voiceStatus({String? characterAlias}) async =>
      characterVoices[characterAlias] ??
      (characterAlias == null || characterAlias == configuredCharacterAlias
          ? VoiceProfileStatus(
              enrolled: voiceEnrolled,
              approved: voiceApproved,
              runtimeReady: voiceRuntimeReady,
              durationMilliseconds: voiceEnrolled ? 20_000 : null,
            )
          : VoiceProfileStatus(
              enrolled: false,
              approved: false,
              runtimeReady: voiceRuntimeReady,
            ));

  @override
  Future<void> enrollVoiceSample({
    required String pin,
    required bool adultAuthorized,
    String? characterAlias,
    Uint8List? wavBytes,
    String? sourceFilename,
    String? sourceMime,
  }) async {
    if (pin != configuredPin || !adultAuthorized) {
      throw StateError('unauthorized');
    }
    enrollVoiceCalls += 1;
    lastEnrolledAlias = characterAlias;
    await enrollCompleter?.future;
    final aliasKey = characterAlias ?? configuredCharacterAlias;
    characterVoices[aliasKey] = VoiceProfileStatus(
      enrolled: true,
      approved: false,
      runtimeReady: voiceRuntimeReady,
      durationMilliseconds: 20_000,
    );
    if (characterAlias == null || characterAlias == configuredCharacterAlias) {
      voiceEnrolled = true;
      voiceApproved = false;
    }
  }

  @override
  Future<void> previewVoice(String pin, {String? characterAlias}) async {
    final status = await voiceStatus(characterAlias: characterAlias);
    if (pin != configuredPin || !status.enrolled) {
      throw StateError('unavailable');
    }
    previewVoiceCalls += 1;
    lastPreviewedAlias = characterAlias;
    await previewCompleter?.future;
  }

  @override
  Future<void> approveVoice(String pin, {String? characterAlias}) async {
    final status = await voiceStatus(characterAlias: characterAlias);
    if (pin != configuredPin || !status.enrolled) {
      throw StateError('unavailable');
    }
    lastApprovedAlias = characterAlias;
    final aliasKey = characterAlias ?? configuredCharacterAlias;
    characterVoices[aliasKey] = VoiceProfileStatus(
      enrolled: true,
      approved: true,
      runtimeReady: voiceRuntimeReady,
      durationMilliseconds: status.durationMilliseconds,
    );
    if (characterAlias == null || characterAlias == configuredCharacterAlias) {
      voiceApproved = true;
    }
  }

  @override
  Future<void> deleteVoice(String pin, {String? characterAlias}) async {
    if (pin != configuredPin) throw StateError('unauthorized');
    lastDeletedVoiceAlias = characterAlias;
    final aliasKey = characterAlias ?? configuredCharacterAlias;
    characterVoices[aliasKey] = VoiceProfileStatus(
      enrolled: false,
      approved: false,
      runtimeReady: voiceRuntimeReady,
    );
    if (characterAlias == null || characterAlias == configuredCharacterAlias) {
      voiceEnrolled = false;
      voiceApproved = false;
    }
  }

  @override
  Future<Uint8List> synthesizeVoice(
    String text, {
    String? characterAlias,
  }) async {
    await synthesizeCompleter?.future;
    clonedSpeech = text;
    return Uint8List.fromList(const [82, 73, 70, 70]);
  }

  @override
  Future<void> speakWithVoice(String text, {String? characterAlias}) async =>
      clonedSpeech = text;

  @override
  Future<LocalModelReadiness> localModelReadiness() async =>
      LocalModelReadiness(
        modelId: 'fixture-model',
        displayName: 'Fixture local model',
        ready: modelReady,
        installSupported: true,
        installing: false,
        runtimeMode: runtimeMode,
        parentConfigured: configuredPin != null,
        ageBand: restoredAgeBand,
        characterAlias: restoredCharacterAlias,
        characterTraits: restoredTraits,
        parentGuidance: restoredGuidance,
        retentionDays: restoredRetentionDays,
      );
}

Future<void> enterParentPin(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final parentPin = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Parent PIN',
  );
  await tester.ensureVisible(parentPin);
  await tester.enterText(parentPin, '4826');
  await tester.tap(find.widgetWithText(FilledButton, 'Confirm').last);
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, String text) async {
  final tooltip = find.byTooltip(text);
  if (tooltip.evaluate().isNotEmpty) {
    await tester.tap(tooltip);
    await tester.pumpAndSettle();
    return;
  }
  Finder target = find.text(text);
  for (final candidate in [
    find.widgetWithText(FilledButton, text),
    find.widgetWithText(OutlinedButton, text),
    find.widgetWithText(TextButton, text),
  ]) {
    if (candidate.evaluate().isNotEmpty) {
      target = candidate;
      break;
    }
  }
  await tester.pumpAndSettle();
  if (find.byType(Scrollable).evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(
      target,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getCenter(target));
  await tester.pumpAndSettle();
}

Future<void> unlockSettingsIfNeeded(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final parentPin = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Parent PIN',
  );
  if (parentPin.evaluate().isEmpty) return;
  await tester.enterText(parentPin, '4826');
  await tester.tap(find.text('Confirm'));
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  await tapVisible(tester, 'Parent Settings');
  await unlockSettingsIfNeeded(tester);
}

Future<void> startChildMode(WidgetTester tester) async {
  await tapVisible(tester, 'Start Playing');
  await tester.pumpAndSettle();
  final parentPin = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Parent PIN',
  );
  if (parentPin.evaluate().isNotEmpty) {
    await enterParentPin(tester);
  }
}

Future<void> openCharacterSettings(
  WidgetTester tester,
  String characterName,
) async {
  await openSettings(tester);
  await tapVisible(tester, 'Kids & Toy Buddies');
  await tapVisible(tester, 'Inaaya');
  await tapVisible(tester, characterName);
}

Future<void> returnToHome(WidgetTester tester, {int depth = 1}) async {
  for (var i = 0; i < depth; i += 1) {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }
}

Future<void> assessIfNeeded(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView), const Offset(0, -700));
  await tester.pumpAndSettle();
  for (final label in ['Check Hub', 'Check again']) {
    if (find.text(label).evaluate().isNotEmpty) {
      await tapVisible(tester, label);
      break;
    }
  }
  await tester.pumpAndSettle();
}

Future<void> completeBasicOnboarding(
  WidgetTester tester, {
  String birthdate = '01/01/2021',
}) async {
  await tester.pumpAndSettle();
  if (find.text('Welcome to ToyTalk').evaluate().isEmpty) {
    return;
  }
  await tapVisible(tester, 'Parent Settings');
  await unlockSettingsIfNeeded(tester);
  await tester.pumpAndSettle();
  final kidNameField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Kid name',
  );
  await tester.ensureVisible(kidNameField);
  await tester.enterText(kidNameField, 'Inaaya');
  final birthdateField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Birthdate',
  );
  await tester.ensureVisible(birthdateField);
  await tester.enterText(birthdateField, birthdate);
  await assessIfNeeded(tester);
  await tapVisible(tester, 'Save setup and go to parent home');
  await unlockSettingsIfNeeded(tester);
  await tester.pumpAndSettle();
}

class FakePlatform implements PlatformBridge {
  FakePlatform({
    this.transcript = 'Why is the sky blue?',
    this.listenError,
    this.recordError,
    this.playWavError,
    Uint8List? recordedWavBytes,
  }) : recordedWavBytes = recordedWavBytes ?? Uint8List.fromList(_fixtureWav);

  final String transcript;
  final PlatformException? listenError;
  final PlatformException? recordError;
  final Object? playWavError;
  final Uint8List recordedWavBytes;
  String? spokenText;
  int playWavCalls = 0;
  int speakCalls = 0;

  @override
  bool get supportsSpeech => true;

  @override
  Future<void> cancelSpeech() async {}

  @override
  Future<void> deleteSecret(String reference) async {}

  @override
  Future<DeviceProfile> deviceProfile() async => const DeviceProfile(
    platform: 'test',
    memoryBytes: 8 << 30,
    logicalProcessors: 8,
  );

  @override
  Future<bool> ensureMicrophonePermission() async => true;

  @override
  Future<String> listen() async {
    final error = listenError;
    if (error != null) {
      throw error;
    }
    return transcript;
  }

  @override
  Future<Uint8List> recordSpeechWav() async {
    final error = recordError;
    if (error != null) {
      throw error;
    }
    return recordedWavBytes;
  }

  @override
  Future<void> playWavBytes(Uint8List wavBytes) async {
    playWavCalls += 1;
    final error = playWavError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> speak(String text) async {
    speakCalls += 1;
    spokenText = text;
  }

  @override
  Future<String> storeSecret(String label, String value) async => 'secret-ref';
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('parent completes local onboarding and enters child mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(seedFixtureKid: false),
        platform: FakePlatform(),
      ),
    );
    expect(find.text('Welcome to ToyTalk'), findsOneWidget);
    await completeBasicOnboarding(tester);
    expect(find.text('Ready to play'), findsOneWidget);
    await startChildMode(tester);
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('entering child mode requires a fresh Hub parent PIN', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(seedFixtureKid: false),
        platform: FakePlatform(),
      ),
    );
    await completeBasicOnboarding(tester);
    expect(find.text('Ready to play'), findsOneWidget);

    await tapVisible(tester, 'Start Playing');
    expect(find.text('Start child mode'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Parent PIN',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Ready to play'), findsOneWidget);
    expect(find.text('Tap to talk'), findsNothing);

    await tapVisible(tester, 'Start Playing');
    await enterParentPin(tester);
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('ToyTalk logo renders the shared teddy mark', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ToyTalkLogo())),
    );

    expect(find.byType(ToyTalkLogo), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ToyTalkLogo),
        matching: find.byType(CustomPaint),
      ),
      findsAtLeastNWidgets(1),
    );
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('setup checklist uses playful status badges', (tester) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(modelReady: false),
        platform: FakePlatform(),
      ),
    );

    expect(find.text('Setup checklist'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.more_horiz_rounded), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('welcome parent settings requires Hub parent PIN', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(seedFixtureKid: false),
        platform: FakePlatform(),
      ),
    );

    await tapVisible(tester, 'Parent Settings');

    expect(find.text('Open parent settings'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Parent PIN',
      ),
      findsOneWidget,
    );

    await enterParentPin(tester);
    expect(find.text('Parent Settings'), findsAtLeastNWidgets(1));
  });

  testWidgets('first-run kid profile can be saved before adding voice', (
    tester,
  ) async {
    final backend = FakeBackend(seedFixtureKid: false)
      ..voiceEnrolled = false
      ..voiceApproved = false;
    backend.savedKids.clear();
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );

    await tapVisible(tester, 'Parent Settings');
    await unlockSettingsIfNeeded(tester);
    final kidNameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Kid name',
    );
    final birthdateField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Birthdate',
    );
    await tester.ensureVisible(kidNameField);
    await tester.enterText(kidNameField, 'Mia');
    await tester.ensureVisible(birthdateField);
    await tester.enterText(birthdateField, '02/03/2021');

    await tapVisible(tester, 'Save kid profile');

    expect(
      find.text('Kid profile saved. Now add a toy buddy.'),
      findsOneWidget,
    );
    expect(backend.savedKids.single.name, 'Mia');
    expect(backend.savedKids.single.birthdateIso, '2021-02-03');
    await tester.ensureVisible(find.text('First character'));
    expect(find.text('Add voice sample'), findsOneWidget);
  });

  testWidgets(
    'birthdate digits auto-format and first voice save skips PIN setup',
    (tester) async {
      final backend = FakeBackend(seedFixtureKid: false)
        ..voiceEnrolled = false
        ..voiceApproved = false;
      backend.savedKids.clear();
      await tester.pumpWidget(
        ToyTalkApp(backend: backend, platform: FakePlatform()),
      );

      await tapVisible(tester, 'Parent Settings');
      await unlockSettingsIfNeeded(tester);
      final kidNameField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Kid name',
      );
      final birthdateField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Birthdate',
      );
      final characterNameField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Character name',
      );

      await tester.ensureVisible(kidNameField);
      await tester.enterText(kidNameField, 'Mia');
      await tester.ensureVisible(birthdateField);
      await tester.enterText(birthdateField, '02032021');
      await tester.pumpAndSettle();
      expect(find.text('02/03/2021'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -700));
      await tester.pumpAndSettle();
      await tester.ensureVisible(characterNameField);
      await tester.enterText(characterNameField, 'Buddy');
      await tester.ensureVisible(find.text('First character'));
      await tester.pumpAndSettle();
      final addVoiceButton = find.widgetWithText(
        FilledButton,
        'Add voice sample',
      );
      await tester.scrollUntilVisible(
        addVoiceButton,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(addVoiceButton);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Parent PIN',
        ),
        findsNothing,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.widgetWithText(FilledButton, 'Choose audio file'));
      await tester.pumpAndSettle();

      expect(backend.savedKids.single.birthdateIso, '2021-02-03');
      expect(backend.configuredCharacterAlias, 'Buddy');
      expect(backend.configureParentPinCalls, 0);
      expect(backend.enrollVoiceCalls, 1);
      expect(find.text('Parent Settings'), findsAtLeastNWidgets(1));
      expect(
        find.text(
          'Buddy voice created. Listen and save it only if it sounds right.',
        ),
        findsOneWidget,
      );
      expect(find.text('Preview voice'), findsOneWidget);
    },
  );

  testWidgets('welcome parent settings explains when Hub PIN is missing', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(parentConfigured: false),
        platform: FakePlatform(),
      ),
    );

    await tapVisible(tester, 'Parent Settings');

    expect(find.text('Hub setup needed'), findsOneWidget);
    expect(
      find.textContaining('Parent PIN is not set yet'),
      findsAtLeastNWidgets(1),
    );
    expect(find.text('Parent Settings'), findsOneWidget);
  });

  testWidgets('child screen hides transcripts and exposes large talk state', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester, birthdate: '01/01/2017');
    await startChildMode(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();
    expect(find.text('Tap to talk'), findsOneWidget);
    expect(find.textContaining('transcript'), findsNothing);
  });

  testWidgets('typed child question reaches local backend and renders answer', (
    tester,
  ) async {
    final backend = FakeBackend();
    final platform = FakePlatform();
    await tester.pumpWidget(ToyTalkApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await startChildMode(tester);

    await tester.enterText(find.byType(TextField), 'Why is the sky blue?');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();

    expect(backend.receivedText, 'Why is the sky blue?');
    expect(find.text('Blue light scatters more in the sky.'), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets(
    'child answer waits for cloned voice preview work and then appears',
    (tester) async {
      final backend = FakeBackend()..synthesizeCompleter = Completer<void>();
      await tester.pumpWidget(
        ToyTalkApp(backend: backend, platform: FakePlatform()),
      );
      await completeBasicOnboarding(tester);
      await startChildMode(tester);

      await tester.enterText(find.byType(TextField), 'Can we play?');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pump();

      expect(find.text('Can we play?'), findsOneWidget);
      expect(find.text('Preparing Teddy voice...'), findsOneWidget);
      expect(find.text('Blue light scatters more in the sky.'), findsNothing);

      backend.synthesizeCompleter!.complete();
      await tester.pumpAndSettle();

      expect(backend.clonedSpeech, 'Blue light scatters more in the sky.');
      expect(find.text('Blue light scatters more in the sky.'), findsOneWidget);
      expect(find.text('Tap to talk'), findsOneWidget);
    },
  );

  testWidgets(
    'approved buddy voice playback failure does not fall back to system speech',
    (tester) async {
      final backend = FakeBackend();
      final platform = FakePlatform(playWavError: StateError('aborted'));
      await tester.pumpWidget(ToyTalkApp(backend: backend, platform: platform));
      await completeBasicOnboarding(tester);
      await startChildMode(tester);

      await tester.enterText(find.byType(TextField), 'Can we play?');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();

      expect(backend.clonedSpeech, 'Blue light scatters more in the sky.');
      expect(platform.playWavCalls, 1);
      expect(platform.speakCalls, 0);
      expect(platform.spokenText, isNull);
      expect(find.text('Blue light scatters more in the sky.'), findsOneWidget);
    },
  );

  testWidgets('child mode is blocked until buddy voice is approved', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..voiceEnrolled = true
      ..voiceApproved = false
      ..voiceRuntimeReady = true;
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester);

    expect(find.text('Preview Teddy’s voice'), findsAtLeastNWidgets(1));
    expect(find.text('Preview voice'), findsAtLeastNWidgets(1));
    expect(find.text('Start Playing'), findsNothing);
    expect(find.text('Tap to talk'), findsNothing);
    expect(backend.receivedText, isNull);
  });

  testWidgets('empty typed child question shows a visible hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester);
    await startChildMode(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Type a message or tap the mic first.'), findsOneWidget);
  });

  testWidgets('spoken child question is transcribed, answered, and spoken', (
    tester,
  ) async {
    final backend = FakeBackend();
    final platform = FakePlatform(transcript: 'Tell me about rainbows');
    await tester.pumpWidget(ToyTalkApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await startChildMode(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();

    expect(backend.receivedText, 'Tell me about rainbows');
    expect(backend.clonedSpeech, 'Blue light scatters more in the sky.');
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('spoken child question falls back to Hub STT', (tester) async {
    final backend = FakeBackend()..sttTranscript = 'What makes thunder loud?';
    final platform = FakePlatform(
      listenError: PlatformException(
        code: 'speech_on_device_unavailable',
        message: 'On-device speech recognition is unavailable.',
      ),
    );
    await tester.pumpWidget(ToyTalkApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await startChildMode(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();

    expect(backend.transcribedWavBytes, isNotNull);
    expect(backend.receivedText, 'What makes thunder loud?');
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('spoken child question failure shows speech error message', (
    tester,
  ) async {
    final backend = FakeBackend();
    final platform = FakePlatform(
      listenError: PlatformException(
        code: 'speech_error',
        message:
            'I did not hear speech yet. Try again and start talking after the beep.',
      ),
      recordError: PlatformException(
        code: 'speech_recording_failed',
        message: 'Microphone recording failed',
      ),
    );
    await tester.pumpWidget(ToyTalkApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await startChildMode(tester);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();

    expect(backend.receivedText, isNull);
    expect(
      find.text(
        'I did not hear speech yet. Try again and start talking after the beep.',
      ),
      findsOneWidget,
    );
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('onboarding stays blocked when host has no verified model', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(modelReady: false),
        platform: FakePlatform(),
      ),
    );
    await tapVisible(tester, 'Parent Settings');
    await unlockSettingsIfNeeded(tester);
    await tester.pumpAndSettle();
    final birthdateField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Birthdate',
    );
    final kidNameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Kid name',
    );
    await tester.ensureVisible(kidNameField);
    await tester.enterText(kidNameField, 'Inaaya');
    await tester.ensureVisible(birthdateField);
    await tester.enterText(birthdateField, '01/01/2021');
    await assessIfNeeded(tester);

    await tapVisible(tester, 'Save setup and go to parent home');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Finish Cloud AI or Local AI setup in ToyTalk Hub before continuing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('parent can install and verify the signed local model', (
    tester,
  ) async {
    final backend = FakeBackend(modelReady: false);
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await backend.installLocalModel();

    expect(backend.modelReady, isTrue);
    expect(backend.modelReady, isTrue);
  });

  testWidgets('child mode exits directly to parent home', (tester) async {
    await tester.pumpWidget(
      ToyTalkApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester);
    await startChildMode(tester);

    await tapVisible(tester, 'Done');
    await tester.pumpAndSettle();
    expect(find.text('ToyTalk'), findsOneWidget);
    expect(find.text('Tap to talk'), findsNothing);
  });

  testWidgets('switching child-mode character clears live chat draft', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            parentConfigured: true,
            restoredAgeBand: '6-8',
            restoredCharacterAlias: 'Mochi',
          )
          ..additionalCharacters.add(
            const CharacterConfiguration(
              alias: 'Buddy',
              traits: ['playful'],
              parentGuidance: null,
              voice: VoiceProfileStatus(
                enrolled: true,
                approved: true,
                runtimeReady: true,
              ),
              kidId: 'kid-fixture',
            ),
          );
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();
    await startChildMode(tester);

    await tester.enterText(find.byType(TextField), 'Can we play?');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('Can we play?'), findsOneWidget);
    expect(find.text('Blue light scatters more in the sky.'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Buddy').last);
    await tester.pumpAndSettle();

    expect(find.text('Can we play?'), findsNothing);
    expect(find.text('Blue light scatters more in the sky.'), findsNothing);
    expect(
      find.text('Tap the mic and tell your buddy anything.'),
      findsOneWidget,
    );
  });

  testWidgets('persisted parent profile restores after host restart', (
    tester,
  ) async {
    await tester.pumpWidget(
      ToyTalkApp(
        backend: FakeBackend(
          parentConfigured: true,
          restoredAgeBand: '6-8',
          restoredCharacterAlias: 'Mochi',
        ),
        platform: FakePlatform(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ToyTalk'), findsOneWidget);
    expect(find.text('Mochi'), findsOneWidget);
  });

  testWidgets(
    'completed Hub setup opens parent home with Start Playing without resaving settings',
    (tester) async {
      await tester.pumpWidget(
        ToyTalkApp(
          backend: FakeBackend(
            parentConfigured: true,
            restoredAgeBand: null,
            restoredCharacterAlias: null,
          ),
          platform: FakePlatform(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Welcome to ToyTalk'), findsNothing);
      expect(find.text('Ready to play'), findsOneWidget);
      expect(find.text('Start Playing'), findsOneWidget);
      expect(find.text('Parent Settings'), findsNothing);
    },
  );

  testWidgets(
    'phone hub settings expose reconnect only and leave device management to Hub',
    (tester) async {
      await tester.pumpWidget(
        ToyTalkApp(
          backend:
              FakeBackend(
                  parentConfigured: true,
                  restoredAgeBand: '6-8',
                  restoredCharacterAlias: 'Mochi',
                )
                ..stationPaired = false
                ..stationBaseUrl = null,
          platform: FakePlatform(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Manage paired devices'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final pairedBackend =
          FakeBackend(
              parentConfigured: true,
              restoredAgeBand: '6-8',
              restoredCharacterAlias: 'Mochi',
            )
            ..stationPaired = true
            ..voiceRuntimeReady = true;
      await tester.pumpWidget(
        ToyTalkApp(backend: pairedBackend, platform: FakePlatform()),
      );
      await tester.pumpAndSettle();

      await openSettings(tester);
      await tapVisible(tester, 'ToyTalk Hub');
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('Forget this phone'), findsNothing);
      expect(find.text('Manage paired devices'), findsNothing);
      expect(
        find.textContaining('Paired devices and backups are managed'),
        findsOneWidget,
      );
    },
  );

  testWidgets('parent can toggle Cloud AI web search through Hub', (
    tester,
  ) async {
    final backend = FakeBackend(
      parentConfigured: true,
      restoredAgeBand: '6-8',
      restoredCharacterAlias: 'Mochi',
    );
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openSettings(tester);
    expect(find.text('Cloud AI web search'), findsOneWidget);
    expect(find.textContaining('Off. Toy buddies ask'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await unlockSettingsIfNeeded(tester);

    expect(backend.lastWebSearchEnabled, isTrue);
  });

  testWidgets('Cloud AI web search setting is hidden in Local AI mode', (
    tester,
  ) async {
    final backend = FakeBackend(
      parentConfigured: true,
      restoredAgeBand: '6-8',
      restoredCharacterAlias: 'Mochi',
      runtimeMode: 'privacy_local_first',
    );
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openSettings(tester);

    expect(find.text('Cloud AI web search'), findsNothing);
  });

  testWidgets(
    'character add and delete refresh the settings list immediately',
    (tester) async {
      final backend = FakeBackend(
        parentConfigured: true,
        restoredAgeBand: '6-8',
        restoredCharacterAlias: 'Mochi',
        restoredTraits: const ['gentle'],
      );
      await tester.pumpWidget(
        ToyTalkApp(backend: backend, platform: FakePlatform()),
      );
      await tester.pumpAndSettle();

      await openSettings(tester);
      await tapVisible(tester, 'Kids & Toy Buddies');
      await tapVisible(tester, 'Inaaya');
      await tapVisible(tester, 'Add Toy Buddy');
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Buddy name',
        ),
        'Buddy',
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Buddy'), findsOneWidget);

      await tapVisible(tester, 'Buddy');
      await tapVisible(tester, 'Delete buddy');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete buddy'));
      await tester.pumpAndSettle();

      expect(find.text('Buddy'), findsNothing);
      expect(find.text('Mochi'), findsOneWidget);
    },
  );

  testWidgets('parent enrolls previews and approves a local character voice', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            parentConfigured: true,
            restoredAgeBand: '6-8',
            restoredCharacterAlias: 'Mochi',
          )
          ..voiceEnrolled = false
          ..voiceApproved = false
          ..stationPaired = true
          ..enrollCompleter = Completer<void>()
          ..previewCompleter = Completer<void>();
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Almost ready'), findsOneWidget);
    await openCharacterSettings(tester, 'Mochi');
    final buddyVoiceTile = find.text('Buddy voice').first;
    await tester.ensureVisible(buddyVoiceTile);
    await tester.tap(buddyVoiceTile);
    await tester.pump();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    if (find.byType(TextField).evaluate().isNotEmpty) {
      await tester.enterText(find.byType(TextField).last, '4826');
    }
    await tester.tap(find.text('Choose audio file'));
    await tester.pump();
    backend.enrollCompleter!.complete();
    await tester.pumpAndSettle();

    expect(backend.voiceEnrolled, isTrue);
    expect(backend.voiceApproved, isFalse);
    expect(backend.enrollVoiceCalls, 1);
    expect(
      find.textContaining('Sample uploaded. Listen before saving'),
      findsOneWidget,
    );

    final previewVoiceTile = find.text('Buddy voice').first;
    await tester.ensureVisible(previewVoiceTile);
    await tester.tap(previewVoiceTile);
    await tester.pump();
    expect(backend.enrollVoiceCalls, 1);
    expect(backend.previewVoiceCalls, 1);
    expect(find.text('Choose audio file'), findsNothing);
    expect(
      find.textContaining('Creating preview audio on ToyTalk Hub'),
      findsOneWidget,
    );
    backend.previewCompleter!.complete();
    await tester.pumpAndSettle();

    await tapVisible(tester, 'Save this voice');
    await tester.pumpAndSettle();
    expect(backend.voiceApproved, isTrue);

    await returnToHome(tester, depth: 4);
    await startChildMode(tester);
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('new character does not inherit another character voice status', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            parentConfigured: true,
            restoredAgeBand: '6-8',
            restoredCharacterAlias: 'Mochi',
            restoredTraits: const ['gentle'],
          )
          ..characterVoices['Mochi'] = const VoiceProfileStatus(
            enrolled: true,
            approved: true,
            runtimeReady: true,
            durationMilliseconds: 20_000,
          )
          ..characterVoices['Buddy'] = const VoiceProfileStatus(
            enrolled: false,
            approved: false,
            runtimeReady: true,
          )
          ..additionalCharacters.add(
            const CharacterConfiguration(
              alias: 'Buddy',
              traits: ['gentle'],
              parentGuidance: null,
              voice: VoiceProfileStatus(
                enrolled: false,
                approved: false,
                runtimeReady: true,
              ),
              kidId: 'kid-fixture',
            ),
          );

    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openCharacterSettings(tester, 'Buddy');

    expect(find.textContaining('No voice sample uploaded yet'), findsOneWidget);
    expect(find.textContaining('Approved for conversations'), findsNothing);
  });

  testWidgets('character detail voice actions are scoped to that character', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            parentConfigured: true,
            restoredAgeBand: '6-8',
            restoredCharacterAlias: 'Mochi',
            restoredTraits: const ['gentle'],
          )
          ..stationPaired = true
          ..characterVoices['Mochi'] = const VoiceProfileStatus(
            enrolled: true,
            approved: true,
            runtimeReady: true,
            durationMilliseconds: 20_000,
          )
          ..additionalCharacters.add(
            const CharacterConfiguration(
              alias: 'Buddy',
              traits: ['gentle'],
              parentGuidance: null,
              voice: VoiceProfileStatus(
                enrolled: false,
                approved: false,
                runtimeReady: true,
              ),
              kidId: 'kid-fixture',
            ),
          );

    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openCharacterSettings(tester, 'Buddy');
    expect(find.textContaining('No voice sample uploaded yet'), findsOneWidget);

    final buddyVoiceTile = find.text('Buddy voice').first;
    await tester.ensureVisible(buddyVoiceTile);
    await tester.tap(buddyVoiceTile);
    await tester.pump();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    await tester.tap(find.text('Choose audio file'));
    await tester.pumpAndSettle();

    expect(backend.lastEnrolledAlias, 'Buddy');
    expect(backend.characterVoices['Buddy']?.enrolled, isTrue);
    expect(backend.characterVoices['Buddy']?.approved, isFalse);
    expect(backend.characterVoices['Mochi']?.approved, isTrue);
  });

  testWidgets('parent clears session and PIN-deletes all local data', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester);

    await openSettings(tester);
    await tapVisible(tester, 'Clear all conversations');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete conversations'));
    await tester.pumpAndSettle();
    expect(backend.sessionEnded, isTrue);

    await tapVisible(tester, 'Delete everything on this phone');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete all'));
    await tester.pumpAndSettle();
    expect(backend.localDataDeleted, isTrue);
    expect(find.text('Welcome to ToyTalk'), findsOneWidget);
  });

  testWidgets('parent edits privacy settings and reviews retained history', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            parentConfigured: true,
            restoredAgeBand: '6-8',
            restoredCharacterAlias: 'Mochi',
            restoredTraits: const ['gentle'],
            restoredRetentionDays: 7,
          )
          ..savedHistory.add(
            const ConversationHistoryEntry(
              childText: 'Why do stars shine?',
              characterText: 'Stars make light in their hot centers.',
              completedAt: 123,
            ),
          );
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openCharacterSettings(tester, 'Mochi');
    await tapVisible(tester, 'Mochi conversations');
    await tester.pumpAndSettle();
    expect(find.textContaining('Why do stars shine?'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await returnToHome(tester, depth: 4);

    await openCharacterSettings(tester, 'Mochi');
    await tapVisible(tester, 'Name, personality, and guidance');
    final cheerfulChip = find.widgetWithText(FilterChip, 'cheerful');
    await tester.ensureVisible(cheerfulChip);
    await tester.tap(cheerfulChip);
    final guidanceField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Parent guidance (optional)',
    );
    await tester.ensureVisible(guidanceField);
    await tester.enterText(guidanceField, 'Prefer nature examples.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.configuredTraits, containsAll(['cheerful', 'gentle']));
    expect(backend.configuredGuidance, 'Prefer nature examples.');
    expect(backend.configuredRetentionDays, 7);
  });

  testWidgets('character detail can rename buddy without losing voice status', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            parentConfigured: true,
            restoredAgeBand: '6-8',
            restoredCharacterAlias: 'Mochi',
            restoredTraits: const ['gentle'],
          )
          ..characterVoices['Mochi'] = const VoiceProfileStatus(
            enrolled: true,
            approved: true,
            runtimeReady: true,
            durationMilliseconds: 21_000,
          );
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openCharacterSettings(tester, 'Mochi');
    await tapVisible(tester, 'Name, personality, and guidance');
    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Buddy name',
    );
    await tester.ensureVisible(nameField);
    await tester.enterText(nameField, 'Sheru');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.configuredCharacterAlias, 'Sheru');
    expect(backend.characterVoices['Sheru']?.approved, isTrue);
    expect(backend.characterVoices['Mochi'], isNull);
    expect(find.textContaining('Sheru was updated'), findsOneWidget);
  });

  testWidgets('parent can change app theme from home screens', (tester) async {
    final backend = FakeBackend(modelReady: true)
      ..voiceApproved = true
      ..voiceRuntimeReady = true
      ..stationPaired = true;
    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Theme'), findsOneWidget);
    await tester.tap(find.byTooltip('Theme'));
    await tester.pumpAndSettle();
    expect(find.text('System'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await completeBasicOnboarding(tester);

    expect(find.byTooltip('Theme'), findsOneWidget);
    await tester.tap(find.byTooltip('Theme'));
    await tester.pumpAndSettle();
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'Dark'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byTooltip('Theme'), findsOneWidget);
    expect(find.byTooltip('Parent Settings'), findsOneWidget);
  });

  testWidgets('duplicate backend character aliases do not crash home screen', (
    tester,
  ) async {
    final backend =
        FakeBackend(
            modelReady: true,
            restoredAgeBand: '4-5',
            restoredCharacterAlias: 'QABuddy',
            restoredTraits: const ['gentle'],
          )
          ..voiceApproved = true
          ..voiceRuntimeReady = true
          ..stationPaired = true
          ..additionalCharacters.add(
            const CharacterConfiguration(
              alias: 'QABuddy',
              traits: ['gentle'],
              parentGuidance: null,
              voice: VoiceProfileStatus(
                enrolled: true,
                approved: true,
                runtimeReady: true,
              ),
              kidId: 'kid-fixture',
              personaAgeYears: 4,
            ),
          );

    await tester.pumpWidget(
      ToyTalkApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('QABuddy'), findsWidgets);
  });

  testWidgets('first launch migrates old theme choice back to system default', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'toytalk.theme_mode': 'light'});

    await tester.pumpWidget(
      ToyTalkApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('toytalk.theme_mode'), 'system');
    expect(
      preferences.getBool('toytalk.theme_mode.v2_system_default_migrated'),
      isTrue,
    );
  });
}
