import 'dart:typed_data';

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
  Future<Uint8List> recordSpeechWav();
  Future<void> playWavBytes(Uint8List wavBytes);
  Future<void> speak(String text);
  Future<void> cancelSpeech();
}
