/**
 * Garment image handling.
 *
 * The fast path never touches the bytes: YouCam accepts `ref_file_url` and
 * fetches the image itself, so a store CDN URL goes straight through and we
 * skip a download + re-upload round trip entirely.
 *
 * Some CDNs (notably Amazon's) reject requests without a browser-ish User-Agent
 * or Referer, which makes the fast path fail. `fetchGarmentBytes` is the
 * fallback: we pull the image the way a browser would, then upload it.
 */

const BROWSER_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  // Narrower than a real browser on purpose. Advertising avif/webp makes any
  // content-negotiating CDN return those, and the try-on API rejects them.
  Accept: 'image/jpeg,image/png,image/*;q=0.5',
  'Accept-Language': 'en-US,en;q=0.9',
};

/** Formats the try-on API accepts for upload. */
export const UPLOADABLE_TYPES = new Set(['image/jpeg', 'image/jpg', 'image/png']);

const MAX_BYTES = 12 * 1024 * 1024;

export async function fetchGarmentBytes(imageUrl, pageUrl) {
  const headers = { ...BROWSER_HEADERS };
  if (pageUrl) {
    try {
      headers.Referer = new URL(pageUrl).origin + '/';
    } catch {
      /* ignore an unparseable page URL */
    }
  }

  const res = await fetch(imageUrl, { headers, redirect: 'follow' });
  if (!res.ok) {
    throw new Error(`Garment image fetch failed (HTTP ${res.status}) for ${imageUrl}`);
  }

  const contentType = (res.headers.get('content-type') || 'image/jpeg').split(';')[0].trim();
  if (!contentType.startsWith('image/')) {
    throw new Error(`Garment URL did not return an image (got ${contentType})`);
  }

  const buffer = Buffer.from(await res.arrayBuffer());
  if (buffer.byteLength > MAX_BYTES) {
    throw new Error(`Garment image is ${Math.round(buffer.byteLength / 1e6)}MB, too large to upload`);
  }
  if (buffer.byteLength < 1024) {
    throw new Error('Garment image was suspiciously small; the page probably served a placeholder');
  }
  if (!UPLOADABLE_TYPES.has(contentType)) {
    // Some CDNs ignore Accept entirely and always serve their modern format.
    throw new Error(
      `That store served the image as ${contentType}, which the try-on API cannot read. ` +
        'Try a different photo of the item, or share a screenshot instead.'
    );
  }

  return { buffer, contentType };
}

/**
 * Identifies an image from its magic bytes.
 *
 * Trusting the Content-Type header is what caused try-ons to fail on stores
 * with content-negotiating CDNs, so the actual bytes get the final say.
 * Returns null when the format is not something we recognise.
 */
export function sniffImageType(buffer) {
  if (!buffer || buffer.byteLength < 12) return null;

  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'image/jpeg';

  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (png.every((byte, i) => buffer[i] === byte)) return 'image/png';

  const header = buffer.subarray(0, 16).toString('latin1');
  if (header.startsWith('RIFF') && header.slice(8, 12) === 'WEBP') return 'image/webp';
  if (header.slice(4, 8) === 'ftyp') {
    const brand = header.slice(8, 12);
    if (brand.startsWith('avi')) return 'image/avif';
    if (brand.startsWith('hei') || brand.startsWith('mif')) return 'image/heic';
  }
  if (header.startsWith('GIF8')) return 'image/gif';

  return null;
}

const LOWER = /\b(jean|jeans|trouser|trousers|pant|pants|chino|short|shorts|skirt|legging|leggings|joggers|sweatpant|cargo)\b/i;
const FULL = /\b(dress|gown|jumpsuit|romper|playsuit|overall|overalls|coverall|kaftan|abaya|saree|sari)\b/i;
const UPPER = /\b(shirt|t-shirt|tshirt|tee|top|blouse|sweater|jumper|hoodie|sweatshirt|jacket|coat|blazer|cardigan|vest|polo|knit|parka|bomber|anorak)\b/i;

/**
 * Best-effort garment category from the product title and breadcrumb.
 * The extension guesses client-side too; this is the server-side safety net.
 */
export function guessCategory(text = '') {
  if (FULL.test(text)) return 'full_body';
  if (LOWER.test(text)) return 'lower_body';
  if (UPPER.test(text)) return 'upper_body';
  return 'upper_body';
}
