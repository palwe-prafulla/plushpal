import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plushpal_ui/src/backend/backend_client.dart';
import 'package:plushpal_ui/src/domain/app_state.dart';
import 'package:plushpal_ui/src/platform/platform_bridge.dart';

const approvedCharacterTraits = <String>[
  'cheerful',
  'curious',
  'gentle',
  'patient',
  'playful',
  'calm',
  'encouraging',
];

enum ChildMessageAuthor { child, character, system }

const appDisplayName = 'PlushBuddy';

typedef CharacterVoiceAction = Future<bool> Function({String? characterAlias});

String get _thisClientLabel => kIsWeb ? 'this browser' : 'this phone';
String get _thisDeviceLabel => kIsWeb ? 'this browser' : 'this device';
String get _voiceSampleStorageLabel => kIsWeb
    ? 'not saved in the browser after profiling.'
    : 'not saved on Android after profiling.';

class ChildAgeDetails {
  const ChildAgeDetails({
    required this.years,
    required this.months,
    required this.ageBand,
  });

  final int years;
  final int months;
  final AgeBand ageBand;

  String get label => '$years years, $months months';
  String get ageBandCode => switch (ageBand) {
    AgeBand.fourToFive => '4-5',
    AgeBand.sixToEight => '6-8',
    AgeBand.nineToTwelve => '9-12',
  };
}

ChildAgeDetails? childAgeFromBirthdate(String birthdateIso) {
  final birthdate = DateTime.tryParse(birthdateIso);
  if (birthdate == null) return null;
  final today = DateTime.now();
  if (birthdate.isAfter(today)) return null;
  var years = today.year - birthdate.year;
  var months = today.month - birthdate.month;
  if (today.day < birthdate.day) months -= 1;
  if (months < 0) {
    years -= 1;
    months += 12;
  }
  if (years < 0) return null;
  final band = years <= 5
      ? AgeBand.fourToFive
      : years <= 8
      ? AgeBand.sixToEight
      : AgeBand.nineToTwelve;
  return ChildAgeDetails(years: years, months: months, ageBand: band);
}

class ChildChatMessage {
  const ChildChatMessage({required this.author, required this.text});

  final ChildMessageAuthor author;
  final String text;
}

class PlushPalApp extends StatelessWidget {
  const PlushPalApp({this.backend, this.platform, super.key});

  final BackendClient? backend;
  final PlatformBridge? platform;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appDisplayName,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Roboto',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff8b5cf6),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xfffffbf2),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: Color(0xfffffbf2),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      useMaterial3: true,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    home: PlushPalRoot(
      backend: backend ?? createBackendClient(),
      platform: platform ?? const MethodChannelPlatformBridge(),
    ),
  );
}

class PlushPalRoot extends StatefulWidget {
  const PlushPalRoot({
    required this.backend,
    required this.platform,
    super.key,
  });

  final BackendClient backend;
  final PlatformBridge platform;

  @override
  State<PlushPalRoot> createState() => _PlushPalRootState();
}

