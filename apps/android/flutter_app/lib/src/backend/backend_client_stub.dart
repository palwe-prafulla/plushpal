import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'backend_client.dart';

BackendClient createPlatformBackendClient() =>
    const MethodChannelBackendClient();

class HubAuthenticationRejectedException implements Exception {
  const HubAuthenticationRejectedException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MethodChannelBackendClient implements BackendClient {
  const MethodChannelBackendClient({
    this.channel = const MethodChannel('com.toytalk/platform'),
  });

  final MethodChannel channel;

  Never _hubRequired() => throw UnsupportedError(
    'Connect ToyTalk Hub before using family, voice, or conversation data.',
  );

  bool _isValidStationResponse(Map<Object?, Object?>? response) {
    if (response == null || response['paired'] != true) return false;
    final baseUrl = response['baseUrl'] as String?;
    final cookie = response['cookie'] as String?;
    final clientId = response['clientId'] as String?;
    final hubId = response['hubId'] as String?;
    return baseUrl != null &&
        cookie != null &&
        clientId != null &&
        hubId != null &&
        baseUrl.isNotEmpty &&
        cookie.isNotEmpty &&
        clientId.isNotEmpty &&
        RegExp(
          r'^(android|ios|web|macos|windows|linux)-[a-f0-9-]{36}$',
        ).hasMatch(clientId) &&
        RegExp(r'^hub-[a-f0-9-]{36}$').hasMatch(hubId);
  }

  Future<_StationBackendClient?> _stationBackend() async {
    final config = await _stationConfig();
    if (config == null) return null;
    return _StationBackendClient(config: config, channel: channel);
  }

  Future<_StationConfig?> _stationConfig() async {
    final response = await channel.invokeMapMethod<Object?, Object?>(
      'stationPairingStatus',
    );
    if (!_isValidStationResponse(response)) return null;
    final baseUrl = response!['baseUrl']! as String;
    final cookie = response['cookie']! as String;
    final clientId = response['clientId']! as String;
    final hubId = response['hubId']! as String;
    return _StationConfig(
      baseUrl: Uri.parse(baseUrl),
      cookie: cookie,
      clientId: clientId,
      hubId: hubId,
    );
  }

  @override
  Future<StationPairingStatus> stationPairingStatus() async {
    final response = await channel.invokeMapMethod<Object?, Object?>(
      'stationPairingStatus',
    );
    final paired = _isValidStationResponse(response);
    if (paired) {
      final config = _StationConfig(
        baseUrl: Uri.parse(response!['baseUrl']! as String),
        cookie: response['cookie']! as String,
        clientId: response['clientId']! as String,
        hubId: response['hubId']! as String,
      );
      try {
        await _StationBackendClient(
          config: config,
          channel: channel,
        ).localModelReadiness();
      } on HubAuthenticationRejectedException {
        return const StationPairingStatus(paired: false);
      } catch (_) {
        // Do not clear pairing for transient Hub startup/network failures.
        // _StationBackendClient._requestBytes clears the platform pairing only
        // when the Hub explicitly rejects the stored session or Hub ID with
        // 401/403. Re-read platform state after the failed probe so auth
        // rejections still surface as unpaired, while warmup timeouts keep the
        // phone paired and allow the UI to say the Hub is still starting.
        final current = await channel.invokeMapMethod<Object?, Object?>(
          'stationPairingStatus',
        );
        if (!_isValidStationResponse(current)) {
          return const StationPairingStatus(paired: false);
        }
      }
    }
    return StationPairingStatus(
      paired: paired,
      baseUrl: paired ? (response?['baseUrl'] as String?) : null,
    );
  }

  @override
  Future<void> pairStation(String pairingUrl) async {
    final clientId =
        await channel.invokeMethod<String>('stationClientId') ??
        'unknown-client';
    final clientLabel =
        await channel.invokeMethod<String>('stationClientLabel') ??
        'Android phone';
    final config = await _StationBackendClient.exchangeBootstrap(
      pairingUrl,
      clientId: clientId,
      clientLabel: clientLabel,
    );
    await channel.invokeMethod<void>('saveStationPairing', {
      'baseUrl': config.baseUrl.toString(),
      'cookie': config.cookie,
      'clientId': config.clientId,
      'hubId': config.hubId,
    });
  }

  @override
  Future<void> clearStationPairing() =>
      channel.invokeMethod<void>('clearStationPairing');

  @override
  Future<List<PairedClientInfo>> pairedClients(String pin) async {
    final station = await _stationBackend();
    if (station != null) return station.pairedClients(pin);
    return const [];
  }

  @override
  Future<void> revokePairedClient({
    required String pin,
    required String clientId,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.revokePairedClient(pin: pin, clientId: clientId);
    }
    throw UnsupportedError('Paired devices are managed by ToyTalk Hub.');
  }

  @override
  Future<ReasoningProviderStatus> reasoningProviderStatus() async {
    final station = await _stationBackend();
    if (station != null) return station.reasoningProviderStatus();
    return const ReasoningProviderStatus(
      provider: 'hub',
      configured: false,
      displayName: 'ToyTalk Hub',
    );
  }

  @override
  Future<void> configureApiKey({
    required String pin,
    required String provider,
    required String apiKey,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.configureApiKey(
        pin: pin,
        provider: provider,
        apiKey: apiKey,
      );
    }
    _hubRequired();
  }

  @override
  Future<void> configureGeminiApiKey(String apiKey) =>
      configureApiKey(pin: '', provider: 'gemini', apiKey: apiKey);

  @override
  Future<List<KidProfile>> kids() async {
    final station = await _stationBackend();
    if (station != null) return station.kids();
    return const [];
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
    final station = await _stationBackend();
    if (station != null) {
      return station.saveKid(
        pin: pin,
        kidId: kidId,
        name: name,
        birthdateIso: birthdateIso,
        photoBytes: photoBytes,
        photoMime: photoMime,
      );
    }
    _hubRequired();
  }

  @override
  Future<void> deleteKid({required String pin, required String kidId}) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.deleteKid(pin: pin, kidId: kidId);
    }
    _hubRequired();
  }

  @override
  Future<LocalModelReadiness> localModelReadiness() async {
    final station = await _stationBackend();
    if (station != null) return station.localModelReadiness();
    return const LocalModelReadiness(
      modelId: 'hub-required',
      displayName: 'ToyTalk Hub',
      ready: false,
      installSupported: false,
      installing: false,
      runtimeMode: 'hub',
      parentConfigured: false,
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
    final station = await _stationBackend();
    if (station != null) {
      return station.beginLocalTurn(
        ageBand: ageBand,
        characterAlias: characterAlias,
        text: text,
        kidId: kidId,
        kidName: kidName,
        childAgeYears: childAgeYears,
        childAgeMonths: childAgeMonths,
        characterPlayAgeYears: characterPlayAgeYears,
      );
    }
    _hubRequired();
  }

  @override
  Future<String> transcribeSpeech(Uint8List wavBytes) async {
    final station = await _stationBackend();
    if (station != null) return station.transcribeSpeech(wavBytes);
    throw UnsupportedError(
      'Hub speech-to-text requires ToyTalk Hub pairing.',
    );
  }

  @override
  Future<void> cancelTurn() async => (await _stationBackend())?.cancelTurn();

  @override
  Future<void> endSession() async => (await _stationBackend())?.endSession();

  @override
  Future<void> installLocalModel() async =>
      (await _stationBackend())?.installLocalModel() ?? _hubRequired();

  @override
  Future<void> cancelModelInstall() async =>
      (await _stationBackend())?.cancelModelInstall();

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
    final station = await _stationBackend();
    if (station != null) {
      return station.configureParentPin(
        pin: pin,
        ageBand: ageBand,
        characterAlias: characterAlias,
        characterTraits: characterTraits,
        parentGuidance: parentGuidance,
        retentionDays: retentionDays,
        kidId: kidId,
      );
    }
    _hubRequired();
  }

  @override
  Future<bool> authorizeParentPin(String pin) async {
    final station = await _stationBackend();
    if (station != null) return station.authorizeParentPin(pin);
    return false;
  }

  @override
  Future<void> deleteAllLocalData(String pin) async =>
      (await _stationBackend())?.deleteAllLocalData(pin) ?? _hubRequired();

  @override
  Future<HubBackup> exportBackup(String pin) async {
    final station = await _stationBackend();
    if (station != null) return station.exportBackup(pin);
    _hubRequired();
  }

  @override
  Future<void> importBackup({
    required String pin,
    required String backupBase64,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.importBackup(pin: pin, backupBase64: backupBase64);
    }
    _hubRequired();
  }

  @override
  Future<List<ConversationHistoryEntry>> history(String pin) async {
    final station = await _stationBackend();
    if (station != null) return station.history(pin);
    return const [];
  }

  @override
  Future<List<ConversationHistoryEntry>> scopedHistory(
    String pin, {
    String? kidId,
    String? characterAlias,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.scopedHistory(
        pin,
        kidId: kidId,
        characterAlias: characterAlias,
      );
    }
    return const [];
  }

  @override
  Future<void> deleteHistory(String pin) async =>
      (await _stationBackend())?.deleteHistory(pin) ?? _hubRequired();

  @override
  Future<List<CharacterConfiguration>> characters() async {
    final station = await _stationBackend();
    if (station != null) return station.characters();
    return const [];
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
    final station = await _stationBackend();
    if (station != null) {
      return station.saveCharacter(
        pin: pin,
        characterAlias: characterAlias,
        characterTraits: characterTraits,
        parentGuidance: parentGuidance,
        kidId: kidId,
        personaAgeYears: personaAgeYears,
      );
    }
    _hubRequired();
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
    final station = await _stationBackend();
    if (station != null) {
      return station.renameCharacter(
        pin: pin,
        currentCharacterAlias: currentCharacterAlias,
        newCharacterAlias: newCharacterAlias,
        characterTraits: characterTraits,
        parentGuidance: parentGuidance,
        kidId: kidId,
        personaAgeYears: personaAgeYears,
      );
    }
    _hubRequired();
  }

  @override
  Future<PickedCharacterPhoto> pickCharacterPhoto() async {
    final picked = await channel.invokeMapMethod<Object?, Object?>(
      'pickCharacterPhoto',
    );
    if (picked == null) throw PlatformException(code: 'no_photo');
    final bytes = picked['bytes'] as Uint8List?;
    if (bytes == null || bytes.isEmpty) {
      throw PlatformException(code: 'invalid_photo');
    }
    return PickedCharacterPhoto(
      bytes: bytes,
      filename: picked['filename'] as String? ?? 'character-photo',
      mime: picked['mime'] as String?,
    );
  }

  @override
  Future<void> saveCharacterPhoto({
    required String pin,
    required String characterAlias,
    required Uint8List photoBytes,
    required String? photoMime,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.saveCharacterPhoto(
        pin: pin,
        characterAlias: characterAlias,
        photoBytes: photoBytes,
        photoMime: photoMime,
      );
    }
    _hubRequired();
  }

  @override
  Future<void> deleteCharacter({
    required String pin,
    required String characterAlias,
    String? kidId,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.deleteCharacter(
        pin: pin,
        characterAlias: characterAlias,
        kidId: kidId,
      );
    }
    _hubRequired();
  }

  @override
  Future<VoiceProfileStatus> voiceStatus({String? characterAlias}) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.voiceStatus(characterAlias: characterAlias);
    }
    return const VoiceProfileStatus(
      enrolled: false,
      approved: false,
      runtimeReady: false,
    );
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
    final station = await _stationBackend();
    if (station != null) {
      final parentAuthorized = await authorizeParentPin(pin);
      if (!parentAuthorized) {
        throw PlatformException(
          code: 'unauthorized',
          message: 'Parent PIN is incorrect or locked',
        );
      }
      Uint8List? uploadBytes = wavBytes;
      String? uploadFilename = sourceFilename;
      String? uploadMime = sourceMime;
      if (uploadBytes == null || uploadBytes.isEmpty) {
        final picked = await channel.invokeMapMethod<Object?, Object?>(
          'pickVoiceSample',
        );
        if (picked == null) throw PlatformException(code: 'no_audio');
        uploadBytes = picked['bytes'] as Uint8List?;
        uploadFilename = picked['filename'] as String?;
        uploadMime = picked['mime'] as String?;
      }
      return station.enrollVoiceSample(
        pin: pin,
        adultAuthorized: adultAuthorized,
        characterAlias: characterAlias,
        wavBytes: uploadBytes,
        sourceFilename: uploadFilename,
        sourceMime: uploadMime,
      );
    }
    _hubRequired();
  }

  @override
  Future<void> previewVoice(String pin, {String? characterAlias}) async {
    final station = await _stationBackend();
    if (station != null) {
      final parentAuthorized = await authorizeParentPin(pin);
      if (!parentAuthorized) {
        throw PlatformException(
          code: 'unauthorized',
          message: 'Parent PIN is incorrect or locked',
        );
      }
      return station.previewVoice(pin, characterAlias: characterAlias);
    }
    _hubRequired();
  }

  @override
  Future<void> approveVoice(String pin, {String? characterAlias}) async {
    final station = await _stationBackend();
    if (station != null) {
      final parentAuthorized = await authorizeParentPin(pin);
      if (!parentAuthorized) {
        throw PlatformException(
          code: 'unauthorized',
          message: 'Parent PIN is incorrect or locked',
        );
      }
      return station.approveVoice(pin, characterAlias: characterAlias);
    }
    _hubRequired();
  }

  @override
  Future<void> deleteVoice(String pin, {String? characterAlias}) async {
    final station = await _stationBackend();
    if (station != null) {
      final parentAuthorized = await authorizeParentPin(pin);
      if (!parentAuthorized) {
        throw PlatformException(
          code: 'unauthorized',
          message: 'Parent PIN is incorrect or locked',
        );
      }
      return station.deleteVoice(pin, characterAlias: characterAlias);
    }
    _hubRequired();
  }

  @override
  Future<Uint8List> synthesizeVoice(
    String text, {
    String? characterAlias,
  }) async {
    final station = await _stationBackend();
    if (station != null) {
      return station.synthesizeVoice(text, characterAlias: characterAlias);
    }
    throw PlatformException(
      code: 'voice_unavailable',
      message: 'Local cloned voice is not installed on Android yet',
    );
  }

  @override
  Future<void> speakWithVoice(String text, {String? characterAlias}) async =>
      (await _stationBackend())?.speakWithVoice(
        text,
        characterAlias: characterAlias,
      ) ??
      _hubRequired();
}

