/**
 * Per-store garment image extraction.
 *
 * Every adapter returns a *ranked list* of candidate image URLs rather than one
 * pick. Product pages show the same garment on a model, flat, and in detail
 * crops, and the try-on quality depends a lot on which one goes in — so the
 * side panel lets the user cycle candidates instead of hoping the first guess
 * was right. It also means an adapter going stale degrades to the generic
 * scorer rather than breaking the feature.
 */

(function () {
  const MIN_DIMENSION = 300;

  /** Highest-resolution entry in a srcset. */
  function fromSrcset(srcset) {
    if (!srcset) return null;
    const best = srcset
      .split(',')
      .map((part) => part.trim().split(/\s+/))
      .map(([url, size]) => ({ url, weight: parseInt(size, 10) || 0 }))
      .sort((a, b) => b.weight - a.weight)[0];
    return best?.url || null;
  }

  function absolute(url) {
    if (!url) return null;
    try {
      return new URL(url, location.href).href;
    } catch {
      return null;
    }
  }

  /** Strip resizing directives so we send the API the largest version available. */
  function upscale(url) {
    if (!url) return url;
    let out = url;
    // Amazon: ..._AC_SX679_.jpg -> ....jpg
    out = out.replace(/\._[A-Z0-9_,]+_\./, '.');
    // Zara / Mango style width params
    out = out.replace(/([?&])w=\d+/, '$1w=1500');
    out = out.replace(/([?&])width=\d+/, '$1width=1500');
    // H&M / Vinted CDN presets
    out = out.replace(/\/f_auto,[^/]*\//, '/f_auto,q_auto,w_1500/');
    return out;
  }

  function pushUnique(list, url) {
    const abs = upscale(absolute(url));
    if (!abs || !/^https?:/.test(abs)) return;
    if (/\.svg(\?|$)/i.test(abs)) return;
    if (/sprite|logo|icon|placeholder|badge|flag/i.test(abs)) return;
    if (!list.includes(abs)) list.push(abs);
  }

  function fromSelectors(selectors) {
    const out = [];
    for (const selector of selectors) {
      for (const el of document.querySelectorAll(selector)) {
        if (el.tagName === 'IMG') {
          pushUnique(out, fromSrcset(el.getAttribute('srcset')) || el.currentSrc || el.src);
          pushUnique(out, el.getAttribute('data-old-hires'));
          pushUnique(out, el.getAttribute('data-src'));
        } else if (el.tagName === 'SOURCE') {
          pushUnique(out, fromSrcset(el.getAttribute('srcset')));
        } else if (el.tagName === 'META') {
          pushUnique(out, el.getAttribute('content'));
        }
      }
    }
    return out;
  }

  /** Structured data is the most reliable source when a site publishes it. */
  function fromJsonLd() {
    const out = [];
    for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
      let data;
      try {
        data = JSON.parse(node.textContent);
      } catch {
        continue;
      }
      const stack = Array.isArray(data) ? [...data] : [data];
      while (stack.length) {
        const item = stack.pop();
        if (!item || typeof item !== 'object') continue;
        if (Array.isArray(item['@graph'])) stack.push(...item['@graph']);
        const type = String(item['@type'] || '');
        if (/product/i.test(type) && item.image) {
          const images = Array.isArray(item.image) ? item.image : [item.image];
          for (const img of images) pushUnique(out, typeof img === 'string' ? img : img?.url);
        }
      }
    }
    return out;
  }

  /**
   * Fallback for any store we have never seen: score every rendered image by
   * area, penalise anything that sits in a header, nav, footer or a
   * "you may also like" rail, and return the survivors largest-first.
   */
  function genericScan() {
    const scored = [];
    for (const img of document.images) {
      const rect = img.getBoundingClientRect();
      const width = img.naturalWidth || rect.width;
      const height = img.naturalHeight || rect.height;
      if (width < MIN_DIMENSION || height < MIN_DIMENSION) continue;

      const ratio = width / height;
      if (ratio > 2 || ratio < 0.35) continue; // banners and thin strips

      let score = width * height;
      if (img.closest('header, nav, footer, [class*="recommend" i], [class*="related" i], [class*="carousel" i][class*="also" i]')) {
        score *= 0.15;
      }
      if (img.closest('[class*="product" i], [class*="gallery" i], main, [role="main"]')) {
        score *= 2.5;
      }
      // Portrait crops are usually the model shot, which tries on best.
      if (ratio < 0.9) score *= 1.3;

      scored.push({ url: img.currentSrc || img.src, score });
    }

    const out = [];
    for (const { url } of scored.sort((a, b) => b.score - a.score)) pushUnique(out, url);
    return out;
  }

  function textOf(selectors) {
    for (const selector of selectors) {
      const el = document.querySelector(selector);
      const text = el?.getAttribute?.('content') || el?.textContent;
      if (text && text.trim()) return text.trim().replace(/\s+/g, ' ').slice(0, 200);
    }
    return '';
  }

  const ADAPTERS = [
    {
      id: 'zara',
      test: (host) => /(^|\.)zara\.com$/.test(host),
      images: () =>
        fromSelectors([
          'picture.media-image source',
          'img.media-image__image',
          '.product-detail-images img',
          'meta[property="og:image"]',
        ]),
      title: () => textOf(['h1.product-detail-info__header-name', 'h1', 'meta[property="og:title"]']),
      price: () => textOf(['.money-amount__main', '[class*="price" i]']),
    },
    {
      id: 'hm',
      test: (host) => /(^|\.)hm\.com$/.test(host),
      images: () =>
        fromSelectors([
          '[class*="product-detail-main-image" i] img',
          '[data-testid="grid-gallery"] img',
          'picture source',
          'meta[property="og:image"]',
        ]),
      title: () => textOf(['h1', 'meta[property="og:title"]']),
      price: () => textOf(['[class*="price" i]']),
    },
    {
      id: 'amazon',
      test: (host) => /(^|\.)amazon\.[a-z.]+$/.test(host),
      images: () => {
        const out = [];
        // Amazon publishes every resolution it has in a JSON attribute.
        const main = document.querySelector('#landingImage, #imgTagWrapperId img');
        const dynamic = main?.getAttribute('data-a-dynamic-image');
        if (dynamic) {
          try {
            const map = JSON.parse(dynamic);
            const sorted = Object.entries(map).sort((a, b) => b[1][0] * b[1][1] - a[1][0] * a[1][1]);
            for (const [url] of sorted) pushUnique(out, url);
          } catch {
            /* fall through to selectors */
          }
        }
        return out.concat(
          fromSelectors(['#landingImage', '#imgTagWrapperId img', '#altImages img', 'meta[property="og:image"]'])
        );
      },
      title: () => textOf(['#productTitle', 'h1', 'meta[property="og:title"]']),
      price: () => textOf(['.a-price .a-offscreen', '#priceblock_ourprice']),
    },
    {
      id: 'vinted',
      test: (host) => /(^|\.)vinted\.[a-z.]+$/.test(host),
      images: () =>
        fromSelectors([
          '[data-testid="item-photo"] img',
          '.item-photo img',
          'figure img',
          'meta[property="og:image"]',
        ]),
      title: () => textOf(['[data-testid="item-page-summary-plugin"] h1', 'h1', 'meta[property="og:title"]']),
      price: () => textOf(['[data-testid*="price"]', '[class*="price" i]']),
      // Resale listings put the real size and condition in the description, and
      // that context is worth showing next to the render.
      notes: () => textOf(['[itemprop="description"]', '[data-testid="item-description"]']),
    },
    {
      id: 'depop',
      test: (host) => /(^|\.)depop\.com$/.test(host),
      images: () => fromSelectors(['[data-testid="product__image"] img', 'main img', 'meta[property="og:image"]']),
      title: () => textOf(['h1', 'meta[property="og:title"]']),
      price: () => textOf(['[data-testid="product__price"]', '[class*="price" i]']),
    },
  ];

  function detect() {
    const host = location.hostname.replace(/^www\./, '');
    const adapter = ADAPTERS.find((a) => a.test(host));

    const adapterImages = adapter ? adapter.images() : [];
    const structured = fromJsonLd();
    const generic = genericScan();

    // Adapter first, then structured data, then the scored sweep. Dedupe order
    // is meaningful: candidate[0] is what we render without asking.
    const images = [];
    for (const url of [...adapterImages, ...structured, ...generic]) {
      if (!images.includes(url)) images.push(url);
    }

    const title =
      (adapter?.title?.() || '') ||
      textOf(['h1', 'meta[property="og:title"]', 'title']);

    return {
      source: adapter?.id || (structured.length ? 'json-ld' : 'generic'),
      host,
      pageUrl: location.href,
      title,
      price: adapter?.price?.() || textOf(['[class*="price" i]']),
      notes: adapter?.notes?.() || '',
      images: images.slice(0, 12),
    };
  }

  window.__EASYBUY_EXTRACT = detect;
})();
