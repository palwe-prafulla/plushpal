(async () => {
  const parameters = new URLSearchParams(window.location.hash.slice(1));
  const bootstrap = parameters.get('bootstrap');
  window.history.replaceState(null, '', window.location.pathname);
  if (!bootstrap) return;
  const response = await fetch('/api/v1/bootstrap', {
    method: 'POST',
    headers: {'X-PlushPal-Bootstrap': bootstrap},
    credentials: 'same-origin',
  });
  if (!response.ok) {
    document.documentElement.dataset.plushpalAuth = 'failed';
  }
})();
