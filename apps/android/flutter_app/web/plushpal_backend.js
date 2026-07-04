(() => {
  const STORE_KEY = 'plushbuddy-web-client-v1';
  const CLIENT_ID_KEY = 'plushbuddy-web-client-id-v1';
  const SESSION_REASONING_KEY = 'plushbuddy-web-reasoning-session-v1';
  const DEFAULT_TRAITS = ['gentle', 'curious'];
  let activeAudio = null;
  let volatileReasoning = null;

  const defaultState = () => ({
    parent: null,
    kids: [],
    characters: [],
    history: [],
    reasoning: {
      provider: 'gemini',
      apiKey: null,
    },
  });

  const readSessionReasoning = () => {
    try {
      const raw = window.sessionStorage?.getItem(SESSION_REASONING_KEY);
      if (!raw) return volatileReasoning;
      const parsed = JSON.parse(raw);
      if (!parsed?.apiKey) return volatileReasoning;
      return {
        provider: parsed.provider === 'openai' ? 'openai' : 'gemini',
        apiKey: String(parsed.apiKey),
      };
    } catch (_) {
      return volatileReasoning;
    }
  };

  const writeSessionReasoning = (provider, apiKey) => {
    const normalized = provider === 'openai' ? 'openai' : 'gemini';
    volatileReasoning = {provider: normalized, apiKey};
    try {
      window.sessionStorage?.setItem(
        SESSION_REASONING_KEY,
        JSON.stringify(volatileReasoning),
      );
    } catch (_) {}
  };

  const clearSessionReasoning = () => {
    volatileReasoning = null;
    try {
      window.sessionStorage?.removeItem(SESSION_REASONING_KEY);
    } catch (_) {}
  };

  const loadState = () => {
    try {
      const raw = window.localStorage.getItem(STORE_KEY);
      const persisted = raw ? JSON.parse(raw) : defaultState();
      const sessionReasoning = readSessionReasoning();
      const provider =
        persisted?.reasoning?.provider ||
        sessionReasoning?.provider ||
        defaultState().reasoning.provider;
      return {
        ...defaultState(),
        ...persisted,
        reasoning: {
          provider,
          apiKey: sessionReasoning?.provider === provider
            ? sessionReasoning.apiKey
            : null,
        },
      };
    } catch (_) {
      return defaultState();
    }
  };

  const saveState = (state) => {
    const persisted = {
      ...state,
      reasoning: {
        provider: state.reasoning?.provider || 'gemini',
        apiKey: null,
      },
    };
    window.localStorage.setItem(STORE_KEY, JSON.stringify(persisted));
  };

  const textEncoder = new TextEncoder();
  const bytesToBase64 = (bytes) => {
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
  };

  const base64ToBytes = (base64) =>
    Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));

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

  window.plushpalWebSpeechSupported = () =>
    Boolean(
      navigator.mediaDevices?.getUserMedia &&
      (window.AudioContext || window.webkitAudioContext)
    );

  window.plushpalRecordSpeechWav = async () => {
    if (!window.plushpalWebSpeechSupported()) {
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

  window.plushpalSpeakText = async (text) => {
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

  const sha256Base64 = async (text) => {
    const digest = await crypto.subtle.digest('SHA-256', textEncoder.encode(text));
    return bytesToBase64(new Uint8Array(digest));
  };

  const newId = (prefix) => `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;

  const stableClientId = () => {
    try {
      const existing = window.localStorage.getItem(CLIENT_ID_KEY);
      if (/^web-[a-f0-9-]{36}$/.test(existing || '')) return existing;
      const generated = `web-${crypto.randomUUID()}`;
      window.localStorage.setItem(CLIENT_ID_KEY, generated);
      return generated;
    } catch (_) {
      return `web-${crypto.randomUUID()}`;
    }
  };

  const stableClientLabel = () => {
    const nav = window.navigator || {};
    const platform =
      nav.userAgentData?.platform || nav.platform || 'browser';
    return `Browser on ${String(platform).slice(0, 60)}`;
  };

  const providerDisplayName = (provider) =>
    provider === 'openai' ? 'OpenAI' : 'Gemini';

  const requirePin = async (pin) => {
    const state = loadState();
    if (!state.parent) throw new Error('Set up a parent PIN first.');
    const hash = await sha256Base64(`${state.parent.pin_salt}:${pin}`);
    if (hash !== state.parent.pin_hash) {
      throw new Error('Parent PIN is incorrect.');
    }
    return state;
  };

  const currentBootstrapToken = () => {
    const hash = window.location.hash || '';
    const match = hash.match(/[#&]bootstrap=([^&]+)/);
    return match ? decodeURIComponent(match[1]) : null;
  };

  let bootstrapAttempted = false;
  const ensureStationSession = async () => {
    if (!bootstrapAttempted && window.__plushpalStationBootstrapReady) {
      bootstrapAttempted = true;
      const status = await window.__plushpalStationBootstrapReady;
      if (status === 'failed') {
        throw new Error('Hub session expired. Open PlushBuddy from Hub again.');
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
      if (!response.ok) throw new Error('Hub session expired. Open PlushBuddy from Hub again.');
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
        ...(options.headers || {}),
      },
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error('Hub session is not ready. Open this browser or Mac app from PlushBuddy Hub again.');
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
    if (activeAudio) {
      activeAudio.pause();
      activeAudio = null;
    }
    const url = URL.createObjectURL(await response.blob());
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

  const selectedCharacter = (alias) => {
    const state = loadState();
    return state.characters.find((character) => character.alias === alias) || null;
  };

  const recentTurns = (kidId, characterAlias) => {
    const state = loadState();
    return state.history
      .filter((turn) =>
        (!kidId || turn.kid_id === kidId) &&
        (!characterAlias || turn.character_alias === characterAlias))
      .slice(-6);
  };

  const buildPrompt = ({
    ageBand,
    characterAlias,
    text,
    kidId,
    kidName,
    childAgeYears,
    childAgeMonths,
    characterPlayAgeYears,
  }) => {
    const character = selectedCharacter(characterAlias);
    const traits = character?.traits?.length ? character.traits : DEFAULT_TRAITS;
    const guidance = character?.parent_guidance || 'cheerful, gentle, playful';
    const playAge = Math.max(2, Math.min(
      characterPlayAgeYears || character?.persona_age_years || childAgeYears || 4,
      childAgeYears || characterPlayAgeYears || 4,
    ));
    const ageContext = childAgeYears != null
      ? `${childAgeYears} years and ${childAgeMonths || 0} months old`
      : `age band ${ageBand}`;
    const safeText = kidName ? text.replaceAll(kidName, 'my friend') : text;
    const continuity = recentTurns(kidId, characterAlias)
      .map((turn) => `Child: ${turn.child_text}\n${characterAlias}: ${turn.character_text}`)
      .join('\n') || 'No prior turns in this active chat.';

    return `You are a fictional plush toy character named ${characterAlias}.
Child profile: ${ageContext}
Character style: ${characterAlias} talks like a playful ${playAge}-year-old pretend-play toy, never older than the child. Use tiny sentences, simple toddler words, giggles/sound effects sparingly, and a gentle toy-like point of view. Do not narrate feelings like "I can't wait to hear"; just respond as the toy would in play.
Knowledge rule: still answer factual questions correctly. The toy age controls wording, sentence length, and playfulness only; it must not reduce factual accuracy. Explain concepts at the child's age level.
Toy memory and parent guidance: Personality traits: ${traits.join(', ')}. ${guidance}. Treat likes, favorite things, personality notes, and pretend-play details here as true for ${characterAlias}. Use them naturally when relevant, but do not force them into every answer.
Safety rules: be age-appropriate; do not ask for private identifying information, addresses, school, secrets, photos, purchases, meetings, or unsafe actions. Never encourage secrecy from a trusted adult.
If the child asks about danger, injury, self-harm, violence, secrets, or anything unsafe, give a very short supportive answer and set suggest_trusted_adult=true.
Keep normal replies warm, playful, concrete, and easy for a young child. Prefer 2-4 tiny sentences, usually 25-45 words total. Short answers are fine for simple prompts, but do not sound clipped or robotic. Let the toy ask one gentle follow-up when it feels natural.
Recent conversation for continuity:
${continuity}
Return only JSON with exactly these fields: speech string, suggest_trusted_adult boolean.
Current child message: ${safeText}`;
  };

  const extractJsonObject = (text) => {
    const start = text.indexOf('{');
    const end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return text.slice(start, end + 1);
  };

  const parseStructuredSpeech = (text) => {
    const json = extractJsonObject(text) || text;
    const decoded = JSON.parse(json);
    if (!decoded.speech || typeof decoded.speech !== 'string') {
      throw new Error('Reasoning response was missing speech text');
    }
    return {
      speech: decoded.speech.trim(),
      suggest_trusted_adult: Boolean(decoded.suggest_trusted_adult),
    };
  };

  const callGemini = async (apiKey, prompt) => {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${encodeURIComponent(apiKey)}`,
      {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({
          contents: [{parts: [{text: prompt}]}],
          generationConfig: {
            temperature: 0.7,
            maxOutputTokens: 220,
            responseMimeType: 'application/json',
          },
        }),
      },
    );
    if (!response.ok) throw new Error(`Gemini HTTP ${response.status}`);
    const decoded = await response.json();
    const text = decoded?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!text) throw new Error('Gemini response was empty');
    return parseStructuredSpeech(text);
  };

  const callOpenAI = async (apiKey, prompt) => {
    const response = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'gpt-4.1-mini',
        input: prompt,
        max_output_tokens: 220,
      }),
    });
    if (!response.ok) throw new Error(`OpenAI HTTP ${response.status}`);
    const decoded = await response.json();
    const text =
      decoded.output_text ||
      decoded.output?.flatMap((item) => item.content || [])
        ?.find((item) => item.type === 'output_text')?.text;
    if (!text) throw new Error('OpenAI response was empty');
    return parseStructuredSpeech(text);
  };

  window.plushpalReasoningProviderStatus = async () => {
    const response = await stationFetch('/api/v1/provider/status');
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Reasoning provider status failed'));
    }
    return JSON.stringify(await response.json());
  };

  window.plushpalConfigureApiKey = async (pin, provider, apiKey) => {
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
    clearSessionReasoning();
  };

  window.plushpalModelStatus = async () => {
    const station = await stationStatus();
    return JSON.stringify({
      model_id: station?.model_id || 'hub-runtime',
      display_name: station?.display_name || 'PlushBuddy Hub',
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

  window.plushpalBeginLocalTurn = async (
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

  window.plushpalTranscribeSpeech = async (wavBase64) => {
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

  window.plushpalCancelTurn = async () => stationCommand('cancel_turn');
  window.plushpalEndSession = async () => stationCommand('exit_child_mode');
  window.plushpalInstallLocalModel = async () => stationCommand('install_local_model');
  window.plushpalCancelModelInstall = async () => stationCommand('cancel_model_install');

  window.plushpalConfigureParentPin = async (
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

  window.plushpalAuthorizeParentPin = async (pin) => {
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

  window.plushpalDeleteAllLocalData = async (pin) => {
    const response = await stationFetch('/api/v1/local-data/delete', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Could not delete local data'));
    }
    try {
      window.localStorage?.removeItem(STORE_KEY);
    } catch (_) {}
    clearSessionReasoning();
  };

  window.plushpalExportBackup = async (pin) => {
    const response = await stationFetch('/api/v1/backup/export', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not export encrypted backup'));
    return JSON.stringify(await response.json());
  };

  window.plushpalImportBackup = async (pin, backupBase64) => {
    const response = await stationFetch('/api/v1/backup/import', {
      method: 'POST',
      body: JSON.stringify({pin, backup_base64: backupBase64}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not import encrypted backup'));
  };

  window.plushpalKids = async () => {
    const response = await stationFetch('/api/v1/kids');
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load kids'));
    return JSON.stringify(await response.json());
  };

  window.plushpalSaveKid = async (
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

  window.plushpalDeleteKid = async (pin, kidId) => {
    const response = await stationFetch('/api/v1/kids/delete', {
      method: 'POST',
      body: JSON.stringify({pin, kid_id: kidId}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not delete kid'));
  };

  window.plushpalPairedClients = async (pin) => {
    const response = await stationFetch('/api/v1/paired-clients', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load paired devices'));
    return JSON.stringify(await response.json());
  };

  window.plushpalRevokePairedClient = async (pin, clientId) => {
    const response = await stationFetch('/api/v1/paired-clients/revoke', {
      method: 'POST',
      body: JSON.stringify({pin, client_id: clientId}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not revoke paired device'));
  };

  window.plushpalHistory = async (pin) => {
    const response = await stationFetch('/api/v1/history/list', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load history'));
    return JSON.stringify(await response.json());
  };

  window.plushpalDeleteHistory = async (pin) => {
    const response = await stationFetch('/api/v1/history/delete', {
      method: 'POST',
      body: JSON.stringify({pin}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not delete history'));
  };

  window.plushpalCharacters = async () => {
    const response = await stationFetch('/api/v1/characters');
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Could not load characters'));
    return JSON.stringify(await response.json());
  };

  window.plushpalSaveCharacter = async (
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

  window.plushpalDeleteCharacter = async (pin, characterAlias, kidId) => {
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

  window.plushpalPickCharacterPhoto = async () => {
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

  window.plushpalSaveCharacterPhoto = async (pin, characterAlias, photoBase64, photoMime) => {
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

  window.plushpalVoiceStatus = async (characterAlias) =>
    JSON.stringify(await voiceStatusFor(characterAlias));

  window.plushpalEnrollVoice = async (pin, adultAuthorized, characterAlias) => {
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

  window.plushpalPreviewVoice = async (pin, characterAlias) => {
    await playWavResponse(await stationFetch('/api/v1/voice/preview', {
      method: 'POST',
      body: JSON.stringify({
        pin,
        text: 'Woof woof! Hi friend, let us play!',
        character_alias: characterAlias || null,
      }),
    }));
  };

  window.plushpalApproveVoice = async (pin, characterAlias) => {
    const response = await stationFetch('/api/v1/voice/approve', {
      method: 'POST',
      body: JSON.stringify({pin, character_alias: characterAlias || null}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Voice approval failed'));
  };

  window.plushpalDeleteVoice = async (pin, characterAlias) => {
    const response = await stationFetch('/api/v1/voice/delete', {
      method: 'POST',
      body: JSON.stringify({pin, character_alias: characterAlias || null}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Voice deletion failed'));
  };

  window.plushpalSpeakWithVoice = async (text, characterAlias) => {
    await playWavResponse(await stationFetch('/api/v1/voice/speak', {
      method: 'POST',
      body: JSON.stringify({text, character_alias: characterAlias || null}),
    }));
  };
})();
