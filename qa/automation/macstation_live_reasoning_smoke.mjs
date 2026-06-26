#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const resultRoot = process.env.PLUSHPAL_TEST_RESULTS_DIR || join(process.env.HOME || '.', 'Downloads', 'PlushPal', 'test-results');
const resultDir = join(resultRoot, `macstation-reasoning-${timestamp()}`);
mkdirSync(resultDir, { recursive: true });

const apiKey = readGeminiApiKey();
if (!apiKey) {
  throw new Error(
    'Set PLUSHPAL_GEMINI_API_KEY or PLUSHPAL_GEMINI_KEY_FILE before running the live reasoning smoke test.',
  );
}

const dataDir = mkdtempSync(join(tmpdir(), 'plushbuddy-reasoning-'));
const env = {
  ...process.env,
  PLUSHPAL_NO_BROWSER: '1',
  PLUSHPAL_PRINT_BOOTSTRAP_URL: '1',
  PLUSHPAL_PORT: '0',
  PLUSHPAL_DATA_DIR: dataDir,
  PLUSHPAL_MODEL_DIR: join(dataDir, 'models'),
  PLUSHPAL_GEMINI_API_KEY: apiKey,
  PLUSHPAL_GEMINI_MODEL: process.env.PLUSHPAL_GEMINI_MODEL || 'gemini-2.5-flash',
  PLUSHPAL_ENABLE_MAC_KEYCHAIN_GEMINI: '0',
};

const report = {
  status: 'started',
  result_dir: resultDir,
  checks: [],
};

let host;
try {
  host = spawn('cargo', ['run', '--release', '-p', 'plushpal-desktop-host', '--features', 'native-runtime'], {
    cwd: root,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const startup = await waitForOutput(host, /PlushPal test bootstrap URL: (http:\/\/[^\s]+)/, 180_000);
  writeFileSync(join(resultDir, 'host-startup.log'), redact(startup));
  const bootstrapUrl = startup.match(/PlushPal test bootstrap URL: (http:\/\/[^\s]+)/)?.[1];
  if (!bootstrapUrl) throw new Error('Could not parse bootstrap URL');
  const url = new URL(bootstrapUrl);
  const baseUrl = `${url.protocol}//${url.host}`;
  const bootstrap = url.hash.match(/bootstrap=([a-f0-9]+)/)?.[1];
  if (!bootstrap) throw new Error('Could not parse bootstrap token');

  const health = await httpJson(baseUrl, 'GET', '/api/v1/health');
  assertStatus(health.status, [200], 'health');
  report.checks.push({
    name: 'health',
    status: health.status,
    voice_engine_ready: health.body.voice_engine_ready,
    conversation_engine_ready: health.body.conversation_engine_ready,
  });
  if (health.body.conversation_engine_ready !== true) {
    throw new Error('Gemini conversation engine was not ready');
  }

  const bootstrapResponse = await httpRaw(baseUrl, 'POST', '/api/v1/bootstrap', {
    headers: { 'x-plushpal-bootstrap': bootstrap },
  });
  assertStatus(bootstrapResponse.status, [204], 'bootstrap');
  const cookie = bootstrapResponse.headers.get('set-cookie')?.split(';', 1)[0];
  if (!cookie) throw new Error('Missing session cookie');
  report.checks.push({ name: 'bootstrap', status: bootstrapResponse.status });

  const pinPayload = {
    pin: '1234',
    age_band: '4-5',
    character_alias: 'Buddy',
    character_traits: ['cheerful', 'playful'],
    parent_guidance: 'Buddy is a tiny pretend-play plush toy. Answer warmly and simply.',
    retention_days: 1,
  };
  const configure = await httpRaw(baseUrl, 'POST', '/api/v1/parent-pin/configure', {
    cookie,
    json: pinPayload,
  });
  assertStatus(configure.status, [204], 'configure parent pin');
  report.checks.push({ name: 'configure_parent_pin', status: configure.status });

  const ws = await openWebSocket(baseUrl.replace('http://', 'ws://') + '/api/v1/events', cookie, baseUrl);
  const requestId = `reasoning-${Date.now()}`;
  const command = await httpRaw(baseUrl, 'POST', '/api/v1/commands', {
    cookie,
    json: {
      schema_version: 1,
      request_id: requestId,
      command: 'begin_local_turn',
      payload: {
        age_band: '4-5',
        character_alias: 'Buddy',
        text: 'Why does rain fall from clouds?',
      },
    },
  });
  assertStatus(command.status, [202], 'begin_local_turn command');
  report.checks.push({ name: 'begin_local_turn_command', status: command.status });

  const event = await waitForEvent(ws, requestId, 60_000);
  ws.close();
  if (event.event !== 'response_ready') {
    throw new Error(`Expected response_ready, got ${event.event}`);
  }
  if (!event.speech || event.speech.length < 5) {
    throw new Error('Gemini response speech was empty');
  }
  report.checks.push({
    name: 'gemini_response_ready',
    event: event.event,
    speech_length: event.speech.length,
    suggest_trusted_adult: event.suggest_trusted_adult,
  });

  report.status = 'pass';
  writeFileSync(join(resultDir, 'report.json'), JSON.stringify(report, null, 2));
  console.log(`PASS: live Gemini reasoning smoke completed. Results: ${resultDir}`);
} catch (error) {
  report.status = 'fail';
  report.error = String(error?.message || error);
  writeFileSync(join(resultDir, 'report.json'), JSON.stringify(report, null, 2));
  console.error(`FAIL: ${report.error}. Results: ${resultDir}`);
  process.exitCode = 1;
} finally {
  if (host && !host.killed) host.kill('SIGTERM');
  rmSync(dataDir, { recursive: true, force: true });
}

function timestamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function readGeminiApiKey() {
  const direct = process.env.PLUSHPAL_GEMINI_API_KEY?.trim();
  if (direct) return direct;
  const file = process.env.PLUSHPAL_GEMINI_KEY_FILE?.trim();
  if (!file) return '';
  return readFileSync(resolve(file), 'utf8').trim();
}

function redact(text) {
  return text.replaceAll(apiKey, '[redacted-api-key]');
}

function waitForOutput(process, regex, timeoutMs) {
  return new Promise((resolvePromise, reject) => {
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error(`Timed out waiting for ${regex}`)), timeoutMs);
    const onData = (chunk) => {
      buffer += chunk.toString();
      if (regex.test(buffer)) {
        clearTimeout(timeout);
        resolvePromise(buffer);
      }
    };
    process.stdout.on('data', onData);
    process.stderr.on('data', onData);
    process.on('exit', (code) => {
      clearTimeout(timeout);
      reject(new Error(`Host exited before ready: ${code}\n${buffer}`));
    });
  });
}

