import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DeviceProfile {
  const DeviceProfile({
    required this.platform,
    required this.memoryBytes,
    required this.logicalProcessors,
  });

  final String platform;
  final int memoryBytes;
  final int logicalProcessors;

  factory DeviceProfile.fromMap(Map<Object?, Object?> map) => DeviceProfile(
    platform: map['platform']! as String,
    memoryBytes: map['memoryBytes']! as int,
    logicalProcessors: map['logicalProcessors']! as int,
  );
}

abstract interface class PlatformBridge {
  bool get supportsSpeech;
  Future<DeviceProfile> deviceProfile();
  Future<String> storeSecret(String label, String value);
  Future<void> deleteSecret(String reference);
  Future<bool> ensureMicrophonePermission();
  Future<String> listen();
  Future<void> playWavBytes(Uint8List wavBytes);
  Future<void> speak(String text);
  Future<void> cancelSpeech();
}

class MethodChannelPlatformBridge implements PlatformBridge {
  const MethodChannelPlatformBridge({
    this._channel = const MethodChannel('com.plushpal/platform'),
  });

  final MethodChannel _channel;

  @override
  bool get supportsSpeech => !kIsWeb;

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
  Future<void> playWavBytes(Uint8List wavBytes) =>
      _channel.invokeMethod<void>('playWavBytes', {'wavBytes': wavBytes});

  @override
  Future<void> speak(String text) =>
      _channel.invokeMethod<void>('speak', {'text': text});

  @override
  Future<void> cancelSpeech() => _channel.invokeMethod<void>('cancelSpeech');
}
