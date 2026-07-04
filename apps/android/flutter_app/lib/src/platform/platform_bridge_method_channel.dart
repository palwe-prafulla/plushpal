import 'package:flutter/services.dart';

import 'platform_bridge_types.dart';

class MethodChannelPlatformBridge implements PlatformBridge {
  const MethodChannelPlatformBridge({
    this._channel = const MethodChannel('com.plushpal/platform'),
  });

  final MethodChannel _channel;

  @override
  bool get supportsSpeech => true;

  @override
  Future<DeviceProfile> deviceProfile() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'deviceProfile',
    );
    if (map == null) throw PlatformException(code: 'invalid_profile');
    return DeviceProfile.fromMap(map);
  }

  @override
  Future<String> storeSecret(String label, String value) async {
    if (label.trim().isEmpty || value.isEmpty) {
      throw PlatformException(code: 'invalid_secret');
    }
    final reference = await _channel.invokeMethod<String>('storeSecret', {
      'label': label,
      'value': value,
    });
    if (reference == null || reference.isEmpty) {
      throw PlatformException(code: 'vault_failure');
    }
    return reference;
  }

  @override
  Future<void> deleteSecret(String reference) =>
      _channel.invokeMethod<void>('deleteSecret', {'reference': reference});

  @override
  Future<bool> ensureMicrophonePermission() async =>
      (await _channel.invokeMethod<bool>('ensureMicrophonePermission')) ??
      false;

  @override
  Future<String> listen() async =>
      (await _channel.invokeMethod<String>('listen')) ?? '';

  @override
  Future<Uint8List> recordSpeechWav() async =>
      (await _channel.invokeMethod<Uint8List>('recordSpeechWav')) ??
      Uint8List(0);

  @override
  Future<void> playWavBytes(Uint8List wavBytes) =>
      _channel.invokeMethod<void>('playWavBytes', {'wavBytes': wavBytes});

  @override
  Future<void> speak(String text) =>
      _channel.invokeMethod<void>('speak', {'text': text});

  @override
  Future<void> cancelSpeech() => _channel.invokeMethod<void>('cancelSpeech');
}
