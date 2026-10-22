#!/usr/bin/env python3
"""Make the synthetic corpus of the render regression test from floors of real posts.

Only run locally: the real posts (the full corpus) never go into the repository. What comes out keeps the structure
of a floor (its tags, the styles that are compared, tables, line breaks, the punctuation of its text) and nothing of
what was written in it, nor anything that tells which post or member it came from:

* every letter of the text (and of the `title`, `alt` and `value` of an element) is replaced by a random one of its
  kind (a Chinese character by another, a kana by a kana, a latin letter by one of the same case, a digit by a
  digit); punctuation, spaces and entities stay, so do the forum's own words in a post (the "click to expand" of a
  spoiler's header, the "copy code" of a code block); the notice of an edit and a member named in a link are made
  the same fixed name;
* attributes are a list of those the app or the web page draws with; any other is dropped;
* the names a post makes up (its ids, its classes, its css variables, the strings of its scripts, the fonts it
  names) are each replaced by a made up name, the same one everywhere in the floor (a class still matches its rule,
  a fold still shows its element); names the forum's pages use everywhere (`quote`, `spoiler`, `none`, `Arial`) stay;
* every number that can name something (an id in a link, `#pid…`, the digits after letters in a name, a number of
  five digits or more) is replaced by a made up one, the same one everywhere in the floor;
* a post's style sheet (`<style>`) keeps only the rules of the elements of the floor the app can read (no pseudo
  classes, attributes or combinators but the descendant one), and a style sheet and a `style` only the properties
  the comparison reads (colors, backgrounds, sizes, weight, slant, decoration, alignment, indent, display); `@`
  rules and comments go;
* links outside the forum go to example.com, links inside it keep their page and get made up ids;
* images become placeholders whose size is in their url (`https://example.com/render/img-<n>-<w>x<h>.png`), which the
  test and `web_snapshot.mjs` both draw; the players of video sites keep their host (the app picks a card by it) with
  a made up id;
* scripts and comments go, `url()` in styles points to example.com, an address hidden by Cloudflare is made a word.

Usage:
  python3 make_corpus.py --threads <dir of the full corpus' <tid>.json and <tid>.html> --select <selection.json> \
      [--images <images.json>] --out test/data/render_regression

`selection.json` (kept outside the repository with the full corpus: it names real floors) is a list of
`{"tid": ..., "pid": ..., "feats": [...]}`. Floors are written as `floors/c<NNN>.html` with the features they were
picked for in `manifest.json`; with `--hand tools/render_regression/hand`, the floors written by hand there (for what
the real ones did not have) are written as `floors/h*.html`, their text made up the same way (any Chinese text has
words of the corpus in it).

The result is checked, and a floor that fails is made again with another seed, then the run stops: no four Chinese
characters in a row of the text of any post of the corpus, no name of a member of the corpus, no number of five
digits or more of the floor, no ascii name of the floor that only one or two threads of the corpus use.
"""
import argparse
import collections
import glob
import html
import html.entities
import html.parser
import json
import os
import random
import re
import sys

# Common characters to make text of; the characters of words the repository must not hold are not in it.
_HAN = (
    '的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定'
    '行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其'
    '些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建'
    '月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接'
    '知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处府研队南给色光门即保治北造百规热领七海口东'
    '导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积'
    '示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书'
)
_KANA_H = 'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん'
_KANA_K = 'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン'

# The forum's own words in a post: kept as they are (they are the same in every post).
_FORUM_WORDS = {
    '（點擊展開 / 收起）', '（点击展开 / 收起）', '复制代码', '此帖仅作者可见', '本帖隐藏的内容需要回复才可以浏览',
}

# The notice of an edit (`i.pstatus`), and a member named in a link: the same made up member.
_EDIT_NOTICE = ' 本帖最后由 用户甲 于 2001-1-1 00:00 编辑 '
_MEMBER = 'member'

# Hosts of the forum (old and current): links to them keep their page.
_FORUM_HOSTS = re.compile(r'(^|\.)(tsdm39\.com|tsdm39\.net|tsdm\.me|tsdm\.net|tsdm\.love|tsdm\.live|tsdm\.tw|tsdm\.vip)$')
# Hosts of players the app shows as a card of their own.
_MEDIA_HOSTS = re.compile(r'(^|\.)(music\.163\.com|bilibili\.com|youtube\.com|youtu\.be|nicovideo\.jp|acfun\.cn|youku\.com|qq\.com)$')

