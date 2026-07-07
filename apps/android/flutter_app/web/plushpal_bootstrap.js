(() => {
  const clientPlatform = () => {
    const platform = String(window.__toytalkClientPlatform || 'web').toLowerCase();
    return /^(web|macos)$/.test(platform) ? platform : 'web';
  };

  const clientIdPattern = (platform) =>
    new RegExp(`^${platform}-[a-f0-9-]{36}$`);

  const clientId = () => {
    const platform = clientPlatform();
    const key = `toytalk-${platform}-client-id-v1`;
    try {
      const existing = window.localStorage.getItem(key);
      if (clientIdPattern(platform).test(existing || '')) return existing;
      if (platform === 'macos') {
        const legacyWeb = window.localStorage.getItem('toytalk-web-client-id-v1');
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

  const clientLabel = () => {
    if (window.__toytalkClientLabel) {
      return String(window.__toytalkClientLabel).slice(0, 80);
    }
    const nav = window.navigator || {};
    const platform =
      nav.userAgentData?.platform || nav.platform || 'browser';
    return `Browser on ${String(platform).slice(0, 60)}`;
  };

  const rememberHubId = (hubId) => {
    if (!/^hub-[a-f0-9-]{36}$/.test(hubId || '')) return;
    try {
      window.localStorage.setItem('toytalk-web-hub-id-v1', hubId);
    } catch (_) {}
  };

  window.__toytalkStationBootstrapStatus = 'not-needed';
  window.__toytalkStationBootstrapReady = (async () => {
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
        'X-PlushBuddy-Client-Label': clientLabel(),
      },
      credentials: 'same-origin',
    });
    if (!response.ok) {
      document.documentElement.dataset.toytalkAuth = 'failed';
      window.__toytalkStationBootstrapStatus = 'failed';
      return 'failed';
    }
    rememberHubId(response.headers.get('x-plushbuddy-hub-id'));
    window.__toytalkStationBootstrapStatus = 'ready';
    return 'ready';
  })().catch(() => {
    document.documentElement.dataset.toytalkAuth = 'failed';
    window.__toytalkStationBootstrapStatus = 'failed';
    return 'failed';
  });
})();
