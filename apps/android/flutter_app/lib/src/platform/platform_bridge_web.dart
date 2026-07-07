import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/services.dart';

import 'platform_bridge_types.dart';

@JS('toytalkWebSpeechSupported')
external JSBoolean _webSpeechSupported();

@JS('toytalkNativeSpeechSupported')
external JSBoolean _nativeSpeechSupported();

@JS('toytalkNativeListen')
external JSPromise<JSString> _nativeListen();

@JS('toytalkRecordSpeechWav')
external JSPromise<JSString> _recordSpeechWav();

@JS('toytalkSpeakText')
external JSPromise<JSAny?> _speakText(JSString text);

@JS('toytalkPlayWavBase64')
external JSPromise<JSAny?> _playWavBase64(JSString wavBase64);

class MethodChannelPlatformBridge implements PlatformBridge {
  const MethodChannelPlatformBridge({MethodChannel? channel});

  @override
  bool get supportsSpeech {
    try {
      return _nativeSpeechSupported().toDart || _webSpeechSupported().toDart;
    } catch (_) {
      try {
        return _webSpeechSupported().toDart;
      } catch (_) {
        return false;
      }
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
    throw UnsupportedError('Browser secrets are stored by ToyTalk Hub.');
  }

  @override
  Future<void> deleteSecret(String reference) async {}

  @override
  Future<bool> ensureMicrophonePermission() async => supportsSpeech;

  @override
  Future<String> listen() async {
    try {
      return (await _nativeListen().toDart).toDart;
    } catch (error) {
      throw PlatformException(
        code: 'speech_on_device_unavailable',
        message: 'Browser on-device speech recognition is unavailable.',
        details: error.toString(),
      );
    }
  }

  @override
  Future<Uint8List> recordSpeechWav() async {
    final wavBase64 = (await _recordSpeechWav().toDart).toDart;
    return base64Decode(wavBase64);
  }

  @override
  Future<void> playWavBytes(Uint8List wavBytes) async {
    await _playWavBase64(base64Encode(wavBytes).toJS).toDart;
  }

  @override
  Future<void> speak(String text) async {
    await _speakText(text.toJS).toDart;
  }

  @override
  Future<void> cancelSpeech() async {}
}