class _StationConfig {
  const _StationConfig({
    required this.baseUrl,
    required this.cookie,
    required this.clientId,
    required this.hubId,
  });

  final Uri baseUrl;
  final String cookie;
  final String clientId;
  final String hubId;

  String get origin => _origin(baseUrl);

  static String _origin(Uri uri) =>
      '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
}

class _StationBackendClient implements BackendClient {
  const _StationBackendClient({required this.config, required this.channel});

  final _StationConfig config;
  final MethodChannel channel;

  static Future<_StationConfig> exchangeBootstrap(
    String pairingUrl, {
    required String clientId,
    required String clientLabel,
  }) async {
    final parsed = Uri.parse(pairingUrl.trim());
    final bootstrap = parsed.fragment
        .split('&')
        .map((part) => part.split('='))
        .where((part) => part.length == 2 && part.first == 'bootstrap')
        .map((part) => Uri.decodeComponent(part.last))
        .firstOrNull;
    if (parsed.scheme != 'http' ||
        parsed.host.isEmpty ||
        parsed.port == 0 ||
        bootstrap == null ||
        bootstrap.isEmpty) {
      throw const FormatException('Paste the full ToyTalk Hub pairing URL.');
    }
    final baseUrl = parsed.replace(path: '', query: '', fragment: '');
    final origin = _StationConfig._origin(baseUrl);
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.postUrl(
        baseUrl.replace(path: '/api/v1/bootstrap'),
      );
      request.headers
        ..set('X-PlushPal-Bootstrap', bootstrap)
        ..set('X-PlushBuddy-Client-Id', clientId)
        ..set('X-PlushBuddy-Client-Label', clientLabel)
        ..set('origin', origin);
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent) {
        final hint = switch (response.statusCode) {
          HttpStatus.unauthorized =>
            'The QR code is stale. Open a fresh pairing QR code in ToyTalk Hub and scan again.',
          HttpStatus.forbidden =>
            'This phone was forgotten by the Hub. Open a fresh pairing QR code and scan again.',
          _ => 'Keep ToyTalk Hub open and scan the latest QR code.',
        };
        throw HttpException(
          'Hub rejected the pairing URL with HTTP ${response.statusCode}. $hint',
        );
      }
      final cookie =
          response.cookies
              .where((cookie) => cookie.name == 'pp_session')
              .map((cookie) => '${cookie.name}=${cookie.value}')
              .firstOrNull ??
          response.headers[HttpHeaders.setCookieHeader]
              ?.expand((value) => value.split(','))
              .map((value) => value.split(';').first.trim())
              .where((value) => value.startsWith('pp_session='))
              .firstOrNull;
      if (cookie == null || cookie.isEmpty) {
        throw const HttpException('Hub did not return a session cookie.');
      }
      final hubId = response.headers.value('x-plushbuddy-hub-id')?.trim();
      if (hubId == null ||
          hubId.isEmpty ||
          !RegExp(r'^hub-[a-f0-9-]{36}$').hasMatch(hubId)) {
        throw const HttpException('Hub did not return a valid Hub ID.');
      }
      return _StationConfig(
        baseUrl: Uri.parse(origin),
        cookie: cookie,
        clientId: clientId,
        hubId: hubId,
      );
    } finally {
      client.close(force: true);
    }
  }

  Uri _uri(String path) => Uri.parse('${config.origin}$path');

  Future<Uint8List> _requestBytes(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool mutating = true,
  }) async {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(method, _uri(path));
      if (authenticated) {
        request.headers.set(HttpHeaders.cookieHeader, config.cookie);
      }
      request.headers.set('X-PlushBuddy-Client-Id', config.clientId);
      request.headers.set('X-PlushBuddy-Hub-Id', config.hubId);
      final clientLabel = await channel
          .invokeMethod<String>('stationClientLabel')
          .catchError((_) => null);
      if (clientLabel != null && clientLabel.trim().isNotEmpty) {
        request.headers.set('X-PlushBuddy-Client-Label', clientLabel.trim());
      }
      // Dart/Android HttpClient is not a browser and does not add Origin
      // automatically. ToyTalk Hub validates API requests against the
      // paired Hub origin for both reads and writes, so send it on every
      // request. Without this, startup GET readiness checks are rejected and
      // the app clears an otherwise valid pairing.
      request.headers.set('origin', config.origin);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 120),
      );
      final bytes = await consolidateHttpClientResponseBytes(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == HttpStatus.unauthorized ||
            response.statusCode == HttpStatus.forbidden) {
          await channel.invokeMethod<void>('clearStationPairing');
        }
        var message = 'Hub request failed with HTTP ${response.statusCode}.';
        try {
          final decoded =
              jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
          message = decoded['message'] as String? ?? message;
        } catch (_) {}
        if (response.statusCode == HttpStatus.unauthorized ||
            response.statusCode == HttpStatus.forbidden) {
          throw HubAuthenticationRejectedException(message);
        }
        throw HttpException(message, uri: _uri(path));
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _requestJson(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool mutating = true,
  }) async =>
      jsonDecode(
            utf8.decode(
              await _requestBytes(
                method,
                path,
                body: body,
                authenticated: authenticated,
                mutating: mutating,
              ),
            ),
          )
          as Map<String, Object?>;

  Future<bool> _voiceEngineReady() async {
    try {
      final health = await _requestJson(
        'GET',
        '/api/v1/health',
        authenticated: false,
        mutating: false,
      );
      final ready = health['voice_engine_ready'] as bool? ?? false;
      debugPrint(
        'ToyTalk Hub health ${config.origin}: voice_engine_ready=$ready',
      );
      return ready;
    } catch (error) {
      debugPrint('ToyTalk Hub health ${config.origin} failed: $error');
      return false;
    }
  }

  Future<List<Object?>> _requestJsonList(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    bool mutating = true,
  }) async =>
      jsonDecode(
            utf8.decode(
              await _requestBytes(
                method,
                path,
                body: body,
                authenticated: authenticated,
                mutating: mutating,
              ),
            ),
          )
          as List<Object?>;

  @override
  Future<StationPairingStatus> stationPairingStatus() async =>
      StationPairingStatus(paired: true, baseUrl: config.baseUrl.toString());

  @override
  Future<void> pairStation(String pairingUrl) =>
      throw UnsupportedError('Already paired to a Hub.');

  @override
  Future<void> clearStationPairing() =>
      throw UnsupportedError('Use the platform backend to clear pairing.');

  @override
  Future<List<PairedClientInfo>> pairedClients(String pin) async {
    final rows = await _requestJsonList(
      'POST',
      '/api/v1/paired-clients',
      body: {'pin': pin},
    );
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
  }) => _requestBytes(
    'POST',
    '/api/v1/paired-clients/revoke',
    body: {'pin': pin, 'client_id': clientId},
  );

  @override
  Future<ReasoningProviderStatus> reasoningProviderStatus() async {
    final decoded = await _requestJson(
      'GET',
      '/api/v1/provider/status',
      mutating: false,
    );
    return ReasoningProviderStatus(
      provider: decoded['provider'] as String? ?? 'gemini',
      configured: decoded['configured'] as bool? ?? false,
      displayName: decoded['display_name'] as String? ?? 'Gemini',
    );
  }

  @override
  Future<void> configureApiKey({
    required String pin,
    required String provider,
    required String apiKey,
  }) async {
    if (pin.isEmpty) {
      throw const HttpException(
        'Open parent settings before saving an API key.',
      );
    }
    await _requestBytes(
      'POST',
      '/api/v1/provider/api-key',
      body: {'pin': pin, 'provider': provider, 'api_key': apiKey},
    );
  }

  @override
  Future<void> configureGeminiApiKey(String apiKey) =>
      configureApiKey(pin: '', provider: 'gemini', apiKey: apiKey);

  @override
  Future<List<KidProfile>> kids() async {
    final rows = await _requestJsonList('GET', '/api/v1/kids', mutating: false);
    return rows.map((item) {
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
  }) => _requestBytes(
    'POST',
    '/api/v1/kids/save',
    body: {
      'pin': pin,
      'kid_id': kidId,
      'name': name,
      'birthdate_iso': birthdateIso,
      'photo_base64': photoBytes == null ? null : base64Encode(photoBytes),
      'photo_mime': photoMime,
    },
  );

  @override
  Future<void> deleteKid({required String pin, required String kidId}) =>
      _requestBytes(
        'POST',
        '/api/v1/kids/delete',
        body: {'pin': pin, 'kid_id': kidId},
      );

  @override
  Future<LocalModelReadiness> localModelReadiness() async {
    final decoded = await _requestJson(
      'GET',
      '/api/v1/status',
      mutating: false,
    );
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
    final requestId = 'android-${DateTime.now().microsecondsSinceEpoch}';
    final turnStartedAt = DateTime.now();
    final wsUri = config.baseUrl.replace(
      scheme: 'ws',
      path: '/api/v1/events',
      query: '',
      fragment: '',
    );
    final socket = await WebSocket.connect(
      wsUri.toString(),
      headers: {
        HttpHeaders.cookieHeader: config.cookie,
        'origin': config.origin,
        'X-PlushBuddy-Client-Id': config.clientId,
        'X-PlushBuddy-Hub-Id': config.hubId,
      },
    ).timeout(const Duration(seconds: 10));
    try {
      final completer = Completer<BackendResponse>();
      final subscription = socket.listen((message) {
        if (message is! String) return;
        final event = jsonDecode(message) as Map<String, Object?>;
        if (event['request_id'] != requestId) return;
        if (event['event'] == 'response_ready') {
          final totalMs = DateTime.now()
              .difference(turnStartedAt)
              .inMilliseconds;
          debugPrint(
            'ToyTalk latency request_id=$requestId phase=android_turn '
            'status=ok total_ms=$totalMs '
            'hub_generate_ms=${event['conversation_generate_ms']} '
            'hub_total_ms=${event['total_ms']}',
          );
          completer.complete(
            BackendResponse(
              speech: event['speech']! as String,
              suggestTrustedAdult: event['suggest_trusted_adult']! as bool,
            ),
          );
        } else if (event['event'] == 'turn_failed') {
          final totalMs = DateTime.now()
              .difference(turnStartedAt)
              .inMilliseconds;
          debugPrint(
            'ToyTalk latency request_id=$requestId phase=android_turn '
            'status=failed total_ms=$totalMs '
            'hub_generate_ms=${event['conversation_generate_ms']} '
            'hub_total_ms=${event['total_ms']}',
          );
          completer.completeError(
            const HttpException('Local generation failed.'),
          );
        }
      }, onError: completer.completeError);
      await _requestBytes(
        'POST',
        '/api/v1/commands',
        body: {
          'schema_version': 1,
          'request_id': requestId,
          'command': 'begin_local_turn',
          'payload': {
            'age_band': ageBand,
            'character_alias': characterAlias,
            'text': text,
            'kid_id': kidId,
            'kid_name': kidName,
            'child_age_years': childAgeYears,
            'child_age_months': childAgeMonths,
            'character_play_age_years': characterPlayAgeYears,
          },
        },
      );
      debugPrint(
        'ToyTalk latency request_id=$requestId phase=android_command '
        'accepted_ms=${DateTime.now().difference(turnStartedAt).inMilliseconds}',
      );
      final response = await completer.future.timeout(
        const Duration(seconds: 45),
      );
      await subscription.cancel();
      return response;
    } finally {
      await socket.close();
    }
  }

  Future<void> _command(String command) => _requestBytes(
    'POST',
    '/api/v1/commands',
    body: {
      'schema_version': 1,
      'request_id': 'android-${DateTime.now().microsecondsSinceEpoch}',
      'command': command,
    },
  );

  @override
  Future<String> transcribeSpeech(Uint8List wavBytes) async {
    if (wavBytes.isEmpty || wavBytes.length > 12 * 1_048_576) {
      throw const HttpException('Recorded speech audio is invalid.');
    }
    final decoded = await _requestJson(
      'POST',
      '/api/v1/stt/transcribe',
      body: {'wav_base64': base64Encode(wavBytes)},
    );
    return decoded['transcript'] as String? ?? '';
  }

  @override
  Future<void> cancelTurn() => _command('cancel_turn');

  @override
  Future<void> endSession() => _command('exit_child_mode');

  @override
  Future<void> installLocalModel() => _command('install_local_model');

  @override
  Future<void> cancelModelInstall() => _command('cancel_model_install');

  @override
  Future<void> configureParentPin({
    required String pin,
    required String ageBand,
    required String characterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    required int? retentionDays,
    String? kidId,
  }) => _requestBytes(
    'POST',
    '/api/v1/parent-pin/configure',
    body: {
      'pin': pin,
      'age_band': ageBand,
      'character_alias': characterAlias,
      'character_traits': characterTraits,
      'parent_guidance': parentGuidance,
      'retention_days': retentionDays,
      'kid_id': kidId,
    },
  );

  @override
  Future<bool> authorizeParentPin(String pin) async {
    try {
      await _requestBytes(
        'POST',
        '/api/v1/parent-pin/authorize',
        body: {'pin': pin},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> deleteAllLocalData(String pin) =>
      _requestBytes('POST', '/api/v1/local-data/delete', body: {'pin': pin});

  @override
  Future<HubBackup> exportBackup(String pin) async {
    final decoded = await _requestJson(
      'POST',
      '/api/v1/backup/export',
      body: {'pin': pin},
    );
    return HubBackup(
      backupBase64: decoded['backup_base64']! as String,
      exportedAt: decoded['exported_at']! as int,
    );
  }

  @override
  Future<void> importBackup({
    required String pin,
    required String backupBase64,
  }) => _requestBytes(
    'POST',
    '/api/v1/backup/import',
    body: {'pin': pin, 'backup_base64': backupBase64},
  );

  @override
  Future<List<ConversationHistoryEntry>> history(String pin) async {
    final rows = await _requestJsonList(
      'POST',
      '/api/v1/history/list',
      body: {'pin': pin},
    );
    return rows.map((item) {
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
  Future<void> deleteHistory(String pin) =>
      _requestBytes('POST', '/api/v1/history/delete', body: {'pin': pin});

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
    final rows = await _requestJsonList(
      'GET',
      '/api/v1/characters',
      mutating: false,
    );
    return rows.map((item) {
      final character = item! as Map<String, Object?>;
      return CharacterConfiguration(
        alias: character['alias']! as String,
        traits: (character['traits'] as List<Object?>? ?? const [])
            .cast<String>(),
        parentGuidance: character['parent_guidance'] as String?,
        voice: _voiceFromJson(character['voice']! as Map<String, Object?>),
        kidId: character['kid_id'] as String?,
        personaAgeYears: character['persona_age_years'] as int?,
        photoBytes: switch (character['photo_base64'] as String?) {
          final value? when value.isNotEmpty => base64Decode(value),
          _ => null,
        },
        photoMime: character['photo_mime'] as String?,
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
  }) => _requestBytes(
    'POST',
    '/api/v1/characters/save',
    body: {
      'pin': pin,
      'character_alias': characterAlias,
      'character_traits': characterTraits,
      'parent_guidance': parentGuidance,
      'kid_id': kidId,
      'persona_age_years': personaAgeYears,
    },
  );

  @override
  Future<void> renameCharacter({
    required String pin,
    required String currentCharacterAlias,
    required String newCharacterAlias,
    required List<String> characterTraits,
    required String? parentGuidance,
    String? kidId,
    int? personaAgeYears,
  }) => _requestBytes(
    'POST',
    '/api/v1/characters/rename',
    body: {
      'pin': pin,
      'current_character_alias': currentCharacterAlias,
      'new_character_alias': newCharacterAlias,
      'character_traits': characterTraits,
      'parent_guidance': parentGuidance,
      'kid_id': kidId,
      'persona_age_years': personaAgeYears,
    },
  );

  @override
  Future<PickedCharacterPhoto> pickCharacterPhoto() async {
    final picked = await channel.invokeMapMethod<Object?, Object?>(
      'pickCharacterPhoto',
    );
    if (picked == null) throw PlatformException(code: 'no_photo');
    final bytes = picked['bytes'] as Uint8List?;
    if (bytes == null || bytes.isEmpty) {
      throw PlatformException(code: 'invalid_photo');
    }
    return PickedCharacterPhoto(
      bytes: bytes,
      filename: picked['filename'] as String? ?? 'character-photo',
      mime: picked['mime'] as String?,
    );
  }

  @override
  Future<void> saveCharacterPhoto({
    required String pin,
    required String characterAlias,
    required Uint8List photoBytes,
    required String? photoMime,
  }) => _requestBytes(
    'POST',
    '/api/v1/characters/photo',
    body: {
      'pin': pin,
      'character_alias': characterAlias,
      'photo_base64': base64Encode(photoBytes),
      'photo_mime': photoMime,
    },
  );

  @override
  Future<void> deleteCharacter({
    required String pin,
    required String characterAlias,
    String? kidId,
  }) => _requestBytes(
    'POST',
    '/api/v1/characters/delete',
    body: {'pin': pin, 'character_alias': characterAlias, 'kid_id': kidId},
  );

  @override
  Future<VoiceProfileStatus> voiceStatus({String? characterAlias}) async {
    final query = characterAlias == null || characterAlias.trim().isEmpty
        ? ''
        : '?character_alias=${Uri.encodeQueryComponent(characterAlias)}';
    final runtimeReady = await _voiceEngineReady();
    try {
      final status = _voiceFromJson(
        await _requestJson(
          'GET',
          '/api/v1/voice/status$query',
          mutating: false,
        ),
      );
      debugPrint(
        'ToyTalk Hub voice status ${config.origin}: '
        'runtime=${status.runtimeReady}, health=$runtimeReady, '
        'enrolled=${status.enrolled}, approved=${status.approved}',
      );
      return VoiceProfileStatus(
        enrolled: status.enrolled,
        approved: status.approved,
        runtimeReady: status.runtimeReady || runtimeReady,
        durationMilliseconds: status.durationMilliseconds,
        profileId: status.profileId,
      );
    } catch (error) {
      debugPrint(
        'ToyTalk Hub voice status ${config.origin} failed: $error; '
        'using health=$runtimeReady',
      );
      return VoiceProfileStatus(
        enrolled: false,
        approved: false,
        runtimeReady: runtimeReady,
      );
    }
  }

  @override
  Future<void> enrollVoiceSample({
    required String pin,
    required bool adultAuthorized,
    String? characterAlias,
    Uint8List? wavBytes,
    String? sourceFilename,
    String? sourceMime,
  }) {
    if (wavBytes == null || wavBytes.isEmpty) {
      throw UnsupportedError(
        'Choose an audio sample before creating a Hub voice profile.',
      );
    }
    final filename = sourceFilename ?? '';
    final mime = sourceMime ?? '';
    final isWav =
        _looksLikeWav(wavBytes) ||
        filename.toLowerCase().endsWith('.wav') ||
        mime == 'audio/wav' ||
        mime == 'audio/x-wav';
    return _requestBytes(
      'POST',
      '/api/v1/voice/enroll',
      body: {
        'pin': pin,
        if (isWav) 'wav_base64': base64Encode(wavBytes),
        if (!isWav) 'source_audio_base64': base64Encode(wavBytes),
        if (!isWav) 'source_filename': sourceFilename,
        if (!isWav) 'source_mime': sourceMime,
        'adult_authorized': adultAuthorized,
        'character_alias': characterAlias,
      },
    );
  }

  bool _looksLikeWav(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x41 && // A
        bytes[10] == 0x56 && // V
        bytes[11] == 0x45; // E
  }

  Future<void> _playWav(Uint8List bytes) =>
      channel.invokeMethod<void>('playWavBytes', {'wavBytes': bytes});

  @override
  Future<void> previewVoice(String pin, {String? characterAlias}) async {
    final bytes = await _requestBytes(
      'POST',
      '/api/v1/voice/preview',
      body: {
        'pin': pin,
        'text': 'Woof woof! Hi friend, let us play!',
        'character_alias': characterAlias,
      },
    );
    await _playWav(bytes);
  }

  @override
  Future<void> approveVoice(String pin, {String? characterAlias}) =>
      _requestBytes(
        'POST',
        '/api/v1/voice/approve',
        body: {'pin': pin, 'character_alias': characterAlias},
      );

  @override
  Future<void> deleteVoice(String pin, {String? characterAlias}) =>
      _requestBytes(
        'POST',
        '/api/v1/voice/delete',
        body: {'pin': pin, 'character_alias': characterAlias},
      );

  @override
  Future<Uint8List> synthesizeVoice(String text, {String? characterAlias}) {
    final requestId = 'android-voice-${DateTime.now().microsecondsSinceEpoch}';
    final startedAt = DateTime.now();
    return _requestBytes(
          'POST',
          '/api/v1/voice/speak',
          body: {
            'text': text,
            'character_alias': characterAlias,
            'request_id': requestId,
          },
        )
        .then((bytes) {
          debugPrint(
            'ToyTalk latency request_id=$requestId phase=android_voice_download '
            'status=ok total_ms=${DateTime.now().difference(startedAt).inMilliseconds} '
            'wav_bytes=${bytes.length}',
          );
          return bytes;
        })
        .catchError((Object error) {
          debugPrint(
            'ToyTalk latency request_id=$requestId phase=android_voice_download '
            'status=failed total_ms=${DateTime.now().difference(startedAt).inMilliseconds} '
            'error=$error',
          );
          throw error;
        });
  }

  @override
  Future<void> speakWithVoice(String text, {String? characterAlias}) async {
    final startedAt = DateTime.now();
    final bytes = await synthesizeVoice(text, characterAlias: characterAlias);
    await _playWav(bytes);
    debugPrint(
      'ToyTalk latency phase=android_voice_playback '
      'status=started total_ms=${DateTime.now().difference(startedAt).inMilliseconds} '
      'wav_bytes=${bytes.length}',
    );
  }
}
