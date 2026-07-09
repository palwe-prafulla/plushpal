import 'dart:typed_data';

import 'backend_client_stub.dart'
    if (dart.library.js_interop) 'backend_client_web.dart';

class BackendResponse {
  const BackendResponse({
    required this.speech,
    required this.suggestTrustedAdult,
  });

  final String speech;
  final bool suggestTrustedAdult;
}

class LocalModelReadiness {
  const LocalModelReadiness({
    required this.modelId,
    required this.displayName,
    required this.ready,
    required this.installSupported,
    required this.installing,
    this.runtimeMode = 'custom',
    this.parentConfigured = false,
    this.ageBand,
    this.characterAlias,
    this.characterTraits = const [],
    this.parentGuidance,
    this.retentionDays,
    this.speechToTextReady = false,
    this.webSearchProviderReady = false,
  });

  final String modelId;
  final String displayName;
  final bool ready;
  final bool installSupported;
  final bool installing;
  final String runtimeMode;
  final bool parentConfigured;
  final String? ageBand;
  final String? characterAlias;
  final List<String> characterTraits;
  final String? parentGuidance;
  final int? retentionDays;
  final bool speechToTextReady;
  final bool webSearchProviderReady;
}

class KidProfile {
  const KidProfile({
    required this.id,
    required this.name,
    required this.birthdateIso,
    this.photoBytes,
    this.photoMime,
  });

  final String id;
  final String name;
  final String birthdateIso;
  final Uint8List? photoBytes;
  final String? photoMime;
}

class ReasoningProviderStatus {
  const ReasoningProviderStatus({
    required this.provider,
    required this.configured,
    required this.displayName,
    this.webSearchEnabled = false,
  });

  final String provider;
  final bool configured;
  final String displayName;
  final bool webSearchEnabled;
}

class ConversationHistoryEntry {
  const ConversationHistoryEntry({
    required this.childText,
    required this.characterText,
    required this.completedAt,
  });

  final String childText;
  final String characterText;
  final int completedAt;
}

class VoiceProfileStatus {
  const VoiceProfileStatus({
    required this.enrolled,
    required this.approved,
    required this.runtimeReady,
    this.durationMilliseconds,
    this.profileId,
  });

  final bool enrolled;
  final bool approved;
  final bool runtimeReady;
  final int? durationMilliseconds;
  final String? profileId;
}

class CharacterConfiguration {
  const CharacterConfiguration({
    required this.alias,
    required this.traits,
    required this.parentGuidance,
    required this.voice,
    this.kidId,
    this.personaAgeYears,
    this.photoBytes,
    this.photoMime,
  });

  final String alias;
  final List<String> traits;
  final String? parentGuidance;
  final VoiceProfileStatus voice;
  final String? kidId;
  final int? personaAgeYears;
  final Uint8List? photoBytes;
  final String? photoMime;
}

class PickedCharacterPhoto {
  const PickedCharacterPhoto({
    required this.bytes,
    required this.filename,
    required this.mime,
  });

  final Uint8List bytes;
  final String filename;
  final String? mime;
}

class StationPairingStatus {
  const StationPairingStatus({required this.paired, this.baseUrl});

  final bool paired;
  final String? baseUrl;
}

class PairedClientInfo {
  const PairedClientInfo({
    required this.clientId,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
    this.label,
    this.lastSeenIp,
    this.revokedAt,
  });

  final String clientId;
  final String platform;
  final String? label;
  final int createdAt;
  final int lastSeenAt;
  final String? lastSeenIp;
  final int? revokedAt;
}

class HubBackup {
  const HubBackup({required this.backupBase64, required this.exportedAt});

  final String backupBase64;
  final int exportedAt;
}

abstract interface class BackendClient {
  Future<StationPairingStatus> stationPairingStatus();
  Future<void> pairStation(String pairingUrl);
  Future<void> clearStationPairing();
  Future<List<PairedClientInfo>> pairedClients(String pin);
  Future<void> revokePairedClient({
    required String pin,
    required String clientId,
  });
  Future<ReasoningProviderStatus> reasoningProviderStatus();
  Future<void> configureApiKey({
    required String pin,
    required String provider,
    required String apiKey,
  });
  Future<void> setWebSearchEnabled({
    required String pin,
    required bool enabled,
  });
  Future<void> configureGeminiApiKey(String apiKey);
  Future<List<KidProfile>> kids();
  Future<void> saveKid({
    required String pin,
    required String? kidId,
    required String name,
    required String birthdateIso,
    Uint8List? photoBytes,
    String? photoMime,
  });
  Future<void> deleteKid({required String pin, required String kidId});
  Future<LocalModelReadiness> localModelReadiness();
  Future<BackendResponse> beginLocalTurn({
    required String ageBand,
    required String characterAlias,
    required String text,
    String? kidId,
    String? kidName,
    int? childAgeYears,
    int? childAgeMonths,
    int? characterPlayAgeYears,
  });
  Future<String> transcribeSpeech(Uint8List wavBytes);
  Future<void> cancelTurn();
  Future<void> endSession();
  Future<void> installLocalModel();
  Future<void> cancelModelInstall();
  Future<void> configureParentPin({
    required String pin,
    required String ageBand,
    required String characterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    required int? retentionDays,
    String? kidId,
  });
  Future<bool> authorizeParentPin(String pin);
  Future<void> deleteAllLocalData(String pin);
  Future<HubBackup> exportBackup(String pin);
  Future<void> importBackup({
    required String pin,
    required String backupBase64,
  });
  Future<List<ConversationHistoryEntry>> history(String pin);
  Future<List<ConversationHistoryEntry>> scopedHistory(
    String pin, {
    String? kidId,
    String? characterAlias,
  });
  Future<void> deleteHistory(String pin);
  Future<List<CharacterConfiguration>> characters();
  Future<void> saveCharacter({
    required String pin,
    required String characterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    String? kidId,
    int? personaAgeYears,
  });
  Future<void> renameCharacter({
    required String pin,
    required String currentCharacterAlias,
    required String newCharacterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    String? kidId,
    int? personaAgeYears,
  });
  Future<PickedCharacterPhoto> pickCharacterPhoto();
  Future<void> saveCharacterPhoto({
    required String pin,
    required String characterAlias,
    required Uint8List photoBytes,
    required String? photoMime,
  });
  Future<void> deleteCharacter({
    required String pin,
    required String characterAlias,
    String? kidId,
  });
  Future<VoiceProfileStatus> voiceStatus({String? characterAlias});
  Future<void> enrollVoiceSample({
    required String pin,
    required bool adultAuthorized,
    String? characterAlias,
    Uint8List? wavBytes,
    String? sourceFilename,
    String? sourceMime,
  });
  Future<void> previewVoice(String pin, {String? characterAlias});
  Future<void> approveVoice(String pin, {String? characterAlias});
  Future<void> deleteVoice(String pin, {String? characterAlias});
  Future<Uint8List> synthesizeVoice(String text, {String? characterAlias});
  Future<void> speakWithVoice(String text, {String? characterAlias});
}

BackendClient createBackendClient() => createPlatformBackendClient();
