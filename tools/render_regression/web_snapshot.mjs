/**
 * The web page's answer for the render regression test: what the forum's page shows of each floor, read in a headless
 * Chromium with the forum's own style sheets and scripts.
 *
 * Only run locally (it needs Playwright and a full corpus of the forum's pages, which never go into the repository);
 * the test reads the snapshot it writes. Nothing is fetched: every request is answered from the corpus (the forum's
 * css and js), with a placeholder (images: of the size in their url) or not at all.
 *
 *   node web_snapshot.mjs --corpus <dir>
 *       The synthetic floors (test/data/render_regression/floors/*.html), each alone in a page of the forum made from
 *       a thread page of the corpus, to test/data/render_regression/web.json.
 *   node web_snapshot.mjs --corpus <dir> --full --out <dir> [--images <images.json>] [tid ...]
 *       The thread pages of the corpus as they are (all of them without tids), to <out>/web/<tid>.json, for
 *       full_corpus_test.dart.
 *
 * The corpus: <dir>/threads/<tid>.html (a thread page as the forum served it to a guest), <dir>/assets/index.json
 * (the forum's path of a css or js file to its file in <dir>/assets). Options: --skeleton <tid> (the page the
 * synthetic floors are put in; the first one by default), --width <px> (1280), --dark (the forum's dark theme),
 * --fonts <fonts.conf> (the fonts the forum's css names; the text and its styles do not depend on them).
 * Playwright: `npm i playwright` next to this file, or PLAYWRIGHT_MODULE=<path to playwright/index.mjs>.
 *
 * Each floor is read from its `td.t_f` as a stream of tokens: text with its computed style, line breaks (`br`) and
 * block boundaries (`sb`), images, rules, players, and the opening and closing of blocks (quote, code, spoiler,
 * hidden content, tables with their rows and columns). Spoilers and the folds a post makes itself are opened first:
 * what is compared is the content, not whether it is folded.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { placeholderPng, transparentPng } from './png.mjs';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const DATA = path.join(REPO, 'test', 'data', 'render_regression');

const args = process.argv.slice(2);
const opt = name => {
  const i = args.indexOf(name);
  if (i < 0) return null;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const flag = name => {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
};
const corpus = opt('--corpus');
const outDir = opt('--out');
const imagesFile = opt('--images');
const skeletonTid = opt('--skeleton');
const width = Number(opt('--width') || 1280);
const fonts = opt('--fonts');
const full = flag('--full');
const dark = flag('--dark');
if (!corpus || (full && !outDir)) {
  console.error('usage: node web_snapshot.mjs --corpus <dir> [--full --out <dir> [--images <file>] [tid ...]]');
  process.exit(2);
}
const threadsDir = path.join(corpus, 'threads');
const assetsDir = path.join(corpus, 'assets');
const assetIndex = JSON.parse(fs.readFileSync(path.join(assetsDir, 'index.json'), 'utf8'));
const images = imagesFile ? JSON.parse(fs.readFileSync(imagesFile, 'utf8')) : {};
const SITE = 'https://www.tsdm39.com/';

const pngCache = new Map();
function placeholder(w, h) {
  const key = `${w}x${h}`;
  if (!pngCache.has(key)) pngCache.set(key, placeholderPng(w, h));
  return pngCache.get(key);
}

/** The image answered for [url]: a placeholder of the size in a synthetic url or in the image list, else none. */
function imageFor(url) {
  const m = /\/render\/(?:img|smiley)-\d+-(\d+)x(\d+)\.\w+$/.exec(url);
  if (m) return placeholder(Number(m[1]), Number(m[2]));
  const rel = url.startsWith(SITE) ? url.slice(SITE.length) : url;
  const info = images[url] || images[rel];
  // Not an image of the post (the page's icons, a background): transparent.
  if (!info) return transparentPng;
  return placeholder(info.w, info.h);
}

const browser = await chromium.launch({
  env: { ...process.env, ...(fonts ? { FONTCONFIG_FILE: path.resolve(fonts) } : {}) },
});