_IMG_ATTRS = {'src', 'file', 'zoomfile', 'data-src', 'data-original'}
_MEDIA_TAGS = {'iframe', 'embed', 'object', 'video', 'audio', 'source', 'param'}
# Attributes whose value is text to read: scrambled.
_TEXT_ATTRS = {'title', 'alt', 'value', 'placeholder', 'label'}
# Attributes of layout the app or the web page draws with: kept when their value is a plain token (a number, a
# color, a keyword), dropped otherwise.
_LAYOUT_ATTRS = {
    'align', 'valign', 'color', 'size', 'width', 'height', 'colspan', 'rowspan', 'bgcolor', 'border', 'cellpadding',
    'cellspacing', 'type', 'target', 'frameborder', 'allowfullscreen', 'controls', 'wmode', 'quality', 'scrolling',
    'start', 'span', 'nowrap', 'smilieid', 'selected', 'hidden', 'marginwidth', 'marginheight',
    'autoplay', 'loop', 'name', 'dir',
}
_PARAMS = {'movie', 'src', 'flashvars', 'allowscriptaccess', 'allowfullscreen', 'wmode', 'quality', 'autostart',
           'autoplay', 'loop', 'play', 'menu', 'scale', 'salign', 'base', 'filename', 'url', 'bgcolor'}
_TOKEN = re.compile(r'^[\w#%.,/+ -]{0,40}$')
# Properties of a post's style sheet the comparison reads; the others (layout, spacing, borders, effects) go.
_CSS_PROPS = {
    'color', 'background', 'background-color', 'background-image', 'font', 'font-size', 'font-weight', 'font-style',
    'font-family', 'text-decoration', 'text-decoration-line', 'text-align', 'text-indent', 'text-shadow', 'display',
    'visibility', 'white-space', 'list-style', 'list-style-type', 'content', 'opacity',
}
# Functions and keywords of css a post's style sheet may use that the forum's do not.
_CSS_WORDS = {
    'clamp', 'calc', 'min', 'max', 'var', 'rgb', 'rgba', 'hsl', 'hsla', 'linear-gradient', 'radial-gradient',
    'repeating-linear-gradient', 'conic-gradient', 'important', 'inherit', 'initial', 'unset', 'transparent',
    'currentColor', 'flex', 'grid', 'inline-block', 'inline-flex', 'inline-grid', 'flow-root', 'contents',
}
# Classes and ids the app's html muncher reads by name.
_APP_NAMES = {
    'jammer', 'pstatus', 'media_container', 'cgtl', 'litype_1', 'litype_2', 'litype_3', 'psth', 'rcd-h', 'bd-h', 'tip',
    'spoiler', 'spoilerheader', 'spoilerbody', 'spoilerbutton', 'blockcode', 'quote', 'locked', 'showhide', 't_f',
    't_fsz', 't_table', 'zoom', 'cm', 'pattl', 'modact', 'hb_mask', '__cf_email__',
}
# Words this script writes itself.
_OWN_WORDS = {'example', 'render', 'smiley', 'media', 'link', 'member', 'https', 'hidden', 'address'}
_SIZES = [(1000, 700), (640, 360), (300, 200), (1800, 420), (120, 90), (480, 800)]
_WORD = re.compile(r'[A-Za-z_][A-Za-z0-9_-]*')


