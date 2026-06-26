'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  TARGET_SAMPLE_RATE,
  normalizeAudioBufferToWav,
} = require('../web/audio_normalization.js');

function decodedFixture({seconds = 20, sampleRate = 48000, channels = 2} = {}) {
  const length = seconds * sampleRate;
  const data = Array.from({length: channels}, (_, channel) => {
    const samples = new Float32Array(length);
    for (let index = 0; index < length; index += 1) {
      samples[index] =
        Math.sin(2 * Math.PI * (channel + 1) * 220 * index / sampleRate) * 0.2;
    }
    return samples;
  });
  return {
    sampleRate,
    numberOfChannels: channels,
    length,
    getChannelData: (channel) => data[channel],
  };
}

function noisySpeechFixture({seconds = 20, sampleRate = 48000, channels = 1} = {}) {
  const length = seconds * sampleRate;
  let seed = 7;
  function noise() {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return (seed / 0xffffffff) * 2 - 1;
  }
  const data = Array.from({length: channels}, () => {
    const samples = new Float32Array(length);
    for (let index = 0; index < length; index += 1) {
      const time = index / sampleRate;
      const stationaryNoise = noise() * 0.035 + Math.sin(2 * Math.PI * 90 * time) * 0.025;
      const speechLike = time < 3
        ? 0
        : Math.sin(2 * Math.PI * 220 * time) * 0.18 +
          Math.sin(2 * Math.PI * 440 * time) * 0.05;
      samples[index] = stationaryNoise + speechLike;
    }
    return samples;
  });
  return {
    sampleRate,
    numberOfChannels: channels,
    length,
    getChannelData: (channel) => data[channel],
  };
}

function pcmSamples(wav) {
  const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
  const samples = new Float32Array((wav.length - 44) / 2);
  for (let offset = 44, index = 0; offset < wav.length; offset += 2, index += 1) {
    samples[index] = view.getInt16(offset, true) / 32768;
  }
  return samples;
}

function rms(samples, startSecond, endSecond) {
  const start = Math.floor(startSecond * TARGET_SAMPLE_RATE);
  const end = Math.min(samples.length, Math.floor(endSecond * TARGET_SAMPLE_RATE));
  let energy = 0;
  for (let index = start; index < end; index += 1) {
    energy += samples[index] * samples[index];
  }
  return Math.sqrt(energy / Math.max(1, end - start));
}

function overallRms(samples) {
  let energy = 0;
  for (const sample of samples) energy += sample * sample;
  return Math.sqrt(energy / Math.max(1, samples.length));
}

test('decoded M4A-style stereo audio becomes validated mono PCM WAV', () => {
  const wav = normalizeAudioBufferToWav(decodedFixture());
  const view = new DataView(wav.buffer);
  assert.equal(Buffer.from(wav.subarray(0, 4)).toString(), 'RIFF');
  assert.equal(Buffer.from(wav.subarray(8, 12)).toString(), 'WAVE');
  assert.equal(view.getUint16(20, true), 1);
  assert.equal(view.getUint16(22, true), 1);
  assert.equal(view.getUint32(24, true), TARGET_SAMPLE_RATE);
  assert.equal(view.getUint16(34, true), 16);
  assert.equal(wav.length, 44 + 20 * TARGET_SAMPLE_RATE * 2);
});

test('normalization rejects recordings outside the enrollment duration window', () => {
  assert.throws(
    () => normalizeAudioBufferToWav(decodedFixture({seconds: 14})),
    /between 15 seconds and 3 minutes/,
  );
  assert.throws(
    () => normalizeAudioBufferToWav(decodedFixture({seconds: 181})),
    /between 15 seconds and 3 minutes/,
  );
});

test('normalization preserves longer recorder files within the enrollment window', () => {
  const wav = normalizeAudioBufferToWav(decodedFixture({seconds: 55}));
  assert.equal(wav.length, 44 + 55 * TARGET_SAMPLE_RATE * 2);
});

test('normalization reduces stationary background noise before enrollment', () => {
  const wav = normalizeAudioBufferToWav(noisySpeechFixture());
  const samples = pcmSamples(wav);
  const roomTone = rms(samples, 0.25, 2.75);
  const voiced = rms(samples, 5, 8);
  assert.ok(roomTone < voiced * 0.35, `room tone ${roomTone} should be well below speech ${voiced}`);
});

test('normalization keeps cleaned speech loud enough for backend enrollment', () => {
  const wav = normalizeAudioBufferToWav(noisySpeechFixture({seconds: 40}));
  const samples = pcmSamples(wav);
  const enrollmentRms = overallRms(samples);
  const clipped = samples.filter((sample) => Math.abs(sample) >= 32440 / 32768).length;
  assert.ok(
    enrollmentRms >= 0.005,
    `backend requires RMS >= 0.005, got ${enrollmentRms}`,
  );
  assert.equal(clipped, 0);
});
