// Follow infoscreen's appearance, including changes while the plugin is open.
(function () {
 'use strict';
 const root = document.documentElement;
 let hostDocument = null;
 try { if (window.parent !== window) hostDocument = window.parent.document; } catch (_) { /* standalone or cross-origin */ }
 function hostTheme() {
  const value = hostDocument?.body?.dataset.theme || hostDocument?.documentElement?.dataset.theme;
  return value === 'light' || value === 'dark' ? value : null;
 }
 function apply(value) { root.dataset.theme = value === 'light' ? 'light' : 'dark'; }
 function syncHost() { const value = hostTheme(); if (value) apply(value); return !!value; }
 async function sync() {
  if (syncHost() || document.hidden) return;
  try {
   const status = await e5.core('/status');
   // A host update during the request takes precedence over its older response.
   if (!syncHost()) apply(status?.screen?.ui_theme);
  } catch (_) { /* retain the last known appearance when disconnected */ }
 }
 apply(hostTheme() || 'dark');
 if (hostDocument) {
  const observer = new MutationObserver(syncHost);
  for (const node of [hostDocument.documentElement, hostDocument.body])
   if (node) observer.observe(node, {attributes: true, attributeFilter: ['data-theme']});
  window.addEventListener('pagehide', () => observer.disconnect(), {once: true});
 }
 sync();
 // Older hosts without a theme attribute and standalone pages use the core setting.
 const timer = setInterval(sync, 30000);
 window.addEventListener('pagehide', () => clearInterval(timer), {once: true});
 window.addEventListener('focus', sync);
 document.addEventListener('visibilitychange', sync);
})();