class Corpus:
    """What the full corpus tells of names: those used all over it are common, the others name a post."""

    def __init__(self, threads_dir):
        self.thread_df = collections.Counter()
        self.post_df = collections.Counter()
        self.numbers = set()
        self.ids = set()
        self.names = set()
        texts = []
        for f in glob.glob(os.path.join(threads_dir, '*.html')):
            t = open(f, encoding='utf-8', errors='replace').read()
            self.thread_df.update(set(_WORD.findall(t)))
            self.ids |= set(re.findall(r'(?:uid|tid|pid|aid|ptid|fromuid|authorid)[=-](\d{4,})', t))
            self.ids |= set(re.findall(r'(?:space-uid|thread)-(\d{4,})', t))
            self.ids.add(os.path.basename(f)[:-5])
        # The words of the forum's own style sheets and scripts (`float`, `getElementById`): not a post's.
        self.vocabulary = set()
        for f in glob.glob(os.path.join(threads_dir, '..', 'assets', '*.*')):
            if f.endswith(('.css', '.js')):
                self.vocabulary |= set(_WORD.findall(open(f, encoding='utf-8', errors='replace').read()))
        for f in glob.glob(os.path.join(threads_dir, '*.json')):
            d = json.load(open(f, encoding='utf-8'))
            self._ids_of(d)
            for p in d.get('posts') or []:
                body = (p.get('body_html') or '') + (p.get('signature_html') or '')
                self.post_df.update(set(_WORD.findall(body)))
                self.numbers |= set(re.findall(r'\d{5,}', body))
                texts.append(_text_of(body))
                for n in (p.get('author'), (p.get('lastedit') or {}).get('username')):
                    if n:
                        self.names.add(n)
        # A name of a letter or two is in any text by chance.
        self.names = {n for n in self.names if len(n) >= 3 or re.search(r'[^\x00-\x7f]', n) and len(n) >= 2}
        self.grams = set()
        for t in texts:
            for run in re.findall(r'[぀-ヿ一-鿿]{4,}', t):
                for i in range(len(run) - 3):
                    self.grams.add(run[i:i + 4])

    def _ids_of(self, o, key=None):
        if isinstance(o, dict):
            for k, v in o.items():
                self._ids_of(v, k)
        elif isinstance(o, list):
            for v in o:
                self._ids_of(v, key)
        elif key in ('uid', 'authorid', 'tid', 'pid', 'fid', 'aid', 'ptid') and str(o).isdigit() and len(str(o)) >= 4:
            self.ids.add(str(o))

    def common_name(self, word):
        """Whether the name [word] (a class, an id, a font) is used all over the corpus (three threads, two posts) or
        by the app, not a post's own."""
        return (word in _APP_NAMES or word.lower() in _OWN_WORDS or
                (self.thread_df[word] >= 3 and self.post_df[word] >= 2))

    def common(self, word):
        """Whether [word] is a common name or a word of css, html or scripts (the forum's own style sheets and
        scripts have it), not a post's own."""
        return (self.common_name(word) or word in self.vocabulary or word in _CSS_WORDS or
                word.lower() in _CSS_PROPS or word.lower() in _LAYOUT_ATTRS or word.lower() in _PARAMS)

    def rare(self, word):
        """Whether [word] names something of one or two threads (the check of what comes out)."""
        return len(word) >= 5 and not self.common(word) and (self.thread_df[word] <= 2 or self.post_df[word] <= 1) \
            and (self.thread_df[word] or self.post_df[word])


def _text_of(markup):
    """The text of [markup], without its styles and scripts."""

    class P(html.parser.HTMLParser):
        def __init__(self):
            super().__init__()
            self.out = []

        def handle_data(self, data):
            if self.cdata_elem is None:
                self.out.append(data)

    p = P()
    p.feed(markup)
    p.close()
    return '\n'.join(p.out)