async function newContext(javaScriptEnabled) {
  const ctx = await browser.newContext({
    viewport: { width, height: 900 },
    deviceScaleFactor: 1,
    locale: 'zh-CN',
    colorScheme: dark ? 'dark' : 'light',
    javaScriptEnabled,
  });
  return ctx;
}

/** Answers every request of [page]: [main] for [mainUrl], the corpus' assets, placeholders; the rest is aborted. */
async function route(page, mainUrl, main) {
  await page.route('**/*', async r => {
    const req = r.request();
    const url = req.url();
    if (url === mainUrl) {
      // The forum's dark theme: the page as the server gives it to a reader who chose it.
      const body = dark ? main.replace(/data-tsdm-mode="light"/g, 'data-tsdm-mode="dark"') : main;
      return r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body });
    }
    const u = new URL(url);
    if (u.hostname === 'www.tsdm39.com') {
      const key = u.pathname.replace(/^\//, '');
      if (assetIndex[key]) {
        return r.fulfill({
          status: 200,
          contentType: key.endsWith('.css') ? 'text/css' : 'application/javascript',
          body: fs.readFileSync(path.join(assetsDir, assetIndex[key])),
        });
      }
    }
    if (req.resourceType() === 'image') {
      return r.fulfill({ status: 200, contentType: 'image/png', body: imageFor(url) });
    }
    return r.abort();
  });
}

