@JS()
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'backend_client.dart';

@JS('toytalkBeginLocalTurn')
external JSPromise<JSString> _beginLocalTurn(
  JSString ageBand,
  JSString characterAlias,
  JSString text,
  JSString? kidId,
  JSString? kidName,
  JSNumber? childAgeYears,
  JSNumber? childAgeMonths,
  JSNumber? characterPlayAgeYears,
);

@JS('toytalkTranscribeSpeech')
external JSPromise<JSString> _transcribeSpeech(JSString wavBase64);

@JS('toytalkCancelTurn')
external JSPromise<JSAny?> _cancelTurn();

@JS('toytalkModelStatus')
external JSPromise<JSString> _modelStatus();

@JS('toytalkEndSession')
external JSPromise<JSAny?> _endSession();

@JS('toytalkInstallLocalModel')
external JSPromise<JSAny?> _installLocalModel();

@JS('toytalkCancelModelInstall')
external JSPromise<JSAny?> _cancelModelInstall();

@JS('toytalkConfigureParentPin')
external JSPromise<JSAny?> _configureParentPin(
  JSString pin,
  JSString ageBand,
  JSString characterAlias,
  JSArray<JSString> characterTraits,
  JSString? parentGuidance,
  JSNumber? retentionDays,
  JSString? kidId,
);

@JS('toytalkReasoningProviderStatus')
external JSPromise<JSString> _reasoningProviderStatus();

@JS('toytalkConfigureApiKey')
external JSPromise<JSAny?> _configureApiKey(
  JSString pin,
  JSString provider,
  JSString apiKey,
);

@JS('toytalkSetWebSearchEnabled')
external JSPromise<JSAny?> _setWebSearchEnabled(
  JSString pin,
  JSBoolean enabled,
);

@JS('toytalkKids')
external JSPromise<JSString> _kids();

@JS('toytalkSaveKid')
external JSPromise<JSAny?> _saveKid(
  JSString pin,
  JSString? kidId,
  JSString name,
  JSString birthdateIso,
  JSString? photoBase64,
  JSString? photoMime,
);

@JS('toytalkDeleteKid')
external JSPromise<JSAny?> _deleteKid(JSString pin, JSString kidId);

@JS('toytalkPairedClients')
external JSPromise<JSString> _pairedClients(JSString pin);

@JS('toytalkRevokePairedClient')
external JSPromise<JSAny?> _revokePairedClient(JSString pin, JSString clientId);

@JS('toytalkAuthorizeParentPin')
external JSPromise<JSBoolean> _authorizeParentPin(JSString pin);

@JS('toytalkDeleteAllLocalData')
external JSPromise<JSAny?> _deleteAllLocalData(JSString pin);

@JS('toytalkExportBackup')
external JSPromise<JSString> _exportBackup(JSString pin);

@JS('toytalkImportBackup')
external JSPromise<JSAny?> _importBackup(JSString pin, JSString backupBase64);

@JS('toytalkHistory')
external JSPromise<JSString> _history(JSString pin);

@JS('toytalkDeleteHistory')
external JSPromise<JSAny?> _deleteHistory(JSString pin);

@JS('toytalkCharacters')
external JSPromise<JSString> _characters();

@JS('toytalkSaveCharacter')
external JSPromise<JSAny?> _saveCharacter(
  JSString pin,
  JSString characterAlias,
  JSArray<JSString> characterTraits,
  JSString? parentGuidance,
  JSString? kidId,
  JSNumber? personaAgeYears,
);

@JS('toytalkRenameCharacter')
external JSPromise<JSAny?> _renameCharacter(
  JSString pin,
  JSString currentCharacterAlias,
  JSString newCharacterAlias,
  JSArray<JSString> characterTraits,
  JSString? parentGuidance,
  JSString? kidId,
  JSNumber? personaAgeYears,
);

@JS('toytalkDeleteCharacter')
external JSPromise<JSAny?> _deleteCharacter(
  JSString pin,
  JSString characterAlias,
  JSString? kidId,
);

@JS('toytalkPickCharacterPhoto')
external JSPromise<JSString> _pickCharacterPhoto();

@JS('toytalkSaveCharacterPhoto')
external JSPromise<JSAny?> _saveCharacterPhoto(
  JSString pin,
  JSString characterAlias,
  JSString photoBase64,
  JSString? photoMime,
);

@JS('toytalkVoiceStatus')
external JSPromise<JSString> _voiceStatus(JSString? characterAlias);

