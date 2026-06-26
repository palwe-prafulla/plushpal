(() => {
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
      headers: {'X-PlushPal-Bootstrap': bootstrap},
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
