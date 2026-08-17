/**
 * Service worker. Routes between the in-page pill, the side panel, and the
 * local proxy. It never holds the YouCam key — every API call goes through
 * http://localhost:8787, which is the only host this extension can reach.
 */

const PENDING = new Map(); // tabId -> garment payload waiting for the panel

chrome.runtime.onInstalled.addListener(() => {
  chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === 'EASYBUY_TRY_ON') {
    const tabId = sender.tab?.id;
    if (tabId != null) {
      PENDING.set(tabId, message.garment);
      // Opening the panel has to happen in the same turn as the user's click.
      chrome.sidePanel.open({ tabId }).catch((err) => console.warn('sidePanel.open failed', err));
      chrome.runtime.sendMessage({ type: 'EASYBUY_GARMENT_READY', tabId, garment: message.garment }).catch(() => {});
    }
    sendResponse({ ok: true });
    return true;
  }

  if (message?.type === 'EASYBUY_GET_GARMENT') {
    getGarmentForActiveTab()
      .then((result) => sendResponse(result))
      .catch((err) => sendResponse({ ok: false, error: String(err) }));
    return true; // async
  }

  return undefined;
});

async function getGarmentForActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab?.id) return { ok: false, error: 'No active tab' };

  const pending = PENDING.get(tab.id);
  if (pending) {
    PENDING.delete(tab.id);
    return { ok: true, garment: pending, tabId: tab.id };
  }

  try {
    const response = await chrome.tabs.sendMessage(tab.id, { type: 'EASYBUY_EXTRACT' });
    if (response?.ok) return { ok: true, garment: response.garment, tabId: tab.id };
    return { ok: false, error: response?.error || 'The page did not respond' };
  } catch {
    // Content scripts are not injected on chrome:// pages or the web store.
    return { ok: false, error: 'EasyBuy cannot read this page. Open a product page and try again.' };
  }
}

// Re-scan when the user switches tabs so the panel always reflects what they
// are actually looking at.
chrome.tabs.onActivated.addListener(() => {
  chrome.runtime.sendMessage({ type: 'EASYBUY_TAB_CHANGED' }).catch(() => {});
});

chrome.tabs.onUpdated.addListener((_tabId, changeInfo) => {
  if (changeInfo.status === 'complete') {
    chrome.runtime.sendMessage({ type: 'EASYBUY_TAB_CHANGED' }).catch(() => {});
  }
});