class _PlushPalRootState extends State<PlushPalRoot>
    with WidgetsBindingObserver {
  AppState state = const AppState();
  String? message;
  String? latestSpeech;
  List<ChildChatMessage> childMessages = const [];
  bool installingModel = false;
  bool modelInstallSupported = false;
  bool voiceEnrolled = false;
  bool voiceApproved = false;
  bool voicePreviewed = false;
  bool voiceEnrolling = false;
  bool voicePreviewing = false;
  bool voiceRuntimeReady = false;
  bool showSetupSettings = false;
  int? voiceDurationMilliseconds;
  bool stationPaired = false;
  String? stationBaseUrl;
  ReasoningProviderStatus reasoningProvider = const ReasoningProviderStatus(
    provider: 'gemini',
    configured: false,
    displayName: 'Gemini',
  );
  String? lastParentHomeAutoRefreshKey;
  List<KidProfile> kids = const [];
  String? selectedKidId;
  List<CharacterConfiguration> characters = const [];
  final childInput = TextEditingController();
  final kidName = TextEditingController(text: 'Inaaya');
  final kidBirthdate = TextEditingController();
  final characterName = TextEditingController(text: 'Teddy');
  final parentGuidance = TextEditingController();
  final parentPin = TextEditingController();
  final confirmParentPin = TextEditingController();
  final selectedTraits = <String>{'gentle', 'curious'};
  int? retentionDays;
  String? unlockedParentPin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(assessDevice());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(assessDevice());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.backend.cancelTurn().catchError((_) {}));
    unawaited(widget.platform.cancelSpeech().catchError((_) {}));
    childInput.dispose();
    kidName.dispose();
    kidBirthdate.dispose();
    characterName.dispose();
    parentGuidance.dispose();
    parentPin.dispose();
    confirmParentPin.dispose();
    super.dispose();
  }

  CharacterConfiguration? get selectedCharacter {
    for (final character in kidCharacters) {
      if (character.alias == state.characterName) return character;
    }
    return kidCharacters.isEmpty ? null : kidCharacters.first;
  }

  KidProfile? get selectedKid {
    for (final kid in kids) {
      if (kid.id == selectedKidId) return kid;
    }
    return kids.isEmpty ? null : kids.first;
  }

  ChildAgeDetails? get selectedChildAge => selectedKid == null
      ? null
      : childAgeFromBirthdate(selectedKid!.birthdateIso);

  List<CharacterConfiguration> get kidCharacters {
    final kid = selectedKid;
    if (kid == null) return characters;
    final scoped = characters
        .where(
          (character) =>
              character.kidId == kid.id ||
              character.kidId == null ||
              character.kidId!.isEmpty,
        )
        .toList();
    return scoped;
  }

  String? get selectedKidCharacterId => selectedKid?.id;

  int? get selectedCharacterPersonaAge {
    final childAge = selectedChildAge?.years;
    final persona = selectedCharacter?.personaAgeYears;
    if (childAge == null) return persona;
    final requested = persona ?? childAge;
    if (requested < 2) return 2;
    if (requested > childAge) return childAge;
    return requested;
  }

  void applyCharacter(CharacterConfiguration character) {
    characterName.text = character.alias;
    parentGuidance.text = character.parentGuidance ?? '';
    selectedTraits
      ..clear()
      ..addAll(character.traits);
    voiceEnrolled = character.voice.enrolled;
    voiceApproved = character.voice.approved;
    voicePreviewed = character.voice.approved;
    voiceRuntimeReady = character.voice.runtimeReady;
    voiceDurationMilliseconds = character.voice.durationMilliseconds;
  }

  void updateCurrentCharacterVoice(
    VoiceProfileStatus voice, {
    String? characterAlias,
  }) {
    final alias = characterAlias ?? state.characterName;
    voiceEnrolled = voice.enrolled;
    voiceApproved = voice.approved;
    voicePreviewed = voice.approved || voicePreviewed;
    voiceRuntimeReady = voice.runtimeReady;
    voiceDurationMilliseconds = voice.durationMilliseconds;
    characters = [
      for (final character in characters)
        character.alias == alias
            ? CharacterConfiguration(
                alias: character.alias,
                traits: character.traits,
                parentGuidance: character.parentGuidance,
                voice: voice,
                kidId: character.kidId,
                personaAgeYears: character.personaAgeYears,
                photoBytes: character.photoBytes,
                photoMime: character.photoMime,
              )
            : character,
    ];
  }

  void selectCharacter(String alias) {
    CharacterConfiguration? character;
    for (final candidate in characters) {
      if (candidate.alias == alias) {
        character = candidate;
        break;
      }
    }
    if (character == null) return;
    final selected = character;
    final changedCharacter = state.characterName != selected.alias;
    final transition = AppReducer.reduce(state, CharacterNamed(selected.alias));
    setState(() {
      state = transition.state;
      message = transition.error;
      applyCharacter(selected);
      if (changedCharacter) {
        latestSpeech = null;
        childMessages = const [];
        childInput.clear();
      }
    });
  }

  Future<void> beginLocalTurn(String text, {bool startListening = true}) async {
    final prompt = text.trim();
    final kid = selectedKid;
    final age = selectedChildAge;
    if (prompt.isEmpty) {
      setState(() => message = 'Type a message or tap the mic first.');
      return;
    }
    if (age == null) {
      setState(() => message = 'Choose a kid before starting playtime.');
      return;
    }
    if (startListening) dispatch(const TalkStarted());
    dispatch(const TranscriptAccepted());
    setState(() {
      childMessages = [
        ...childMessages,
        ChildChatMessage(author: ChildMessageAuthor.child, text: prompt),
      ];
      childInput.clear();
      message = null;
    });
    BackendResponse response;
    try {
      response = await widget.backend.beginLocalTurn(
        ageBand: age.ageBandCode,
        characterAlias: state.characterName,
        text: prompt,
        kidId: kid?.id,
        kidName: kid?.name,
        childAgeYears: age.years,
        childAgeMonths: age.months,
        characterPlayAgeYears: selectedCharacterPersonaAge,
      );
    } catch (error) {
      debugPrint('PlushPal turn generation failed: $error');
      if (!mounted) return;
      setState(
        () => message = userFacingError(
          error,
          fallback:
              'I could not think of an answer. Check the reasoning API key and internet connection, then try again.',
        ),
      );
      dispatch(const ConversationFailed());
      return;
    }
    if (!mounted ||
        state.step != AppStep.childMode ||
        state.conversationStatus != ConversationStatus.thinking) {
      return;
    }
    var responseShown = false;
    void showResponse({String? overrideMessage}) {
      if (responseShown || !mounted) return;
      responseShown = true;
      dispatch(const ResponseReady());
      setState(() {
        latestSpeech = response.speech;
        childMessages = [
          ...childMessages,
          ChildChatMessage(
            author: ChildMessageAuthor.character,
            text: response.speech,
          ),
        ];
        message =
            overrideMessage ??
            (response.suggestTrustedAdult
                ? 'Please involve a trusted adult.'
                : null);
      });
    }

    try {
      if (voiceApproved && voiceRuntimeReady) {
        setState(() => message = 'Preparing ${state.characterName} voice...');
        final wavBytes = await widget.backend.synthesizeVoice(
          response.speech,
          characterAlias: state.characterName,
        );
        if (!mounted ||
            state.step != AppStep.childMode ||
            state.conversationStatus != ConversationStatus.thinking) {
          return;
        }
        showResponse();
        await widget.platform.playWavBytes(wavBytes);
        if (!mounted) return;
      } else if (widget.platform.supportsSpeech) {
        showResponse();
        await widget.platform.speak(response.speech);
        if (!mounted) return;
      } else {
        showResponse();
      }
      if (state.step == AppStep.childMode &&
          state.conversationStatus == ConversationStatus.speaking) {
        dispatch(const PlaybackCompleted());
      }
    } catch (error) {
      debugPrint('PlushPal voice playback failed: $error');
      if (!mounted) return;
      showResponse(
        overrideMessage:
            'I answered below, but the buddy voice could not play. Check the Magic Voice Box and try again.',
      );
      if (widget.platform.supportsSpeech) {
        try {
          await widget.platform.speak(response.speech);
        } catch (fallbackError) {
          debugPrint('PlushPal fallback speech failed: $fallbackError');
        }
      }
      if (!mounted) return;
      if (state.step == AppStep.childMode &&
          state.conversationStatus == ConversationStatus.speaking) {
        dispatch(const PlaybackCompleted());
      }
    }
  }

  Future<void> beginSpokenTurn() async {
    if (!widget.platform.supportsSpeech || selectedChildAge == null) return;
    final hasMicrophonePermission = await widget.platform
        .ensureMicrophonePermission();
    if (!mounted) return;
    if (!hasMicrophonePermission) {
      setState(
        () => message =
            'Microphone permission is needed to talk. You can still type a message.',
      );
      return;
    }
    dispatch(const TalkStarted());
    try {
      final transcript = await widget.platform.listen();
      if (!mounted) return;
      if (transcript.trim().isEmpty) {
        dispatch(const ConversationFailed());
        setState(
          () => message = 'I did not hear a question. Please try again.',
        );
        return;
      }
      await beginLocalTurn(transcript, startListening: false);
    } catch (error) {
      if (!mounted) return;
      dispatch(const ConversationFailed());
      final speechMessage =
          error is PlatformException &&
              error.message != null &&
              error.message!.trim().isNotEmpty
          ? error.message!.trim()
          : 'I did not catch that yet. Try again and pause a little after you finish, or type a message.';
      setState(() => message = speechMessage);
    }
  }

  Future<void> enterChildMode() async {
    if (widget.platform.supportsSpeech) {
      final hasMicrophonePermission = await widget.platform
          .ensureMicrophonePermission();
      if (!mounted) return;
      if (!hasMicrophonePermission) {
        setState(
          () => message =
              'Microphone permission is needed to talk. You can still use child mode by typing.',
        );
      }
    }
    dispatch(const ChildModeStarted());
  }

  Future<void> assessDevice() async {
    try {
      final pairing = await widget.backend.stationPairingStatus();
      final provider = await widget.backend.reasoningProviderStatus();
      final readiness = await widget.backend.localModelReadiness();
      var loadedKids = <KidProfile>[];
      try {
        loadedKids = await widget.backend.kids();
      } catch (_) {
        loadedKids = const [];
      }
      var loadedCharacters = <CharacterConfiguration>[];
      if (readiness.parentConfigured) {
        try {
          loadedCharacters = await widget.backend.characters();
        } catch (_) {
          loadedCharacters = const [];
        }
      }
      if (!mounted) return;
      dispatch(
        DeviceAssessed(
          ModelRecommendation(
            modelId: readiness.modelId,
            displayName: readiness.displayName,
            installed: readiness.ready,
          ),
        ),
      );
      if (loadedCharacters.isEmpty &&
          readiness.parentConfigured &&
          readiness.characterAlias != null) {
        final fallbackVoice = await widget.backend.voiceStatus(
          characterAlias: readiness.characterAlias,
        );
        loadedCharacters = [
          CharacterConfiguration(
            alias: readiness.characterAlias!,
            traits: readiness.characterTraits,
            parentGuidance: readiness.parentGuidance,
            voice: fallbackVoice,
            personaAgeYears: selectedChildAge?.years,
          ),
        ];
      }
      final nextSelectedKidId =
          selectedKidId ?? (loadedKids.isNotEmpty ? loadedKids.first.id : null);
      final activeCharacters = nextSelectedKidId == null
          ? loadedCharacters
          : loadedCharacters
                .where(
                  (character) =>
                      character.kidId == nextSelectedKidId ||
                      character.kidId == null ||
                      character.kidId!.isEmpty,
                )
                .toList();
      CharacterConfiguration? activeCharacter;
      for (final character in activeCharacters) {
        if (character.alias == state.characterName) {
          activeCharacter = character;
          break;
        }
      }
      activeCharacter ??= activeCharacters.isNotEmpty
          ? activeCharacters.first
          : null;
      final activeVoice =
          activeCharacter?.voice ??
          await widget.backend.voiceStatus(characterAlias: state.characterName);
      setState(() {
        stationPaired = pairing.paired;
        stationBaseUrl = pairing.baseUrl;
        reasoningProvider = provider;
        kids = loadedKids;
        selectedKidId = nextSelectedKidId;
        installingModel = readiness.installing;
        modelInstallSupported = readiness.installSupported;
        characters = loadedCharacters;
        voiceEnrolled = activeVoice.enrolled;
        voiceApproved = activeVoice.approved;
        voicePreviewed = activeVoice.approved;
        voiceEnrolling = false;
        voicePreviewing = false;
        voiceRuntimeReady = activeVoice.runtimeReady;
        if (activeVoice.runtimeReady) lastParentHomeAutoRefreshKey = null;
        voiceDurationMilliseconds = activeVoice.durationMilliseconds;
      });
      final activeKid = selectedKid;
      final activeAge = activeKid == null
          ? null
          : childAgeFromBirthdate(activeKid.birthdateIso);
      if (readiness.parentConfigured &&
          state.step == AppStep.onboarding &&
          (activeAge != null || readiness.ageBand != null) &&
          readiness.characterAlias != null) {
        final restoredAge =
            activeAge?.ageBand ??
            switch (readiness.ageBand) {
              '4-5' => AgeBand.fourToFive,
              '6-8' => AgeBand.sixToEight,
              '9-12' => AgeBand.nineToTwelve,
              _ => null,
            };
        if (restoredAge != null) {
          CharacterConfiguration? preferredCharacter;
          for (final character in loadedCharacters) {
            if (character.alias == readiness.characterAlias!) {
              preferredCharacter = character;
              break;
            }
          }
          if (preferredCharacter != null) {
            applyCharacter(preferredCharacter);
          } else {
            characterName.text = readiness.characterAlias!;
            parentGuidance.text = readiness.parentGuidance ?? '';
            selectedTraits
              ..clear()
              ..addAll(readiness.characterTraits);
          }
          retentionDays = readiness.retentionDays;
          dispatch(AgeSelected(restoredAge));
          dispatch(CharacterNamed(readiness.characterAlias!));
          if (readiness.ready) dispatch(const OnboardingCompleted());
        }
      }
      if (!readiness.ready) {
        setState(
          () => message = stationPaired
              ? 'The Magic Voice Box is connected. Now set up the AI Brain on $_thisClientLabel.'
              : 'Set up the AI Brain on $_thisClientLabel, then connect the Magic Voice Box for buddy voices.',
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => message = 'Could not check the AI Brain or Magic Voice Box.',
      );
    }
  }

  Future<void> pairWithStation() async {
    if (kIsWeb) {
      setState(() => message = 'Checking the local Magic Voice Box...');
      await assessDevice();
      if (!mounted) return;
      setState(
        () => message = stationPaired
            ? 'Magic Voice Box connected automatically.'
            : 'Open PlushBuddy from Station, then refresh this client.',
      );
      return;
    }

    final pairingUrl = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const StationQrScannerScreen()),
    );
    if (pairingUrl == null || !mounted) return;
    setState(() => message = 'Connecting the Magic Voice Box...');
    try {
      await widget.backend.pairStation(pairingUrl.trim());
      if (!mounted) return;
      setState(() => message = 'Magic Voice Box connected.');
      await assessDevice();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => message = userFacingError(
          error,
          fallback:
              'Pairing failed. Keep the Mac awake, on the same Wi‑Fi, and scan a fresh QR code.',
        ),
      );
    }
  }

  Future<void> clearStationPairing() async {
    await widget.backend.clearStationPairing();
    if (!mounted) return;
    setState(() {
      stationPaired = false;
      stationBaseUrl = null;
      message = 'Magic Voice Box connection was removed.';
    });
    await assessDevice();
  }

  Future<void> configureGeminiKey() async {
    final controller = TextEditingController();
    var provider = reasoningProvider.provider;
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Configure reasoning provider'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: provider,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Provider',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'gemini', child: Text('Gemini')),
                    DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                  ],
                  onChanged: (value) => update(() {
                    provider = value ?? 'gemini';
                  }),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: provider == 'openai'
                        ? 'OpenAI API key'
                        : 'Gemini API key',
                    helperText: 'Stored locally on $_thisDeviceLabel.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) return;
    try {
      await widget.backend.configureApiKey(
        provider: provider,
        apiKey: controller.text,
      );
      if (!mounted) return;
      setState(() => message = 'Reasoning API key saved on this device.');
      await assessDevice();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => message = userFacingError(
          error,
          fallback: 'Could not save the API key.',
        ),
      );
    }
  }

  Future<void> installModel() async {
    setState(() {
      installingModel = true;
      message = 'Downloading and verifying the local model...';
    });
    try {
      await widget.backend.installLocalModel();
      if (!mounted) return;
      await assessDevice();
    } catch (_) {
      if (!mounted) return;
      setState(() => message = 'Model installation failed. Please try again.');
    } finally {
      if (mounted) setState(() => installingModel = false);
    }
  }

  Future<void> cancelModelInstall() async {
    await widget.backend.cancelModelInstall();
    if (!mounted) return;
    setState(() {
      installingModel = false;
      message = 'Model installation cancelled.';
    });
  }

  Future<void> exitChildMode() async {
    await widget.backend.cancelTurn();
    await widget.platform.cancelSpeech();
    await widget.backend.endSession();
    if (!mounted) return;
    setState(() => latestSpeech = null);
    dispatch(const ChildModeExited(parentAuthorized: true));
  }

  Future<void> completeOnboarding() async {
    final pin = parentPin.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin) || pin != confirmParentPin.text) {
      setState(() => message = 'Choose matching 4-8 digit parent PINs.');
      return;
    }
    final childAge = childAgeFromBirthdate(kidBirthdate.text.trim());
    if (childAge != null && state.ageBand != childAge.ageBand) {
      dispatch(AgeSelected(childAge.ageBand));
    }
    if (childAge == null || state.recommendation?.installed != true) {
      await assessDevice();
      if (!mounted) return;
    }
    if (childAge == null || state.recommendation?.installed != true) {
      setState(() {
        if (kidName.text.trim().isEmpty || childAge == null) {
          message = 'Add a kid profile with name and birthdate first.';
        } else if (state.recommendation?.installed != true) {
          message =
              'Save a reasoning API key on $_thisClientLabel before continuing to Parent Home.';
        } else {
          message = 'Finish the required setup items before continuing.';
        }
      });
      return;
    }
    final named = AppReducer.reduce(state, CharacterNamed(characterName.text));
    if (named.error != null) {
      setState(() => message = named.error);
      return;
    }
    try {
      final newKidId =
          selectedKidId ?? 'kid-${DateTime.now().microsecondsSinceEpoch}';
      await widget.backend.configureParentPin(
        pin: pin,
        ageBand: childAge.ageBandCode,
        characterAlias: characterName.text.trim(),
        characterTraits: selectedTraits.toList()..sort(),
        parentGuidance: parentGuidance.text.trim().isEmpty
            ? null
            : parentGuidance.text.trim(),
        retentionDays: retentionDays,
        kidId: newKidId,
      );
      await widget.backend.saveKid(
        pin: pin,
        kidId: newKidId,
        name: kidName.text.trim(),
        birthdateIso: kidBirthdate.text.trim(),
      );
      selectedKidId = newKidId;
      await widget.backend.saveCharacter(
        pin: pin,
        characterAlias: characterName.text.trim(),
        characterTraits: selectedTraits.toList()..sort(),
        parentGuidance: parentGuidance.text.trim().isEmpty
            ? null
            : parentGuidance.text.trim(),
        kidId: newKidId,
        personaAgeYears: childAge.years,
      );
      if (!mounted) return;
      dispatch(AgeSelected(childAge.ageBand));
      dispatch(CharacterNamed(characterName.text));
      dispatch(const OnboardingCompleted());
      parentPin.clear();
      confirmParentPin.clear();
      await assessDevice();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = userFacingError(
            error,
            fallback: 'Could not secure the parent PIN.',
          ),
        );
      }
    }
  }

  Future<String?> promptParentPin(String title) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final controller = TextEditingController();
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: const InputDecoration(labelText: 'Parent PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Confirm'),
          ),
        ],
      );
    },
  );

  Future<String?> requestParentPin(String title) async {
    if (unlockedParentPin case final pin?) return pin;
    return promptParentPin(title);
  }

  Future<bool> unlockParentPortal() async {
    final pin = await promptParentPin('Open parent settings');
    if (pin == null) return false;
    final authorized = await widget.backend.authorizeParentPin(pin);
    if (!mounted) return false;
    if (!authorized) {
      setState(() => message = 'Incorrect PIN or parent access is locked.');
      return false;
    }
    unlockedParentPin = pin;
    return true;
  }

  Future<bool> confirmAction({
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void showActionMessage(String text) {
    if (!mounted) return;
    setState(() => message = text);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String userFacingError(Object error, {required String fallback}) {
    if (error is PlatformException) {
      final code = error.code.trim();
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return code.isEmpty ? message : '$message ($code)';
      }
      if (code.isNotEmpty) return '$fallback ($code)';
    }
    final message = error.toString().replaceFirst(RegExp(r'^Error:\s*'), '');
    if (message.trim().isEmpty ||
        message.contains('Instance of') ||
        message.contains('JavaScriptObject')) {
      return fallback;
    }
    return message;
  }

  Future<void> clearCurrentConversation() async {
    await widget.backend.cancelTurn();
    await widget.platform.cancelSpeech();
    await widget.backend.endSession();
    if (!mounted) return;
    setState(() {
      latestSpeech = null;
      childMessages = const [];
    });
    showActionMessage('The current conversation was cleared.');
  }

  Future<void> deleteAllLocalData() async {
    final confirmed = await confirmAction(
      title: 'Delete all local data?',
      message:
          'This erases parent setup, kids, characters, pairing, and saved conversations from this device. This cannot be undone.',
      confirmLabel: 'Delete all',
      destructive: true,
    );
    if (!confirmed) return;
    final pin = await requestParentPin('Delete all local data?');
    if (pin == null) return;
    try {
      await widget.backend.deleteAllLocalData(pin);
      if (!mounted) return;
      characterName.text = 'Teddy';
      parentGuidance.clear();
      selectedTraits
        ..clear()
        ..addAll({'gentle', 'curious'});
      retentionDays = null;
      parentPin.clear();
      confirmParentPin.clear();
      setState(() {
        state = const AppState();
        latestSpeech = null;
        childMessages = const [];
        characters = const [];
        stationPaired = false;
        stationBaseUrl = null;
        voiceEnrolled = false;
        voiceApproved = false;
        voicePreviewed = false;
        voiceEnrolling = false;
        voicePreviewing = false;
        voiceRuntimeReady = false;
        voiceDurationMilliseconds = null;
        lastParentHomeAutoRefreshKey = null;
        showSetupSettings = false;
      });
      Navigator.of(context).popUntil((route) => route.isFirst);
      await assessDevice();
      showActionMessage(
        'All parent, child, and conversation data was deleted.',
      );
    } catch (error) {
      if (mounted) {
        showActionMessage(userFacingError(error, fallback: 'Deletion failed.'));
      }
    }
  }

  Future<void> reviewSavedHistory() async {
    final pin = await requestParentPin('Review saved history');
    if (pin == null) return;
    try {
      final history = await widget.backend.scopedHistory(
        pin,
        kidId: selectedKidCharacterId,
        characterAlias: state.characterName,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => HistoryScreen(
            characterName: state.characterName,
            history: history,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'History access failed. Check the parent PIN.',
        );
      }
    }
  }

  Future<void> deleteSavedHistory() async {
    final confirmed = await confirmAction(
      title: 'Delete saved history?',
      message:
          'This deletes saved conversation history. Current kid and character profiles will stay.',
      confirmLabel: 'Delete history',
      destructive: true,
    );
    if (!confirmed) return;
    final pin = await requestParentPin('Delete saved history?');
    if (pin == null) return;
    try {
      await widget.backend.deleteHistory(pin);
      if (mounted) {
        showActionMessage('Saved conversation history was deleted.');
      }
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(error, fallback: 'History deletion failed.'),
        );
      }
    }
  }

  Future<void> deleteAllConversations() async {
    final confirmed = await confirmAction(
      title: 'Delete all conversations?',
      message:
          'This clears the current chat and deletes saved conversation history for every kid and character. Kid profiles, characters, voices, and settings will stay.',
      confirmLabel: 'Delete conversations',
      destructive: true,
    );
    if (!confirmed) return;
    final pin = await requestParentPin('Delete all conversations?');
    if (pin == null) return;
    try {
      await widget.backend.cancelTurn();
      await widget.platform.cancelSpeech();
      await widget.backend.endSession();
      await widget.backend.deleteHistory(pin);
      if (!mounted) return;
      setState(() {
        latestSpeech = null;
        childMessages = const [];
      });
      showActionMessage('All conversations were deleted.');
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(error, fallback: 'Conversation deletion failed.'),
        );
      }
    }
  }

  Future<void> editCurrentCharacterDetails() async {
    final guidance = TextEditingController(text: parentGuidance.text);
    final childAge = selectedChildAge?.years;
    final personaAge = TextEditingController(
      text: (selectedCharacterPersonaAge ?? childAge ?? 2).toString(),
    );
    final pin = TextEditingController();
    final portalPin = unlockedParentPin;
    final traits = <String>{...selectedTraits};
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: Text('Edit ${state.characterName}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Only this character’s personality and parent guidance are changed here.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Personality'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: approvedCharacterTraits
                        .map(
                          (trait) => FilterChip(
                            label: Text(trait),
                            selected: traits.contains(trait),
                            onSelected: (_) => updateDialog(() {
                              if (!traits.remove(trait)) {
                                traits.add(trait);
                              }
                            }),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: personaAge,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: 'Character play age',
                      helperText:
                          '2${childAge == null ? '+' : '–$childAge'} years old. Defaults to the child’s age.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: guidance,
                    maxLength: 2000,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Parent guidance (optional)',
                      helperText:
                          'Example: Loves gentle puppy jokes and slow pretend-play pauses.',
                    ),
                  ),
                  if (portalPin == null) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 8,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Parent PIN to save changes',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) return;
    final pinText = portalPin ?? pin.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pinText)) {
      setState(() => message = 'Enter the configured parent PIN.');
      return;
    }
    try {
      final age = selectedChildAge;
      if (age == null) {
        setState(() => message = 'Select a kid before editing characters.');
        return;
      }
      final parsedPersonaAge =
          int.tryParse(personaAge.text.trim()) ?? age.years;
      if (parsedPersonaAge < 2 || parsedPersonaAge > age.years) {
        setState(
          () => message =
              'Character play age must be between 2 and ${age.years}.',
        );
        return;
      }
      await widget.backend.configureParentPin(
        pin: pinText,
        ageBand: age.ageBandCode,
        characterAlias: state.characterName,
        characterTraits: traits.toList()..sort(),
        parentGuidance: guidance.text.trim().isEmpty
            ? null
            : guidance.text.trim(),
        retentionDays: retentionDays,
        kidId: selectedKidCharacterId,
      );
      await widget.backend.saveCharacter(
        pin: pinText,
        characterAlias: state.characterName,
        characterTraits: traits.toList()..sort(),
        parentGuidance: guidance.text.trim().isEmpty
            ? null
            : guidance.text.trim(),
        kidId: selectedKidCharacterId,
        personaAgeYears: parsedPersonaAge,
      );
      if (!mounted) return;
      setState(() {
        selectedTraits
          ..clear()
          ..addAll(traits);
        parentGuidance.text = guidance.text.trim();
      });
      showActionMessage('${state.characterName} was updated.');
      await assessDevice();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = userFacingError(
            error,
            fallback: 'Update failed. Check the parent PIN.',
          ),
        );
      }
    }
  }

  Future<void> uploadCharacterPhoto() async {
    final pin = TextEditingController();
    final portalPin = unlockedParentPin;
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Upload photo for ${state.characterName}'),
        content: portalPin == null
            ? TextField(
                controller: pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: const InputDecoration(labelText: 'Parent PIN'),
              )
            : const Text('Choose a photo to store locally for this character.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Choose photo'),
          ),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    final pinText = portalPin ?? pin.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pinText)) {
      setState(() => message = 'Enter the configured parent PIN.');
      return;
    }
    try {
      final picked = await widget.backend.pickCharacterPhoto();
      await widget.backend.saveCharacterPhoto(
        pin: pinText,
        characterAlias: state.characterName,
        photoBytes: picked.bytes,
        photoMime: picked.mime,
      );
      if (!mounted) return;
      await assessDevice();
      if (!mounted) return;
      showActionMessage('Character photo saved locally.');
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(
            error,
            fallback: 'Could not save the character photo.',
          ),
        );
      }
    }
  }

  Future<void> openSettingsMenu() async {
    final parentProfileExists =
        state.step != AppStep.onboarding || characters.isNotEmpty;
    if (parentProfileExists && unlockedParentPin == null) {
      final unlocked = await unlockParentPortal();
      if (!unlocked || !mounted) return;
    }
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => SettingsMenuScreen(
            state: state,
            kids: kids,
            selectedKid: selectedKid,
            selectedChildAge: selectedChildAge,
            characters: characters,
            reasoningProvider: reasoningProvider,
            stationPaired: stationPaired,
            stationBaseUrl: stationBaseUrl,
            voiceEnrolled: voiceEnrolled,
            voiceApproved: voiceApproved,
            voicePreviewed: voicePreviewed,
            voiceRuntimeReady: voiceRuntimeReady,
            voiceDurationMilliseconds: voiceDurationMilliseconds,
            retentionDays: retentionDays,
            configureGeminiKey: configureGeminiKey,
            pairWithStation: pairWithStation,
            clearStationPairing: clearStationPairing,
            selectKid: selectKid,
            addOrEditKid: addOrEditKid,
            uploadKidPhoto: uploadKidPhoto,
            deleteKid: deleteKid,
            selectCharacter: selectCharacter,
            refreshCharacters: refreshCharactersForSettings,
            editCurrentCharacterDetails: editCurrentCharacterDetails,
            addCharacter: addCharacter,
            uploadCharacterPhoto: uploadCharacterPhoto,
            enrollVoice: enrollVoice,
            previewVoice: previewVoice,
            approveVoice: approveVoice,
            removeVoice: removeVoice,
            deleteCurrentCharacter: deleteCurrentCharacter,
            reviewSavedHistory: reviewSavedHistory,
            deleteAllConversations: deleteAllConversations,
            deleteAllLocalData: deleteAllLocalData,
          ),
        ),
      );
    } finally {
      unlockedParentPin = null;
    }
    if (mounted) unawaited(assessDevice());
  }

  Future<List<CharacterConfiguration>> refreshCharactersForSettings() async {
    await assessDevice();
    return characters;
  }

  Future<void> selectKid(String kidId) async {
    final kid = kids.where((candidate) => candidate.id == kidId).firstOrNull;
    if (kid == null) return;
    final age = childAgeFromBirthdate(kid.birthdateIso);
    final changedKid = selectedKidId != kid.id;
    setState(() {
      selectedKidId = kid.id;
      if (age != null) {
        state = AppReducer.reduce(state, AgeSelected(age.ageBand)).state;
      }
      if (changedKid) {
        latestSpeech = null;
        childMessages = const [];
        childInput.clear();
      }
    });
    final scoped = characters
        .where((character) => character.kidId == kid.id)
        .toList();
    if (scoped.isNotEmpty) selectCharacter(scoped.first.alias);
    await assessDevice();
  }

  Future<void> addOrEditKid([KidProfile? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final birthdate = TextEditingController(text: existing?.birthdateIso ?? '');
    final portalPin = unlockedParentPin;
    final pin = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'Add kid' : 'Edit ${existing.name}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 40,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Kid name',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: birthdate,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Birthdate',
                  helperText:
                      'Use YYYY-MM-DD. Age guardrails are derived from this.',
                ),
              ),
              if (portalPin == null) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: pin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(labelText: 'Parent PIN'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    final age = childAgeFromBirthdate(birthdate.text.trim());
    if (age == null) {
      setState(() => message = 'Enter a valid birthdate as YYYY-MM-DD.');
      return;
    }
    final pinText = portalPin ?? pin.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pinText)) {
      setState(() => message = 'Enter the configured parent PIN.');
      return;
    }
    try {
      final kidId =
          existing?.id ?? 'kid-${DateTime.now().microsecondsSinceEpoch}';
      await widget.backend.saveKid(
        pin: pinText,
        kidId: kidId,
        name: name.text.trim(),
        birthdateIso: birthdate.text.trim(),
      );
      selectedKidId = kidId;
      await assessDevice();
      if (!mounted) return;
      showActionMessage('${name.text.trim()} is ready.');
    } catch (error) {
      if (!mounted) return;
      showActionMessage(
        userFacingError(error, fallback: 'Could not save the kid profile.'),
      );
    }
  }

  Future<void> deleteKid(KidProfile kid) async {
    final confirmed = await confirmAction(
      title: 'Delete ${kid.name}?',
      message:
          'This removes ${kid.name}, all characters linked to this kid, and their local settings. This cannot be undone.',
      confirmLabel: 'Delete kid',
      destructive: true,
    );
    if (!confirmed) return;
    final pin = await requestParentPin('Delete ${kid.name}?');
    if (pin == null) return;
    try {
      await widget.backend.deleteKid(pin: pin, kidId: kid.id);
      if (!mounted) return;
      selectedKidId = null;
      await assessDevice();
      if (!mounted) return;
      showActionMessage('${kid.name} was deleted.');
    } catch (error) {
      if (!mounted) return;
      showActionMessage(
        userFacingError(error, fallback: 'Could not delete the kid profile.'),
      );
    }
  }

  Future<void> uploadKidPhoto(KidProfile kid) async {
    final pin = await requestParentPin('Update ${kid.name} photo?');
    if (pin == null) return;
    try {
      final picked = await widget.backend.pickCharacterPhoto();
      await widget.backend.saveKid(
        pin: pin,
        kidId: kid.id,
        name: kid.name,
        birthdateIso: kid.birthdateIso,
        photoBytes: picked.bytes,
        photoMime: picked.mime,
      );
      if (!mounted) return;
      await assessDevice();
      if (!mounted) return;
      showActionMessage('${kid.name} photo saved locally.');
    } catch (error) {
      if (!mounted) return;
      showActionMessage(
        userFacingError(error, fallback: 'Could not save the kid photo.'),
      );
    }
  }

  Future<void> addCharacter() async {
    final name = TextEditingController();
    final guidance = TextEditingController();
    final childAge = selectedChildAge?.years;
    final personaAge = TextEditingController(text: (childAge ?? 2).toString());
    final pin = TextEditingController();
    final portalPin = unlockedParentPin;
    final traits = <String>{'gentle', 'curious'};
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Text('Add Toy Buddy'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    maxLength: 40,
                    decoration: const InputDecoration(labelText: 'Buddy name'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: approvedCharacterTraits
                        .map(
                          (trait) => FilterChip(
                            label: Text(trait),
                            selected: traits.contains(trait),
                            onSelected: (_) => updateDialog(() {
                              if (!traits.remove(trait)) traits.add(trait);
                            }),
                          ),
                        )
                        .toList(),
                  ),
                  TextField(
                    controller: personaAge,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Buddy play age',
                      helperText:
                          '2${childAge == null ? '+' : '–$childAge'} years old. Defaults to the child’s age.',
                    ),
                  ),
                  TextField(
                    controller: guidance,
                    maxLength: 160,
                    decoration: const InputDecoration(
                      labelText: 'Parent guidance (optional)',
                    ),
                  ),
                  if (portalPin == null)
                    TextField(
                      controller: pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 8,
                      decoration: const InputDecoration(
                        labelText: 'Parent PIN',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) return;
    final transition = AppReducer.reduce(state, CharacterNamed(name.text));
    if (transition.error != null) {
      setState(() => message = transition.error);
      return;
    }
    final pinText = portalPin ?? pin.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pinText)) {
      setState(() => message = 'Enter the configured parent PIN.');
      return;
    }
    final age = selectedChildAge;
    if (age == null) {
      setState(() => message = 'Select a kid before adding a buddy.');
      return;
    }
    final parsedPersonaAge = int.tryParse(personaAge.text.trim()) ?? age.years;
    if (parsedPersonaAge < 2 || parsedPersonaAge > age.years) {
      setState(
        () => message = 'Buddy play age must be between 2 and ${age.years}.',
      );
      return;
    }
    try {
      await widget.backend.saveCharacter(
        pin: pinText,
        characterAlias: name.text.trim(),
        characterTraits: traits.toList()..sort(),
        parentGuidance: guidance.text.trim().isEmpty
            ? null
            : guidance.text.trim(),
        kidId: selectedKidCharacterId,
        personaAgeYears: parsedPersonaAge,
      );
      if (!mounted) return;
      await assessDevice();
      if (!mounted) return;
      selectCharacter(name.text.trim());
      final addedVoice = characters
          .where((character) => character.alias == name.text.trim())
          .firstOrNull
          ?.voice;
      showActionMessage(
        addedVoice?.approved == true
            ? 'Toy buddy added with its saved voice.'
            : 'Toy buddy added. Upload a voice sample next.',
      );
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(error, fallback: 'Could not add the toy buddy.'),
        );
      }
    }
  }

  Future<bool> deleteCurrentCharacter() async {
    final character = state.characterName;
    final confirmed = await confirmAction(
      title: 'Delete $character?',
      message:
          'This removes $character from the selected kid. Its local settings and buddy voice may also be removed.',
      confirmLabel: 'Delete buddy',
      destructive: true,
    );
    if (!confirmed) return false;
    final pin = await requestParentPin('Delete ${state.characterName}?');
    if (pin == null) return false;
    try {
      await widget.backend.deleteCharacter(
        pin: pin,
        characterAlias: state.characterName,
        kidId: selectedKidCharacterId,
      );
      if (!mounted) return false;
      final remaining = characters
          .where((character) => character.alias != state.characterName)
          .toList();
      setState(() {
        characters = remaining;
      });
      if (remaining.isNotEmpty) selectCharacter(remaining.first.alias);
      await assessDevice();
      if (mounted) showActionMessage('$character was deleted.');
      return true;
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(
            error,
            fallback: 'Could not delete the character. Check the parent PIN.',
          ),
        );
      }
      return false;
    }
  }

  Future<bool> enrollVoice({String? characterAlias}) async {
    final alias = characterAlias ?? state.characterName;
    if (!stationPaired && !voiceRuntimeReady) {
      setState(
        () => message =
            'Connect the Magic Voice Box before uploading a voice sample.',
      );
      return false;
    }
    if (!voiceRuntimeReady) {
      setState(
        () => message =
            'The Magic Voice Box is connected, but not awake yet. Keep the Mac app open and try again.',
      );
      return false;
    }
    final pin = TextEditingController();
    final portalPin = unlockedParentPin;
    var authorized = false;
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Create buddy voice'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Choose a clean 15-second to 3-minute M4A, WAV, MP3, AAC, OGG, or '
                    'WebM recording. PlushBuddy sends it over the paired local connection '
                    'to the Magic Voice Box to create the buddy voice. Raw upload bytes are '
                    '$_voiceSampleStorageLabel',
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: authorized,
                    onChanged: (value) =>
                        update(() => authorized = value ?? false),
                    title: const Text(
                      'I own this voice or have permission to use it.',
                    ),
                    subtitle: const Text(
                      'Do not enroll a child or another person without authorization.',
                    ),
                  ),
                  if (portalPin == null)
                    TextField(
                      controller: pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 8,
                      decoration: const InputDecoration(
                        labelText: 'Parent PIN',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: authorized ? () => Navigator.pop(context, true) : null,
              child: const Text('Choose audio file'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true || !mounted) return false;
    setState(() {
      voiceEnrolling = true;
      voicePreviewed = false;
      message = 'Sending the voice sample to the Magic Voice Box...';
    });
    try {
      await widget.backend.enrollVoiceSample(
        pin: portalPin ?? pin.text,
        adultAuthorized: authorized,
        characterAlias: alias,
      );
      await assessDevice();
      if (!mounted) return false;
      setState(() {
        voiceEnrolled = true;
        voiceApproved = false;
        voicePreviewed = false;
        updateCurrentCharacterVoice(
          VoiceProfileStatus(
            enrolled: true,
            approved: false,
            runtimeReady: voiceRuntimeReady,
            durationMilliseconds: voiceDurationMilliseconds,
          ),
          characterAlias: alias,
        );
        voiceEnrolling = false;
        voicePreviewing = false;
      });
      showActionMessage(
        'Buddy voice created. Listen and save it only if it sounds right.',
      );
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => voiceEnrolling = false);
        if (error is PlatformException &&
            error.code == 'audio_pick_cancelled' &&
            voiceEnrolled) {
          showActionMessage(
            'No new audio selected. The existing voice profile was kept.',
          );
          return false;
        }
        showActionMessage(
          userFacingError(
            error,
            fallback:
                'Voice enrollment failed. Check the PIN, format, duration, and recording quality.',
          ),
        );
      }
      return false;
    }
  }

  Future<bool> previewVoice({String? characterAlias}) async {
    if (voicePreviewing) return false;
    final alias = characterAlias ?? state.characterName;
    final pin = await requestParentPin('Preview $alias voice clone');
    if (pin == null) return false;
    setState(() {
      voicePreviewing = true;
      voicePreviewed = false;
      message =
          'Generating voice clone preview. This can take 30-90 seconds on the first run.';
    });
    try {
      await widget.backend.previewVoice(pin, characterAlias: alias);
      if (mounted) {
        setState(() {
          voicePreviewing = false;
          voicePreviewed = true;
        });
        showActionMessage(
          'Voice preview finished. Approve only if it sounds like the uploaded sample.',
        );
        return true;
      }
    } catch (error) {
      if (mounted) {
        setState(() => voicePreviewing = false);
        showActionMessage(
          userFacingError(
            error,
            fallback: 'Voice preview failed. Check the local voice model.',
          ),
        );
      }
    }
    return false;
  }

  Future<bool> approveVoice({String? characterAlias}) async {
    final alias = characterAlias ?? state.characterName;
    final pin = await requestParentPin('Approve $alias voice clone?');
    if (pin == null) return false;
    try {
      await widget.backend.approveVoice(pin, characterAlias: alias);
      if (!mounted) return false;
      await assessDevice();
      if (!mounted) return false;
      setState(() {
        voiceApproved = true;
        voicePreviewed = true;
        voiceEnrolling = false;
        voicePreviewing = false;
        updateCurrentCharacterVoice(
          VoiceProfileStatus(
            enrolled: true,
            approved: true,
            runtimeReady: voiceRuntimeReady,
            durationMilliseconds: voiceDurationMilliseconds,
          ),
          characterAlias: alias,
        );
      });
      showActionMessage('Character voice approved for conversations.');
      return true;
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(error, fallback: 'Voice approval failed.'),
        );
      }
    }
    return false;
  }

  Future<bool> removeVoice({String? characterAlias}) async {
    final alias = characterAlias ?? state.characterName;
    final confirmed = await confirmAction(
      title: 'Remove $alias voice?',
      message:
          'This removes the approved voice profile for $alias. You can upload a new sample later.',
      confirmLabel: 'Remove voice',
      destructive: true,
    );
    if (!confirmed) return false;
    final pin = await requestParentPin('Remove $alias voice?');
    if (pin == null) return false;
    try {
      await widget.backend.deleteVoice(pin, characterAlias: alias);
      if (!mounted) return false;
      await assessDevice();
      if (!mounted) return false;
      setState(() {
        voiceEnrolled = false;
        voiceApproved = false;
        voicePreviewed = false;
        voiceEnrolling = false;
        voicePreviewing = false;
        voiceDurationMilliseconds = null;
        updateCurrentCharacterVoice(
          VoiceProfileStatus(
            enrolled: false,
            approved: false,
            runtimeReady: voiceRuntimeReady,
          ),
          characterAlias: alias,
        );
      });
      showActionMessage('Character voice was removed.');
      return true;
    } catch (error) {
      if (mounted) {
        showActionMessage(
          userFacingError(error, fallback: 'Voice deletion failed.'),
        );
      }
    }
    return false;
  }

  void dispatch(AppEvent event) {
    final transition = AppReducer.reduce(state, event);
    setState(() {
      state = transition.state;
      message = transition.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (state.step == AppStep.parentHome &&
        stationPaired &&
        !voiceRuntimeReady) {
      final refreshKey =
          '${stationBaseUrl ?? 'station'}:${state.characterName}';
      if (lastParentHomeAutoRefreshKey != refreshKey) {
        lastParentHomeAutoRefreshKey = refreshKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(assessDevice());
        });
      }
    }
    final child = switch (state.step) {
      AppStep.onboarding => OnboardingScreen(
        state: state,
        message: message,
        showSettings: showSetupSettings,
        openSettings: () => setState(() => showSetupSettings = true),
        closeSettings: () => setState(() => showSetupSettings = false),
        dispatch: dispatch,
        assessDevice: assessDevice,
        installModel: installModel,
        cancelModelInstall: cancelModelInstall,
        installingModel: installingModel,
        modelInstallSupported: modelInstallSupported,
        kidName: kidName,
        kidBirthdate: kidBirthdate,
        characterName: characterName,
        parentGuidance: parentGuidance,
        selectedTraits: selectedTraits,
        toggleTrait: (trait) => setState(() {
          if (!selectedTraits.remove(trait)) selectedTraits.add(trait);
        }),
        retentionDays: retentionDays,
        retentionChanged: (value) => setState(() => retentionDays = value),
        parentPin: parentPin,
        confirmParentPin: confirmParentPin,
        completeOnboarding: completeOnboarding,
        stationPaired: stationPaired,
        stationBaseUrl: stationBaseUrl,
        pairWithStation: pairWithStation,
        clearStationPairing: clearStationPairing,
        configureGeminiKey: configureGeminiKey,
      ),
      AppStep.parentHome => ParentHomeScreen(
        state: state,
        enterChildMode: enterChildMode,
        kids: kids,
        selectedKid: selectedKid,
        selectedChildAge: selectedChildAge,
        selectKid: selectKid,
        characters: kidCharacters,
        selectCharacter: selectCharacter,
        addCharacter: addCharacter,
        clearCurrentConversation: clearCurrentConversation,
        deleteAllLocalData: deleteAllLocalData,
        message: message,
        characterTraits: selectedTraits.toList()..sort(),
        characterPhotoBytes: selectedCharacter?.photoBytes,
        parentGuidance: parentGuidance.text.trim(),
        retentionDays: retentionDays,
        reviewSavedHistory: reviewSavedHistory,
        deleteSavedHistory: deleteSavedHistory,
        editCharacterAndPrivacy: openSettingsMenu,
        voiceEnrolled: voiceEnrolled,
        voiceApproved: voiceApproved,
        voicePreviewed: voicePreviewed,
        voiceEnrolling: voiceEnrolling,
        voicePreviewing: voicePreviewing,
        voiceRuntimeReady: voiceRuntimeReady,
        voiceDurationMilliseconds: voiceDurationMilliseconds,
        enrollVoice: enrollVoice,
        previewVoice: previewVoice,
        approveVoice: approveVoice,
        removeVoice: removeVoice,
        stationPaired: stationPaired,
        stationBaseUrl: stationBaseUrl,
        pairWithStation: pairWithStation,
        clearStationPairing: clearStationPairing,
        configureGeminiKey: configureGeminiKey,
        assessDevice: assessDevice,
      ),
      AppStep.childMode => ChildModeScreen(
        state: state,
        selectedKid: selectedKid,
        selectedChildAge: selectedChildAge,
        dispatch: dispatch,
        characters: kidCharacters,
        selectCharacter: selectCharacter,
        beginLocalTurn: beginLocalTurn,
        beginSpokenTurn: beginSpokenTurn,
        speechAvailable: widget.platform.supportsSpeech,
        latestSpeech: latestSpeech,
        messages: childMessages,
        characterPhotoBytes: selectedCharacter?.photoBytes,
        message: message,
        inputController: childInput,
        exitChildMode: exitChildMode,
      ),
    };
    return SafeArea(child: child);
  }
}