/** In the page: the token stream of every floor's `td.t_f`. */
function pageExtract() {
  const styleCache = new Map();
  const cs = el => {
    let s = styleCache.get(el);
    if (!s) {
      s = getComputedStyle(el);
      styleCache.set(el, s);
    }
    return s;
  };
  const isBlock = d =>
    /^(block|list-item|table|table-row|table-cell|table-caption|flex|grid|table-row-group|table-header-group|table-footer-group|flow-root)$/.test(
      d,
    );
  const transparent = c => !c || c === 'transparent' || c === 'rgba(0, 0, 0, 0)';
  const kindOf = el => {
    const c = el.classList;
    const t = el.localName;
    if (t === 'blockquote') return 'quote';
    if (c.contains('blockcode')) return 'code';
    if (c.contains('spoiler') || c.contains('fold-body')) return 'spoiler';
    if (c.contains('locked')) return 'locked';
    if (c.contains('showhide')) return 'hide';
    if (c.contains('cm') && /^comment_/.test(el.id)) return 'comment';
    if (c.contains('pattl')) return 'attach';
    if (t === 'table') return 'table';
    if (t === 'ul' || t === 'ol') return 'list';
    if (c.contains('modact')) return 'modact';
    if (t === 'fieldset') return 'fieldset';
    if (t === 'center') return 'center';
    return null;
  };
  // The classes of the forum's own template: the color and size they give are not the author's.
  const structural =
    /^(quote|blockcode|spoiler|spoilerheader|spoilerbody|locked|showhide|pstatus|xg1|xg2|xi1|xi2|xw1|xs0|xs1|xs2|t_f|t_table|cm|psth|pstl|psta|psti|attach_nopermission|attach_tips|y|z|cl|mtn|mbn|ptn|pbn)$/;
  const authored = e =>
    !(e.localName === 'a' || e.localName === 'blockquote' || (e.localName === 'em' && e.closest('.blockcode'))) &&
    ([...e.classList].some(c => !structural.test(c)) || /^h[1-6]$/.test(e.localName));
  const floors = [];
  for (const post of document.querySelectorAll('div[id^="post_"]')) {
    const pid = post.id.replace('post_', '');
    if (!/^\d+$/.test(pid)) continue;
    const root = post.querySelector('td#postmessage_' + pid) || post.querySelector('td.t_f');
    if (!root) {
      floors.push({ pid, missing: true });
      continue;
    }
    const base = cs(root);
    const linkDefault = (() => {
      const a = root.querySelector('a[href]');
      return a ? cs(a).color : null;
    })();
    const tokens = [];
    const styleOf = (el, link) => {
      const s = cs(el);
      let u = 0;
      let st = 0;
      let bg = null;
      // A picture right behind the text (a `background` of the author, under no background color nearer the text):
      // what it is on is not a color.
      let pic = 0;
      let behind = false;
      for (let e = el; e; e = e.parentElement) {
        const c = cs(e);
        const d = c.textDecorationLine || '';
        if (d.includes('underline')) u = 1;
        if (d.includes('line-through')) st = 1;
        if (!bg && c.display.startsWith('inline') && !transparent(c.backgroundColor)) bg = c.backgroundColor;
        if (!behind && c.backgroundImage && c.backgroundImage !== 'none') {
          pic = 1;
          behind = true;
        } else if (!behind && !transparent(c.backgroundColor)) {
          behind = true;
        }
        if (e === root) break;
      }
      // What the author gave (the color, size and face of a <font>, a style), told from what the forum's css gives.
      let hasColor = false;
      let hasSize = false;
      let hasBg = false;
      let face = null;
      let ps = 0;
      let bbg = null;
      for (let e = el; e && e !== root; e = e.parentElement) {
        const inline = e.getAttribute('style') || '';
        const pe = e.parentElement;
        const ce = cs(e);
        const cp = pe ? cs(pe) : null;
        if ((e.localName === 'font' && e.hasAttribute('color')) || /(^|;)\s*color\s*:/i.test(inline)) hasColor = true;
        else if (cp && ce.color !== cp.color && authored(e)) hasColor = true;
        if ((e.localName === 'font' && e.hasAttribute('size')) || /font-size\s*:/i.test(inline)) hasSize = true;
        else if (cp && ce.fontSize !== cp.fontSize && authored(e)) hasSize = true;
        if (/background(-color)?\s*:/i.test(inline)) hasBg = true;
        // The background of the block the text is in: the nearest one the author gave (bgcolor, a style, a class).
        if (
          bbg === null &&
          !transparent(ce.backgroundColor) &&
          !ce.display.startsWith('inline') &&
          (e.hasAttribute('bgcolor') || /background/i.test(inline) || [...e.classList].some(c => !structural.test(c)))
        ) {
          bbg = ce.backgroundColor;
        }
        if (face === null && ((e.localName === 'font' && e.hasAttribute('face')) || /font-family\s*:/i.test(inline))) {
          face = e.getAttribute('face') || s.fontFamily;
        }
        if (e.localName === 'i' && e.classList.contains('pstatus')) ps = 1;
      }
      const al = s.textAlign;
      return {
        bbg,
        ec: hasColor ? s.color : null,
        efs: hasSize ? parseFloat(s.fontSize) : null,
        ebg: hasBg ? bg : null,
        face,
        ps,
        b: parseInt(s.fontWeight, 10) >= 600 ? 1 : 0,
        i: /italic|oblique/.test(s.fontStyle) ? 1 : 0,
        u,
        s: st,
        c: s.color,
        fs: parseFloat(s.fontSize),
        bg,
        al: /center/.test(al) ? 'c' : /right|end/.test(al) ? 'r' : 'l',
        ff: s.fontFamily,
        a: link ? 1 : 0,
        pic,
      };
    };
    const listIndex = new Map();
    const pathCache = new Map();
    const tagPath = el => {
      let p = pathCache.get(el);
      if (p !== undefined) return p;
      const parts = [];
      for (let e = el; e && e !== root; e = e.parentElement) {
        parts.unshift(e.localName + (e.classList.length ? '.' + e.classList[0] : ''));
        if (parts.length > 8) break;
      }
      p = parts.join('>');
      pathCache.set(el, p);
      return p;
    };
    const walk = (node, link, inCode) => {
      if (node.nodeType === 3) {
        const parent = node.parentElement;
        const ps = cs(parent);
        let t = node.data;
        const pre = /^pre/.test(ps.whiteSpace) || ps.whiteSpace === 'break-spaces';
        if (!pre) t = t.replace(/[ \t\n\r\f]+/g, ' ');
        if (!t) return;
        const st = styleOf(parent, link);
        const tp = tagPath(parent);
        if (pre && t.includes('\n')) {
          t.split('\n').forEach((p, i) => {
            if (i > 0) tokens.push({ k: 'br', tag: 'pre-nl' });
            if (p) tokens.push({ k: 't', s: p, st, tp });
          });
        } else {
          tokens.push({ k: 't', s: t, st, tp });
        }
        return;
      }
      if (node.nodeType !== 1) return;
      const el = node;
      const tag = el.localName;
      if (['script', 'style', 'noscript', 'template', 'link', 'meta'].includes(tag)) return;
      if (/^post_rate_div_/.test(el.id) || (tag === 'dl' && el.classList.contains('rate'))) return;
      const s = cs(el);
      if (s.display === 'none' || s.visibility === 'hidden') return;
      if (tag === 'br') {
        tokens.push({ k: 'br', tag: 'br' });
        return;
      }
      if (tag === 'img') {
        const r = el.getBoundingClientRect();
        tokens.push({
          k: 'img',
          tp: tagPath(el),
          src: el.getAttribute('src') || '',
          w: Math.round(r.width * 10) / 10,
          h: Math.round(r.height * 10) / 10,
          sm: el.hasAttribute('smilieid') ? 1 : 0,
          a: link ? 1 : 0,
          aw: el.getAttribute('width'),
        });
        return;
      }
      if (['iframe', 'embed', 'object', 'video', 'audio'].includes(tag)) {
        const r = el.getBoundingClientRect();
        tokens.push({ k: 'media', tag, w: r.width, h: r.height });
        return;
      }
      if (['input', 'button', 'textarea', 'select'].includes(tag)) {
        const v = tag === 'input' ? (/^(button|submit)$/.test(el.type) ? el.value : '') : el.innerText;
        if (v && v.trim()) tokens.push({ k: 'ctl', s: v.trim() });
        return;
      }
      if (tag === 'em' && /copycode|viewsource/.test((el.getAttribute('onclick') || '') + el.className)) {
        tokens.push({ k: 'ctl', s: el.innerText.trim() });
        return;
      }
      if (tag === 'hr') {
        tokens.push({ k: 'sb' }, { k: 'hr' }, { k: 'sb' });
        return;
      }
      const block = isBlock(s.display);
      const kind = kindOf(el);
      const btag = tag + (el.classList.length ? '.' + el.classList[0] : '');
      if (block) tokens.push({ k: 'sb', tag: btag });
      if (kind) {
        const open = { k: 'open', kind };
        if (kind === 'table') {
          const rows = [...el.rows].filter(r => r.closest('table') === el);
          const r = el.getBoundingClientRect();
          open.rows = rows.length;
          open.cols = Math.max(0, ...rows.map(r => [...r.cells].length));
          open.w = Math.round(r.width);
          const first = rows.length && rows[0].cells.length ? cs(rows[0].cells[0]) : null;
          open.border = first ? first.borderTopStyle !== 'none' && parseFloat(first.borderTopWidth) > 0 : false;
        }
        if (kind === 'spoiler') {
          const b = el.querySelector('input');
          open.title = b ? b.value : '';
        }
        tokens.push(open);
      }
      if (s.display === 'list-item' && !inCode) {
        const lst = s.listStyleType;
        if (lst && lst !== 'none') {
          const parent = el.parentElement;
          const n = (listIndex.get(parent) || 0) + 1;
          listIndex.set(parent, n);
          const mark = /decimal/.test(lst)
            ? `${n}.`
            : /alpha|latin/.test(lst)
              ? `${String.fromCharCode((/upper/.test(lst) ? 64 : 96) + n)}.`
              : '•';
          tokens.push({ k: 't', s: mark + ' ', st: styleOf(el, link), marker: 1, tp: tagPath(el) });
        }
      }
      const nlink = tag === 'a' && el.hasAttribute('href') ? el.getAttribute('href') : link;
      for (const ch of el.childNodes) walk(ch, nlink, inCode || kind === 'code');
      if (kind) tokens.push({ k: 'close', kind });
      if (block) tokens.push({ k: 'sb', tag: '/' + btag });
    };
    for (const ch of root.childNodes) walk(ch, null, false);
    floors.push({
      pid,
      base: {
        c: base.color,
        fs: parseFloat(base.fontSize),
        ff: base.fontFamily,
        link: linkDefault,
        w: Math.round(root.getBoundingClientRect().width),
        bg: base.backgroundColor,
      },
      tokens,
    });
  }
  return floors;
}

