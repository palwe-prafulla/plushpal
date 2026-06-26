(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.PlushPalAudioNormalization = api;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  const TARGET_SAMPLE_RATE = 24000;
  const MIN_DURATION_SECONDS = 15;
  const MAX_DURATION_SECONDS = 180;
  const MAX_IMPORT_DURATION_SECONDS = 180;
  const FRAME_SIZE = 1024;
  const HOP_SIZE = 512;
  const HIGH_PASS_CUTOFF_HZ = 80;
  const TARGET_RMS = 0.10;
  const PEAK_LIMIT = 0.92;

  function writeAscii(view, offset, value) {
    for (let index = 0; index < value.length; index += 1) {
      view.setUint8(offset + index, value.charCodeAt(index));
    }
  }

  function hannWindow(length) {
    const window = new Float32Array(length);
    for (let index = 0; index < length; index += 1) {
      window[index] = 0.5 - 0.5 * Math.cos((2 * Math.PI * index) / (length - 1));
    }
    return window;
  }

  function fft(real, imaginary, inverse) {
    const length = real.length;
    for (let index = 1, swap = 0; index < length; index += 1) {
      let bit = length >> 1;
      for (; swap & bit; bit >>= 1) swap ^= bit;
      swap ^= bit;
      if (index < swap) {
        const temporaryReal = real[index];
        const temporaryImaginary = imaginary[index];
        real[index] = real[swap];
        imaginary[index] = imaginary[swap];
        real[swap] = temporaryReal;
        imaginary[swap] = temporaryImaginary;
      }
    }
    for (let size = 2; size <= length; size <<= 1) {
      const half = size >> 1;
      const direction = inverse ? 1 : -1;
      const phaseStep = direction * 2 * Math.PI / size;
      const stepReal = Math.cos(phaseStep);
      const stepImaginary = Math.sin(phaseStep);
      for (let start = 0; start < length; start += size) {
        let rotationReal = 1;
        let rotationImaginary = 0;
        for (let offset = 0; offset < half; offset += 1) {
          const even = start + offset;
          const odd = even + half;
          const oddReal = real[odd] * rotationReal - imaginary[odd] * rotationImaginary;
          const oddImaginary = real[odd] * rotationImaginary + imaginary[odd] * rotationReal;
          real[odd] = real[even] - oddReal;
          imaginary[odd] = imaginary[even] - oddImaginary;
          real[even] += oddReal;
          imaginary[even] += oddImaginary;
          const nextReal = rotationReal * stepReal - rotationImaginary * stepImaginary;
          rotationImaginary = rotationReal * stepImaginary + rotationImaginary * stepReal;
          rotationReal = nextReal;
        }
      }
    }
    if (inverse) {
      for (let index = 0; index < length; index += 1) {
        real[index] /= length;
        imaginary[index] /= length;
      }
    }
  }

  function resampleAndMix(audioBuffer) {
    const duration = audioBuffer.length / audioBuffer.sampleRate;
    const outputLength = Math.round(duration * TARGET_SAMPLE_RATE);
    const channels = [];
    for (let channel = 0; channel < audioBuffer.numberOfChannels; channel += 1) {
      channels.push(audioBuffer.getChannelData(channel));
    }
    const sourceStep = audioBuffer.sampleRate / TARGET_SAMPLE_RATE;
    const mixedSamples = new Float32Array(outputLength);
    for (let outputIndex = 0; outputIndex < outputLength; outputIndex += 1) {
      const sourcePosition = outputIndex * sourceStep;
      const lower = Math.min(Math.floor(sourcePosition), audioBuffer.length - 1);
      const upper = Math.min(lower + 1, audioBuffer.length - 1);
      const fraction = sourcePosition - lower;
      let mixed = 0;
      for (const channel of channels) {
        mixed += channel[lower] + (channel[upper] - channel[lower]) * fraction;
      }
      mixedSamples[outputIndex] = Math.max(-1, Math.min(1, mixed / channels.length));
    }
    return mixedSamples;
  }

  function rms(samples, start, end) {
    let energy = 0;
    for (let index = start; index < end; index += 1) {
      energy += samples[index] * samples[index];
    }
    return Math.sqrt(energy / Math.max(1, end - start));
  }

  function selectBestSpeechWindow(samples) {
    const maximumLength = Math.round(MAX_DURATION_SECONDS * TARGET_SAMPLE_RATE);
    if (samples.length <= maximumLength) return samples;

    const windowLength = maximumLength;
    const step = TARGET_SAMPLE_RATE;
    let bestStart = 0;
    let bestScore = -Infinity;
    for (let start = 0; start + windowLength <= samples.length; start += step) {
      const secondScores = [];
      for (let offset = 0; offset < windowLength; offset += step) {
        secondScores.push(rms(samples, start + offset, Math.min(start + offset + step, samples.length)));
      }
      const sorted = secondScores.slice().sort((a, b) => a - b);
      const quietCount = Math.max(1, Math.floor(sorted.length * 0.15));
      const speechCount = Math.max(1, Math.floor(sorted.length * 0.55));
      const quiet =
        sorted.slice(0, quietCount).reduce((sum, value) => sum + value, 0) / quietCount;
      const speech =
        sorted.slice(-speechCount).reduce((sum, value) => sum + value, 0) / speechCount;
      const score = speech - quiet * 0.6;
      if (score > bestScore) {
        bestScore = score;
        bestStart = start;
      }
    }
    return samples.slice(bestStart, bestStart + windowLength);
  }

  function highPass(samples) {
    const filtered = new Float32Array(samples.length);
    const dt = 1 / TARGET_SAMPLE_RATE;
    const rc = 1 / (2 * Math.PI * HIGH_PASS_CUTOFF_HZ);
    const alpha = rc / (rc + dt);
    let previousInput = samples[0] || 0;
    let previousOutput = 0;
    for (let index = 0; index < samples.length; index += 1) {
      const current = samples[index];
      const output = alpha * (previousOutput + current - previousInput);
      filtered[index] = output;
      previousInput = current;
      previousOutput = output;
    }
    return filtered;
  }

  function frameRmsValues(samples, window) {
    const values = [];
    for (let start = 0; start + FRAME_SIZE <= samples.length; start += HOP_SIZE) {
      let energy = 0;
      for (let index = 0; index < FRAME_SIZE; index += 1) {
        const sample = samples[start + index] * window[index];
        energy += sample * sample;
      }
      values.push({start, value: Math.sqrt(energy / FRAME_SIZE)});
    }
    return values;
  }

  function estimateNoiseSpectrum(samples, window, frames) {
    const sorted = frames.slice().sort((a, b) => a.value - b.value);
    const noiseFrames = sorted.slice(0, Math.max(3, Math.floor(sorted.length * 0.15)));
    const noise = new Float32Array(FRAME_SIZE);
    const real = new Float32Array(FRAME_SIZE);
    const imaginary = new Float32Array(FRAME_SIZE);
    for (const frame of noiseFrames) {
      real.fill(0);
      imaginary.fill(0);
      for (let index = 0; index < FRAME_SIZE; index += 1) {
        real[index] = (samples[frame.start + index] || 0) * window[index];
      }
      fft(real, imaginary, false);
      for (let bin = 0; bin < FRAME_SIZE; bin += 1) {
        noise[bin] += Math.hypot(real[bin], imaginary[bin]);
      }
    }
    for (let bin = 0; bin < FRAME_SIZE; bin += 1) {
      noise[bin] /= noiseFrames.length;
    }
    return noise;
  }

  function spectralNoiseReduction(samples) {
    if (samples.length < FRAME_SIZE * 2) return samples;
    const window = hannWindow(FRAME_SIZE);
    const frames = frameRmsValues(samples, window);
    if (frames.length < 3) return samples;
    const noise = estimateNoiseSpectrum(samples, window, frames);
    const output = new Float32Array(samples.length);
    const normalization = new Float32Array(samples.length);
    const real = new Float32Array(FRAME_SIZE);
    const imaginary = new Float32Array(FRAME_SIZE);

    for (const frame of frames) {
      real.fill(0);
      imaginary.fill(0);
      for (let index = 0; index < FRAME_SIZE; index += 1) {
        real[index] = (samples[frame.start + index] || 0) * window[index];
      }
      fft(real, imaginary, false);
      for (let bin = 0; bin < FRAME_SIZE; bin += 1) {
        const magnitude = Math.hypot(real[bin], imaginary[bin]);
        if (magnitude <= 0) continue;
        const cleaned = Math.max(magnitude * 0.35, magnitude - noise[bin] * 0.55);
        const scale = cleaned / magnitude;
        real[bin] *= scale;
        imaginary[bin] *= scale;
      }
      fft(real, imaginary, true);
      for (let index = 0; index < FRAME_SIZE; index += 1) {
        const target = frame.start + index;
        if (target >= output.length) break;
        const weight = window[index] * window[index];
        output[target] += real[index] * window[index];
        normalization[target] += weight;
      }
    }
    for (let index = 0; index < output.length; index += 1) {
      output[index] = normalization[index] > 0
        ? output[index] / normalization[index]
        : samples[index];
    }
    return output;
  }

  function softGateAndNormalize(samples) {
    const gateWindowSize = Math.max(1, Math.floor(TARGET_SAMPLE_RATE / 50));
    const windowRms = [];
    for (let start = 0; start < samples.length; start += gateWindowSize) {
      windowRms.push(rms(samples, start, Math.min(samples.length, start + gateWindowSize)));
    }
    const sorted = windowRms.slice().sort((a, b) => a - b);
    const noiseWindowCount = Math.max(1, Math.floor(sorted.length / 10));
    const noiseFloor =
      sorted.slice(0, noiseWindowCount).reduce((sum, value) => sum + value, 0) /
      noiseWindowCount;
    const gateThreshold = Math.min(0.020, Math.max(0.0015, noiseFloor * 1.35));
    const cleaned = new Float32Array(samples.length);
    const magnitudes = new Float32Array(samples.length);
    let energy = 0;
    let peak = 0;
    for (let index = 0; index < samples.length; index += 1) {
      const magnitude = Math.abs(samples[index]);
      const gateGain = magnitude < gateThreshold
        ? Math.max(0.45, magnitude / Math.max(gateThreshold, 0.000001))
        : 1;
      const sample = samples[index] * gateGain;
      cleaned[index] = sample;
      magnitudes[index] = Math.abs(sample);
      energy += sample * sample;
      peak = Math.max(peak, Math.abs(sample));
    }
    const currentRms = Math.sqrt(energy / Math.max(1, cleaned.length));
    const rmsGain = currentRms > 0 ? TARGET_RMS / currentRms : 1;
    magnitudes.sort();
    const robustPeak =
      magnitudes[Math.min(magnitudes.length - 1, Math.floor(magnitudes.length * 0.995))] ||
      peak;
    const peakGain = robustPeak > 0 ? PEAK_LIMIT / robustPeak : 1;
    const gain = Math.min(rmsGain, peakGain, 64);
    for (let index = 0; index < cleaned.length; index += 1) {
      cleaned[index] = Math.max(-PEAK_LIMIT, Math.min(PEAK_LIMIT, cleaned[index] * gain));
    }
    return cleaned;
  }

  function cleanVoiceReference(samples) {
    const selected = selectBestSpeechWindow(samples);
    const highPassed = highPass(selected);
    const denoised = spectralNoiseReduction(highPassed);
    return softGateAndNormalize(denoised);
  }

  function wavFromSamples(samples) {
    const wav = new ArrayBuffer(44 + samples.length * 2);
    const view = new DataView(wav);
    writeAscii(view, 0, 'RIFF');
    view.setUint32(4, 36 + samples.length * 2, true);
    writeAscii(view, 8, 'WAVE');
    writeAscii(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, TARGET_SAMPLE_RATE, true);
    view.setUint32(28, TARGET_SAMPLE_RATE * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    writeAscii(view, 36, 'data');
    view.setUint32(40, samples.length * 2, true);
    for (let index = 0; index < samples.length; index += 1) {
      const sample = Math.max(-1, Math.min(1, samples[index]));
      const pcm = sample < 0 ? Math.round(sample * 32768) : Math.round(sample * 32767);
      view.setInt16(44 + index * 2, pcm, true);
    }
    return new Uint8Array(wav);
  }

  function normalizeAudioBufferToWav(audioBuffer) {
    if (!audioBuffer ||
        !Number.isFinite(audioBuffer.sampleRate) ||
        audioBuffer.sampleRate < 8000 ||
        audioBuffer.numberOfChannels < 1 ||
        audioBuffer.length < 1) {
      throw new Error('The selected recording could not be decoded');
    }
    const duration = audioBuffer.length / audioBuffer.sampleRate;
    if (duration < MIN_DURATION_SECONDS || duration > MAX_IMPORT_DURATION_SECONDS) {
      throw new Error('Choose a recording between 15 seconds and 3 minutes');
    }

    const mixedSamples = resampleAndMix(audioBuffer);
    const cleanedSamples = cleanVoiceReference(mixedSamples);
    return wavFromSamples(cleanedSamples);
  }

  return Object.freeze({
    TARGET_SAMPLE_RATE,
    MIN_DURATION_SECONDS,
    MAX_DURATION_SECONDS,
    normalizeAudioBufferToWav,
  });
});
