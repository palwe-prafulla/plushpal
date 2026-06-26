import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plushpal_ui/src/app.dart';
import 'package:plushpal_ui/src/backend/backend_client.dart';
import 'package:plushpal_ui/src/platform/platform_bridge.dart';

class FakeBackend implements BackendClient {
  FakeBackend({
    this.modelReady = true,
    this.parentConfigured = false,
    this.restoredAgeBand,
    this.restoredCharacterAlias,
    this.restoredTraits = const [],
    this.restoredGuidance,
    this.restoredRetentionDays,
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
  String? receivedText;
  bool sessionEnded = false;
  bool localDataDeleted = false;
  final savedHistory = <ConversationHistoryEntry>[];
  bool voiceEnrolled = true;
  bool voiceApproved = true;
  bool voiceRuntimeReady = true;
  String? clonedSpeech;
  Completer<void>? enrollCompleter;
  Completer<void>? previewCompleter;
  int enrollVoiceCalls = 0;
  int previewVoiceCalls = 0;
  String? lastEnrolledAlias;
  String? lastPreviewedAlias;
  String? lastApprovedAlias;
  String? lastDeletedVoiceAlias;
  int? receivedCharacterPlayAgeYears;
  bool stationPaired = false;
  String? stationBaseUrl;
  final savedKids = <KidProfile>[];
  final additionalCharacters = <CharacterConfiguration>[];
  final characterVoices = <String, VoiceProfileStatus>{};

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
  Future<ReasoningProviderStatus> reasoningProviderStatus() async =>
      ReasoningProviderStatus(
        provider: 'gemini',
        configured: modelReady,
        displayName: 'Gemini',
      );

  @override
  Future<void> configureApiKey({
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
  Future<List<KidProfile>> kids() async => savedKids.isEmpty
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
        parentConfigured: parentConfigured,
        ageBand: restoredAgeBand,
        characterAlias: restoredCharacterAlias,
        characterTraits: restoredTraits,
        parentGuidance: restoredGuidance,
        retentionDays: restoredRetentionDays,
      );
}

Future<void> enterParentPin(WidgetTester tester) async {
  if (find.byType(ListView).evaluate().isNotEmpty) {
    await tester.drag(find.byType(ListView).first, const Offset(0, 1000));
    await tester.pumpAndSettle();
  }
  final createPin = find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Create parent PIN (4-8 digits)',
  );
  final confirmPin = find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Confirm parent PIN',
  );
  await tester.ensureVisible(createPin);
  await tester.enterText(createPin, '4826');
  await tester.ensureVisible(confirmPin);
  await tester.enterText(confirmPin, '4826');
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
  if (find.text('Open parent settings').evaluate().isEmpty) return;
  await tester.enterText(find.byType(TextField).last, '4826');
  await tester.tap(find.text('Confirm'));
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  await tapVisible(tester, 'Parent Settings');
  await unlockSettingsIfNeeded(tester);
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
  for (final label in ['Check reasoning status', 'Check local model']) {
    if (find.text(label).evaluate().isNotEmpty) {
      await tapVisible(tester, label);
      break;
    }
  }
  await tester.pumpAndSettle();
}

Future<void> completeBasicOnboarding(
  WidgetTester tester, {
  String birthdate = '2021-01-01',
}) async {
  await tapVisible(tester, 'Parent Settings');
  await tester.pumpAndSettle();
  final birthdateField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.labelText == 'Birthdate',
  );
  await tester.ensureVisible(birthdateField);
  await tester.enterText(birthdateField, birthdate);
  await assessIfNeeded(tester);
  await enterParentPin(tester);
  await tapVisible(tester, 'Continue to parent home');
  await tester.pumpAndSettle();
}

class FakePlatform implements PlatformBridge {
  FakePlatform({this.transcript = 'Why is the sky blue?', this.listenError});

  final String transcript;
  final PlatformException? listenError;
  String? spokenText;

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
  Future<void> playWavBytes(Uint8List wavBytes) async {}

  @override
  Future<void> speak(String text) async => spokenText = text;

  @override
  Future<String> storeSecret(String label, String value) async => 'secret-ref';
}

