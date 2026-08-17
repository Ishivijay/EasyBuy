const API = 'http://localhost:8787';

const el = (id) => document.getElementById(id);
const ui = {
  status: el('status'),
  dropzone: el('dropzone'),
  dropzoneCopy: el('dropzone-copy'),
  modelInput: el('model-input'),
  modelThumb: el('model-thumb'),
  changeModel: el('change-model'),
  garmentEmpty: el('garment-empty'),
  garmentBody: el('garment-body'),
  garmentThumb: el('garment-thumb'),
  garmentTitle: el('garment-title'),
  garmentPrice: el('garment-price'),
  garmentHost: el('garment-host'),
  garmentSource: el('garment-source'),
  candidates: el('candidates'),
  candidateStrip: el('candidate-strip'),
  category: el('category'),
  render: el('render'),
  resultCard: el('result-card'),
  resultImg: el('result-img'),
  resultCaption: el('result-caption'),
  toggleCompare: el('toggle-compare'),
  rerender: el('rerender'),
  progressCard: el('progress-card'),
  progressStage: el('progress-stage'),
  progressDetail: el('progress-detail'),
  errorCard: el('error-card'),
  errorMessage: el('error-message'),
  errorDetailWrap: el('error-detail-wrap'),
  errorDetail: el('error-detail'),
  trayCard: el('tray-card'),
  tray: el('tray'),
  trayCount: el('tray-count'),
};

const state = {
  modelUrl: null,
  garment: null,
  imageIndex: 0,
  showingOriginal: false,
  lastRender: null,
  polling: null,
};

const STAGE_COPY = {
  queued: 'Queued',
  'preparing-model': 'Preparing your photo',
  'downloading-garment': 'Fetching the garment image',
  submitting: 'Sending to YouCam',
  rendering: 'Rendering the try-on',
  saving: 'Saving your render',
};

// --- helpers --------------------------------------------------------------

async function api(path, options) {
  const res = await fetch(`${API}${path}`, options);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body.message || body.error || `Request failed (${res.status})`);
    err.code = body.error;
    err.body = body;
    throw err;
  }
  return body;
}

function show(node, visible) {
  node.hidden = !visible;
}

function showError(message, detail) {
  ui.errorMessage.textContent = message;
  if (detail) {
    ui.errorDetail.textContent = typeof detail === 'string' ? detail : JSON.stringify(detail, null, 2);
    show(ui.errorDetailWrap, true);
  } else {
    show(ui.errorDetailWrap, false);
  }
  show(ui.errorCard, true);
}

function clearError() {
  show(ui.errorCard, false);
}

function guessCategory(text = '') {
  if (/\b(dress|gown|jumpsuit|romper|playsuit|overall|kaftan|saree)\b/i.test(text)) return 'full_body';
  if (/\b(jean|jeans|trouser|pant|pants|chino|short|shorts|skirt|legging|jogger|cargo)\b/i.test(text)) {
    return 'lower_body';
  }
  return 'upper_body';
}

// --- backend health -------------------------------------------------------

async function checkHealth() {
  try {
    const health = await api('/api/health');
    if (!health.configured) {
      ui.status.dataset.state = 'down';
      ui.status.textContent = 'no API key';
      showError('The proxy is running but has no YouCam API key. Add it to backend/.env and restart.');
      return;
    }
    ui.status.dataset.state = 'ok';
    const units = findUnits(health.credit);
    ui.status.textContent = units == null ? 'connected' : `${units} units left`;
  } catch {
    ui.status.dataset.state = 'down';
    ui.status.textContent = 'proxy offline';
    showError('Cannot reach the local proxy. Run `npm start` in the backend folder, then reopen this panel.');
  }
}

/** The balance response nests the number differently across API versions. */
function findUnits(payload) {
  let found = null;
  (function walk(node) {
    if (!node || typeof node !== 'object' || found != null) return;
    for (const [key, value] of Object.entries(node)) {
      if (typeof value === 'number' && /credit|unit|balance|remain|^amount$/i.test(key)) {
        found = value;
        return;
      }
      walk(value);
    }
  })(payload);
  return found;
}

// --- model photo ----------------------------------------------------------

