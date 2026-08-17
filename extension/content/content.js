/**
 * Injected on every page. Two jobs:
 *   1. answer extraction requests from the side panel
 *   2. show an unobtrusive "Try it on" pill when the page looks like a product
 *
 * The pill matters more than it looks: nobody navigates to a separate try-on
 * site while shopping, so the affordance has to appear inside the store.
 */

(function () {
  const PILL_ID = 'easybuy-tryon-pill';
  let lastUrl = location.href;
  let lastSignature = '';

  function looksLikeProductPage(info) {
    if (!info.images.length) return false;
    if (info.source !== 'generic') return true; // a store adapter matched
    // Generic pages need more evidence before we interrupt.
    return Boolean(info.title) && Boolean(info.price);
  }

  function ensurePill(info) {
    let pill = document.getElementById(PILL_ID);
    if (!looksLikeProductPage(info)) {
      pill?.remove();
      return;
    }
    if (pill) return;

    pill = document.createElement('button');
    pill.id = PILL_ID;
    pill.type = 'button';
    pill.textContent = 'Try it on';
    pill.setAttribute('aria-label', 'Try this garment on with EasyBuy');
    pill.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      pill.textContent = 'Opening…';
      chrome.runtime.sendMessage({ type: 'EASYBUY_TRY_ON', garment: window.__EASYBUY_EXTRACT() }, () => {
        pill.textContent = 'Try it on';
      });
    });
    document.body.appendChild(pill);
  }

  function refresh() {
    if (!document.body || typeof window.__EASYBUY_EXTRACT !== 'function') return;
    let info;
    try {
      info = window.__EASYBUY_EXTRACT();
    } catch {
      return;
    }
    const signature = `${location.href}|${info.images[0] || ''}`;
    if (signature === lastSignature) return;
    lastSignature = signature;
    ensurePill(info);
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === 'EASYBUY_EXTRACT') {
      try {
        sendResponse({ ok: true, garment: window.__EASYBUY_EXTRACT() });
      } catch (err) {
        sendResponse({ ok: false, error: String(err) });
      }
      return true;
    }
    return undefined;
  });

  // Most fashion sites are single-page apps, so a load-time scan is not enough.
  const observer = new MutationObserver(() => {
    if (location.href !== lastUrl) {
      lastUrl = location.href;
      lastSignature = '';
      document.getElementById(PILL_ID)?.remove();
    }
    scheduleRefresh();
  });

  let refreshTimer = null;
  function scheduleRefresh() {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(refresh, 400);
  }

  observer.observe(document.documentElement, { childList: true, subtree: true });
  scheduleRefresh();
})();