void main() {
  testWidgets('parent completes local onboarding and enters child mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      PlushPalApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    expect(find.text('Welcome to PlushBuddy'), findsOneWidget);
    await completeBasicOnboarding(tester);
    expect(find.text('Ready to play'), findsOneWidget);
    await tapVisible(tester, 'Start Playing');
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('child screen hides transcripts and exposes large talk state', (
    tester,
  ) async {
    await tester.pumpWidget(
      PlushPalApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester, birthdate: '2017-01-01');
    await tapVisible(tester, 'Start Playing');

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
    await tester.pumpWidget(PlushPalApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await tapVisible(tester, 'Start Playing');

    await tester.enterText(find.byType(TextField), 'Why is the sky blue?');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();

    expect(backend.receivedText, 'Why is the sky blue?');
    expect(find.text('Blue light scatters more in the sky.'), findsOneWidget);
    expect(find.text('Tap to talk'), findsOneWidget);
  });

  testWidgets('empty typed child question shows a visible hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      PlushPalApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester);
    await tapVisible(tester, 'Start Playing');

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
    await tester.pumpWidget(PlushPalApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await tapVisible(tester, 'Start Playing');

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();

    expect(backend.receivedText, 'Tell me about rainbows');
    expect(backend.clonedSpeech, 'Blue light scatters more in the sky.');
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
    );
    await tester.pumpWidget(PlushPalApp(backend: backend, platform: platform));
    await completeBasicOnboarding(tester);
    await tapVisible(tester, 'Start Playing');

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
      PlushPalApp(
        backend: FakeBackend(modelReady: false),
        platform: FakePlatform(),
      ),
    );
    await tapVisible(tester, 'Parent Settings');
    await tester.pumpAndSettle();
    final birthdateField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Birthdate',
    );
    await tester.ensureVisible(birthdateField);
    await tester.enterText(birthdateField, '2021-01-01');
    await assessIfNeeded(tester);

    await enterParentPin(tester);
    await tapVisible(tester, 'Continue to parent home');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Save a reasoning API key on this phone before continuing to Parent Home.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('parent can install and verify the signed local model', (
    tester,
  ) async {
    final backend = FakeBackend(modelReady: false);
    await tester.pumpWidget(
      PlushPalApp(backend: backend, platform: FakePlatform()),
    );
    await backend.installLocalModel();

    expect(backend.modelReady, isTrue);
    expect(backend.modelReady, isTrue);
  });

  testWidgets('child mode exits directly to parent home', (tester) async {
    await tester.pumpWidget(
      PlushPalApp(backend: FakeBackend(), platform: FakePlatform()),
    );
    await completeBasicOnboarding(tester);
    await tapVisible(tester, 'Start Playing');

    await tapVisible(tester, 'Done');
    await tester.pumpAndSettle();
    expect(find.text('PlushBuddy'), findsOneWidget);
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
      PlushPalApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, 'Start Playing');

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
      PlushPalApp(
        backend: FakeBackend(
          parentConfigured: true,
          restoredAgeBand: '6-8',
          restoredCharacterAlias: 'Mochi',
        ),
        platform: FakePlatform(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('PlushBuddy'), findsOneWidget);
    expect(find.text('Mochi'), findsOneWidget);
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
        PlushPalApp(backend: backend, platform: FakePlatform()),
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
      PlushPalApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Make Mochi sound magical'), findsOneWidget);
    await openCharacterSettings(tester, 'Mochi');
    await tapVisible(tester, 'Buddy voice');
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
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

    await tapVisible(tester, 'Buddy voice');
    await tester.pump();
    expect(backend.enrollVoiceCalls, 1);
    expect(backend.previewVoiceCalls, 1);
    expect(find.text('Choose audio file'), findsNothing);
    backend.previewCompleter!.complete();
    await tester.pumpAndSettle();

    await tapVisible(tester, 'Save this voice');
    await tester.pumpAndSettle();
    expect(backend.voiceApproved, isTrue);

    await returnToHome(tester, depth: 4);
    await tapVisible(tester, 'Start Playing');
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
      PlushPalApp(backend: backend, platform: FakePlatform()),
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
      PlushPalApp(backend: backend, platform: FakePlatform()),
    );
    await tester.pumpAndSettle();

    await openCharacterSettings(tester, 'Buddy');
    expect(find.textContaining('No voice sample uploaded yet'), findsOneWidget);

    await tapVisible(tester, 'Buddy voice');
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
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
      PlushPalApp(backend: backend, platform: FakePlatform()),
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
    expect(find.text('Welcome to PlushBuddy'), findsOneWidget);
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
      PlushPalApp(backend: backend, platform: FakePlatform()),
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
}