@JS('toytalkEnrollVoice')
external JSPromise<JSAny?> _enrollVoice(
  JSString pin,
  JSBoolean adultAuthorized,
  JSString? characterAlias,
);

@JS('toytalkPreviewVoice')
external JSPromise<JSAny?> _previewVoice(
  JSString pin,
  JSString? characterAlias,
);

@JS('toytalkApproveVoice')
external JSPromise<JSAny?> _approveVoice(
  JSString pin,
  JSString? characterAlias,
);

@JS('toytalkDeleteVoice')
external JSPromise<JSAny?> _deleteVoice(JSString pin, JSString? characterAlias);

@JS('toytalkSpeakWithVoice')
external JSPromise<JSAny?> _speakWithVoice(
  JSString text,
  JSString? characterAlias,
);

@JS('toytalkSynthesizeVoice')
external JSPromise<JSString> _synthesizeVoice(
  JSString text,
  JSString? characterAlias,
);

BackendClient createPlatformBackendClient() => const WebBackendClient();

class WebBackendClient implements BackendClient {
  const WebBackendClient();

  @override
  Future<StationPairingStatus> stationPairingStatus() async {
    final readiness = await localModelReadiness();
    return StationPairingStatus(
      paired: readiness.installSupported,
      baseUrl: Uri.base.origin,
    );
  }

  @override
  Future<void> pairStation(String pairingUrl) async {
    // Browser clients are normally opened from the Station URL itself. Accepting
    // this as a no-op keeps the shared settings UI usable if the action appears.
  }

  @override
  Future<void> clearStationPairing() async {}

  @override
  Future<List<PairedClientInfo>> pairedClients(String pin) async {
    final rows =
        jsonDecode((await _pairedClients(pin.toJS).toDart).toDart)
            as List<Object?>;
    return rows.map((item) {
      final row = item! as Map<String, Object?>;
      return PairedClientInfo(
        clientId: row['client_id']! as String,
        platform: row['platform']! as String,
        label: row['label'] as String?,
        createdAt: row['created_at']! as int,
        lastSeenAt: row['last_seen_at']! as int,
        lastSeenIp: row['last_seen_ip'] as String?,
        revokedAt: row['revoked_at'] as int?,
      );
    }).toList();
  }

  @override
  Future<void> revokePairedClient({
    required String pin,
    required String clientId,
  }) async {
    await _revokePairedClient(pin.toJS, clientId.toJS).toDart;
  }

  @override
  Future<ReasoningProviderStatus> reasoningProviderStatus() async {
    final decoded =
        jsonDecode((await _reasoningProviderStatus().toDart).toDart)
            as Map<String, Object?>;
    return ReasoningProviderStatus(
      provider: decoded['provider'] as String? ?? 'gemini',
      configured: decoded['configured'] as bool? ?? false,
      displayName: decoded['display_name'] as String? ?? 'Gemini',
      webSearchEnabled: decoded['web_search_enabled'] as bool? ?? false,
    );
  }

  @override
  Future<void> configureApiKey({
    required String pin,
    required String provider,
    required String apiKey,
  }) async {
    await _configureApiKey(pin.toJS, provider.toJS, apiKey.toJS).toDart;
  }

  @override
  Future<void> configureGeminiApiKey(String apiKey) =>
      configureApiKey(pin: '', provider: 'gemini', apiKey: apiKey);

  @override
  Future<void> setWebSearchEnabled({
    required String pin,
    required bool enabled,
  }) async {
    await _setWebSearchEnabled(pin.toJS, enabled.toJS).toDart;
  }

  @override
  Future<List<KidProfile>> kids() async {
    final decoded = jsonDecode((await _kids().toDart).toDart) as List<Object?>;
    return decoded.map((item) {
      final kid = item! as Map<String, Object?>;
      return KidProfile(
        id: kid['id']! as String,
        name: kid['name']! as String,
        birthdateIso: kid['birthdate_iso']! as String,
        photoBytes: switch (kid['photo_base64'] as String?) {
          final value? when value.isNotEmpty => base64Decode(value),
          _ => null,
        },
        photoMime: kid['photo_mime'] as String?,
      );
    }).toList();
  }

  @override
  Future<void> saveKid({
    required String pin,
    required String? kidId,
    required String name,
    required String birthdateIso,
    Uint8List? photoBytes,
    String? photoMime,
  }) async {
    await _saveKid(
      pin.toJS,
      kidId?.toJS,
      name.toJS,
      birthdateIso.toJS,
      photoBytes == null ? null : base64Encode(photoBytes).toJS,
      photoMime?.toJS,
    ).toDart;
  }