class Scrambler:
    def __init__(self, seed, corpus):
        self.rng = random.Random(seed)
        self.corpus = corpus
        self.names = {}
        self.numbers = {}

    def char(self, c):
        o = ord(c)
        r = self.rng
        if 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xF900 <= o <= 0xFAFF:
            return r.choice(_HAN)
        if 0x3041 <= o <= 0x3096:
            return r.choice(_KANA_H)
        if 0x30A1 <= o <= 0x30FA:
            return r.choice(_KANA_K)
        if 0xAC00 <= o <= 0xD7A3:
            return chr(r.randint(0xAC00, 0xD7A3))
        if 'a' <= c <= 'z':
            return chr(r.randint(97, 122))
        if 'A' <= c <= 'Z':
            return chr(r.randint(65, 90))
        if '0' <= c <= '9':
            return str(r.randint(0, 9))
        return c

    def text(self, s):
        if s.strip() in _FORUM_WORDS:
            return s
        return ''.join(self.char(c) for c in s)

    def name(self, s):
        """A made up name for the name [s], the same one each time in a floor (letters, digits, other characters
        stay what they are)."""
        if s not in self.names:
            self.names[s] = ''.join(self.char(c) for c in s)
        return self.names[s]

    def class_name(self, w):
        """[w] when it is a common name, a made up name otherwise."""
        return w if self.corpus.common_name(w) else self.name(w)

    def word(self, w):
        """[w] when it is common, a made up name otherwise; its digits made up either way when it has letters."""
        if self.corpus.common(w):
            return w
        return self.name(w)

    def number(self, n):
        """A made up number of as many digits for [n], the same one each time in a floor."""
        if n not in self.numbers:
            lo = 10 ** (len(n) - 1) if len(n) > 1 else 0
            while True:
                fake = str(self.rng.randint(lo, 10 ** len(n) - 1))
                # Not a number of the corpus by chance.
                if fake not in self.corpus.ids and fake not in self.corpus.numbers:
                    break
            self.numbers[n] = fake
        return self.numbers[n]

    def numbers_in(self, s, min_len=5):
        return re.sub(r'(?<![#\w])\d{%d,}(?!\w)' % min_len, lambda m: self.number(m.group(0)), s)


class Names(html.parser.HTMLParser):
    """The classes and ids of a floor's elements: the rules of its style sheet that apply to them are kept."""

    def __init__(self):
        super().__init__()
        self.classes = set()
        self.ids = set()
        self.tags = set()
        self.variables = set()

    def feed(self, data):
        self.variables |= set(re.findall(r'var\(\s*--([\w-]+)', data))
        super().feed(data)

    def handle_starttag(self, tag, attrs):
        self.tags.add(tag)
        for k, v in attrs:
            if k == 'class' and v:
                self.classes |= set(v.split())
            if k == 'id' and v:
                self.ids.add(v)

    handle_startendtag = handle_starttag


_ID_PARTS = re.compile(r'^(postmessage_|aimg_|code_|ratelog_|comment_)?(.*?)(_menu)?$', re.S)


