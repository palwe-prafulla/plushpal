(() => {
  const clientId = () => {
    const key = 'plushbuddy-web-client-id-v1';
    try {
      const existing = window.localStorage.getItem(key);
      if (/^web-[a-f0-9-]{36}$/.test(existing || '')) return existing;
      const generated = `web-${crypto.randomUUID()}`;
      window.localStorage.setItem(key, generated);
      return generated;
    } catch (_) {
      return `web-${crypto.randomUUID()}`;
    }
  };

  window.__plushpalStationBootstrapStatus = 'not-needed';
  window.__plushpalStationBootstrapReady = (async () => {
    const parameters = new URLSearchParams(window.location.hash.slice(1));
    const bootstrap = parameters.get('bootstrap');
    if (!bootstrap) return 'not-needed';

    window.history.replaceState(
      null,
      '',
      `${window.location.pathname}${window.location.search}`,
    );

    const response = await fetch('/api/v1/bootstrap', {
      method: 'POST',
      headers: {
        'X-PlushPal-Bootstrap': bootstrap,
        'X-PlushBuddy-Client-Id': clientId(),
      },
      credentials: 'same-origin',
    });
    if (!response.ok) {
      document.documentElement.dataset.plushpalAuth = 'failed';
      window.__plushpalStationBootstrapStatus = 'failed';
      return 'failed';
    }
    window.__plushpalStationBootstrapStatus = 'ready';
    return 'ready';
  })().catch(() => {
    document.documentElement.dataset.plushpalAuth = 'failed';
    window.__plushpalStationBootstrapStatus = 'failed';
    return 'failed';
  });
})();