  @override
  Future<void> deleteKid({required String pin, required String kidId}) async {
    await _deleteKid(pin.toJS, kidId.toJS).toDart;
  }

  @override
  Future<LocalModelReadiness> localModelReadiness() async {
    final decoded =
        jsonDecode((await _modelStatus().toDart).toDart)
            as Map<String, Object?>;
    return LocalModelReadiness(
      modelId: decoded['model_id']! as String,
      displayName: decoded['display_name']! as String,
      ready: decoded['model_ready']! as bool,
      installSupported: decoded['model_install_supported']! as bool,
      installing: decoded['model_installing']! as bool,
      runtimeMode: decoded['runtime_mode'] as String? ?? 'custom',
      parentConfigured: decoded['parent_configured'] as bool? ?? false,
      ageBand: decoded['age_band'] as String?,
      characterAlias: decoded['character_alias'] as String?,
      characterTraits:
          (decoded['character_traits'] as List<Object?>? ?? const [])
              .cast<String>(),
      parentGuidance: decoded['parent_guidance'] as String?,
      retentionDays: decoded['retention_days'] as int?,
      speechToTextReady: decoded['speech_to_text_ready'] as bool? ?? false,
      webSearchProviderReady:
          decoded['web_search_provider_ready'] as bool? ?? false,
    );
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
    final encoded = (await _beginLocalTurn(
      ageBand.toJS,
      characterAlias.toJS,
      text.toJS,
      kidId?.toJS,
      kidName?.toJS,
      childAgeYears?.toJS,
      childAgeMonths?.toJS,
      characterPlayAgeYears?.toJS,
    ).toDart).toDart;
    final decoded = jsonDecode(encoded) as Map<String, Object?>;
    return BackendResponse(
      speech: decoded['speech']! as String,
      suggestTrustedAdult: decoded['suggest_trusted_adult']! as bool,
    );
  }

  @override
  Future<String> transcribeSpeech(Uint8List wavBytes) async {
    if (wavBytes.isEmpty || wavBytes.length > 12 * 1_048_576) {
      throw StateError('Recorded speech audio is invalid.');
    }
    return (await _transcribeSpeech(base64Encode(wavBytes).toJS).toDart).toDart;
  }

  @override
  Future<void> cancelTurn() async {
    await _cancelTurn().toDart;
  }

  @override
  Future<void> endSession() async {
    await _endSession().toDart;
  }

  @override
  Future<void> installLocalModel() async {
    await _installLocalModel().toDart;
  }

