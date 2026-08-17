import express from 'express';
import cors from 'cors';
import { createHash, randomUUID } from 'node:crypto';

import { config } from './config.js';
import * as youcam from './youcam.js';
import { fetchGarmentBytes, guessCategory, sniffImageType, UPLOADABLE_TYPES } from './garment.js';
import { extractFromUrl, urlFromSharedText } from './extract.js';
import {
  initStore,
  RENDER_DIR,
  MODEL_DIR,
  saveModel,
  getModel,
  listModels,
  setActiveModel,
  getActiveModelId,
  modelFileIdIsFresh,
  rememberModelFileId,
  readModelBytes,
  renderKey,
  getRender,
  listRenders,
  saveRender,
  forgetRender,
  setVerdict,
  deleteRender,
  deleteModel,
  deleteEverything,
} from './store.js';

await initStore();

const app = express();
app.use(cors());
app.use(express.json({ limit: '20mb' }));
app.use('/renders', express.static(RENDER_DIR, { maxAge: '1h' }));
app.use('/models', express.static(MODEL_DIR, { maxAge: '1h' }));

/** jobId -> { state, stage, key, render, error } */
const jobs = new Map();

app.get('/api/health', async (_req, res) => {
  const out = { ok: true, configured: Boolean(config.apiKey), activeModelId: getActiveModelId() };
  if (out.configured) {
    try {
      out.credit = await youcam.getCredit();
    } catch (err) {
      out.ok = false;
      out.creditError = err.message;
    }
  }
  res.json(out);
});

// --- model photo ----------------------------------------------------------