class Floor(html.parser.HTMLParser):
    def __init__(self, scrambler, pid, images, counters, names):
        super().__init__(convert_charrefs=False)
        self.s = scrambler
        self.pid = pid
        self.images = images
        self.counters = counters
        self.names = names
        self.out = []
        self.in_pstatus = 0
        self.pstatus_written = False
        self.stack = []

    # -- names

    def id(self, v):
        """A made up id for the id [v] (the forum's prefixes and suffix kept: the app reads them)."""
        m = _ID_PARTS.match(v)
        prefix, core, suffix = m.group(1) or '', m.group(2), m.group(3) or ''
        if prefix == 'postmessage_':
            return prefix + self.pid
        return prefix + (core if core in _APP_NAMES else self.s.name(core)) + suffix

    def cls(self, v):
        return ' '.join(self.s.class_name(c) for c in v.split())

    def literal(self, v):
        """A string of a script: an id or class of the floor by its made up name, a common word as it is."""
        if v in self.names.ids:
            return self.id(v)
        if v in self.names.classes:
            return self.s.class_name(v)
        v = re.sub(r'[^\x00-\x7f]+', lambda m: self.s.name(m.group(0)), v)
        return _WORD.sub(lambda m: self.s.word(m.group(0)), self.s.numbers_in(v, 2))

    def fonts(self, value):
        """A list of fonts: common ones kept, the others made up."""
        out = []
        for f in value.split(','):
            name = f.strip().strip('\'"')
            if not name:
                continue
            words = _WORD.findall(name)
            if re.search(r'[^\x00-\x7f]', name) or all(self.s.corpus.common_name(w) for w in words):
                out.append(f.strip())
            else:
                q = '\'' if '\'' in f or '"' in f else ''
                out.append(q + _WORD.sub(lambda m: self.s.name(m.group(0)), name) + q)
        return ', '.join(out)

    # -- urls

    def link(self, url):
        u = url.strip()
        if not u or u.startswith('#'):
            return '#' + self.id(u[1:]) if len(u) > 1 else u
        if u.lower().startswith('javascript:'):
            return self.script(u)
        if u.lower().startswith('mailto:'):
            return 'https://example.com/mail'
        m = re.match(r'^(https?:)?//([^/?#]+)(.*)$', u, re.I)
        if m and not _FORUM_HOSTS.search(m.group(2).lower().split(':')[0]):
            self.counters['link'] += 1
            return f'https://example.com/link/{self.counters["link"]}'
        # A page of the forum: its ids, numbers and names made up, its page kept.
        u = re.sub(r'(username=)([^&#]*)', lambda x: x.group(1) + _MEMBER, u, flags=re.I)
        u = re.sub(r'[^\x00-\x7f]+', lambda x: self.s.text(x.group(0)), u)
        u = re.sub(r'\d{2,}', lambda x: self.s.number(x.group(0)), u)
        return _WORD.sub(lambda x: self.s.word(x.group(0)), u)

    def media(self, url):
        u = url.strip()
        m = re.match(r'^(https?:)?//([^/?#]+)(.*)$', u, re.I)
        if m and _MEDIA_HOSTS.search(m.group(2).lower().split(':')[0]):
            rest = re.sub(r'\d{4,}', lambda x: self.s.number(x.group(0)), m.group(3))
            rest = _WORD.sub(lambda x: self.s.word(x.group(0)), rest)
            return f'{m.group(1) or ""}//{m.group(2)}{rest}'
        self.counters['media'] += 1
        return f'https://example.com/media/{self.counters["media"]}'

    def image(self, url, attrs):
        u = url.strip()
        if re.match(r'^(https?://[^/]+/)?static/image/(common|filetype|stamp)/[\w.-]+$', u):
            # The forum's own icons (the quote's "go to the post" arrow, which the app shows as a button): kept.
            return u
        info = self.images.get(u) or self.images.get(re.sub(r'^https?://[^/]+/', '', u)) or {}
        smiley = 'smilieid' in attrs or info.get('kind') == 'smiley' or 'static/image/smiley' in u
        self.counters['img'] += 1
        n = self.counters['img']
        w, h = info.get('w'), info.get('h')
        if smiley:
            w, h = w or 48, h or 48
            return f'https://example.com/render/smiley-{n}-{w}x{h}.gif'
        if not w or (w, h) == (1000, 700):
            # Unknown size: one of a few, some wide, some small, some tall.
            w, h = _SIZES[self.s.rng.randrange(len(_SIZES))]
        return f'https://example.com/render/img-{n}-{w}x{h}.png'

    # -- styles

    def css_value(self, prop, value):
        def url(_):
            self.counters['bg'] += 1
            return f'url(https://example.com/render/bg-{self.counters["bg"]}.png)'

        v = re.sub(r'url\(\s*([\'"]?)[^)]*\1\s*\)', url, value, flags=re.I)
        v = re.sub(r'--[\w-]+', lambda m: '--' + self.s.name(m.group(0)[2:]), v)
        v = re.sub(r'(["\'])(.*?)\1', lambda m: m.group(1) + self.s.text(m.group(2)) + m.group(1), v) \
            if prop == 'content' else v
        if prop in ('font-family', 'font'):
            v = self.fonts(v) if prop == 'font-family' else re.sub(
                r'([\'"][^\'"]+[\'"]|[A-Za-z][\w -]*)$', lambda m: self.fonts(m.group(0)), v)
        # Words of only a thread or two (a name of an animation, a misspelt keyword): made up. Colors stay.
        v = re.sub(r'(?<![#\w-])[A-Za-z_][\w-]*',
                   lambda m: self.s.name(m.group(0)) if self.s.corpus.rare(m.group(0)) else m.group(0), v)
        return self.s.numbers_in(v)

    def declarations(self, decls):
        out = []
        for d in decls.split(';'):
            if ':' not in d:
                continue
            prop, value = d.split(':', 1)
            prop = prop.strip().lower()
            if not prop:
                continue
            if prop == 'text-decoration-line':
                # The same as `text-decoration` for its lines.
                prop = 'text-decoration'
            if prop == 'background-image':
                # The same as `background` with a picture.
                prop = 'background'
            if prop.startswith('--'):
                # A variable: only one the floor reads.
                if prop[2:] not in self.names.variables:
                    continue
                name = '--' + self.s.name(prop[2:])
            elif prop in _CSS_PROPS:
                name = prop
            else:
                continue
            out.append(f'{name}: {self.css_value(prop, value.strip())}')
        return '; '.join(out)

    def selector(self, sel):
        """[sel] with its names made up; None when it names a class or id no element of the floor has, or is more than
        the app reads (a pseudo class, an attribute, a child or sibling combinator, `*`): the app would not apply it."""
        if re.search(r'[:\[>+~*]', sel):
            return None
        classes = re.findall(r'\.([\w-]+)', sel)
        ids = re.findall(r'#([\w-]+)', sel)
        if any(c not in self.names.classes for c in classes) or any(i not in self.names.ids for i in ids):
            return None
        sel = re.sub(r'\.([\w-]+)', lambda m: '.' + self.s.class_name(m.group(1)), sel)
        sel = re.sub(r'#([\w-]+)', lambda m: '#' + self.id(m.group(1)), sel)
        return ' '.join(sel.split())

    def sheet(self, css):
        """A post's style sheet: the rules of the floor's elements, the properties compared; `@` rules go."""
        css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
        css = re.sub(r'<!--|-->', '', css)
        rules = []
        i = 0
        while i < len(css):
            while i < len(css) and css[i].isspace():
                i += 1
            if i >= len(css):
                break
            if css[i] == '@':
                semi = css.find(';', i)
                brace = css.find('{', i)
                if brace < 0 or 0 <= semi < brace:
                    i = len(css) if semi < 0 else semi + 1
                    continue
                depth = 0
                j = brace
                while j < len(css):
                    depth += {'{': 1, '}': -1}.get(css[j], 0)
                    j += 1
                    if depth == 0:
                        break
                i = j
                continue
            brace = css.find('{', i)
            if brace < 0:
                break
            end = css.find('}', brace)
            end = len(css) if end < 0 else end
            sels = [x for x in (self.selector(s) for s in css[i:brace].split(',')) if x]
            decls = self.declarations(css[brace + 1:end])
            if sels and decls:
                rules.append(f'{", ".join(sels)} {{ {decls} }}')
            i = end + 1
        return '\n' + '\n'.join(rules) + '\n' if rules else ''

    def script(self, js):
        out = []
        for part in re.split(r'(\'[^\']*\'|"[^"]*")', js):
            if part[:1] in ('\'', '"') and len(part) >= 2:
                # A string: an id or class of the floor by its made up name, other words made up unless common.
                inner = part[1:-1]
                if re.match(r'^(https?:)?//', inner):
                    inner = self.link(inner)
                else:
                    inner = self.literal(inner)
                out.append(part[0] + inner + part[0])
            else:
                # Code: names of the post's own (a function) made up unless common.
                part = re.sub(r'[^\x00-\x7f]+', lambda m: self.s.name(m.group(0)), part)
                out.append(_WORD.sub(lambda m: self.s.word(m.group(0)), self.s.numbers_in(part)))
        return ''.join(out)

    # -- tags

    def attrs(self, tag, attrs):
        names = {k for k, _ in attrs}
        out = []
        for k, v in attrs:
            if v is None:
                if k in _LAYOUT_ATTRS:
                    out.append(k)
                continue
            if k in _IMG_ATTRS and tag == 'img':
                v = self.image(v, names)
            elif k in ('src', 'data') and tag in _MEDIA_TAGS:
                v = self.media(v)
            elif k in ('value', 'flashvars') and tag in _MEDIA_TAGS:
                v = self.media(v) if re.match(r'^(https?:)?//', v.strip(), re.I) else self.s.text(v)
            elif k == 'href':
                v = self.link(v)
            elif k == 'background':
                v = self.media(v)
            elif k == 'id':
                v = self.id(v)
            elif k == 'class':
                v = self.cls(v)
            elif k == 'style':
                v = self.declarations(v)
                if not v:
                    continue
            elif k == 'onclick':
                v = self.script(v)
            elif k in _TEXT_ATTRS:
                v = self.s.text(v)
            elif k == 'face':
                v = self.fonts(v)
            elif k == 'data-cfemail':
                v = cf_encode('hidden-address', self.s.rng.randint(1, 255))
            elif k == 'name':
                # The name of a player's parameter (the app reads `flashvars`, `movie`…); any other name goes.
                if tag != 'param' or v.lower() not in _PARAMS:
                    continue
            elif k == 'type' and tag == 'button' and v.lower() == 'submit':
                # What a button is without it.
                continue
            elif k in _LAYOUT_ATTRS and _TOKEN.match(v):
                v = self.s.numbers_in(re.sub(r'(?<![#\w-])[A-Za-z_][\w-]*', lambda m: self.s.name(m.group(0))
                                             if self.s.corpus.rare(m.group(0)) else m.group(0), v))
            else:
                # Not drawn with (a misspelt attribute, `onmouseover`, `name`…): dropped.
                continue
            out.append(f'{k}="{_attr(v)}"')
        return ''.join(' ' + a for a in out)

    def handle_starttag(self, tag, attrs):
        if tag == 'i' and 'pstatus' in (dict(attrs).get('class') or '').split():
            self.in_pstatus += 1
            self.pstatus_written = False
            self.stack.append('pstatus')
        elif tag not in _VOID:
            self.stack.append(tag)
        self.out.append(f'<{tag}{self.attrs(tag, attrs)}>')

    def handle_startendtag(self, tag, attrs):
        self.out.append(f'<{tag}{self.attrs(tag, attrs)} />')

    def handle_endtag(self, tag):
        if tag == 'i' and self.stack and self.stack[-1] == 'pstatus':
            self.in_pstatus -= 1
        if self.stack and self.stack[-1] in (tag, 'pstatus'):
            self.stack.pop()
        self.out.append(f'</{tag}>')

    def handle_data(self, data):
        if self.cdata_elem == 'script':
            return
        if self.cdata_elem == 'style':
            self.out.append(self.sheet(data))
            return
        if self.in_pstatus:
            # The notice of an edit names the member who edited: a fixed one.
            if not self.pstatus_written:
                self.out.append(_EDIT_NOTICE)
                self.pstatus_written = True
            return
        self.out.append(html.escape(self.s.text(data), quote=False))

    def handle_entityref(self, name):
        if self.in_pstatus:
            return
        if name in html.entities.name2codepoint:
            self.out.append(f'&{name};')
        else:
            # Not an entity (`&authorid=` in the text of a link): text.
            self.out.append('&amp;' + html.escape(self.s.text(name), quote=False))

    def handle_charref(self, name):
        if self.in_pstatus:
            return
        try:
            c = chr(int(name[1:], 16) if name[:1] in 'xX' else int(name))
        except ValueError:
            self.out.append(f'&#{name};')
            return
        s = self.s.char(c)
        self.out.append(f'&#{name};' if s == c else s)

    def handle_comment(self, data):
        pass

    def handle_decl(self, decl):
        pass

    def unknown_decl(self, data):
        pass


