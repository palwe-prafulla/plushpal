(() => {
  const STORE_KEY = 'plushbuddy-web-client-v1';
  const DEFAULT_TRAITS = ['gentle', 'curious'];
  let activeAudio = null;

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

  const loadState = () => {
    try {
      const raw = window.localStorage.getItem(STORE_KEY);
      if (!raw) return defaultState();
      return {...defaultState(), ...JSON.parse(raw)};
    } catch (_) {
      return defaultState();
    }
  };

  const saveState = (state) => {
    window.localStorage.setItem(STORE_KEY, JSON.stringify(state));
  };

  const textEncoder = new TextEncoder();
  const bytesToBase64 = (bytes) => {
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
  };

  const base64ToBytes = (base64) =>
    Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));

  const sha256Base64 = async (text) => {
    const digest = await crypto.subtle.digest('SHA-256', textEncoder.encode(text));
    return bytesToBase64(new Uint8Array(digest));
  };

  const newId = (prefix) => `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;

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
    const token = currentBootstrapToken();
    if (token && !bootstrapAttempted) {
      bootstrapAttempted = true;
      const response = await fetch('/api/v1/bootstrap', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {'x-plushpal-bootstrap': token},
      });
      if (!response.ok) throw new Error('MacStation pairing expired. Open a fresh browser link from MacStation.');
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
        ...(options.headers || {}),
      },
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error('MacStation session is not ready. Open PlushBuddy from the MacStation browser link or refresh with a fresh QR/link.');
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
    const state = loadState();
    return JSON.stringify({
      provider: state.reasoning.provider || 'gemini',
      configured: Boolean(state.reasoning.apiKey),
      display_name: providerDisplayName(state.reasoning.provider || 'gemini'),
    });
  };

  window.plushpalConfigureApiKey = async (provider, apiKey) => {
    const normalized = provider === 'openai' ? 'openai' : 'gemini';
    if (!apiKey || !apiKey.trim()) throw new Error('API key is required.');
    const state = loadState();
    state.reasoning = {provider: normalized, apiKey: apiKey.trim()};
    saveState(state);
  };

  window.plushpalModelStatus = async () => {
    const state = loadState();
    const station = await stationStatus();
    const character = state.characters[0] || null;
    return JSON.stringify({
      model_id: state.reasoning.apiKey
        ? `${state.reasoning.provider || 'gemini'}-cloud`
        : 'browser-cloud',
      display_name: state.reasoning.apiKey
        ? `${providerDisplayName(state.reasoning.provider || 'gemini')} cloud reasoning`
        : 'Browser cloud reasoning',
      model_ready: Boolean(state.reasoning.apiKey),
      model_install_supported: Boolean(station),
      model_installing: false,
      parent_configured: Boolean(state.parent),
      age_band: state.parent?.age_band || null,
      character_alias: character?.alias || state.parent?.character_alias || null,
      character_traits: character?.traits || state.parent?.character_traits || DEFAULT_TRAITS,
      parent_guidance: character?.parent_guidance || state.parent?.parent_guidance || null,
      retention_days: state.parent?.retention_days || null,
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
    const state = loadState();
    if (!state.reasoning.apiKey) throw new Error('Save a Gemini or OpenAI API key first.');
    const prompt = buildPrompt({
      ageBand,
      characterAlias,
      text,
      kidId,
      kidName,
      childAgeYears,
      childAgeMonths,
      characterPlayAgeYears,
    });
    const result = state.reasoning.provider === 'openai'
      ? await callOpenAI(state.reasoning.apiKey, prompt)
      : await callGemini(state.reasoning.apiKey, prompt);

    const turn = {
      kid_id: kidId || null,
      character_alias: characterAlias,
      child_text: text,
      character_text: result.speech,
      completed_at: Date.now(),
    };
    const next = loadState();
    next.history = [...(next.history || []), turn].slice(-200);
    saveState(next);
    return JSON.stringify(result);
  };

  window.plushpalCancelTurn = async () => {};
  window.plushpalEndSession = async () => {};
  window.plushpalInstallLocalModel = async () => {};
  window.plushpalCancelModelInstall = async () => {};

  window.plushpalConfigureParentPin = async (
    pin,
    ageBand,
    characterAlias,
    characterTraits,
    parentGuidance,
    retentionDays,
    kidId,
  ) => {
    if (!/^[0-9]{4,8}$/.test(pin)) throw new Error('Choose a 4-8 digit parent PIN.');
    const salt = bytesToBase64(crypto.getRandomValues(new Uint8Array(16)));
    const hash = await sha256Base64(`${salt}:${pin}`);
    const state = loadState();
    state.parent = {
      pin_salt: salt,
      pin_hash: hash,
      age_band: ageBand,
      character_alias: characterAlias,
      character_traits: Array.from(characterTraits || DEFAULT_TRAITS),
      parent_guidance: parentGuidance || null,
      retention_days: retentionDays || null,
      kid_id: kidId || null,
    };
    saveState(state);
  };

  window.plushpalAuthorizeParentPin = async (pin) => {
    try {
      await requirePin(pin);
      return true;
    } catch (_) {
      return false;
    }
  };

  window.plushpalDeleteAllLocalData = async (pin) => {
    await requirePin(pin);
    window.localStorage.removeItem(STORE_KEY);
  };

  window.plushpalKids = async () => JSON.stringify(loadState().kids || []);

  window.plushpalSaveKid = async (
    pin,
    kidId,
    name,
    birthdateIso,
    photoBase64,
    photoMime,
  ) => {
    const state = await requirePin(pin);
    const id = kidId || newId('kid');
    const row = {
      id,
      name: name.trim(),
      birthdate_iso: birthdateIso.trim(),
      photo_base64: photoBase64 || null,
      photo_mime: photoMime || null,
    };
    state.kids = [
      ...state.kids.filter((kid) => kid.id !== id),
      row,
    ];
    saveState(state);
  };

  window.plushpalDeleteKid = async (pin, kidId) => {
    const state = await requirePin(pin);
    state.kids = state.kids.filter((kid) => kid.id !== kidId);
    state.characters = state.characters.filter((character) => character.kid_id !== kidId);
    state.history = state.history.filter((turn) => turn.kid_id !== kidId);
    saveState(state);
  };

  window.plushpalHistory = async (pin) => {
    const state = await requirePin(pin);
    return JSON.stringify((state.history || []).map((turn) => ({
      child_text: turn.child_text,
      character_text: turn.character_text,
      completed_at: turn.completed_at,
    })));
  };

  window.plushpalDeleteHistory = async (pin) => {
    const state = await requirePin(pin);
    state.history = [];
    saveState(state);
  };

  window.plushpalCharacters = async () => {
    const state = loadState();
    const rows = await Promise.all((state.characters || []).map(async (character) => ({
      ...character,
      voice: await voiceStatusFor(character.alias),
    })));
    return JSON.stringify(rows);
  };

  window.plushpalSaveCharacter = async (
    pin,
    characterAlias,
    characterTraits,
    parentGuidance,
    kidId,
    personaAgeYears,
  ) => {
    const state = await requirePin(pin);
    const alias = characterAlias.trim();
    const existing = state.characters.find((character) => character.alias === alias);
    const row = {
      alias,
      traits: Array.from(characterTraits || DEFAULT_TRAITS),
      parent_guidance: parentGuidance || null,
      kid_id: kidId || existing?.kid_id || state.parent?.kid_id || null,
      persona_age_years: personaAgeYears || existing?.persona_age_years || null,
      photo_base64: existing?.photo_base64 || null,
      photo_mime: existing?.photo_mime || null,
      voice: existing?.voice || {
        enrolled: false,
        approved: false,
        runtime_ready: false,
        profile_id: alias,
      },
    };
    state.characters = [
      ...state.characters.filter((character) => character.alias !== alias),
      row,
    ];
    saveState(state);
  };

  window.plushpalDeleteCharacter = async (pin, characterAlias, kidId) => {
    const state = await requirePin(pin);
    state.characters = state.characters.filter((character) =>
      character.alias !== characterAlias ||
      (kidId && character.kid_id !== kidId));
    state.history = state.history.filter((turn) => turn.character_alias !== characterAlias);
    saveState(state);
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
    const state = await requirePin(pin);
    state.characters = state.characters.map((character) =>
      character.alias === characterAlias
        ? {...character, photo_base64: photoBase64, photo_mime: photoMime || null}
        : character);
    saveState(state);
  };

  window.plushpalVoiceStatus = async (characterAlias) =>
    JSON.stringify(await voiceStatusFor(characterAlias));

  window.plushpalEnrollVoice = async (pin, adultAuthorized, characterAlias) => {
    await requirePin(pin);
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
    await requirePin(pin);
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
    await requirePin(pin);
    const response = await stationFetch('/api/v1/voice/approve', {
      method: 'POST',
      body: JSON.stringify({pin, character_alias: characterAlias || null}),
    });
    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Voice approval failed'));
  };

  window.plushpalDeleteVoice = async (pin, characterAlias) => {
    await requirePin(pin);
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
