import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../web/plushpal_backend.js', import.meta.url), 'utf8');
const bootstrapSource = fs.readFileSync(
  new URL('../web/plushpal_bootstrap.js', import.meta.url),
  'utf8',
);

function createHarness({runBootstrapScript = false} = {}) {
  const storage = new Map();
  const requests = [];
  const context = {
    console,
    TextEncoder,
    URLSearchParams,
    Uint8Array,
    Blob,
    Audio: class {
      play() {
        setTimeout(() => this.onended?.(), 0);
        return Promise.resolve();
      }
      pause() {}
    },
    URL: {
      createObjectURL: () => 'blob:voice',
      revokeObjectURL: () => {},
    },
    btoa: (text) => Buffer.from(text, 'binary').toString('base64'),
    atob: (text) => Buffer.from(text, 'base64').toString('binary'),
    crypto: {
      getRandomValues(bytes) {
        return crypto.webcrypto.getRandomValues(bytes);
      },
      subtle: crypto.webcrypto.subtle,
    },
    document: {
      title: 'PlushBuddy',
      documentElement: {
        dataset: {},
      },
      body: {
        appendChild() {},
      },
      createElement() {
        return {
          remove() {},
          click() {},
          style: {},
        };
      },
    },
    history: {
      replaceState(_state, _title, url) {
        context.location.hash = '';
        context.location.pathname = url || '/';
      },
    },
    location: {
      hash: '#bootstrap=test-bootstrap',
      pathname: '/',
      search: '',
      href: 'http://127.0.0.1:3210/#bootstrap=test-bootstrap',
    },
    localStorage: {
      getItem(key) {
        return storage.get(key) ?? null;
      },
      setItem(key, value) {
        storage.set(key, value);
      },
      removeItem(key) {
        storage.delete(key);
      },
    },
    fetch: async (url, options = {}) => {
      requests.push({url: String(url), options});
      if (String(url) === '/api/v1/bootstrap') {
        assert.equal(
          options.headers['x-plushpal-bootstrap'] ??
            options.headers['X-PlushPal-Bootstrap'],
          'test-bootstrap',
        );
        return {ok: true, status: 204, text: async () => ''};
      }
      if (String(url) === '/api/v1/status') {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            model_ready: true,
            voice_engine: 'luxtts',
          }),
          text: async () => '{}',
        };
      }
      if (String(url).startsWith('/api/v1/voice/status')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            enrolled: true,
            approved: true,
            runtime_ready: true,
            profile_id: 'Buddy',
          }),
          text: async () => '{}',
        };
      }
      if (String(url) === '/api/v1/voice/speak') {
        return {
          ok: true,
          status: 200,
          blob: async () => new Blob(['RIFF....WAVE'], {type: 'audio/wav'}),
          text: async () => '',
        };
      }
      if (String(url).startsWith('https://generativelanguage.googleapis.com/')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      text: JSON.stringify({
                        speech: 'Woof woof, rain comes from clouds!',
                        suggest_trusted_adult: false,
                      }),
                    },
                  ],
                },
              },
            ],
          }),
        };
      }
      throw new Error(`Unexpected fetch ${url}`);
    },
  };
  context.window = context;
  vm.createContext(context);
  if (runBootstrapScript) {
    vm.runInContext(bootstrapSource, context, {filename: 'plushpal_bootstrap.js'});
  }
  vm.runInContext(source, context, {filename: 'plushpal_backend.js'});
  return {context, requests, storage};
}

test('browser backend stores app data locally and uses Station only for voice/status', async () => {
  const {context, requests, storage} = createHarness();

  assert.equal(typeof context.plushpalModelStatus, 'function');
  assert.equal(typeof context.plushpalBeginLocalTurn, 'function');

  let status = JSON.parse(await context.plushpalModelStatus());
  assert.equal(status.model_ready, false);
  assert.equal(status.model_install_supported, true);
  assert.equal(context.location.hash, '');
  assert.ok(requests.some((request) => request.url === '/api/v1/bootstrap'));

  await context.plushpalConfigureParentPin(
    '1234',
    '4-5',
    'Buddy',
    ['playful', 'gentle'],
    'Buddy loves blocks.',
    7,
    null,
  );
  await context.plushpalSaveKid('1234', null, 'Inaaya', '2021-06-01', null, null);
  const kids = JSON.parse(await context.plushpalKids());
  assert.equal(kids.length, 1);

  await context.plushpalSaveCharacter(
    '1234',
    'Buddy',
    ['playful'],
    'Buddy loves blocks and puppy sounds.',
    kids[0].id,
    2,
  );
  const characters = JSON.parse(await context.plushpalCharacters());
  assert.equal(characters[0].voice.approved, true);

  await context.plushpalConfigureApiKey('gemini', 'test-key');
  status = JSON.parse(await context.plushpalModelStatus());
  assert.equal(status.model_id, 'gemini-cloud');

  const turn = JSON.parse(
    await context.plushpalBeginLocalTurn(
      '4-5',
      'Buddy',
      'How does rain work?',
      kids[0].id,
      'Inaaya',
      5,
      0,
      2,
    ),
  );
  assert.equal(turn.speech, 'Woof woof, rain comes from clouds!');
  assert.equal(turn.suggest_trusted_adult, false);
  assert.ok(
    requests.some((request) =>
      request.url.startsWith('https://generativelanguage.googleapis.com/'),
    ),
  );

  await context.plushpalSpeakWithVoice('Hi buddy', 'Buddy');
  const speakRequest = requests.find((request) => request.url === '/api/v1/voice/speak');
  assert.ok(speakRequest);
  assert.deepEqual(JSON.parse(speakRequest.options.body), {
    text: 'Hi buddy',
    character_alias: 'Buddy',
  });

  const stored = JSON.parse(storage.get('plushbuddy-web-client-v1'));
  assert.equal(stored.kids[0].name, 'Inaaya');
  assert.equal(stored.characters[0].alias, 'Buddy');
  assert.equal(stored.history.length, 1);
});

test('browser bootstrap script exchanges Station token before backend status checks', async () => {
  const {context, requests} = createHarness({runBootstrapScript: true});

  assert.equal(await context.__plushpalStationBootstrapReady, 'ready');
  assert.equal(context.location.hash, '');

  const status = JSON.parse(await context.plushpalModelStatus());
  assert.equal(status.model_install_supported, true);
  assert.equal(status.model_ready, false);

  const bootstrapRequests = requests.filter(
    (request) => request.url === '/api/v1/bootstrap',
  );
  assert.equal(bootstrapRequests.length, 1);
});