  @override
  Future<void> cancelModelInstall() async {
    await _cancelModelInstall().toDart;
  }

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
    await _configureParentPin(
      pin.toJS,
      ageBand.toJS,
      characterAlias.toJS,
      characterTraits.map((value) => value.toJS).toList().toJS,
      parentGuidance?.toJS,
      retentionDays?.toJS,
      kidId?.toJS,
    ).toDart;
  }

  @override
  Future<bool> authorizeParentPin(String pin) async =>
      (await _authorizeParentPin(pin.toJS).toDart).toDart;

  @override
  Future<void> deleteAllLocalData(String pin) async {
    await _deleteAllLocalData(pin.toJS).toDart;
  }

  @override
  Future<HubBackup> exportBackup(String pin) async {
    final decoded =
        jsonDecode((await _exportBackup(pin.toJS).toDart).toDart)
            as Map<String, Object?>;
    return HubBackup(
      backupBase64: decoded['backup_base64']! as String,
      exportedAt: decoded['exported_at']! as int,
    );
  }

  @override
  Future<void> importBackup({
    required String pin,
    required String backupBase64,
  }) async {
    await _importBackup(pin.toJS, backupBase64.toJS).toDart;
  }

  @override
  Future<List<ConversationHistoryEntry>> history(String pin) async {
    final decoded =
        jsonDecode((await _history(pin.toJS).toDart).toDart) as List<Object?>;
    return decoded.map((item) {
      final entry = item! as Map<String, Object?>;
      return ConversationHistoryEntry(
        childText: entry['child_text']! as String,
        characterText: entry['character_text']! as String,
        completedAt: entry['completed_at']! as int,
      );
    }).toList();
  }

  @override
  Future<List<ConversationHistoryEntry>> scopedHistory(
    String pin, {
    String? kidId,
    String? characterAlias,
  }) => history(pin);

  @override
  Future<void> deleteHistory(String pin) async {
    await _deleteHistory(pin.toJS).toDart;
  }

  VoiceProfileStatus _voiceFromJson(Map<String, Object?> decoded) =>
      VoiceProfileStatus(
        enrolled: decoded['enrolled'] as bool? ?? false,
        approved: decoded['approved'] as bool? ?? false,
        runtimeReady: decoded['runtime_ready'] as bool? ?? false,
        durationMilliseconds: decoded['duration_milliseconds'] as int?,
        profileId: decoded['profile_id'] as String?,
      );

  @override
  Future<List<CharacterConfiguration>> characters() async {
    final decoded =
        jsonDecode((await _characters().toDart).toDart) as List<Object?>;
    return decoded.map((item) {
      final character = item! as Map<String, Object?>;
      return CharacterConfiguration(
        alias: character['alias']! as String,
        traits: (character['traits'] as List<Object?>? ?? const [])
            .cast<String>(),
        parentGuidance: character['parent_guidance'] as String?,
        voice: _voiceFromJson(character['voice']! as Map<String, Object?>),
        kidId: character['kid_id'] as String?,
        personaAgeYears: character['persona_age_years'] as int?,
      );
    }).toList();
  }

  @override
  Future<void> saveCharacter({
    required String pin,
    required String characterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    String? kidId,
    int? personaAgeYears,
  }) async {
    await _saveCharacter(
      pin.toJS,
      characterAlias.toJS,
      characterTraits.map((value) => value.toJS).toList().toJS,
      parentGuidance?.toJS,
      kidId?.toJS,
      personaAgeYears?.toJS,
    ).toDart;
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
    await _renameCharacter(
      pin.toJS,
      currentCharacterAlias.toJS,
      newCharacterAlias.toJS,
      characterTraits.map((value) => value.toJS).toList().toJS,
      parentGuidance?.toJS,
      kidId?.toJS,
      personaAgeYears?.toJS,
    ).toDart;
  }

  @override
  Future<PickedCharacterPhoto> pickCharacterPhoto() async {
    final decoded =
        jsonDecode((await _pickCharacterPhoto().toDart).toDart)
            as Map<String, Object?>;
    return PickedCharacterPhoto(
      bytes: base64Decode(decoded['bytes_base64']! as String),
      filename: decoded['filename'] as String? ?? 'character-photo',
      mime: decoded['mime'] as String?,
    );
  }

  @override
  Future<void> saveCharacterPhoto({
    required String pin,
    required String characterAlias,
    required Uint8List photoBytes,
    required String? photoMime,
  }) async {
    await _saveCharacterPhoto(
      pin.toJS,
      characterAlias.toJS,
      base64Encode(photoBytes).toJS,
      photoMime?.toJS,
    ).toDart;
  }

  @override
  Future<void> deleteCharacter({
    required String pin,
    required String characterAlias,
    String? kidId,
  }) async {
    await _deleteCharacter(pin.toJS, characterAlias.toJS, kidId?.toJS).toDart;
  }

  @override
  Future<VoiceProfileStatus> voiceStatus({String? characterAlias}) async {
    final decoded =
        jsonDecode((await _voiceStatus(characterAlias?.toJS).toDart).toDart)
            as Map<String, Object?>;
    return _voiceFromJson(decoded);
  }

  @override
  Future<void> enrollVoiceSample({
    required String pin,
    required bool adultAuthorized,
    String? characterAlias,
    Uint8List? wavBytes,
    String? sourceFilename,
    String? sourceMime,
  }) async {
    if (wavBytes != null) {
      throw UnsupportedError('Browser enrollment uses the local file picker.');
    }
    await _enrollVoice(
      pin.toJS,
      adultAuthorized.toJS,
      characterAlias?.toJS,
    ).toDart;
  }

  @override
  Future<void> previewVoice(String pin, {String? characterAlias}) async {
    await _previewVoice(pin.toJS, characterAlias?.toJS).toDart;
  }

  @override
  Future<void> approveVoice(String pin, {String? characterAlias}) async {
    await _approveVoice(pin.toJS, characterAlias?.toJS).toDart;
  }

  @override
  Future<void> deleteVoice(String pin, {String? characterAlias}) async {
    await _deleteVoice(pin.toJS, characterAlias?.toJS).toDart;
  }

  @override
  Future<Uint8List> synthesizeVoice(
    String text, {
    String? characterAlias,
  }) async {
    final wavBase64 = (await _synthesizeVoice(
      text.toJS,
      characterAlias?.toJS,
    ).toDart).toDart;
    return base64Decode(wavBase64);
  }

  @override
  Future<void> speakWithVoice(String text, {String? characterAlias}) async {
    await _speakWithVoice(text.toJS, characterAlias?.toJS).toDart;
  }
}