async function httpRaw(baseUrl, method, path, options = {}) {
  const headers = {
    Host: new URL(baseUrl).host,
    Origin: baseUrl,
    ...(options.headers || {}),
  };
  let body;
  if (options.cookie) headers.Cookie = options.cookie;
  if (options.json) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(options.json);
  }
  return fetch(baseUrl + path, { method, headers, body });
}

async function httpJson(baseUrl, method, path, options = {}) {
  const response = await httpRaw(baseUrl, method, path, options);
  return { status: response.status, body: await response.json() };
}

function assertStatus(actual, expected, label) {
  if (!expected.includes(actual)) {
    throw new Error(`${label}: expected ${expected.join('/')}, got ${actual}`);
  }
}

function openWebSocket(url, cookie, origin) {
  return new Promise((resolvePromise, reject) => {
    const ws = new WebSocket(url, { headers: { Cookie: cookie, Origin: origin } });
    const timeout = setTimeout(() => reject(new Error('Timed out opening websocket')), 10_000);
    ws.addEventListener('open', () => {
      clearTimeout(timeout);
      resolvePromise(ws);
    }, { once: true });
    ws.addEventListener('error', () => {
      clearTimeout(timeout);
      reject(new Error('WebSocket failed'));
    }, { once: true });
  });
}

function waitForEvent(ws, requestId, timeoutMs) {
  return new Promise((resolvePromise, reject) => {
    const timeout = setTimeout(() => reject(new Error('Timed out waiting for reasoning event')), timeoutMs);
    ws.addEventListener('message', (message) => {
      try {
        const event = JSON.parse(message.data);
        if (event.request_id !== requestId) return;
        if (event.event === 'command_accepted') return;
        clearTimeout(timeout);
        resolvePromise(event);
      } catch (error) {
        clearTimeout(timeout);
        reject(error);
      }
    });
    ws.addEventListener('error', () => {
      clearTimeout(timeout);
      reject(new Error('WebSocket errored while waiting for event'));
    }, { once: true });
  });
}