_VOID = {'br', 'img', 'hr', 'input', 'meta', 'link', 'param', 'source', 'embed', 'col', 'area', 'wbr'}


def _attr(v):
    return v.replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;').replace('>', '&gt;')


def cf_encode(text, key):
    return '%02x' % key + ''.join('%02x' % (ord(c) ^ key) for c in text)


def holder_table(body):
    """The table holding the floor's `td.t_f`, as the post has it (what the test and the web snapshot read)."""

    class P(html.parser.HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=False)
            self.offs = [0] + [m.end() for m in re.finditer('\n', body)]
            self.stack = []
            self.holder = None
            self.end = None

        def pos(self):
            line, col = self.getpos()
            return self.offs[line - 1] + col

        def handle_starttag(self, tag, attrs):
            if tag == 'table':
                self.stack.append(self.pos())
            a = dict(attrs)
            if tag == 'td' and self.holder is None and self.stack and (
                    't_f' in (a.get('class') or '').split() or (a.get('id') or '').startswith('postmessage_')):
                self.holder = (self.stack[-1], len(self.stack))

        def handle_endtag(self, tag):
            if tag == 'table' and self.stack:
                if self.holder and len(self.stack) == self.holder[1] and self.end is None:
                    self.end = body.index('>', self.pos()) + 1
                self.stack.pop()

    p = P()
    p.feed(body)
    p.close()
    if not p.holder or p.end is None:
        return None
    return body[p.holder[0]:p.end]


