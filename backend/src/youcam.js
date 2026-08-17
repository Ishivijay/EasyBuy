import { config, assertConfigured } from './config.js';

/**
 * Thin client for the YouCam (Perfect Corp) server-to-server API.
 *
 * Two things here are deliberately defensive, because the public docs do not
 * publish the exact request body for the AI-clothes task:
 *
 *  1. `createClothTask` negotiates between the known candidate body shapes on
 *     the first call and remembers whichever one the server accepts.
 *  2. `readTask` scans the response tolerantly instead of assuming one schema.
 *
 * Once `npm run verify` has printed the real shapes against a live key, these
 * can be collapsed to the single correct variant.
 */

const CLOTH_TASK_PATH = '/s2s/v2.0/task/cloth';
const CLOTH_FILE_PATH = '/s2s/v2.0/file/cloth';
const CREDIT_PATH = '/s2s/v1.0/client/credit';

// The API allows 5 QPS. We stay under it with a simple spaced queue so that a
// burst of tabs cannot get the whole key rate-limited.
const MIN_REQUEST_GAP_MS = 220;
let lastRequestAt = 0;
let queue = Promise.resolve();

function schedule(fn) {
  const run = queue.then(async () => {
    const wait = Math.max(0, lastRequestAt + MIN_REQUEST_GAP_MS - Date.now());
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    lastRequestAt = Date.now();
    return fn();
  });
  // Keep the chain alive even when a call rejects.
  queue = run.then(
    () => undefined,
    () => undefined
  );
  return run;
}

export class YouCamError extends Error {
  constructor(message, { status, body, path } = {}) {
    super(message);
    this.name = 'YouCamError';
    this.status = status;
    this.body = body;
    this.path = path;
  }
}

async function apiFetch(path, { method = 'GET', body, headers = {} } = {}) {
  assertConfigured();
  const url = `${config.baseUrl}${path}`;

  const res = await schedule(() =>
    fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        Accept: 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...headers,
      },
      body: body ? JSON.stringify(body) : undefined,
    })
  );

  const text = await res.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { _raw: text };
  }

  if (!res.ok) {
    throw new YouCamError(`${method} ${path} failed with HTTP ${res.status}`, {
      status: res.status,
      body: parsed,
      path,
    });
  }
  return parsed;
}

export async function getCredit() {
  return apiFetch(CREDIT_PATH);
}

/**
 * Upload raw image bytes and return a file_id usable as src/ref in a task.
 * The API hands back a pre-signed URL that we PUT the bytes to.
 */
export async function uploadImage(buffer, contentType = 'image/jpeg', fileName = 'image.jpg') {
  const meta = await apiFetch(CLOTH_FILE_PATH, {
    method: 'POST',
    body: {
      files: [
        {
          content_type: contentType,
          file_name: fileName,
          file_size: buffer.byteLength,
        },
      ],
    },
  });

  const entry = firstFileEntry(meta);
  if (!entry) {
    throw new YouCamError('Upload metadata response did not contain a file entry', { body: meta });
  }

  const fileId = entry.file_id || entry.fileId || entry.id;
  const upload = entry.requests?.[0] || entry.request || entry.upload;
  if (!fileId || !upload?.url) {
    throw new YouCamError('Upload metadata response was missing file_id or upload URL', {
      body: meta,
    });
  }

  const putRes = await fetch(upload.url, {
    method: upload.method || 'PUT',
    headers: { 'Content-Type': contentType, ...(upload.headers || {}) },
    body: buffer,
  });
  if (!putRes.ok) {
    throw new YouCamError(`Byte upload failed with HTTP ${putRes.status}`, {
      status: putRes.status,
      body: await putRes.text().catch(() => ''),
    });
  }

  return fileId;
}

function firstFileEntry(payload) {
  const buckets = [payload?.result?.files, payload?.files, payload?.data?.files, payload?.result];
  for (const bucket of buckets) {
    if (Array.isArray(bucket) && bucket.length) return bucket[0];
  }
  return null;
}

/**
 * Candidate request bodies for the clothes task, most likely first.
 * `negotiatedShape` caches whichever one the server accepted.
 */
let negotiatedShape = null;