/** In the page: spoilers open, the folds a post makes itself open, lazy images loaded. */
function pageOpen() {
  for (const e of document.querySelectorAll('td.t_f .spoilerbody, td.t_f .spoiler_content, td.t_f .spoiler_body')) {
    e.style.display = 'block';
  }
  // A fold of the post's own: a hidden element (with an id, none of the forum's popups) another element shows by its
  // id when clicked (its onclick or its href: `getElementById('c1')`, `$('c1')`). The app shows it as a spoiler with
  // the text of that element as its title: the element is marked `fold-header` (its text is the title), the fold
  // `fold-body` (a spoiler), as the app's html muncher finds them.
  const foldRe = /(?:getElementById|\$)\(\s*['"]([^'"]+)['"]\s*\)/g;
  for (const tf of document.querySelectorAll('td.t_f')) {
    const titles = [...tf.querySelectorAll('[onclick], a[href]')];
    const folds = [];
    for (const title of titles) {
      const code = `${title.getAttribute('onclick') || ''} ${title.getAttribute('href') || ''}`;
      for (const m of code.matchAll(foldRe)) {
        const target = [...tf.querySelectorAll('[id]')].find(e => e.id === m[1]);
        if (
          target &&
          !target.id.endsWith('_menu') &&
          !target.classList.contains('tip') &&
          getComputedStyle(target).display === 'none' &&
          !title.contains(target) &&
          !folds.some(f => f.target === target)
        ) {
          folds.push({ title, target });
        }
      }
    }
    for (const { title, target } of folds) {
      title.className = ('fold-header ' + title.className).trim();
      target.className = ('fold-body ' + target.className).trim();
      target.style.display = 'block';
    }
  }
  // An address Cloudflare hides (`a.__cf_email__`): shown as Cloudflare's script shows it, as the app does.
  for (const e of document.querySelectorAll('td.t_f [data-cfemail]')) {
    const hex = e.getAttribute('data-cfemail');
    const key = parseInt(hex.slice(0, 2), 16);
    let text = '';
    for (let i = 2; i < hex.length; i += 2) text += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16) ^ key);
    e.textContent = text;
  }
  for (const img of document.querySelectorAll('td.t_f img[file]')) {
    if (!img.getAttribute('src')) img.setAttribute('src', img.getAttribute('file'));
  }
}

