import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/services.dart';

import 'platform_bridge_types.dart';

@JS('plushpalWebSpeechSupported')
external JSBoolean _webSpeechSupported();

@JS('plushpalRecordSpeechWav')
external JSPromise<JSString> _recordSpeechWav();

@JS('plushpalSpeakText')
external JSPromise<JSAny?> _speakText(JSString text);

class MethodChannelPlatformBridge implements PlatformBridge {
  const MethodChannelPlatformBridge({MethodChannel? channel});

  @override
  bool get supportsSpeech {
    try {
      return _webSpeechSupported().toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DeviceProfile> deviceProfile() async => const DeviceProfile(
    platform: 'web',
    memoryBytes: 0,
    logicalProcessors: 0,
  );

  @override
  Future<String> storeSecret(String label, String value) {
    throw UnsupportedError('Browser secrets are stored by PlushBuddy Hub.');
  }

  @override
  Future<void> deleteSecret(String reference) async {}

  @override
  Future<bool> ensureMicrophonePermission() async => supportsSpeech;

  @override
  Future<String> listen() {
    throw PlatformException(
      code: 'speech_on_device_unavailable',
      message: 'Browser on-device speech recognition is unavailable.',
    );
  }

  @override
  Future<Uint8List> recordSpeechWav() async {
    final wavBase64 = (await _recordSpeechWav().toDart).toDart;
    return base64Decode(wavBase64);
  }

  @override
  Future<void> playWavBytes(Uint8List wavBytes) {
    throw UnsupportedError(
      'Browser WAV playback is handled by Hub voice APIs.',
    );
  }

  @override
  Future<void> speak(String text) async {
    await _speakText(text.toJS).toDart;
  }

  @override
  Future<void> cancelSpeech() async {}
}