app.post('/api/model', async (req, res) => {
  try {
    const { imageBase64, contentType = 'image/jpeg' } = req.body || {};
    if (!imageBase64) return res.status(400).json({ error: 'imageBase64 is required' });

    const buffer = Buffer.from(String(imageBase64).replace(/^data:[^;]+;base64,/, ''), 'base64');
    if (buffer.byteLength < 2048) {
      return res.status(400).json({ error: 'That image looks empty or corrupt' });
    }

    const model = await saveModel({ buffer, contentType });
    res.json({ modelId: model.id, url: `/models/${model.id}.${contentType === 'image/png' ? 'png' : 'jpg'}` });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/models', (_req, res) => {
  res.json({
    activeModelId: getActiveModelId(),
    models: listModels().map((m) => ({
      id: m.id,
      createdAt: m.createdAt,
      url: `/models/${m.id}.${m.contentType === 'image/png' ? 'png' : 'jpg'}`,
    })),
  });
});

app.post('/api/models/active', (req, res) => {
  const ok = setActiveModel(req.body?.modelId);
  if (!ok) return res.status(404).json({ error: 'Unknown modelId' });
  res.json({ activeModelId: getActiveModelId() });
});

// --- shared links ---------------------------------------------------------

/**
 * The mobile app receives a bare URL (often wrapped in chatty share text) and
 * has no DOM to read, so extraction happens here.
 */
app.post('/api/extract', async (req, res) => {
  const raw = req.body?.url || urlFromSharedText(req.body?.text || '');
  if (!raw) {
    return res.status(400).json({ error: 'no-url', message: 'That share did not contain a link' });
  }

  try {
    const garment = await extractFromUrl(raw);
    if (!garment.images.length) {
      return res.status(422).json({
        error: 'no-images',
        message: 'No product image found on that page. Try sharing a screenshot instead.',
        garment,
      });
    }
    res.json({ garment, category: guessCategory(garment.title) });
  } catch (err) {
    res.status(422).json({ error: 'extract-failed', message: err.message });
  }
});

// --- try-on ---------------------------------------------------------------

app.post('/api/tryon', async (req, res) => {
  const {
    garmentUrl,
    garmentImageBase64,
    garmentContentType = 'image/jpeg',
    pageUrl,
    title = '',
    modelId,
    force = false,
  } = req.body || {};

  if (!garmentUrl && !garmentImageBase64) {
    return res.status(400).json({ error: 'garmentUrl or garmentImageBase64 is required' });
  }

  const model = getModel(modelId);
  if (!model) {
    return res.status(409).json({ error: 'no-model', message: 'Add a photo of yourself first' });
  }

  // The app sends bytes whenever it has them, because major retailers block
  // server-side fetches of both their pages and (sometimes) their images. A
  // phone is a real browser and is not blocked, so it does the fetching.
  // A shared screenshot has no URL at all, so it is keyed on its bytes.
  let garmentBuffer = null;
  let garmentType = garmentContentType;
  if (garmentImageBase64) {
    garmentBuffer = Buffer.from(String(garmentImageBase64).replace(/^data:[^;]+;base64,/, ''), 'base64');
    if (garmentBuffer.byteLength < 1024) {
      return res.status(400).json({ error: 'That image looks empty or corrupt' });
    }

    // The bytes get the final say over the declared Content-Type.
    const sniffed = sniffImageType(garmentBuffer);
    if (sniffed) garmentType = sniffed;

    if (!UPLOADABLE_TYPES.has(garmentType)) {
      if (!garmentUrl) {
        // A shared screenshot in an unsupported format has no fallback path.
        return res.status(415).json({
          error: 'unsupported-format',
          message: `That image is ${garmentType ?? 'in an unrecognised format'}, which the ` +
              'try-on API cannot read. Take a screenshot of it and share that instead.',
        });
      }
      // There is a URL to fall back on, so drop the bytes and let YouCam fetch.
      console.warn(`[tryon] discarding ${garmentType} bytes; falling back to URL for ${garmentUrl}`);
      garmentBuffer = null;
    }
  }
  const cacheSubject =
    garmentUrl || `sha256:${createHash('sha256').update(garmentBuffer).digest('hex')}`;

  const category = req.body?.category || guessCategory(title);
  const key = renderKey({ modelId: model.id, garmentUrl: cacheSubject, category });

  if (!force) {
    const cached = getRender(key);
    if (cached) {
      // Revisiting a product page is free and instant, which is the whole point
      // of caching on the garment URL rather than on the task id.
      return res.json({ jobId: null, state: 'done', cached: true, render: cached });
    }
  }

  const jobId = randomUUID();
  jobs.set(jobId, { state: 'running', stage: 'queued', key, startedAt: Date.now() });
  res.json({ jobId, state: 'running', cached: false, category });

  runTryOn(jobId, {
    model,
    garmentUrl,
    garmentBuffer,
    garmentContentType: garmentType,
    cacheSubject,
    pageUrl,
    category,
    key,
    title,
  }).catch((err) => {
    // Log enough to diagnose a failure after the fact — which garment, which
    // format, and what the API actually said.
    console.error(
      `[tryon] job failed\n  garment: ${garmentUrl || `(${garmentType} bytes)`}\n` +
        `  page:    ${pageUrl || '-'}\n  category: ${category}\n  error:   ${err.message}`
    );
    if (err.body) console.error(`  body:    ${JSON.stringify(err.body)}`);
    jobs.set(jobId, { state: 'error', error: err.message, detail: err.body, key });
  });
});

app.get('/api/tryon/:jobId', (req, res) => {
  const job = jobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: 'Unknown jobId' });
  res.json(job);
});

app.get('/api/renders', (_req, res) => {
  res.json({ renders: listRenders() });
});

/** Record whether the user would actually buy it. */
app.patch('/api/renders/:key', (req, res) => {
  const { verdict } = req.body || {};
  if (verdict !== 'keep' && verdict !== 'pass' && verdict !== null) {
    return res.status(400).json({ error: 'verdict must be "keep", "pass" or null' });
  }
  const render = setVerdict(req.params.key, verdict);
  if (!render) return res.status(404).json({ error: 'Unknown render' });
  res.json({ render });
});

app.delete('/api/renders/:key', async (req, res) => {
  const removed = await deleteRender(req.params.key);
  if (!removed) forgetRender(req.params.key);
  res.json({ ok: true });
});

/** Wipes every stored photo and every render. */
app.delete('/api/data', async (_req, res) => {
  await deleteEverything();
  res.json({ ok: true, activeModelId: null });
});

/** Deletes a stored photo and every render made from it. */
app.delete('/api/model/:id', async (req, res) => {
  const removed = await deleteModel(req.params.id);
  if (!removed) return res.status(404).json({ error: 'Unknown model' });
  res.json({ ok: true, activeModelId: getActiveModelId() });
});