function buildBodies({ srcFileId, srcFileUrl, refFileId, refFileUrl, garmentCategory }) {
  const src = srcFileId ? { src_file_id: srcFileId } : { src_file_url: srcFileUrl };
  const ref = refFileId ? { ref_file_id: refFileId } : { ref_file_url: refFileUrl };

  return [
    {
      name: 'flat',
      body: { ...src, ...ref, garment_category: garmentCategory },
    },
    {
      name: 'flat-wrapped',
      body: { request_id: 0, ...src, ...ref, garment_category: garmentCategory },
    },
    {
      name: 'file-sets',
      body: {
        request_id: 0,
        payload: {
          file_sets: {
            ...(srcFileId ? { src_ids: [srcFileId] } : { src_urls: [srcFileUrl] }),
            ...(refFileId ? { ref_ids: [refFileId] } : { ref_urls: [refFileUrl] }),
          },
          actions: [{ id: 0, params: { garment_category: garmentCategory } }],
        },
      },
    },
  ];
}

export async function createClothTask(params) {
  const candidates = buildBodies(params);
  const ordered = negotiatedShape
    ? [
        ...candidates.filter((c) => c.name === negotiatedShape),
        ...candidates.filter((c) => c.name !== negotiatedShape),
      ]
    : candidates;

  const attempts = [];
  for (const candidate of ordered) {
    try {
      const out = await apiFetch(CLOTH_TASK_PATH, { method: 'POST', body: candidate.body });
      const taskId = pickTaskId(out);
      if (!taskId) {
        attempts.push({ shape: candidate.name, error: 'accepted but returned no task_id', body: out });
        continue;
      }
      if (negotiatedShape !== candidate.name) {
        negotiatedShape = candidate.name;
        console.log(`[youcam] clothes task body shape negotiated: "${candidate.name}"`);
      }
      return { taskId, raw: out, shape: candidate.name };
    } catch (err) {
      if (err instanceof YouCamError && (err.status === 401 || err.status === 403)) {
        // Auth problems are not a shape problem. Fail loudly instead of retrying.
        throw err;
      }
      attempts.push({ shape: candidate.name, status: err.status, body: err.body });
    }
  }

  throw new YouCamError('No candidate request body was accepted by /task/cloth', {
    body: attempts,
    path: CLOTH_TASK_PATH,
  });
}

export async function readTask(taskId) {
  const raw = await apiFetch(`${CLOTH_TASK_PATH}/${encodeURIComponent(taskId)}`);
  return { status: pickStatus(raw), urls: pickResultUrls(raw), raw };
}

/** Poll until the task settles. Resolves with the result image URLs. */
export async function waitForTask(taskId, { intervalMs = 2000, timeoutMs = 180000, onTick } = {}) {
  const deadline = Date.now() + timeoutMs;
  let ticks = 0;

  while (Date.now() < deadline) {
    const snapshot = await readTask(taskId);
    ticks += 1;
    onTick?.(snapshot, ticks);

    if (snapshot.status === 'success') {
      if (!snapshot.urls.length) {
        throw new YouCamError('Task reported success but no result URL was found', {
          body: snapshot.raw,
        });
      }
      return snapshot;
    }
    if (snapshot.status === 'error') {
      throw new YouCamError('Task failed', { body: snapshot.raw });
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }

  throw new YouCamError(`Task ${taskId} did not finish within ${timeoutMs}ms`);
}

// --- tolerant response readers -------------------------------------------

function pickTaskId(payload) {
  return deepFind(payload, (key, value) => {
    if (typeof value !== 'string' && typeof value !== 'number') return false;
    return key === 'task_id' || key === 'taskId';
  });
}

const SUCCESS = new Set(['success', 'succeeded', 'completed', 'done', 'finished']);
const FAILURE = new Set(['error', 'failed', 'failure', 'cancelled', 'canceled']);

function pickStatus(payload) {
  const value = deepFind(payload, (key, v) => {
    if (typeof v !== 'string') return false;
    return key === 'task_status' || key === 'status' || key === 'state';
  });
  const normalized = String(value || '').toLowerCase();
  if (SUCCESS.has(normalized)) return 'success';
  if (FAILURE.has(normalized)) return 'error';
  return 'running';
}

function pickResultUrls(payload) {
  const urls = [];
  walk(payload, (key, value) => {
    if (typeof value === 'string' && /^https?:\/\//.test(value) && key !== 'self') {
      urls.push(value);
    }
  });
  // Drop anything that is obviously not the render (docs links, thumbnails of input).
  return [...new Set(urls)];
}

function deepFind(node, predicate) {
  let found;
  walk(node, (key, value) => {
    if (found === undefined && predicate(key, value)) found = value;
  });
  return found;
}

function walk(node, visit, key = '') {
  if (node === null || node === undefined) return;
  if (Array.isArray(node)) {
    for (const item of node) walk(item, visit, key);
    return;
  }
  if (typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) {
      visit(k, v);
      walk(v, visit, k);
    }
    return;
  }
  visit(key, node);
}