/** Styles and tag paths of [floors] in tables of their own (the snapshot is a tenth of the size). */
function compact(floors) {
  const styles = [];
  const styleIndex = new Map();
  const paths = [];
  const pathIndex = new Map();
  const intern = (list, index, v) => {
    const key = typeof v === 'string' ? v : JSON.stringify(v);
    let i = index.get(key);
    if (i === undefined) {
      i = list.length;
      list.push(v);
      index.set(key, i);
    }
    return i;
  };
  for (const f of floors) {
    for (const t of f.tokens || []) {
      if (t.st) t.st = intern(styles, styleIndex, t.st);
      if (t.tp !== undefined) t.tp = intern(paths, pathIndex, t.tp);
    }
  }
  return { styles, paths };
}

async function load(ctx, mainUrl, html) {
  const page = await ctx.newPage();
  await route(page, mainUrl, html);
  try {
    await page.goto(mainUrl, { waitUntil: 'load', timeout: 60000 });
  } catch (e) {
    console.log('load error', e.message.split('\n')[0]);
  }
  return page;
}

async function read(ctx, mainUrl, html) {
  const page = await load(ctx, mainUrl, html);
  await page.waitForTimeout(1000);
  await page.evaluate(pageOpen);
  await page.waitForTimeout(500);
  const floors = await page.evaluate(pageExtract);
  await page.close();
  return floors;
}

