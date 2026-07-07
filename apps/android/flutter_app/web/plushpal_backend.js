(() => {
  const CLIENT_ID_KEY = 'toytalk-web-client-id-v1';
  const HUB_ID_KEY = 'toytalk-web-hub-id-v1';
  const DEFAULT_TRAITS = ['gentle', 'curious'];
  let activeAudio = null;

  const clientPlatform = () => {
    const platform = String(window.__toytalkClientPlatform || 'web').toLowerCase();
    return /^(web|macos)$/.test(platform) ? platform : 'web';
  };

  const clientIdStorageKey = () => {
    const platform = clientPlatform();
    return platform === 'web' ? CLIENT_ID_KEY : `toytalk-${platform}-client-id-v1`;
  };

  const clientIdPattern = (platform) =>
    new RegExp(`^${platform}-[a-f0-9-]{36}$`);

  const bytesToBase64 = (bytes) => {
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
  };

  const encodeWavBase64 = (samples, sampleRate) => {
    const bytesPerSample = 2;
    const buffer = new ArrayBuffer(44 + samples.length * bytesPerSample);
    const view = new DataView(buffer);
    const writeAscii = (offset, value) => {
      for (let index = 0; index < value.length; index += 1) {
        view.setUint8(offset + index, value.charCodeAt(index));
      }
    };
    writeAscii(0, 'RIFF');
    view.setUint32(4, 36 + samples.length * bytesPerSample, true);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * bytesPerSample, true);
    view.setUint16(32, bytesPerSample, true);
    view.setUint16(34, 16, true);
    writeAscii(36, 'data');
    view.setUint32(40, samples.length * bytesPerSample, true);
    let offset = 44;
    for (const sample of samples) {
      const clamped = Math.max(-1, Math.min(1, sample));
      view.setInt16(offset, clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff, true);
      offset += 2;
    }
    return bytesToBase64(new Uint8Array(buffer));
  };

  const resampleLinear = (chunks, sourceRate, targetRate) => {
    const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    const source = new Float32Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      source.set(chunk, offset);
      offset += chunk.length;
    }
    if (!source.length || sourceRate === targetRate) return source;
    const targetLength = Math.max(1, Math.round(source.length * targetRate / sourceRate));
    const target = new Float32Array(targetLength);
    const ratio = (source.length - 1) / Math.max(1, targetLength - 1);
    for (let index = 0; index < targetLength; index += 1) {
      const position = index * ratio;
      const left = Math.floor(position);
      const right = Math.min(source.length - 1, left + 1);
      const weight = position - left;
      target[index] = source[left] * (1 - weight) + source[right] * weight;
    }
    return target;
  };

  window.toytalkWebSpeechSupported = () =>
    Boolean(
      navigator.mediaDevices?.getUserMedia &&
      (window.AudioContext || window.webkitAudioContext)
    );

  window.toytalkNativeSpeechSupported ??= () => false;

  window.toytalkNativeListen ??= async () => {
    throw new Error('Native on-device speech recognition is unavailable.');
  };

  window.toytalkRecordSpeechWav = async () => {
    if (!window.toytalkWebSpeechSupported()) {
      throw new Error('Browser microphone capture is unavailable.');
    }
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    const AudioContextCtor = window.AudioContext || window.webkitAudioContext;
    const audioContext = new AudioContextCtor();
    const sourceSampleRate = audioContext.sampleRate || 48_000;
    const source = audioContext.createMediaStreamSource(stream);
    const processor = audioContext.createScriptProcessor(4096, 1, 1);
    const sink = audioContext.createGain();
    sink.gain.value = 0;
    const chunks = [];
    let started = false;
    let lastVoiceAt = performance.now();
    const startedAt = performance.now();
    const stopTracks = () => {
      for (const track of stream.getTracks()) track.stop();
    };
    try {
      await new Promise((resolve) => {
        processor.onaudioprocess = (event) => {
          const input = event.inputBuffer.getChannelData(0);
          chunks.push(new Float32Array(input));
          let peak = 0;
          for (let index = 0; index < input.length; index += 1) {
            peak = Math.max(peak, Math.abs(input[index]));
          }
          const now = performance.now();
          if (peak > 0.025) {
            started = true;
            lastVoiceAt = now;
          }
          if (now - startedAt >= 10_000) resolve();
          if (!started && now - startedAt >= 5_000) resolve();
          if (started && now - startedAt >= 1_200 && now - lastVoiceAt >= 1_800) resolve();
        };
        source.connect(processor);
        processor.connect(sink);
        sink.connect(audioContext.destination);
      });
    } finally {
      processor.disconnect();
      source.disconnect();
      sink.disconnect();
      stopTracks();
      await audioContext.close().catch(() => {});
    }
    const samples = resampleLinear(chunks, sourceSampleRate, 16_000);
    if (samples.length < 800) throw new Error('I did not hear speech yet. Try again after the beep.');
    return encodeWavBase64(samples, 16_000);
  };

  window.toytalkSpeakText = async (text) => {
    if (!window.speechSynthesis || !window.SpeechSynthesisUtterance) {
      throw new Error('Browser speech synthesis is unavailable.');
    }
    await new Promise((resolve, reject) => {
      const utterance = new SpeechSynthesisUtterance(String(text || '').slice(0, 2000));
      utterance.lang = 'en-US';
      utterance.onend = resolve;
      utterance.onerror = () => reject(new Error('Browser speech synthesis failed.'));
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(utterance);
    });
  };

  const newId = (prefix) => `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;

  const stableClientId = () => {
    const platform = clientPlatform();
    const key = clientIdStorageKey();
    try {
      const existing = window.localStorage.getItem(key);
      if (clientIdPattern(platform).test(existing || '')) return existing;
      if (platform === 'macos') {
        const legacyWeb = window.localStorage.getItem(CLIENT_ID_KEY);
        if (/^web-[a-f0-9-]{36}$/.test(legacyWeb || '')) {
          const migrated = `macos-${legacyWeb.slice(4)}`;
          window.localStorage.setItem(key, migrated);
          return migrated;
        }
      }
      const generated = `${platform}-${crypto.randomUUID()}`;
      window.localStorage.setItem(key, generated);
      return generated;
    } catch (_) {
      return `${platform}-${crypto.randomUUID()}`;
    }
  };

  const stableClientLabel = () => {
    if (window.__toytalkClientLabel) {
      return String(window.__toytalkClientLabel).slice(0, 80);
    }
    const nav = window.navigator || {};
    const platform =
      nav.userAgentData?.platform || nav.platform || 'browser';
    return `Browser on ${String(platform).slice(0, 60)}`;
  };

  const storedHubId = () => {
    try {
      const existing = window.localStorage.getItem(HUB_ID_KEY);
      return /^hub-[a-f0-9-]{36}$/.test(existing || '') ? existing : null;
    } catch (_) {
      return null;
    }
  };

  const rememberHubId = (hubId) => {
    if (!/^hub-[a-f0-9-]{36}$/.test(hubId || '')) return;
    try {
      window.localStorage.setItem(HUB_ID_KEY, hubId);
    } catch (_) {}
  };

  const currentBootstrapToken = () => {
    const hash = window.location.hash || '';
    const match = hash.match(/[#&]bootstrap=([^&]+)/);
    return match ? decodeURIComponent(match[1]) : null;
  };

  let bootstrapAttempted = false;
  const ensureStationSession = async () => {
    if (!bootstrapAttempted && window.__toytalkStationBootstrapReady) {
      bootstrapAttempted = true;
      const status = await window.__toytalkStationBootstrapReady;
      if (status === 'failed') {
        throw new Error('Hub session expired. Open ToyTalk from Hub again.');
      }
      return;
    }

    const token = currentBootstrapToken();
    if (token && !bootstrapAttempted) {
      bootstrapAttempted = true;
      const response = await fetch('/api/v1/bootstrap', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'x-plushpal-bootstrap': token,
          'x-plushbuddy-client-id': stableClientId(),
          'x-plushbuddy-client-label': stableClientLabel(),
        },
      });
      if (!response.ok) throw new Error('Hub session expired. Open ToyTalk from Hub again.');
      rememberHubId(response.headers.get('x-plushbuddy-hub-id'));
      history.replaceState(null, document.title, `${window.location.pathname}${window.location.search}`);
      return;
    }
    bootstrapAttempted = true;
  };

  const stationFetch = async (path, options = {}) => {
    await ensureStationSession();
    const response = await fetch(path, {
      credentials: 'same-origin',
      cache: 'no-store',
      ...options,
      headers: {
        ...(options.body ? {'Content-Type': 'application/json'} : {}),
        'X-PlushBuddy-Client-Id': stableClientId(),
        ...(storedHubId() ? {'X-PlushBuddy-Hub-Id': storedHubId()} : {}),
        ...(options.headers || {}),
      },
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error('Hub session is not ready. Open this browser or Mac app from ToyTalk Hub again.');
    }
    return response;
  };

  const stationStatus = async () => {
    try {
      const response = await stationFetch('/api/v1/status');
      if (!response.ok) throw new Error('status failed');
      return await response.json();
    } catch (_) {
      return null;
    }
  };

  const responseErrorMessage = async (response, fallback) => {
    let body = '';
    try {
      body = await response.text();
    } catch (_) {
      body = '';
    }
    if (body) {
      try {
        const decoded = JSON.parse(body);
        if (decoded && typeof decoded.message === 'string' && decoded.message.trim()) {
          return decoded.message.trim();
        }
      } catch (_) {
        if (body.trim()) return body.trim();
      }
    }
    if (response.status === 413) return 'The voice sample is too large after local conversion.';
    if (response.status === 422) return 'Use a clean 15-second to 3-minute voice recording.';
    return fallback;
  };

  const voiceStatusFor = async (characterAlias) => {
    const query = characterAlias
      ? `?character_alias=${encodeURIComponent(characterAlias)}`
      : '';
    try {
      const response = await stationFetch(`/api/v1/voice/status${query}`);
      if (!response.ok) throw new Error('Voice status unavailable');
      return await response.json();
    } catch (_) {
      return {
        enrolled: false,
        approved: false,
        runtime_ready: false,
        duration_milliseconds: null,
        profile_id: characterAlias || null,
      };
    }
  };

  const playWavResponse = async (response) => {
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Local voice synthesis failed'));
    }
    if (window.toytalkNativeAudioSupported && window.toytalkNativeAudioSupported()) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      await window.toytalkNativePlayWavBase64(bytesToBase64(bytes));
      return;
    }
    await playWavBlob(await response.blob());
  };

  const playWavBlob = async (blob) => {
    if (activeAudio) {
      activeAudio.pause();
      activeAudio = null;
    }
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    activeAudio = audio;
    try {
      await new Promise((resolve, reject) => {
        audio.onended = resolve;
        audio.onerror = () => reject(new Error('Audio playback failed'));
        audio.play().catch(reject);
      });
    } finally {
      URL.revokeObjectURL(url);
      if (activeAudio === audio) activeAudio = null;
    }
  };

  window.toytalkPlayWavBase64 = async (wavBase64) => {
    if (window.toytalkNativeAudioSupported && window.toytalkNativeAudioSupported()) {
      await window.toytalkNativePlayWavBase64(wavBase64);
      return;
    }
    const binary = atob(String(wavBase64 || ''));
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    await playWavBlob(new Blob([bytes], {type: 'audio/wav'}));
  };

  window.toytalkReasoningProviderStatus = async () => {
    const response = await stationFetch('/api/v1/provider/status');
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Reasoning provider status failed'));
    }
    return JSON.stringify(await response.json());
  };

  window.toytalkConfigureApiKey = async (pin, provider, apiKey) => {
    const normalized = provider === 'openai' ? 'openai' : 'gemini';
    if (!apiKey || !apiKey.trim()) throw new Error('API key is required.');
    const response = await stationFetch('/api/v1/provider/api-key', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        provider: normalized,
        api_key: apiKey.trim(),
      }),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Could not save the API key'));
    }
  };

  window.toytalkModelStatus = async () => {
    const station = await stationStatus();
    return JSON.stringify({
      model_id: station?.model_id || 'hub-runtime',
      display_name: station?.display_name || 'ToyTalk Hub',
      runtime_mode: station?.runtime_mode || 'browser',
      model_ready: Boolean(station?.model_ready),
      model_install_supported: Boolean(station),
      model_installing: Boolean(station?.model_installing),
      speech_to_text_ready: Boolean(station?.speech_to_text_ready),
      parent_configured: Boolean(station?.parent_configured),
      age_band: station?.age_band || null,
      character_alias: station?.character_alias || null,
      character_traits: station?.character_traits || DEFAULT_TRAITS,
      parent_guidance: station?.parent_guidance || null,
      retention_days: station?.retention_days || null,
    });
  };

  window.toytalkBeginLocalTurn = async (
    ageBand,
    characterAlias,
    text,
    kidId,
    kidName,
    childAgeYears,
    childAgeMonths,
    characterPlayAgeYears,
  ) => {
    const response = await stationFetch('/api/v1/conversation/turn', {
      method: 'POST',
      body: JSON.stringify({
        age_band: ageBand,
        character_alias: characterAlias,
        text,
        kid_id: kidId || null,
        kid_name: kidName || null,
        child_age_years: childAgeYears ?? null,
        child_age_months: childAgeMonths ?? null,
        character_play_age_years: characterPlayAgeYears ?? null,
      }),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Conversation failed'));
    }
    return JSON.stringify(await response.json());
  };

  window.toytalkTranscribeSpeech = async (wavBase64) => {
    const response = await stationFetch('/api/v1/stt/transcribe', {
      method: 'POST',
      body: JSON.stringify({wav_base64: wavBase64}),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Hub speech-to-text could not understand that yet.'));
    }
    const decoded = await response.json();
    return decoded?.transcript || '';
  };

  const stationCommand = async (command) => {
    const response = await stationFetch('/api/v1/commands', {
      method: 'POST',
      body: JSON.stringify({
        schema_version: 1,
        request_id: `browser-${Date.now()}-${Math.floor(Math.random() * 1e9)}`,
        command,
      }),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Hub command failed'));
    }
  };

  window.toytalkCancelTurn = async () => stationCommand('cancel_turn');
  window.toytalkEndSession = async () => stationCommand('exit_child_mode');
  window.toytalkInstallLocalModel = async () => stationCommand('install_local_model');
  window.toytalkCancelModelInstall = async () => stationCommand('cancel_model_install');

  window.toytalkConfigureParentPin = async (
    pin,
    ageBand,
    characterAlias,
    characterTraits,
    parentGuidance,
    retentionDays,
    kidId,
  ) => {
    const response = await stationFetch('/api/v1/parent-pin/configure', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        age_band: ageBand,
        character_alias: characterAlias,
        character_traits: Array.from(characterTraits || DEFAULT_TRAITS),
        parent_guidance: parentGuidance || null,
        retention_days: retentionDays || null,
        kid_id: kidId || null,
      }),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Could not configure parent PIN'));
    }
  };

  window.toytalkAuthorizeParentPin = async (pin) => {
    try {
      const response = await stationFetch('/api/v1/parent-pin/authorize', {
        method: 'POST',
        body: JSON.stringify({pin}),
      });
      return response.ok;
    } catch (_) {
      return false;
    }
  };

  window.toytalkDeleteAllLocalData = async (pin) => {
    const response = await stationFetch('/api/v1/local-data/delete', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Could not delete local data'));
    }
  };

  window.toytalkExportBackup = async (pin) => {
    const response = await stationFetch('/api/v1/backup/export', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not export encrypted backup'));
    return JSON.stringify(await response.json());
  };

  window.toytalkImportBackup = async (pin, backupBase64) => {
    const response = await stationFetch('/api/v1/backup/import', {
      method: 'POST',
      body: JSON.stringify({pin, backup_base64: backupBase64}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not import encrypted backup'));
  };

  window.toytalkKids = async () => {
    const response = await stationFetch('/api/v1/kids');
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load kids'));
    return JSON.stringify(await response.json());
  };

  window.toytalkSaveKid = async (
    pin,
    kidId,
    name,
    birthdateIso,
    photoBase64,
    photoMime,
  ) => {
    const response = await stationFetch('/api/v1/kids/save', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        kid_id: kidId || null,
        name: name.trim(),
        birthdate_iso: birthdateIso.trim(),
        photo_base64: photoBase64 || null,
        photo_mime: photoMime || null,
      }),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not save kid'));
  };

  window.toytalkDeleteKid = async (pin, kidId) => {
    const response = await stationFetch('/api/v1/kids/delete', {
      method: 'POST',
      body: JSON.stringify({pin, kid_id: kidId}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not delete kid'));
  };

  window.toytalkPairedClients = async (pin) => {
    const response = await stationFetch('/api/v1/paired-clients', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load paired devices'));
    return JSON.stringify(await response.json());
  };

  window.toytalkRevokePairedClient = async (pin, clientId) => {
    const response = await stationFetch('/api/v1/paired-clients/revoke', {
      method: 'POST',
      body: JSON.stringify({pin, client_id: clientId}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not revoke paired device'));
  };

  window.toytalkHistory = async (pin) => {
    const response = await stationFetch('/api/v1/history/list', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load history'));
    return JSON.stringify(await response.json());
  };

  window.toytalkDeleteHistory = async (pin) => {
    const response = await stationFetch('/api/v1/history/delete', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not delete history'));
  };

  window.toytalkCharacters = async () => {
    const response = await stationFetch('/api/v1/characters');
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load characters'));
    return JSON.stringify(await response.json());
  };

  window.toytalkSaveCharacter = async (
    pin,
    characterAlias,
    characterTraits,
    parentGuidance,
    kidId,
    personaAgeYears,
  ) => {
    const response = await stationFetch('/api/v1/characters/save', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        character_alias: characterAlias.trim(),
        character_traits: Array.from(characterTraits || DEFAULT_TRAITS),
        parent_guidance: parentGuidance || null,
        kid_id: kidId || null,
        persona_age_years: personaAgeYears || null,
      }),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not save character'));
  };

  window.toytalkRenameCharacter = async (
    pin,
    currentCharacterAlias,
    newCharacterAlias,
    characterTraits,
    parentGuidance,
    kidId,
    personaAgeYears,
  ) => {
    const response = await stationFetch('/api/v1/characters/rename', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        current_character_alias: currentCharacterAlias.trim(),
        new_character_alias: newCharacterAlias.trim(),
        character_traits: Array.from(characterTraits || DEFAULT_TRAITS),
        parent_guidance: parentGuidance || null,
        kid_id: kidId || null,
        persona_age_years: personaAgeYears || null,
      }),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not rename character'));
  };

  window.toytalkDeleteCharacter = async (pin, characterAlias, kidId) => {
    const response = await stationFetch('/api/v1/characters/delete', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        character_alias: characterAlias,
        kid_id: kidId || null,
      }),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not delete character'));
  };

  const pickFile = ({accept, maxBytes}) => new Promise((resolve, reject) => {
    const input = document.createElement('input');
    let settled = false;
    const finish = (file) => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timeout);
      input.remove();
      resolve(file);
    };
    input.type = 'file';
    input.accept = accept;
    input.style.position = 'fixed';
    input.style.left = '-10000px';
    input.style.top = '0';
    input.onchange = () => finish(input.files && input.files[0]);
    input.oncancel = () => finish(null);
    const timeout = window.setTimeout(() => finish(null), 30000);
    document.body.appendChild(input);
    input.click();
  }).then((file) => {
    if (!file) throw new Error('No file selected');
    if (maxBytes && file.size > maxBytes) throw new Error('Selected file is too large');
    return file;
  });

  window.toytalkPickCharacterPhoto = async () => {
    const file = await pickFile({
      accept: 'image/png,image/jpeg,image/webp,image/heic,.png,.jpg,.jpeg,.webp,.heic',
      maxBytes: 20 * 1024 * 1024,
    });
    const dataUrl = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(new Error('Photo could not be read'));
      reader.readAsDataURL(file);
    });
    const comma = dataUrl.indexOf(',');
    return JSON.stringify({
      bytes_base64: dataUrl.slice(comma + 1),
      filename: file.name || 'character-photo',
      mime: file.type || null,
    });
  };

  window.toytalkSaveCharacterPhoto = async (pin, characterAlias, photoBase64, photoMime) => {
    const response = await stationFetch('/api/v1/characters/photo', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        character_alias: characterAlias,
        photo_base64: photoBase64,
        photo_mime: photoMime || null,
      }),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Could not save character photo'));
    }
  };

  window.toytalkVoiceStatus = async (characterAlias) =>
    JSON.stringify(await voiceStatusFor(characterAlias));

  window.toytalkEnrollVoice = async (pin, adultAuthorized, characterAlias) => {
    const file = await pickFile({
      accept:
        '.m4a,.mp4,.aac,.wav,.mp3,.ogg,.webm,' +
        'audio/mp4,audio/aac,audio/wav,audio/x-wav,audio/mpeg,audio/ogg,audio/webm',
      maxBytes: 32 * 1024 * 1024,
    });
    const dataUrl = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(new Error('Voice sample could not be read'));
      reader.readAsDataURL(file);
    });
    const comma = dataUrl.indexOf(',');
    if (comma < 0) throw new Error('Voice sample could not be encoded');
    const response = await stationFetch('/api/v1/voice/enroll', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        source_audio_base64: dataUrl.slice(comma + 1),
        source_filename: file.name || null,
        source_mime: file.type || null,
        adult_authorized: Boolean(adultAuthorized),
        character_alias: characterAlias || null,
      }),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Voice enrollment failed'));
    }
  };

  window.toytalkPreviewVoice = async (pin, characterAlias) => {
    await playWavResponse(await stationFetch('/api/v1/voice/preview', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        text: 'Woof woof! Hi friend, let us play!',
        character_alias: characterAlias || null,
      }),
    }));
  };

  window.toytalkApproveVoice = async (pin, characterAlias) => {
    const response = await stationFetch('/api/v1/voice/approve', {
      method: 'POST',
      body: JSON.stringify({pin, character_alias: characterAlias || null}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Voice approval failed'));
  };

  window.toytalkDeleteVoice = async (pin, characterAlias) => {
    const response = await stationFetch('/api/v1/voice/delete', {
      method: 'POST',
      body: JSON.stringify({pin, character_alias: characterAlias || null}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Voice deletion failed'));
  };

  window.toytalkSpeakWithVoice = async (text, characterAlias) => {
    await playWavResponse(await stationFetch('/api/v1/voice/speak', {
      method: 'POST',
      body: JSON.stringify({text, character_alias: characterAlias || null}),
    }));
  };

  window.toytalkSynthesizeVoice = async (text, characterAlias) => {
    const response = await stationFetch('/api/v1/voice/speak', {
      method: 'POST',
      body: JSON.stringify({text, character_alias: characterAlias || null}),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Local voice synthesis failed'));
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    return bytesToBase64(bytes);
  };
})();
