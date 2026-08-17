/**
 * Server-side garment extraction from a shared product URL.
 *
 * On mobile there is no DOM to read — the app receives a bare link from the
 * share sheet — so extraction has to work against raw HTML. That sounds worse
 * than the extension's DOM scraping, but it holds up: every store publishes
 * `og:image` and usually JSON-LD `Product.image` in the server-rendered HTML,
 * because link previews and Google Shopping depend on it. Even SPA-heavy sites
 * like Zara ship those tags before any JavaScript runs.
 */

const BROWSER_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
  Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'en-US,en;q=0.9',
};

const MAX_HTML_BYTES = 4 * 1024 * 1024;

export async function extractFromUrl(rawUrl) {
  const url = normaliseUrl(rawUrl);
  const res = await fetch(url, { headers: BROWSER_HEADERS, redirect: 'follow' });
  if (!res.ok) throw new Error(`Could not open that link (HTTP ${res.status})`);

  const contentType = res.headers.get('content-type') || '';
  if (contentType.startsWith('image/')) {
    // Some shares are a direct image link rather than a product page.
    return { host: hostOf(res.url), pageUrl: res.url, title: '', price: '', images: [res.url], source: 'direct-image' };
  }

  const html = (await res.text()).slice(0, MAX_HTML_BYTES);
  const finalUrl = res.url || url;

  const meta = readMetaImages(html);
  const structured = readJsonLd(html);
  const inline = readInlineImages(html);

  const images = [];
  for (const candidate of [...structured, ...meta, ...inline]) {
    const absolute = toAbsolute(candidate, finalUrl);
    if (absolute && !images.includes(absolute)) images.push(absolute);
  }

  return {
    host: hostOf(finalUrl),
    pageUrl: finalUrl,
    title: readTitle(html),
    price: readPrice(html),
    source: structured.length ? 'json-ld' : meta.length ? 'og' : 'inline',
    images: images.slice(0, 12),
  };
}

/** Share sheets hand over messy text: "Check this out https://..." */
export function urlFromSharedText(text = '') {
  const match = String(text).match(/https?:\/\/[^\s<>"')]+/i);
  return match ? match[0] : null;
}

function normaliseUrl(raw) {
  const trimmed = String(raw || '').trim();
  const withScheme = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  const parsed = new URL(withScheme); // throws on garbage, which the route reports
  return parsed.href;
}

function hostOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return '';
  }
}

function toAbsolute(candidate, base) {
  if (!candidate) return null;
  let url;
  try {
    url = new URL(decodeEntities(candidate), base).href;
  } catch {
    return null;
  }
  if (!/^https?:/.test(url)) return null;
  if (/\.svg(\?|$)/i.test(url)) return null;
  if (/sprite|logo|icon|placeholder|badge|flag|pixel|tracking/i.test(url)) return null;
  return upscale(url);
}

/** Strip CDN resize directives so the API gets the largest available render. */
function upscale(url) {
  return url
    .replace(/\._[A-Z0-9_,]+_\./, '.')
    .replace(/([?&])w=\d+/, '$1w=1500')
    .replace(/([?&])width=\d+/, '$1width=1500')
    .replace(/\/f_auto,[^/]*\//, '/f_auto,q_auto,w_1500/');
}

function decodeEntities(text) {
  return String(text)
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

function readMetaImages(html) {
  const out = [];
  const tagPattern = /<meta\b[^>]*>/gi;
  for (const [tag] of html.matchAll(tagPattern)) {
    const key = attr(tag, 'property') || attr(tag, 'name');
    if (!key) continue;
    if (/^(og:image(:secure_url|:url)?|twitter:image(:src)?)$/i.test(key)) {
      const content = attr(tag, 'content');
      if (content) out.push(content);
    }
  }
  return out;
}

function readJsonLd(html) {
  const out = [];
  const blocks = html.matchAll(
    /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi
  );
  for (const [, body] of blocks) {
    let data;
    try {
      data = JSON.parse(body.trim());
    } catch {
      continue;
    }
    const stack = Array.isArray(data) ? [...data] : [data];
    while (stack.length) {
      const item = stack.pop();
      if (!item || typeof item !== 'object') continue;
      if (Array.isArray(item['@graph'])) stack.push(...item['@graph']);
      for (const value of Object.values(item)) {
        if (value && typeof value === 'object') stack.push(value);
      }
      if (/product/i.test(String(item['@type'] || '')) && item.image) {
        const images = Array.isArray(item.image) ? item.image : [item.image];
        for (const image of images) out.push(typeof image === 'string' ? image : image?.url);
      }
    }
  }
  return out.filter(Boolean);
}

/**
 * Last resort: pull <img> sources that look like product photography.
 * Ranked by the resolution hints in the URL, since we cannot measure the
 * rendered size without a browser.
 */
function readInlineImages(html) {
  const scored = [];
  for (const [tag] of html.matchAll(/<img\b[^>]*>/gi)) {
    const src = attr(tag, 'data-old-hires') || bestFromSrcset(attr(tag, 'srcset')) || attr(tag, 'src');
    if (!src) continue;
    const dimensions = [...src.matchAll(/(\d{3,4})/g)].map((m) => Number(m[1]));
    const hint = dimensions.length ? Math.max(...dimensions) : 0;
    scored.push({ src, hint });
  }
  return scored.sort((a, b) => b.hint - a.hint).map((s) => s.src);
}

function bestFromSrcset(srcset) {
  if (!srcset) return null;
  return (
    srcset
      .split(',')
      .map((part) => part.trim().split(/\s+/))
      .map(([url, size]) => ({ url, weight: parseInt(size, 10) || 0 }))
      .sort((a, b) => b.weight - a.weight)[0]?.url || null
  );
}

function readTitle(html) {
  const og = html.match(/<meta\b[^>]*property=["']og:title["'][^>]*>/i)?.[0];
  const fromOg = og && attr(og, 'content');
  if (fromOg) return decodeEntities(fromOg).trim().slice(0, 200);

  const h1 = html.match(/<h1\b[^>]*>([\s\S]{0,300}?)<\/h1>/i)?.[1];
  if (h1) return decodeEntities(stripTags(h1)).trim().slice(0, 200);

  const title = html.match(/<title\b[^>]*>([\s\S]{0,300}?)<\/title>/i)?.[1];
  return title ? decodeEntities(stripTags(title)).trim().slice(0, 200) : '';
}

function readPrice(html) {
  const metaPrice = html.match(
    /<meta\b[^>]*(?:property|name)=["'](?:product:price:amount|og:price:amount)["'][^>]*>/i
  )?.[0];
  const amount = metaPrice && attr(metaPrice, 'content');
  const currencyTag = html.match(
    /<meta\b[^>]*(?:property|name)=["'](?:product:price:currency|og:price:currency)["'][^>]*>/i
  )?.[0];
  const currency = (currencyTag && attr(currencyTag, 'content')) || '';
  if (amount) return `${amount} ${currency}`.trim();

  const inline = html.match(/[$£€]\s?\d{1,4}(?:[.,]\d{2})?/);
  return inline ? inline[0] : '';
}

function stripTags(text) {
  return text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
}

function attr(tag, name) {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i'));
  return match ? match[2] ?? match[3] ?? match[4] ?? null : null;
}