async function runTryOn(
  jobId,
  { model, garmentUrl, garmentBuffer, garmentContentType, cacheSubject, pageUrl, category, key, title }
) {
  const setStage = (stage, extra = {}) =>
    jobs.set(jobId, { ...jobs.get(jobId), state: 'running', stage, ...extra });

  // 1. Make sure we hold a live file_id for the person photo.
  setStage('preparing-model');
  let srcFileId = modelFileIdIsFresh(model) ? model.fileId : null;
  if (!srcFileId) {
    const bytes = await readModelBytes(model);
    srcFileId = await youcam.uploadImage(bytes, model.contentType, `model-${model.id}.jpg`);
    rememberModelFileId(model.id, srcFileId);
  }

  // 2. Get the garment in front of the API, then poll.
  //
  // Uploading the bytes is the primary path whenever we have them. Handing over
  // `ref_file_url` is free and needs no upload, but the retailers that matter
  // block YouCam's fetcher exactly as they block ours — Zara answers with
  // `error_download_image`. That failure arrives *asynchronously*, while
  // polling, long after the task was accepted, and a failed task still costs
  // units. So we only gamble on the URL when there is nothing else to send.
  let garmentPath;
  let taskShape;
  let finished;

  const runWithUpload = async (buffer, contentType, label) => {
    setStage('uploading-garment');
    const refFileId = await youcam.uploadImage(buffer, contentType, 'garment.jpg');
    setStage('submitting');
    const task = await youcam.createClothTask({ srcFileId, refFileId, garmentCategory: category });
    garmentPath = label;
    taskShape = task.shape;
    setStage('rendering', { taskId: task.taskId });
    return youcam.waitForTask(task.taskId, {
      onTick: (snap, n) => setStage('rendering', { taskId: task.taskId, polls: n, apiStatus: snap.status }),
    });
  };

  if (garmentBuffer) {
    finished = await runWithUpload(
      garmentBuffer,
      garmentContentType,
      garmentUrl ? 'app-supplied-bytes' : 'shared-image'
    );
  } else {
    setStage('submitting');
    try {
      const task = await youcam.createClothTask({
        srcFileId,
        refFileUrl: garmentUrl,
        garmentCategory: category,
      });
      garmentPath = 'ref_file_url';
      taskShape = task.shape;
      setStage('rendering', { taskId: task.taskId });
      finished = await youcam.waitForTask(task.taskId, {
        onTick: (snap, n) => setStage('rendering', { taskId: task.taskId, polls: n, apiStatus: snap.status }),
      });
    } catch (urlPathErr) {
      // Covers both a rejected request and a task that failed while polling.
      console.warn(`[tryon] ref_file_url path failed (${urlPathErr.message}); fetching it ourselves`);
      setStage('downloading-garment');
      const { buffer, contentType } = await fetchGarmentBytes(garmentUrl, pageUrl);
      finished = await runWithUpload(buffer, contentType, 'server-fetched-bytes');
    }
  }

  const remoteUrl = pickRenderUrl(finished.urls, garmentUrl);
  if (!remoteUrl) {
    throw new youcam.YouCamError('Could not identify the result image in the task response', {
      body: finished.raw,
    });
  }

  // 5. Copy it locally; YouCam download links expire in about two hours.
  setStage('saving');
  const render = await saveRender(key, {
    modelId: model.id,
    garmentUrl: cacheSubject,
    category,
    remoteUrl,
    meta: {
      pageUrl,
      title,
      garmentPath,
      shape: taskShape,
      tookMs: Date.now() - jobs.get(jobId).startedAt,
    },
  });

  jobs.set(jobId, { state: 'done', stage: 'done', key, render });
}

function pickRenderUrl(urls, garmentUrl) {
  const usable = urls.filter((u) => u !== garmentUrl);
  const imageish = usable.filter((u) => /\.(jpe?g|png|webp)(\?|$)/i.test(u));
  const resultish = usable.filter((u) => /result|output|download|render/i.test(u));
  return resultish[0] || imageish[imageish.length - 1] || usable[0] || null;
}

app.listen(config.port, () => {
  console.log(`EasyBuy proxy listening on http://localhost:${config.port}`);
  if (!config.apiKey) {
    console.warn('YOUCAM_API_KEY is not set — copy .env.example to backend/.env before trying a render.');
  }
});
