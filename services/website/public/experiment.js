'use strict';

(() => {
  if (document.body.dataset.experimentActive !== 'true') return;
  const sent = new Set();
  const pending = new Set();
  function track(event) {
    if (sent.has(event) || pending.has(event)) return;
    pending.add(event);
    void fetch('/api/experiment/event', {
      method: 'POST', credentials: 'same-origin', keepalive: true,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ event, variant: document.documentElement.dataset.copyVariant })
    }).then((response) => { if (response.ok) sent.add(event); })
      .catch(() => {})
      .finally(() => pending.delete(event));
  }
  function expose() { if (document.visibilityState === 'visible') track('exposure'); }
  expose();
  document.addEventListener('visibilitychange', expose);
  window.addEventListener('pageshow', expose);
  document.querySelectorAll('[data-early-access]').forEach((link) => {
    link.addEventListener('click', () => track('early_access'));
  });
  document.getElementById('demo-questions')?.addEventListener('click', (event) => {
    if (event.target instanceof Element && event.target.closest('button')) track('demo_engaged');
  });
})();