const threadUrl = tid => `${SITE}forum.php?mod=viewthread&tid=${tid}`;

if (full) {
  const tids = args.length
    ? args
    : fs
        .readdirSync(threadsDir)
        .filter(f => f.endsWith('.html'))
        .map(f => f.slice(0, -5))
        .sort();
  fs.mkdirSync(path.join(outDir, 'web'), { recursive: true });
  const ctx = await newContext(true);
  for (const tid of tids) {
    const html = fs.readFileSync(path.join(threadsDir, `${tid}.html`), 'utf8');
    const floors = await read(ctx, threadUrl(tid), html);
    const tables = compact(floors);
    fs.writeFileSync(path.join(outDir, 'web', `${tid}.json`), JSON.stringify({ width, dark, ...tables, floors }));
    console.log(tid, floors.length, 'floors');
  }
} else {
  // The page the synthetic floors are put in: a thread page of the corpus with its floors taken out but one, which
  // is emptied (its author, its signature…) and gets each synthetic floor in turn. Made with scripts off, so the page
  // is the server's; its scripts run when each floor's page is read.
  const tid =
    skeletonTid ||
    fs
      .readdirSync(threadsDir)
      .filter(f => f.endsWith('.html'))
      .sort()[0]
      .slice(0, -5);
  const mainUrl = threadUrl(tid);
  const build = await newContext(false);
  const sk = await load(build, mainUrl, fs.readFileSync(path.join(threadsDir, `${tid}.html`), 'utf8'));
  const template = await sk.evaluate(() => {
    const posts = [...document.querySelectorAll('#postlist > div[id^="post_"]')].filter(p =>
      /^post_\d+$/.test(p.id),
    );
    const keep = posts[1] || posts[0];
    const pid = keep.id.slice('post_'.length);
    for (const p of posts) if (p !== keep) p.remove();
    for (const e of keep.querySelectorAll('td.pls, div.pi, div.pob, div.sign, div.pstl, div.psth, .cm, dl.rate')) {
      e.innerHTML = '';
    }
    const pcb = keep.querySelector('div.pcb');
    pcb.innerHTML = '@@FLOOR@@';
    let html = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
    html = html.split(pid).join('@@PID@@');
    return html;
  });
  await build.close();
  const files = fs
    .readdirSync(path.join(DATA, 'floors'))
    .filter(f => f.endsWith('.html'))
    .sort();
  const ctx = await newContext(true);
  const floors = {};
  for (const file of files) {
    const id = file.replace(/\.html$/, '');
    const fragment = fs.readFileSync(path.join(DATA, 'floors', file), 'utf8');
    const pid = /id="postmessage_(\d+)"/.exec(fragment)[1];
    const html = template.split('@@PID@@').join(pid).replace('@@FLOOR@@', () => fragment);
    const read_ = await read(ctx, mainUrl, html);
    const floor = read_.find(f => f.pid === pid);
    if (!floor || floor.missing) throw new Error(`${id}: no floor`);
    delete floor.pid;
    floors[id] = floor;
    console.log(id, floor.tokens.length, 'tokens');
  }
  const list = Object.values(floors);
  const tables = compact(list);
  const out = path.join(DATA, dark ? 'web_dark.json' : 'web.json');
  // One style, one tag path, one floor a line: a change of the snapshot reads in a diff.
  const lines = [
    `{"width": ${width}, "dark": ${dark},`,
    ` "styles": [\n${tables.styles.map(x => '  ' + JSON.stringify(x)).join(',\n')}\n ],`,
    ` "paths": [\n${tables.paths.map(x => '  ' + JSON.stringify(x)).join(',\n')}\n ],`,
    ` "floors": {\n${Object.entries(floors)
      .map(([id, f]) => `  ${JSON.stringify(id)}: ${JSON.stringify(f)}`)
      .join(',\n')}\n }`,
    '}',
  ];
  fs.writeFileSync(out, lines.join('\n') + '\n');
  console.log('written', path.relative(REPO, out));
}
await browser.close();