typedef Dispatch = void Function(AppEvent event);

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({
    required this.state,
    required this.message,
    required this.showSettings,
    required this.openSettings,
    required this.closeSettings,
    required this.dispatch,
    required this.assessDevice,
    required this.installModel,
    required this.cancelModelInstall,
    required this.installingModel,
    required this.modelInstallSupported,
    required this.kidName,
    required this.kidBirthdate,
    required this.characterName,
    required this.parentGuidance,
    required this.selectedTraits,
    required this.toggleTrait,
    required this.retentionDays,
    required this.retentionChanged,
    required this.parentPin,
    required this.confirmParentPin,
    required this.completeOnboarding,
    required this.stationPaired,
    required this.stationBaseUrl,
    required this.pairWithStation,
    required this.clearStationPairing,
    required this.configureGeminiKey,
    super.key,
  });

  final AppState state;
  final String? message;
  final bool showSettings;
  final VoidCallback openSettings;
  final VoidCallback closeSettings;
  final Dispatch dispatch;
  final Future<void> Function() assessDevice;
  final Future<void> Function() installModel;
  final Future<void> Function() cancelModelInstall;
  final bool installingModel;
  final bool modelInstallSupported;
  final TextEditingController kidName;
  final TextEditingController kidBirthdate;
  final TextEditingController characterName;
  final TextEditingController parentGuidance;
  final Set<String> selectedTraits;
  final ValueChanged<String> toggleTrait;
  final int? retentionDays;
  final ValueChanged<int?> retentionChanged;
  final TextEditingController parentPin;
  final TextEditingController confirmParentPin;
  final Future<void> Function() completeOnboarding;
  final bool stationPaired;
  final String? stationBaseUrl;
  final Future<void> Function() pairWithStation;
  final Future<void> Function() clearStationPairing;
  final Future<void> Function() configureGeminiKey;

  @override
  Widget build(BuildContext context) {
    if (!showSettings) {
      return Scaffold(
        appBar: AppBar(title: const Text(appDisplayName)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const PlushBuddyLogo(size: 104),
                const SizedBox(height: 16),
                Text(
                  'Welcome to PlushBuddy',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Make toy buddies, give them voices, and let your child jump into pretend play.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Setup checklist',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        _StatusLine(
                          ok:
                              kidName.text.trim().isNotEmpty &&
                              childAgeFromBirthdate(kidBirthdate.text.trim()) !=
                                  null,
                          label:
                              kidName.text.trim().isEmpty ||
                                  childAgeFromBirthdate(
                                        kidBirthdate.text.trim(),
                                      ) ==
                                      null
                              ? 'Add kid name and birthdate'
                              : 'Kid profile started',
                        ),
                        _StatusLine(
                          ok: stationPaired,
                          label: stationPaired
                              ? 'Magic Voice Box connected'
                              : kIsWeb
                              ? 'Open from Station to connect Magic Voice Box'
                              : 'Connect Magic Voice Box',
                        ),
                        _StatusLine(
                          ok: state.recommendation?.installed == true,
                          label: state.recommendation?.installed == true
                              ? 'AI Brain ready'
                              : 'Save Gemini or OpenAI API key',
                        ),
                        _StatusLine(
                          ok: retentionDays != null,
                          label: retentionDays == null
                              ? 'Conversation history: session only'
                              : 'Conversation history configured',
                        ),
                        const _StatusLine(
                          ok: true,
                          label: 'Buddy personalities can be added anytime',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: openSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('Parent Settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Parent Settings'),
        leading: IconButton(
          tooltip: 'Back to welcome',
          onPressed: closeSettings,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Parent Settings',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                kIsWeb
                    ? 'Complete these grown-up steps once. Parent data stays in this browser; the Magic Voice Box is used only for buddy voices.'
                    : 'Complete these grown-up steps once. Parent data stays encrypted on this device; the Magic Voice Box is used only for buddy voices.',
              ),
              const SizedBox(height: 24),
              _SettingsCard(
                icon: Icons.lock,
                title: 'Parent lock',
                status:
                    kidName.text.trim().isNotEmpty &&
                        childAgeFromBirthdate(kidBirthdate.text.trim()) !=
                            null &&
                        parentPin.text.isNotEmpty
                    ? 'Ready'
                    : 'Required',
                complete:
                    kidName.text.trim().isNotEmpty &&
                    childAgeFromBirthdate(kidBirthdate.text.trim()) != null &&
                    parentPin.text.isNotEmpty,
                children: [
                  TextField(
                    controller: kidName,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Kid name',
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: kidBirthdate,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Birthdate',
                      helperText:
                          'Use YYYY-MM-DD. PlushBuddy derives age guardrails from this.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: parentPin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Create parent PIN (4-8 digits)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmParentPin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Confirm parent PIN',
                    ),
                  ),
                ],
              ),
              _SettingsCard(
                icon: Icons.psychology,
                title: 'AI Brain',
                status: state.recommendation?.installed == true
                    ? 'Ready'
                    : 'Required',
                complete: state.recommendation?.installed == true,
                children: [
                  Text(
                    state.recommendation?.displayName ??
                        'Save a Gemini or OpenAI API key for PlushBuddy.',
                  ),
                  const SizedBox(height: 12),
                  if (state.recommendation == null)
                    FilledButton.tonal(
                      onPressed: assessDevice,
                      child: const Text('Check AI Brain'),
                    )
                  else if (state.recommendation!.installed)
                    const _StatusLine(ok: true, label: 'AI Brain is ready')
                  else if (installingModel) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: cancelModelInstall,
                      child: const Text('Cancel model download'),
                    ),
                  ] else ...[
                    const Text(
                      'No AI Brain is ready yet. Configure Gemini or OpenAI now, or install a local model later.',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: configureGeminiKey,
                          icon: const Icon(Icons.key),
                          label: const Text('Save API key'),
                        ),
                        if (modelInstallSupported)
                          FilledButton.tonal(
                            onPressed: installModel,
                            child: const Text('Install local model'),
                          ),
                        TextButton(
                          onPressed: assessDevice,
                          child: const Text('Check again'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              _SettingsCard(
                icon: Icons.computer,
                title: 'Magic Voice Box',
                status: stationPaired ? 'Paired' : 'Not paired',
                complete: stationPaired,
                children: [
                  Text(
                    stationPaired
                        ? 'Connected to ${stationBaseUrl ?? 'the Magic Voice Box'}'
                        : kIsWeb
                        ? 'Open this browser or Mac app from PlushBuddy Station. It connects automatically.'
                        : 'Use the Mac only for buddy voices and toy audio.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: pairWithStation,
                        icon: Icon(kIsWeb ? Icons.sync : Icons.qr_code_2),
                        label: Text(
                          kIsWeb
                              ? 'Check Voice Box'
                              : stationPaired
                              ? 'Reconnect Voice Box'
                              : 'Connect Voice Box',
                        ),
                      ),
                      if (stationPaired && !kIsWeb)
                        TextButton(
                          onPressed: clearStationPairing,
                          child: const Text('Disconnect'),
                        ),
                    ],
                  ),
                ],
              ),
              _SettingsCard(
                icon: Icons.history,
                title: 'Conversation history',
                status: retentionDays == null ? 'Session only' : 'Encrypted',
                complete: true,
                children: [
                  DropdownButtonFormField<int?>(
                    initialValue: retentionDays,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Conversation history',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: null,
                        child: Text('Session only'),
                      ),
                      DropdownMenuItem(
                        value: 1,
                        child: Text('Keep encrypted for 1 day'),
                      ),
                      DropdownMenuItem(
                        value: 7,
                        child: Text('Keep encrypted for 7 days'),
                      ),
                      DropdownMenuItem(
                        value: 30,
                        child: Text('Keep encrypted for 30 days'),
                      ),
                    ],
                    onChanged: retentionChanged,
                  ),
                ],
              ),
              _SettingsCard(
                icon: Icons.pets,
                title: 'First character',
                status: characterName.text.trim().isEmpty
                    ? 'Required'
                    : characterName.text.trim(),
                complete: characterName.text.trim().isNotEmpty,
                children: [
                  TextField(
                    controller: characterName,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Character name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Character personality'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: approvedCharacterTraits
                        .map(
                          (trait) => FilterChip(
                            label: Text(trait),
                            selected: selectedTraits.contains(trait),
                            onSelected: (_) => toggleTrait(trait),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: parentGuidance,
                    maxLength: 2000,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Parent guidance (optional)',
                      helperText:
                          'Example: Enjoys simple science and animal stories.',
                    ),
                  ),
                ],
              ),
              if (message != null) ...[
                const SizedBox(height: 12),
                Text(
                  message!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: completeOnboarding,
                child: const Text('Continue to parent home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StationQrScannerScreen extends StatefulWidget {
  const StationQrScannerScreen({super.key});

  @override
  State<StationQrScannerScreen> createState() => _StationQrScannerScreenState();
}

class _StationQrScannerScreenState extends State<StationQrScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool completed = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _handleDetection(BarcodeCapture capture) {
    if (completed) return;
    final value = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    if (value == null) return;
    if (!value.startsWith('http://') || !value.contains('#bootstrap=')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That is not a PlushBuddy Station pairing QR code.'),
        ),
      );
      return;
    }
    completed = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan Voice Box QR')),
    body: Stack(
      children: [
        MobileScanner(controller: controller, onDetect: _handleDetection),
        Align(
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Point the camera at the QR code shown by PlushBuddy on the Mac.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    ),
  );
}

class ParentHomeScreen extends StatelessWidget {
  const ParentHomeScreen({
    required this.state,
    required this.enterChildMode,
    required this.kids,
    required this.selectedKid,
    required this.selectedChildAge,
    required this.selectKid,
    required this.characters,
    required this.selectCharacter,
    required this.addCharacter,
    required this.clearCurrentConversation,
    required this.deleteAllLocalData,
    required this.message,
    required this.characterTraits,
    required this.characterPhotoBytes,
    required this.parentGuidance,
    required this.retentionDays,
    required this.reviewSavedHistory,
    required this.deleteSavedHistory,
    required this.editCharacterAndPrivacy,
    required this.voiceEnrolled,
    required this.voiceApproved,
    required this.voicePreviewed,
    required this.voiceEnrolling,
    required this.voicePreviewing,
    required this.voiceRuntimeReady,
    required this.voiceDurationMilliseconds,
    required this.enrollVoice,
    required this.previewVoice,
    required this.approveVoice,
    required this.removeVoice,
    required this.stationPaired,
    required this.stationBaseUrl,
    required this.pairWithStation,
    required this.clearStationPairing,
    required this.configureGeminiKey,
    required this.assessDevice,
    super.key,
  });
  final AppState state;
  final Future<void> Function() enterChildMode;
  final List<KidProfile> kids;
  final KidProfile? selectedKid;
  final ChildAgeDetails? selectedChildAge;
  final Future<void> Function(String kidId) selectKid;
  final List<CharacterConfiguration> characters;
  final void Function(String alias) selectCharacter;
  final Future<void> Function() addCharacter;
  final Future<void> Function() clearCurrentConversation;
  final Future<void> Function() deleteAllLocalData;
  final String? message;
  final List<String> characterTraits;
  final Uint8List? characterPhotoBytes;
  final String parentGuidance;
  final int? retentionDays;
  final Future<void> Function() reviewSavedHistory;
  final Future<void> Function() deleteSavedHistory;
  final Future<void> Function() editCharacterAndPrivacy;
  final bool voiceEnrolled;
  final bool voiceApproved;
  final bool voicePreviewed;
  final bool voiceEnrolling;
  final bool voicePreviewing;
  final bool voiceRuntimeReady;
  final int? voiceDurationMilliseconds;
  final CharacterVoiceAction enrollVoice;
  final CharacterVoiceAction previewVoice;
  final CharacterVoiceAction approveVoice;
  final CharacterVoiceAction removeVoice;
  final bool stationPaired;
  final String? stationBaseUrl;
  final Future<void> Function() pairWithStation;
  final Future<void> Function() clearStationPairing;
  final Future<void> Function() configureGeminiKey;
  final Future<void> Function() assessDevice;

  @override
  Widget build(BuildContext context) {
    final reasoningReady = state.recommendation?.installed == true;
    final childModeReady =
        selectedKid != null &&
        reasoningReady &&
        voiceRuntimeReady &&
        voiceApproved;
    final activeCharacter = characters
        .where((character) => character.alias == state.characterName)
        .firstOrNull;
    final activePhotoBytes = activeCharacter?.photoBytes ?? characterPhotoBytes;
    final activeTraits = activeCharacter?.traits ?? characterTraits;
    final setupLabel = childModeReady
        ? 'Ready to play'
        : selectedKid == null
        ? 'Add your kid'
        : !reasoningReady
        ? 'Connect the AI Brain'
        : !stationPaired
        ? 'Connect the Magic Voice Box'
        : !voiceRuntimeReady
        ? 'Wake up the Magic Voice Box'
        : !voiceEnrolled
        ? 'Make ${state.characterName} sound magical'
        : !voicePreviewed
        ? 'Listen to ${state.characterName}'
        : !voiceApproved
        ? 'Save ${state.characterName}’s voice'
        : 'Almost ready';
    final setupActionLabel = childModeReady
        ? null
        : selectedKid == null
        ? 'Add kid'
        : !reasoningReady
        ? 'Set up AI Brain'
        : !stationPaired
        ? kIsWeb
              ? 'Check Voice Box'
              : 'Pair Voice Box'
        : !voiceRuntimeReady
        ? 'Check Voice Box'
        : !voiceEnrolled
        ? 'Create buddy voice'
        : !voicePreviewed
        ? 'Preview buddy voice'
        : !voiceApproved
        ? 'Approve buddy voice'
        : 'Open Settings';
    final Future<void> Function()? setupAction = childModeReady
        ? null
        : !reasoningReady
        ? configureGeminiKey
        : !stationPaired
        ? pairWithStation
        : !voiceRuntimeReady
        ? assessDevice
        : editCharacterAndPrivacy;
    final readinessIcon = childModeReady
        ? Icons.check_circle
        : !reasoningReady
        ? Icons.key
        : !stationPaired
        ? kIsWeb
              ? Icons.sync
              : Icons.qr_code_2
        : !voiceRuntimeReady
        ? Icons.refresh
        : !voiceEnrolled
        ? Icons.graphic_eq
        : !voicePreviewed
        ? Icons.play_circle_outline
        : !voiceApproved
        ? Icons.verified
        : Icons.settings;
    final colorScheme = Theme.of(context).colorScheme;
    final readinessColor = childModeReady
        ? const Color(0xff16a34a)
        : colorScheme.primary;
    final kidLabel = selectedKid == null
        ? 'No kid selected yet'
        : '${selectedKid!.name}${selectedChildAge == null ? '' : ' • ${selectedChildAge!.label}'}';
    final compactHome = MediaQuery.sizeOf(context).height < 720;
    final buddyImageSize = compactHome ? 76.0 : 132.0;
    final buddyLogoSize = compactHome ? 70.0 : 104.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text(appDisplayName),
        actions: [
          IconButton(
            tooltip: 'Parent Settings',
            onPressed: editCharacterAndPrivacy,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Card(
                color: const Color(0xfffff0f7),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    22,
                    compactHome ? 14 : 24,
                    22,
                    compactHome ? 14 : 22,
                  ),
                  child: Column(
                    children: [
                      if (activePhotoBytes == null)
                        PlushBuddyLogo(size: buddyLogoSize)
                      else
                        ClipRRect(
                          borderRadius: BorderRadius.circular(
                            compactHome ? 24 : 36,
                          ),
                          child: Image.memory(
                            activePhotoBytes,
                            width: buddyImageSize,
                            height: buddyImageSize,
                            fit: BoxFit.cover,
                          ),
                        ),
                      SizedBox(height: compactHome ? 10 : 18),
                      Text(
                        childModeReady
                            ? 'Ready for pretend play'
                            : 'Almost ready',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: readinessColor,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: compactHome ? 2 : 6),
                      Text(
                        state.characterName,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontSize: compactHome ? 26 : 34),
                      ),
                      if (!compactHome) ...[
                        const SizedBox(height: 8),
                        Text(
                          activeTraits.isEmpty
                              ? 'A little buddy for stories, giggles, and questions.'
                              : activeTraits.join(' • '),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                      if (!compactHome && parentGuidance.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          parentGuidance,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                      SizedBox(height: compactHome ? 8 : 16),
                      Chip(
                        avatar: Icon(
                          readinessIcon,
                          size: 18,
                          color: readinessColor,
                        ),
                        label: Text(setupLabel),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (kids.isNotEmpty || characters.length > 1)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        if (kids.isNotEmpty) ...[
                          DropdownButtonFormField<String>(
                            initialValue: selectedKid?.id,
                            decoration: const InputDecoration(
                              labelText: 'Playing as',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.child_care),
                            ),
                            items: kids
                                .map(
                                  (kid) => DropdownMenuItem(
                                    value: kid.id,
                                    child: Text(
                                      '${kid.name}${selectedChildAge == null ? '' : ' • ${selectedChildAge!.label}'}',
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) selectKid(value);
                            },
                          ),
                          if (characters.length > 1) const SizedBox(height: 12),
                        ],
                        if (characters.length > 1)
                          DropdownButtonFormField<String>(
                            initialValue: state.characterName,
                            decoration: const InputDecoration(
                              labelText: 'Toy buddy',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.toys),
                            ),
                            items: characters
                                .map(
                                  (character) => DropdownMenuItem(
                                    value: character.alias,
                                    child: Text(character.alias),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) selectCharacter(value);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: childModeReady ? enterChildMode : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(58),
                  textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Start Playing'),
              ),
              if (!childModeReady) ...[
                const SizedBox(height: 14),
                Card(
                  color: colorScheme.surfaceContainerLowest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Finish the magic setup',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Just a few grown-up steps before playtime.',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        _PlaySetupStep(
                          complete: selectedKid != null,
                          label: selectedKid == null ? 'Add a kid' : kidLabel,
                        ),
                        _PlaySetupStep(
                          complete: reasoningReady,
                          label: reasoningReady
                              ? 'AI Brain is ready'
                              : 'Connect the AI Brain',
                        ),
                        _PlaySetupStep(
                          complete: stationPaired && voiceRuntimeReady,
                          label: stationPaired && voiceRuntimeReady
                              ? 'Magic Voice Box is awake'
                              : 'Connect the Magic Voice Box',
                        ),
                        _PlaySetupStep(
                          complete: voiceApproved,
                          label: voiceApproved
                              ? '${state.characterName} has a buddy voice'
                              : 'Create ${state.characterName}’s buddy voice',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed:
                              setupAction == null ||
                                  voiceEnrolling ||
                                  voicePreviewing
                              ? null
                              : () => unawaited(setupAction()),
                          icon: Icon(readinessIcon),
                          label: Text(setupActionLabel ?? 'Open Settings'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (voiceEnrolling || voicePreviewing) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
              if (message != null) ...[
                const SizedBox(height: 16),
                Text(message!, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaySetupStep extends StatelessWidget {
  const _PlaySetupStep({required this.complete, required this.label});

  final bool complete;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: complete ? const Color(0xff16a34a) : colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: complete
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant,
                fontWeight: complete ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsMenuScreen extends StatelessWidget {
  const SettingsMenuScreen({
    required this.state,
    required this.kids,
    required this.selectedKid,
    required this.selectedChildAge,
    required this.characters,
    required this.reasoningProvider,
    required this.stationPaired,
    required this.stationBaseUrl,
    required this.voiceEnrolled,
    required this.voiceApproved,
    required this.voicePreviewed,
    required this.voiceRuntimeReady,
    required this.voiceDurationMilliseconds,
    required this.retentionDays,
    required this.configureGeminiKey,
    required this.pairWithStation,
    required this.clearStationPairing,
    required this.selectKid,
    required this.addOrEditKid,
    required this.uploadKidPhoto,
    required this.deleteKid,
    required this.selectCharacter,
    required this.refreshCharacters,
    required this.editCurrentCharacterDetails,
    required this.addCharacter,
    required this.uploadCharacterPhoto,
    required this.enrollVoice,
    required this.previewVoice,
    required this.approveVoice,
    required this.removeVoice,
    required this.deleteCurrentCharacter,
    required this.reviewSavedHistory,
    required this.deleteAllConversations,
    required this.deleteAllLocalData,
    super.key,
  });

  final AppState state;
  final List<KidProfile> kids;
  final KidProfile? selectedKid;
  final ChildAgeDetails? selectedChildAge;
  final List<CharacterConfiguration> characters;
  final ReasoningProviderStatus reasoningProvider;
  final bool stationPaired;
  final String? stationBaseUrl;
  final bool voiceEnrolled;
  final bool voiceApproved;
  final bool voicePreviewed;
  final bool voiceRuntimeReady;
  final int? voiceDurationMilliseconds;
  final int? retentionDays;
  final Future<void> Function() configureGeminiKey;
  final Future<void> Function() pairWithStation;
  final Future<void> Function() clearStationPairing;
  final Future<void> Function(String kidId) selectKid;
  final Future<void> Function([KidProfile? existing]) addOrEditKid;
  final Future<void> Function(KidProfile kid) uploadKidPhoto;
  final Future<void> Function(KidProfile kid) deleteKid;
  final void Function(String alias) selectCharacter;
  final Future<List<CharacterConfiguration>> Function() refreshCharacters;
  final Future<void> Function() editCurrentCharacterDetails;
  final Future<void> Function() addCharacter;
  final Future<void> Function() uploadCharacterPhoto;
  final CharacterVoiceAction enrollVoice;
  final CharacterVoiceAction previewVoice;
  final CharacterVoiceAction approveVoice;
  final CharacterVoiceAction removeVoice;
  final Future<bool> Function() deleteCurrentCharacter;
  final Future<void> Function() reviewSavedHistory;
  final Future<void> Function() deleteAllConversations;
  final Future<void> Function() deleteAllLocalData;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final reasoningReady = state.recommendation?.installed == true;
    final totalMappedCharacters = characters
        .where(
          (character) => character.kidId != null && character.kidId!.isNotEmpty,
        )
        .length;
    final voiceSummary = voiceApproved
        ? 'Buddy voice ready'
        : voiceEnrolled
        ? 'Listen and save needed'
        : 'Needs a voice sample';
    return Scaffold(
      appBar: AppBar(title: const Text('Parent Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsGroup(
            title: 'Get ready',
            children: [
              _SettingsTile(
                icon: Icons.lock,
                title: 'Parent lock',
                subtitle: reasoningReady
                    ? 'PIN saved • AI Brain ready'
                    : 'PIN saved • AI Brain needs setup',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(
                  context,
                  _ParentSetupSettingsScreen(
                    reasoningReady: reasoningReady,
                    reasoningProvider: reasoningProvider,
                    configureGeminiKey: configureGeminiKey,
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.computer,
                title: 'Magic Voice Box',
                subtitle: stationPaired
                    ? 'Connected to the Mac voice helper.'
                    : kIsWeb
                    ? 'Opens from Station and connects automatically.'
                    : 'Scan the QR code from the Mac app.',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(
                  context,
                  _MacStationSettingsScreen(
                    stationPaired: stationPaired,
                    stationBaseUrl: stationBaseUrl,
                    pairWithStation: pairWithStation,
                    clearStationPairing: clearStationPairing,
                  ),
                ),
              ),
            ],
          ),
          _SettingsGroup(
            title: 'Family & buddies',
            children: [
              _SettingsTile(
                icon: Icons.child_care,
                title: 'Kids & Toy Buddies',
                subtitle:
                    '${kids.length}/4 kids • $totalMappedCharacters buddies',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(
                  context,
                  _KidsSettingsScreen(
                    state: state,
                    kids: kids,
                    selectedKid: selectedKid,
                    characters: characters,
                    voiceSummary: voiceSummary,
                    voiceEnrolled: voiceEnrolled,
                    voiceApproved: voiceApproved,
                    voicePreviewed: voicePreviewed,
                    voiceRuntimeReady: voiceRuntimeReady,
                    voiceDurationMilliseconds: voiceDurationMilliseconds,
                    retentionDays: retentionDays,
                    selectKid: selectKid,
                    addOrEditKid: addOrEditKid,
                    uploadKidPhoto: uploadKidPhoto,
                    deleteKid: deleteKid,
                    selectCharacter: selectCharacter,
                    refreshCharacters: refreshCharacters,
                    editCurrentCharacterDetails: editCurrentCharacterDetails,
                    addCharacter: addCharacter,
                    uploadCharacterPhoto: uploadCharacterPhoto,
                    enrollVoice: enrollVoice,
                    previewVoice: previewVoice,
                    approveVoice: approveVoice,
                    removeVoice: removeVoice,
                    deleteCurrentCharacter: deleteCurrentCharacter,
                    reviewSavedHistory: reviewSavedHistory,
                  ),
                ),
              ),
            ],
          ),
          _SettingsGroup(
            title: 'Privacy & cleanup',
            children: [
              _SettingsTile(
                icon: Icons.delete_sweep,
                title: 'Clear all conversations',
                subtitle:
                    'Clear current chats and saved history for every kid and buddy.',
                onTap: deleteAllConversations,
              ),
              _SettingsTile(
                icon: Icons.delete_forever,
                title: 'Delete everything on $_thisClientLabel',
                subtitle:
                    'Erase local parent, kid, buddy, history, and pairing data.',
                onTap: deleteAllLocalData,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SettingsStatusSummary(
            reasoningReady: reasoningReady,
            stationPaired: stationPaired,
            voiceRuntimeReady: voiceRuntimeReady,
            voiceApproved: voiceApproved,
          ),
        ],
      ),
    );
  }
}

class _ParentSetupSettingsScreen extends StatelessWidget {
  const _ParentSetupSettingsScreen({
    required this.reasoningReady,
    required this.reasoningProvider,
    required this.configureGeminiKey,
  });

  final bool reasoningReady;
  final ReasoningProviderStatus reasoningProvider;
  final Future<void> Function() configureGeminiKey;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Parent lock & AI Brain')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsGroup(
          title: 'Parent lock',
          children: const [
            _SettingsTile(
              icon: Icons.lock,
              title: 'Parent PIN',
              subtitle:
                  'Needed only for Parent Settings and important cleanup.',
              trailing: Icon(Icons.check_circle, color: Colors.green),
            ),
          ],
        ),
        _SettingsGroup(
          title: 'AI Brain',
          children: [
            _SettingsTile(
              icon: Icons.psychology,
              title: '${reasoningProvider.displayName} AI Brain',
              subtitle: reasoningReady
                  ? 'Ready for curious questions.'
                  : 'Save a Gemini or OpenAI API key for conversations.',
              trailing: reasoningReady
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.chevron_right),
              onTap: configureGeminiKey,
            ),
          ],
        ),
      ],
    ),
  );
}

class _MacStationSettingsScreen extends StatelessWidget {
  const _MacStationSettingsScreen({
    required this.stationPaired,
    required this.stationBaseUrl,
    required this.pairWithStation,
    required this.clearStationPairing,
  });

  final bool stationPaired;
  final String? stationBaseUrl;
  final Future<void> Function() pairWithStation;
  final Future<void> Function() clearStationPairing;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Magic Voice Box')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsGroup(
          title: 'Connect',
          children: [
            _SettingsTile(
              icon: Icons.computer,
              title: stationPaired
                  ? 'Voice Box connected'
                  : kIsWeb
                  ? 'Check Voice Box'
                  : 'Connect Voice Box',
              subtitle: stationPaired
                  ? 'Your Mac is ready to make buddy voices.'
                  : kIsWeb
                  ? 'Open this browser or Mac app from PlushBuddy Station. No QR scan is needed on this Mac.'
                  : 'Open PlushBuddy on the phone and scan the QR code from Station.',
              trailing: stationPaired
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : Icon(kIsWeb ? Icons.sync : Icons.qr_code_2),
              onTap: pairWithStation,
            ),
            if (stationPaired && !kIsWeb)
              _SettingsTile(
                icon: Icons.link_off,
                title: 'Forget Voice Box',
                subtitle: 'Remove this client’s connection.',
                onTap: clearStationPairing,
              ),
          ],
        ),
      ],
    ),
  );
}

class _KidsSettingsScreen extends StatelessWidget {
  const _KidsSettingsScreen({
    required this.state,
    required this.kids,
    required this.selectedKid,
    required this.characters,
    required this.voiceSummary,
    required this.voiceEnrolled,
    required this.voiceApproved,
    required this.voicePreviewed,
    required this.voiceRuntimeReady,
    required this.voiceDurationMilliseconds,
    required this.retentionDays,
    required this.selectKid,
    required this.addOrEditKid,
    required this.uploadKidPhoto,
    required this.deleteKid,
    required this.selectCharacter,
    required this.refreshCharacters,
    required this.editCurrentCharacterDetails,
    required this.addCharacter,
    required this.uploadCharacterPhoto,
    required this.enrollVoice,
    required this.previewVoice,
    required this.approveVoice,
    required this.removeVoice,
    required this.deleteCurrentCharacter,
    required this.reviewSavedHistory,
  });

  final AppState state;
  final List<KidProfile> kids;
  final KidProfile? selectedKid;
  final List<CharacterConfiguration> characters;
  final String voiceSummary;
  final bool voiceEnrolled;
  final bool voiceApproved;
  final bool voicePreviewed;
  final bool voiceRuntimeReady;
  final int? voiceDurationMilliseconds;
  final int? retentionDays;
  final Future<void> Function(String kidId) selectKid;
  final Future<void> Function([KidProfile? existing]) addOrEditKid;
  final Future<void> Function(KidProfile kid) uploadKidPhoto;
  final Future<void> Function(KidProfile kid) deleteKid;
  final void Function(String alias) selectCharacter;
  final Future<List<CharacterConfiguration>> Function() refreshCharacters;
  final Future<void> Function() editCurrentCharacterDetails;
  final Future<void> Function() addCharacter;
  final Future<void> Function() uploadCharacterPhoto;
  final CharacterVoiceAction enrollVoice;
  final CharacterVoiceAction previewVoice;
  final CharacterVoiceAction approveVoice;
  final CharacterVoiceAction removeVoice;
  final Future<bool> Function() deleteCurrentCharacter;
  final Future<void> Function() reviewSavedHistory;

  List<CharacterConfiguration> charactersForKid(KidProfile kid) => characters
      .where(
        (character) =>
            character.kidId == kid.id ||
            (selectedKid?.id == kid.id &&
                (character.kidId == null || character.kidId!.isEmpty)),
      )
      .toList();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kids & Toy Buddies')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsGroup(
          title: 'Kids',
          children: [
            if (kids.isEmpty)
              const _SettingsTile(
                icon: Icons.child_care,
                title: 'No kids yet',
                subtitle: 'Add a kid, then make their toy buddies.',
              ),
            for (final kid in kids)
              _SettingsTile(
                icon: Icons.child_care,
                title: kid.name,
                subtitle:
                    '${childAgeFromBirthdate(kid.birthdateIso)?.label ?? kid.birthdateIso} • ${charactersForKid(kid).length}/3 buddies${selectedKid?.id == kid.id ? ' • playing now' : ''}',
                trailing: selectedKid?.id == kid.id
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : const Icon(Icons.chevron_right),
                onTap: () async {
                  await selectKid(kid.id);
                  if (context.mounted) {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => _KidDetailSettingsScreen(
                          state: state,
                          kid: kid,
                          characters: charactersForKid(kid),
                          voiceSummary: voiceSummary,
                          voiceEnrolled: voiceEnrolled,
                          voiceApproved: voiceApproved,
                          voicePreviewed: voicePreviewed,
                          voiceRuntimeReady: voiceRuntimeReady,
                          voiceDurationMilliseconds: voiceDurationMilliseconds,
                          retentionDays: retentionDays,
                          addOrEditKid: addOrEditKid,
                          uploadKidPhoto: uploadKidPhoto,
                          deleteKid: deleteKid,
                          selectCharacter: selectCharacter,
                          refreshCharacters: refreshCharacters,
                          editCurrentCharacterDetails:
                              editCurrentCharacterDetails,
                          addCharacter: addCharacter,
                          uploadCharacterPhoto: uploadCharacterPhoto,
                          enrollVoice: enrollVoice,
                          previewVoice: previewVoice,
                          approveVoice: approveVoice,
                          removeVoice: removeVoice,
                          deleteCurrentCharacter: deleteCurrentCharacter,
                          reviewSavedHistory: reviewSavedHistory,
                        ),
                      ),
                    );
                  }
                },
              ),
            if (kids.length < 4)
              _SettingsTile(
                icon: Icons.add,
                title: 'Add kid',
                subtitle: 'Up to 4 kids can have their own buddies.',
                onTap: () => addOrEditKid(),
              ),
          ],
        ),
      ],
    ),
  );
}

class _KidDetailSettingsScreen extends StatefulWidget {
  const _KidDetailSettingsScreen({
    required this.state,
    required this.kid,
    required this.characters,
    required this.voiceSummary,
    required this.voiceEnrolled,
    required this.voiceApproved,
    required this.voicePreviewed,
    required this.voiceRuntimeReady,
    required this.voiceDurationMilliseconds,
    required this.retentionDays,
    required this.addOrEditKid,
    required this.uploadKidPhoto,
    required this.deleteKid,
    required this.selectCharacter,
    required this.refreshCharacters,
    required this.editCurrentCharacterDetails,
    required this.addCharacter,
    required this.uploadCharacterPhoto,
    required this.enrollVoice,
    required this.previewVoice,
    required this.approveVoice,
    required this.removeVoice,
    required this.deleteCurrentCharacter,
    required this.reviewSavedHistory,
  });

  final AppState state;
  final KidProfile kid;
  final List<CharacterConfiguration> characters;
  final String voiceSummary;
  final bool voiceEnrolled;
  final bool voiceApproved;
  final bool voicePreviewed;
  final bool voiceRuntimeReady;
  final int? voiceDurationMilliseconds;
  final int? retentionDays;
  final Future<void> Function([KidProfile? existing]) addOrEditKid;
  final Future<void> Function(KidProfile kid) uploadKidPhoto;
  final Future<void> Function(KidProfile kid) deleteKid;
  final void Function(String alias) selectCharacter;
  final Future<List<CharacterConfiguration>> Function() refreshCharacters;
  final Future<void> Function() editCurrentCharacterDetails;
  final Future<void> Function() addCharacter;
  final Future<void> Function() uploadCharacterPhoto;
  final CharacterVoiceAction enrollVoice;
  final CharacterVoiceAction previewVoice;
  final CharacterVoiceAction approveVoice;
  final CharacterVoiceAction removeVoice;
  final Future<bool> Function() deleteCurrentCharacter;
  final Future<void> Function() reviewSavedHistory;

  @override
  State<_KidDetailSettingsScreen> createState() =>
      _KidDetailSettingsScreenState();
}

class _KidDetailSettingsScreenState extends State<_KidDetailSettingsScreen> {
  late List<CharacterConfiguration> characters = widget.characters;

  List<CharacterConfiguration> charactersForKid(
    List<CharacterConfiguration> allCharacters,
  ) => allCharacters
      .where(
        (character) =>
            character.kidId == widget.kid.id ||
            character.kidId == null ||
            character.kidId!.isEmpty,
      )
      .toList();

  Future<void> refresh() async {
    final updated = await widget.refreshCharacters();
    if (mounted) setState(() => characters = charactersForKid(updated));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.kid.name)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsGroup(
          title: 'Kid profile',
          children: [
            _SettingsTile(
              icon: Icons.cake,
              title: 'Birthdate',
              subtitle:
                  '${widget.kid.birthdateIso} • ${childAgeFromBirthdate(widget.kid.birthdateIso)?.label ?? 'age unknown'}',
              onTap: () => widget.addOrEditKid(widget.kid),
            ),
            _SettingsTile(
              icon: Icons.edit,
              title: 'Name and birthday',
              subtitle: 'Update this kid profile.',
              onTap: () => widget.addOrEditKid(widget.kid),
            ),
            _SettingsTile(
              icon: Icons.photo_camera,
              title: 'Photo',
              subtitle: widget.kid.photoBytes == null
                  ? 'Add a kid photo.'
                  : 'Replace this kid photo.',
              onTap: () => widget.uploadKidPhoto(widget.kid),
            ),
          ],
        ),
        _SettingsGroup(
          title: '${widget.kid.name}’s Toy Buddies',
          children: [
            if (characters.isEmpty)
              const _SettingsTile(
                icon: Icons.toys,
                title: 'No buddies yet',
                subtitle: 'Create a toy buddy for this kid.',
              ),
            for (final character in characters)
              _SettingsTile(
                icon: Icons.toys,
                title: character.alias,
                subtitle: character.voice.approved
                    ? 'Buddy voice ready'
                    : character.voice.enrolled
                    ? 'Listen and save the voice'
                    : 'Needs a buddy voice',
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  widget.selectCharacter(character.alias);
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => _CharacterDetailSettingsScreen(
                        character: character,
                        voiceSummary: widget.voiceSummary,
                        voiceEnrolled: widget.voiceEnrolled,
                        voiceApproved: widget.voiceApproved,
                        voicePreviewed: widget.voicePreviewed,
                        voiceRuntimeReady: widget.voiceRuntimeReady,
                        voiceDurationMilliseconds:
                            widget.voiceDurationMilliseconds,
                        retentionDays: widget.retentionDays,
                        editCurrentCharacterDetails:
                            widget.editCurrentCharacterDetails,
                        uploadCharacterPhoto: widget.uploadCharacterPhoto,
                        enrollVoice: widget.enrollVoice,
                        previewVoice: widget.previewVoice,
                        approveVoice: widget.approveVoice,
                        removeVoice: widget.removeVoice,
                        deleteCurrentCharacter: widget.deleteCurrentCharacter,
                        reviewSavedHistory: widget.reviewSavedHistory,
                      ),
                    ),
                  );
                  await refresh();
                },
              ),
            if (characters.length < 3)
              _SettingsTile(
                icon: Icons.add,
                title: 'Add Toy Buddy',
                subtitle:
                    'Make a new buddy for ${widget.kid.name}. Each kid can have up to 3.',
                onTap: () async {
                  await widget.addCharacter();
                  await refresh();
                },
              ),
            if (characters.length >= 3)
              const _SettingsTile(
                icon: Icons.info_outline,
                title: 'Buddy limit reached',
                subtitle: 'Each kid can have up to 3 toy buddies.',
              ),
          ],
        ),
        _SettingsGroup(
          title: 'Careful actions',
          children: [
            _SettingsTile(
              icon: Icons.delete_forever,
              title: 'Delete kid profile',
              subtitle: 'Also removes buddies linked to this kid.',
              onTap: () async {
                await widget.deleteKid(widget.kid);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _CharactersSettingsScreen extends StatefulWidget {
  const _CharactersSettingsScreen({
    required this.state,
    required this.characters,
    required this.voiceSummary,
    required this.voiceEnrolled,
    required this.voiceApproved,
    required this.voicePreviewed,
    required this.voiceRuntimeReady,
    required this.voiceDurationMilliseconds,
    required this.retentionDays,
    required this.selectCharacter,
    required this.refreshCharacters,
    required this.editCurrentCharacterDetails,
    required this.addCharacter,
    required this.uploadCharacterPhoto,
    required this.enrollVoice,
    required this.previewVoice,
    required this.approveVoice,
    required this.removeVoice,
    required this.deleteCurrentCharacter,
    required this.reviewSavedHistory,
  });

  final AppState state;
  final List<CharacterConfiguration> characters;
  final String voiceSummary;
  final bool voiceEnrolled;
  final bool voiceApproved;
  final bool voicePreviewed;
  final bool voiceRuntimeReady;
  final int? voiceDurationMilliseconds;
  final int? retentionDays;
  final void Function(String alias) selectCharacter;
  final Future<List<CharacterConfiguration>> Function() refreshCharacters;
  final Future<void> Function() editCurrentCharacterDetails;
  final Future<void> Function() addCharacter;
  final Future<void> Function() uploadCharacterPhoto;
  final CharacterVoiceAction enrollVoice;
  final CharacterVoiceAction previewVoice;
  final CharacterVoiceAction approveVoice;
  final CharacterVoiceAction removeVoice;
  final Future<bool> Function() deleteCurrentCharacter;
  final Future<void> Function() reviewSavedHistory;

  @override
  State<_CharactersSettingsScreen> createState() =>
      _CharactersSettingsScreenState();
}

class _CharactersSettingsScreenState extends State<_CharactersSettingsScreen> {
  late List<CharacterConfiguration> characters = widget.characters;

  Future<void> refresh() async {
    final updated = await widget.refreshCharacters();
    if (mounted) setState(() => characters = updated);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Characters')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsGroup(
          title: 'Characters',
          children: [
            for (final character
                in characters.isEmpty
                    ? [
                        CharacterConfiguration(
                          alias: widget.state.characterName,
                          traits: const [],
                          parentGuidance: null,
                          voice: const VoiceProfileStatus(
                            enrolled: false,
                            approved: false,
                            runtimeReady: false,
                          ),
                          personaAgeYears: null,
                        ),
                      ]
                    : characters)
              _SettingsTile(
                icon: Icons.toys,
                title: character.alias,
                subtitle: character.alias == widget.state.characterName
                    ? 'Current character'
                    : 'Saved character',
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  widget.selectCharacter(character.alias);
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => _CharacterDetailSettingsScreen(
                        character: character,
                        voiceSummary: widget.voiceSummary,
                        voiceEnrolled: widget.voiceEnrolled,
                        voiceApproved: widget.voiceApproved,
                        voicePreviewed: widget.voicePreviewed,
                        voiceRuntimeReady: widget.voiceRuntimeReady,
                        voiceDurationMilliseconds:
                            widget.voiceDurationMilliseconds,
                        retentionDays: widget.retentionDays,
                        editCurrentCharacterDetails:
                            widget.editCurrentCharacterDetails,
                        uploadCharacterPhoto: widget.uploadCharacterPhoto,
                        enrollVoice: widget.enrollVoice,
                        previewVoice: widget.previewVoice,
                        approveVoice: widget.approveVoice,
                        removeVoice: widget.removeVoice,
                        deleteCurrentCharacter: widget.deleteCurrentCharacter,
                        reviewSavedHistory: widget.reviewSavedHistory,
                      ),
                    ),
                  );
                  await refresh();
                },
              ),
            _SettingsTile(
              icon: Icons.add,
              title: 'Add character',
              subtitle: 'Create another toy profile.',
              onTap: () async {
                await widget.addCharacter();
                await refresh();
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _CharacterDetailSettingsScreen extends StatefulWidget {
  const _CharacterDetailSettingsScreen({
    required this.character,
    required this.voiceSummary,
    required this.voiceEnrolled,
    required this.voiceApproved,
    required this.voicePreviewed,
    required this.voiceRuntimeReady,
    required this.voiceDurationMilliseconds,
    required this.retentionDays,
    required this.editCurrentCharacterDetails,
    required this.uploadCharacterPhoto,
    required this.enrollVoice,
    required this.previewVoice,
    required this.approveVoice,
    required this.removeVoice,
    required this.deleteCurrentCharacter,
    required this.reviewSavedHistory,
  });

  final CharacterConfiguration character;
  final String voiceSummary;
  final bool voiceEnrolled;
  final bool voiceApproved;
  final bool voicePreviewed;
  final bool voiceRuntimeReady;
  final int? voiceDurationMilliseconds;
  final int? retentionDays;
  final Future<void> Function() editCurrentCharacterDetails;
  final Future<void> Function() uploadCharacterPhoto;
  final CharacterVoiceAction enrollVoice;
  final CharacterVoiceAction previewVoice;
  final CharacterVoiceAction approveVoice;
  final CharacterVoiceAction removeVoice;
  final Future<bool> Function() deleteCurrentCharacter;
  final Future<void> Function() reviewSavedHistory;

  @override
  State<_CharacterDetailSettingsScreen> createState() =>
      _CharacterDetailSettingsScreenState();
}

class _CharacterDetailSettingsScreenState
    extends State<_CharacterDetailSettingsScreen> {
  late bool voiceEnrolled = widget.character.voice.enrolled;
  late bool voiceApproved = widget.character.voice.approved;
  late bool voicePreviewed = widget.character.voice.approved;
  late bool voiceRuntimeReady =
      widget.voiceRuntimeReady || widget.character.voice.runtimeReady;
  late int? voiceDurationMilliseconds =
      widget.character.voice.durationMilliseconds;

  String get voiceLifecycleSummary {
    if (!voiceRuntimeReady) return 'Magic Voice Box is not ready.';
    final duration = voiceDurationMilliseconds == null
        ? ''
        : ' • ${(voiceDurationMilliseconds! / 1000).toStringAsFixed(1)}s sample';
    if (!voiceEnrolled) return 'No voice sample uploaded yet.';
    if (voiceApproved) return 'Ready for playtime$duration';
    if (voicePreviewed) {
      return 'Preview played. Save it if it sounds right$duration';
    }
    return 'Sample uploaded. Listen before saving$duration';
  }

  Future<void> handleEnrollVoice() async {
    final enrolled = await widget.enrollVoice(
      characterAlias: widget.character.alias,
    );
    if (!mounted || !enrolled) return;
    setState(() {
      voiceEnrolled = true;
      voiceApproved = false;
      voicePreviewed = false;
      voiceRuntimeReady = true;
    });
  }

  Future<void> handlePreviewVoice() async {
    if (!voiceEnrolled) {
      await handleEnrollVoice();
      return;
    }
    final previewed = await widget.previewVoice(
      characterAlias: widget.character.alias,
    );
    if (!mounted || !previewed) return;
    setState(() => voicePreviewed = true);
  }

  Future<void> handleApproveVoice() async {
    final approved = await widget.approveVoice(
      characterAlias: widget.character.alias,
    );
    if (!mounted || !approved) return;
    setState(() {
      voiceEnrolled = true;
      voicePreviewed = true;
      voiceApproved = true;
    });
  }

  Future<void> handleRemoveVoice() async {
    final removed = await widget.removeVoice(
      characterAlias: widget.character.alias,
    );
    if (!mounted || !removed) return;
    setState(() {
      voiceEnrolled = false;
      voicePreviewed = false;
      voiceApproved = false;
      voiceDurationMilliseconds = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.character.alias)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsGroup(
          title: 'Buddy profile',
          children: [
            _SettingsTile(
              icon: Icons.edit,
              title: 'Name, personality, and guidance',
              subtitle: 'Shape how this buddy talks and plays.',
              onTap: widget.editCurrentCharacterDetails,
            ),
            _SettingsTile(
              icon: Icons.photo_camera,
              title: 'Photo',
              subtitle: 'Add or replace the buddy picture.',
              onTap: widget.uploadCharacterPhoto,
            ),
          ],
        ),
        _SettingsGroup(
          title: 'Buddy Voice',
          children: [
            _SettingsTile(
              icon: Icons.graphic_eq,
              title: 'Buddy voice',
              subtitle: voiceLifecycleSummary,
              trailing: voiceApproved
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.chevron_right),
              onTap: voiceEnrolled ? handlePreviewVoice : handleEnrollVoice,
            ),
            if (voiceEnrolled)
              _SettingsTile(
                icon: Icons.upload_file,
                title: 'Replace voice sample',
                subtitle:
                    'Upload a new sample. Canceling keeps the current voice.',
                onTap: handleEnrollVoice,
              )
            else
              _SettingsTile(
                icon: Icons.upload_file,
                title: 'Upload voice sample',
                subtitle: 'Make a playful voice for this buddy.',
                onTap: handleEnrollVoice,
              ),
            if (voiceEnrolled && !voicePreviewed)
              _SettingsTile(
                icon: Icons.play_circle_outline,
                title: 'Preview buddy voice',
                subtitle: 'Listen before saving it for playtime.',
                onTap: handlePreviewVoice,
              ),
            if (voiceEnrolled && !voiceApproved)
              _SettingsTile(
                icon: Icons.verified,
                title: 'Save this voice',
                subtitle: voicePreviewed
                    ? 'Save only if it sounds like the toy.'
                    : 'Preview the voice first.',
                onTap: voicePreviewed ? handleApproveVoice : null,
              ),
            if (voiceEnrolled)
              _SettingsTile(
                icon: Icons.delete_outline,
                title: 'Remove buddy voice',
                subtitle: 'Delete this buddy’s current voice.',
                onTap: handleRemoveVoice,
              ),
          ],
        ),
        _SettingsGroup(
          title: 'Conversations',
          children: [
            _SettingsTile(
              icon: Icons.forum_outlined,
              title: '${widget.character.alias} conversations',
              subtitle: widget.retentionDays == null
                  ? 'Saving conversations is off for this buddy.'
                  : 'Review saved conversations for this buddy.',
              onTap: widget.retentionDays == null
                  ? null
                  : widget.reviewSavedHistory,
            ),
          ],
        ),
        _SettingsGroup(
          title: 'Careful actions',
          children: [
            _SettingsTile(
              icon: Icons.delete_forever,
              title: 'Delete buddy',
              subtitle:
                  'Remove ${widget.character.alias}, its settings, and its voice.',
              onTap: () async {
                final deleted = await widget.deleteCurrentCharacter();
                if (deleted && context.mounted) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _SettingsStatusSummary extends StatelessWidget {
  const _SettingsStatusSummary({
    required this.reasoningReady,
    required this.stationPaired,
    required this.voiceRuntimeReady,
    required this.voiceApproved,
  });

  final bool reasoningReady;
  final bool stationPaired;
  final bool voiceRuntimeReady;
  final bool voiceApproved;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ready check',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          _StatusLine(
            ok: reasoningReady,
            label: reasoningReady ? 'AI Brain ready' : 'AI Brain needs setup',
          ),
          _StatusLine(
            ok: stationPaired,
            label: stationPaired
                ? 'Magic Voice Box connected'
                : 'Magic Voice Box not connected',
          ),
          _StatusLine(
            ok: voiceRuntimeReady,
            label: voiceRuntimeReady
                ? 'Voice maker ready'
                : 'Voice maker not ready',
          ),
          _StatusLine(
            ok: voiceApproved,
            label: voiceApproved
                ? 'Buddy voice saved'
                : 'Buddy voice not saved',
          ),
        ],
      ),
    ),
  );
}

class PlushBuddyLogo extends StatelessWidget {
  const PlushBuddyLogo({this.size = 80, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xffff8bd1), Color(0xff8b5cf6), Color(0xff38bdf8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(size * 0.28),
          boxShadow: [
            BoxShadow(
              color: const Color(0xff8b5cf6).withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.favorite, size: size * 0.62, color: Colors.white),
            Positioned(
              right: size * 0.16,
              bottom: size * 0.14,
              child: Container(
                width: size * 0.34,
                height: size * 0.34,
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: size * 0.04),
                ),
                child: Icon(
                  Icons.toys,
                  size: size * 0.19,
                  color: colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({
    required this.characterName,
    required this.history,
    super.key,
  });

  final String characterName;
  final List<ConversationHistoryEntry> history;

  String _formatCompletedAt(int secondsSinceEpoch) {
    final completed = DateTime.fromMillisecondsSinceEpoch(
      secondsSinceEpoch * 1000,
    ).toLocal();
    final hour = completed.hour == 0
        ? 12
        : completed.hour > 12
        ? completed.hour - 12
        : completed.hour;
    final minute = completed.minute.toString().padLeft(2, '0');
    final period = completed.hour >= 12 ? 'PM' : 'AM';
    return '${completed.month}/${completed.day}/${completed.year} $hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('$characterName history')),
      body: history.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.forum_outlined,
                      size: 64,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No saved conversations yet',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'After child mode has a completed turn, saved history for $characterName will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: history.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final entry = history[index];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _formatCompletedAt(entry.completedAt),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        _HistoryBubble(
                          label: 'Child',
                          text: entry.childText,
                          alignment: CrossAxisAlignment.end,
                          color: colorScheme.primaryContainer,
                          textColor: colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(height: 10),
                        _HistoryBubble(
                          label: characterName,
                          text: entry.characterText,
                          alignment: CrossAxisAlignment.start,
                          color: colorScheme.surfaceContainerHighest,
                          textColor: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _HistoryBubble extends StatelessWidget {
  const _HistoryBubble({
    required this.label,
    required this.text,
    required this.alignment,
    required this.color,
    required this.textColor,
  });

  final String label;
  final String text;
  final CrossAxisAlignment alignment;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: alignment,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 4),
      DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(text, style: TextStyle(color: textColor)),
        ),
      ),
    ],
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing:
        trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
    onTap: onTap,
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.status,
    required this.complete,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String status;
  final bool complete;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: complete
                      ? colorScheme.primaryContainer
                      : colorScheme.surfaceContainerHighest,
                  foregroundColor: complete
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  child: Icon(icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status,
                        style: TextStyle(
                          color: complete
                              ? Colors.green.shade700
                              : colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  complete ? Icons.check_circle : Icons.error_outline,
                  color: complete ? Colors.green : colorScheme.outline,
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.ok, required this.label});

  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.radio_button_unchecked,
          color: ok ? Colors.green : Theme.of(context).colorScheme.outline,
          size: 20,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

class ChildModeScreen extends StatelessWidget {
  const ChildModeScreen({
    required this.state,
    required this.selectedKid,
    required this.selectedChildAge,
    required this.dispatch,
    required this.characters,
    required this.selectCharacter,
    required this.beginLocalTurn,
    required this.beginSpokenTurn,
    required this.speechAvailable,
    required this.latestSpeech,
    required this.messages,
    required this.characterPhotoBytes,
    required this.message,
    required this.inputController,
    required this.exitChildMode,
    super.key,
  });
  final AppState state;
  final KidProfile? selectedKid;
  final ChildAgeDetails? selectedChildAge;
  final Dispatch dispatch;
  final List<CharacterConfiguration> characters;
  final void Function(String alias) selectCharacter;
  final Future<void> Function(String text) beginLocalTurn;
  final Future<void> Function() beginSpokenTurn;
  final bool speechAvailable;
  final String? latestSpeech;
  final List<ChildChatMessage> messages;
  final Uint8List? characterPhotoBytes;
  final String? message;
  final TextEditingController inputController;
  final Future<void> Function() exitChildMode;

  String get status => switch (state.conversationStatus) {
    ConversationStatus.idle => 'Tap to talk',
    ConversationStatus.listening => 'I’m listening...',
    ConversationStatus.thinking => 'Thinking of something fun...',
    ConversationStatus.speaking => '${state.characterName} is talking...',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final visibleMessages = messages.isNotEmpty
        ? messages
        : [
            if (latestSpeech != null)
              ChildChatMessage(
                author: ChildMessageAuthor.character,
                text: latestSpeech!,
              ),
          ];
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: characterPhotoBytes == null
                  ? CircleAvatar(
                      radius: 18,
                      backgroundColor: colorScheme.primaryContainer,
                      child: const Icon(Icons.toys, size: 20),
                    )
                  : Image.memory(
                      characterPhotoBytes!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(state.characterName)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              label: 'Done playing and return home',
              button: true,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: exitChildMode,
                icon: const Icon(Icons.check_circle_outline, size: 20),
                label: const Text('Done'),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                if (characters.length > 1 &&
                    state.conversationStatus == ConversationStatus.idle)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: DropdownButtonFormField<String>(
                      initialValue: state.characterName,
                      decoration: const InputDecoration(
                        labelText: 'Toy buddy',
                        border: OutlineInputBorder(),
                      ),
                      items: characters
                          .map(
                            (character) => DropdownMenuItem(
                              value: character.alias,
                              child: Text(character.alias),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) selectCharacter(value);
                      },
                    ),
                  ),
                Expanded(
                  child: ListView(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    children: [
                      if (message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            message!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ),
                      if (visibleMessages.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 96),
                          child: Column(
                            children: [
                              characterPhotoBytes == null
                                  ? Icon(
                                      Icons.toys,
                                      size: 104,
                                      color: colorScheme.primary,
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(32),
                                      child: Image.memory(
                                        characterPhotoBytes!,
                                        width: 128,
                                        height: 128,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                              const SizedBox(height: 18),
                              Text(
                                'Talk with ${state.characterName}',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                speechAvailable
                                    ? 'Tap the mic and tell your buddy anything.'
                                    : 'Type a message to your buddy.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        for (final chatMessage in visibleMessages.reversed)
                          _ChildMessageBubble(
                            message: chatMessage,
                            characterName: state.characterName,
                          ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Row(
                    children: [
                      Semantics(
                        button: true,
                        label: status,
                        child: SizedBox.square(
                          dimension: 56,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              shape: const CircleBorder(),
                            ),
                            onPressed:
                                state.conversationStatus ==
                                        ConversationStatus.idle &&
                                    speechAvailable
                                ? beginSpokenTurn
                                : null,
                            child: Icon(
                              state.conversationStatus ==
                                      ConversationStatus.listening
                                  ? Icons.hearing
                                  : Icons.mic,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: colorScheme.outlineVariant,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: inputController,
                                  enabled:
                                      state.conversationStatus ==
                                      ConversationStatus.idle,
                                  minLines: 1,
                                  maxLines: 5,
                                  maxLength: 600,
                                  keyboardType: TextInputType.multiline,
                                  onSubmitted:
                                      state.conversationStatus ==
                                          ConversationStatus.idle
                                      ? beginLocalTurn
                                      : null,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: InputDecoration(
                                    hintText:
                                        state.conversationStatus ==
                                            ConversationStatus.idle
                                        ? 'Say something to ${state.characterName}'
                                        : status,
                                    counterText: '',
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.fromLTRB(
                                      18,
                                      14,
                                      8,
                                      14,
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 6,
                                  bottom: 6,
                                ),
                                child: ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: inputController,
                                  builder: (context, value, _) {
                                    final canSend =
                                        state.conversationStatus ==
                                            ConversationStatus.idle &&
                                        value.text.trim().isNotEmpty;
                                    return IconButton.filled(
                                      tooltip: 'Send message',
                                      onPressed: canSend
                                          ? () => beginLocalTurn(
                                              inputController.text,
                                            )
                                          : null,
                                      icon: const Icon(Icons.arrow_upward),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    status,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChildMessageBubble extends StatelessWidget {
  const _ChildMessageBubble({
    required this.message,
    required this.characterName,
  });

  final ChildChatMessage message;
  final String characterName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isChild = message.author == ChildMessageAuthor.child;
    final label = isChild ? 'You' : characterName;
    return Align(
      alignment: isChild ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Card(
          elevation: 0,
          color: isChild
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isChild
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message.text,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: isChild
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