async function loadModel() {
  try {
    const { activeModelId, models } = await api('/api/models');
    const active = models.find((m) => m.id === activeModelId) || models[0];
    if (!active) return;
    state.modelUrl = `${API}${active.url}`;
    ui.modelThumb.src = state.modelUrl;
    show(ui.modelThumb, true);
    show(ui.dropzoneCopy, false);
    show(ui.changeModel, true);
  } catch {
    /* proxy offline; checkHealth already reported it */
  }
}

async function uploadModel(file) {
  if (!file || !file.type.startsWith('image/')) {
    showError('That file is not an image.');
    return;
  }
  clearError();
  ui.dropzoneCopy.textContent = 'Uploading…';

  const imageBase64 = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });

  try {
    const out = await api('/api/model', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ imageBase64, contentType: file.type }),
    });
    state.modelUrl = `${API}${out.url}`;
    ui.modelThumb.src = state.modelUrl;
    show(ui.modelThumb, true);
    show(ui.dropzoneCopy, false);
    show(ui.changeModel, true);
    updateRenderButton();
  } catch (err) {
    showError(err.message, err.body);
    show(ui.dropzoneCopy, true);
  }
}

ui.dropzone.addEventListener('click', () => ui.modelInput.click());
ui.modelInput.addEventListener('change', (e) => uploadModel(e.target.files?.[0]));
ui.changeModel.addEventListener('click', (e) => {
  e.stopPropagation();
  ui.modelInput.click();
});

for (const type of ['dragenter', 'dragover']) {
  ui.dropzone.addEventListener(type, (e) => {
    e.preventDefault();
    ui.dropzone.classList.add('dragging');
  });
}
for (const type of ['dragleave', 'drop']) {
  ui.dropzone.addEventListener(type, (e) => {
    e.preventDefault();
    ui.dropzone.classList.remove('dragging');
  });
}
ui.dropzone.addEventListener('drop', (e) => uploadModel(e.dataTransfer?.files?.[0]));

// --- garment on the current tab ------------------------------------------

async function refreshGarment() {
  const response = await chrome.runtime.sendMessage({ type: 'EASYBUY_GET_GARMENT' }).catch(() => null);

  if (!response?.ok || !response.garment?.images?.length) {
    state.garment = null;
    show(ui.garmentBody, false);
    show(ui.garmentEmpty, true);
    ui.garmentEmpty.textContent =
      response?.error || 'No garment found on this page. Open a product page and reopen the panel.';
    show(ui.garmentSource, false);
    updateRenderButton();
    return;
  }

  state.garment = response.garment;
  state.imageIndex = 0;
  renderGarmentCard();
  updateRenderButton();
}

function renderGarmentCard() {
  const g = state.garment;
  show(ui.garmentEmpty, false);
  show(ui.garmentBody, true);

  ui.garmentSource.textContent = g.source;
  show(ui.garmentSource, true);

  ui.garmentThumb.src = g.images[state.imageIndex];
  ui.garmentTitle.textContent = g.title || 'Untitled item';
  ui.garmentPrice.textContent = g.price || '';
  ui.garmentHost.textContent = g.host;
  ui.category.value = guessCategory(`${g.title} ${g.notes || ''}`);

  ui.candidateStrip.replaceChildren();
  if (g.images.length > 1) {
    g.images.forEach((url, index) => {
      const img = document.createElement('img');
      img.src = url;
      img.alt = `Candidate image ${index + 1}`;
      img.setAttribute('aria-selected', String(index === state.imageIndex));
      img.addEventListener('click', () => {
        state.imageIndex = index;
        renderGarmentCard();
      });
      ui.candidateStrip.appendChild(img);
    });
    show(ui.candidates, true);
  } else {
    show(ui.candidates, false);
  }
}

function updateRenderButton() {
  ui.render.disabled = !(state.modelUrl && state.garment);
}

// --- rendering ------------------------------------------------------------

