"""Pack murrtty.org (this folder's pages and stylesheet) into one Cloudflare
Worker module that serves them. The pictures (the icon and the README
picture in images/murrtty/) come from the public repository's raw files,
fetched by the Worker and cached at Cloudflare's edge, so the page still
loads everything from murrtty.org and the module stays a few kilobytes.
Their addresses name the last commit that changed images/murrtty, so a
new picture has a new address and no cache serves the old one: push that
commit to the public repository first, then build and deploy.

    python build_worker.py <out.js>

Routes: / and /code-signing (no .html), /style.css, /icon.png,
/screenshot.png; www.murrtty.org redirects to murrtty.org; anything else is
404. Every page carries a strict Content-Security-Policy.
"""
import json
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))

PAGES = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/code-signing': ('code-signing.html', 'text/html; charset=utf-8'),
    '/style.css': ('style.css', 'text/css; charset=utf-8'),
}


def pictures():
    images = os.path.join(here, '..', 'images', 'murrtty')
    ref = subprocess.run(
        ['git', '-C', here, 'log', '-1', '--format=%H', '--', images],
        capture_output=True, text=True, check=True).stdout.strip()
    if not ref:
        sys.exit('no commit found for images/murrtty')
    raw = f'https://raw.githubusercontent.com/murr2k/murrtty/{ref}/images/murrtty/'
    return {
        '/icon.png': raw + 'icon.png',
        '/screenshot.png': raw + 'screenshot.png',
    }

TEMPLATE = r"""// murrtty.org, built by site/build_worker.py; edit the site's files, not this.
const PAGES = __PAGES__;
const PICTURES = __PICTURES__;

const HEADERS = {
  'Content-Security-Policy': "default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Strict-Transport-Security': 'max-age=31536000',
};

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.hostname === 'www.murrtty.org') {
      url.hostname = 'murrtty.org';
      return Response.redirect(url.toString(), 301);
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: { ...HEADERS, Allow: 'GET, HEAD' } });
    }
    let path = url.pathname;
    if (path.endsWith('.html')) path = path.slice(0, -5);
    if (path === '/index') path = '/';
    const page = PAGES[path];
    if (page) {
      return new Response(request.method === 'HEAD' ? null : page.body, {
        headers: { ...HEADERS, 'Content-Type': page.type, 'Cache-Control': 'public, max-age=3600' },
      });
    }
    const raw = PICTURES[path];
    if (raw) {
      const upstream = await fetch(raw, { cf: { cacheTtl: 86400, cacheEverything: true } });
      if (!upstream.ok) {
        return new Response('Not available', { status: 502, headers: { ...HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });
      }
      return new Response(request.method === 'HEAD' ? null : upstream.body, {
        headers: { ...HEADERS, 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=86400' },
      });
    }
    return new Response('Not found', { status: 404, headers: { ...HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });
  },
};
"""


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    pages = {}
    for route, (name, kind) in PAGES.items():
        with open(os.path.join(here, name), encoding='utf-8') as f:
            pages[route] = {'type': kind, 'body': f.read()}
    module = TEMPLATE.replace('__PAGES__', json.dumps(pages, indent=1, ensure_ascii=True))
    pics = pictures()
    module = module.replace('__PICTURES__', json.dumps(pics, indent=1))
    with open(sys.argv[1], 'w', encoding='utf-8', newline='\n') as f:
        f.write(module)
    print(f'{sys.argv[1]}: {len(module)} bytes, {len(pages) + len(pics)} routes')


if __name__ == '__main__':
    main()