def problems(out, corpus, floor_numbers):
    """What [out] still holds of the corpus: four Chinese characters in a row of a post, a member's name, a number of
    five digits or more of the floor, an ascii name of only one or two threads."""
    found = []
    text = _text_of(out)
    for run in re.findall(r'[぀-ヿ一-鿿]{4,}', text):
        for i in range(len(run) - 3):
            g = run[i:i + 4]
            if g in corpus.grams and not any(g in w for w in _FORUM_WORDS) and g not in _EDIT_NOTICE:
                found.append(('text', g))
    found += [('name', n) for n in corpus.names if n in out]
    colorless = re.sub(r'#[0-9a-fA-F]{3,8}\b', '#', out)
    found += [('number', n) for n in set(re.findall(r'(?<!\d)\d{5,}(?!\d)', colorless)) if n in floor_numbers]
    # Digits of the text that make an id of the corpus by chance.
    found += [('text', n) for n in set(re.findall(r'(?<!\d)\d{4,}(?!\d)', colorless)) if n in corpus.ids]
    found += [('word', w) for w in set(re.findall(r'(?<![#\w-])[A-Za-z_][\w-]*', out)) if corpus.rare(w)]
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--threads', required=True)
    ap.add_argument('--select', required=True)
    ap.add_argument('--images')
    ap.add_argument('--out', required=True)
    ap.add_argument('--hand', help='the hand written floors (h*.html), their text made up the same way')
    a = ap.parse_args()
    images = json.load(open(a.images, encoding='utf-8')) if a.images else {}
    selection = json.load(open(a.select, encoding='utf-8'))
    corpus = Corpus(a.threads)
    posts = {}
    for f in glob.glob(os.path.join(a.threads, '*.json')):
        for p in json.load(open(f, encoding='utf-8')).get('posts') or []:
            posts[str(p['pid'])] = p
    floors_dir = os.path.join(a.out, 'floors')
    os.makedirs(floors_dir, exist_ok=True)
    for old in glob.glob(os.path.join(floors_dir, 'c*.html')) + (
            glob.glob(os.path.join(floors_dir, 'h*.html')) if a.hand else []):
        os.remove(old)
    manifest = []
    jobs = [(f'c{i:03d}', i, str(900000 + i), posts[str(sel['pid'])].get('body_html') or '', sel.get('feats', []))
            for i, sel in enumerate(selection, 1)]
    if a.hand:
        for i, f in enumerate(sorted(glob.glob(os.path.join(a.hand, 'h*.html'))), 1):
            markup = open(f, encoding='utf-8').read()
            jobs.append((os.path.basename(f)[:-5], 500 + i, re.search(r'postmessage_(\d+)', markup).group(1), markup,
                         None))
    for fid, i, pid, body, feats in jobs:
        tf = holder_table(body)
        if tf is None:
            sys.exit(f'no td.t_f in floor {fid}')
        names = Names()
        names.feed(tf)
        names.close()
        floor_numbers = set(re.findall(r'\d{5,}', tf)) - {pid}
        for attempt in range(30):
            fl = Floor(Scrambler(i * 1000 + attempt, corpus), pid, images,
                       {'link': 0, 'media': 0, 'img': 0, 'bg': 0}, names)
            fl.feed(tf)
            fl.close()
            out = ('<div class="t_fsz">' + ''.join(fl.out) + '</div>\n').replace('\r\n', '\n').replace('\r', '\n')
            # A name of signs only is not made by the scrambler but kept from the floor: other signs.
            for n in corpus.names:
                if n in out and not re.search(r'\w', n):
                    out = out.replace(n, '◇' * len(n))
            found = problems(out, corpus, floor_numbers)
            # Only text made by chance is made again; anything else is a gap of this script.
            if not found or any(kind != 'text' for kind, _ in found):
                break
        if found:
            # Print the kind and where, not what: it may name a member.
            kinds = collections.Counter(kind for kind, _ in found)
            sys.exit(f'floor {fid}: not clean: {dict(kinds)}')
        with open(os.path.join(floors_dir, fid + '.html'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(out)
        if feats is not None:
            manifest.append({'id': fid, 'features': feats})
    with open(os.path.join(a.out, 'manifest.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write('\n')
    print(len(manifest), 'floors written')


if __name__ == '__main__':
    main()