async function startRender({ force = false } = {}) {
  if (!state.garment || !state.modelUrl) return;
  clearError();
  show(ui.resultCard, false);
  show(ui.progressCard, true);
  ui.progressStage.textContent = 'Starting…';
  ui.progressDetail.textContent = '';
  ui.render.disabled = true;

  try {
    const job = await api('/api/tryon', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        garmentUrl: state.garment.images[state.imageIndex],
        pageUrl: state.garment.pageUrl,
        title: state.garment.title,
        category: ui.category.value,
        force,
      }),
    });

    if (job.state === 'done') {
      // Cache hit: this exact garment has been rendered on this photo before.
      finishRender(job.render, { cached: true });
      return;
    }
    pollJob(job.jobId);
  } catch (err) {
    show(ui.progressCard, false);
    ui.render.disabled = false;
    if (err.code === 'no-model') {
      showError('Add a photo of yourself first.');
    } else {
      showError(err.message, err.body);
    }
  }
}

function pollJob(jobId) {
  clearInterval(state.polling);
  state.polling = setInterval(async () => {
    let job;
    try {
      job = await api(`/api/tryon/${jobId}`);
    } catch (err) {
      clearInterval(state.polling);
      show(ui.progressCard, false);
      ui.render.disabled = false;
      showError(err.message);
      return;
    }

    if (job.state === 'running') {
      ui.progressStage.textContent = STAGE_COPY[job.stage] || job.stage;
      ui.progressDetail.textContent = job.polls ? `${job.polls * 2}s elapsed on the API` : '';
      return;
    }

    clearInterval(state.polling);
    show(ui.progressCard, false);
    ui.render.disabled = false;

    if (job.state === 'error') {
      showError(job.error || 'The render failed.', job.detail);
      return;
    }
    finishRender(job.render, { cached: false });
  }, 900);
}

function finishRender(render, { cached }) {
  state.lastRender = render;
  state.showingOriginal = false;
  ui.resultImg.src = `${API}${render.localPath}`;
  ui.toggleCompare.textContent = 'show original';

  const parts = [];
  if (cached) parts.push('from cache, no units spent');
  else if (render.tookMs) parts.push(`${(render.tookMs / 1000).toFixed(1)}s`);
  if (render.garmentPath) parts.push(render.garmentPath === 'ref_file_url' ? 'URL passthrough' : 'uploaded garment');
  ui.resultCaption.textContent = parts.join(' · ');

  show(ui.progressCard, false);
  show(ui.resultCard, true);
  loadTray();
}

ui.render.addEventListener('click', () => startRender());
ui.rerender.addEventListener('click', () => startRender({ force: true }));

ui.toggleCompare.addEventListener('click', () => {
  if (!state.lastRender) return;
  state.showingOriginal = !state.showingOriginal;
  ui.resultImg.src = state.showingOriginal ? state.modelUrl : `${API}${state.lastRender.localPath}`;
  ui.toggleCompare.textContent = state.showingOriginal ? 'show try-on' : 'show original';
});

// --- compare tray ---------------------------------------------------------

async function loadTray() {
  try {
    const { renders } = await api('/api/renders');
    if (!renders.length) {
      show(ui.trayCard, false);
      return;
    }
    ui.trayCount.textContent = `${renders.length} tried`;
    ui.tray.replaceChildren();

    for (const render of renders) {
      const figure = document.createElement('figure');
      const img = document.createElement('img');
      img.src = `${API}${render.localPath}`;
      img.alt = render.title || 'Previous try-on';
      const caption = document.createElement('figcaption');
      let host = '';
      try {
        host = new URL(render.pageUrl || render.garmentUrl).hostname.replace(/^www\./, '');
      } catch {
        host = '';
      }
      caption.textContent = host;
      figure.append(img, caption);
      figure.addEventListener('click', () => {
        if (render.pageUrl) chrome.tabs.create({ url: render.pageUrl });
      });
      ui.tray.appendChild(figure);
    }
    show(ui.trayCard, true);
  } catch {
    show(ui.trayCard, false);
  }
}

// --- wiring ---------------------------------------------------------------

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === 'EASYBUY_TAB_CHANGED' || message?.type === 'EASYBUY_GARMENT_READY') {
    refreshGarment();
  }
});

(async function boot() {
  await checkHealth();
  await loadModel();
  await refreshGarment();
  await loadTray();
  updateRenderButton();
})();
