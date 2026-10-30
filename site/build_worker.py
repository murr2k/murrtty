"""Pack murrtty.org (this folder's pages and stylesheet) into one Cloudflare
Worker module that serves them. The pictures (the icon and the README
picture in images/murrtty/) come from the public repository's raw files,
fetched by the Worker and cached at Cloudflare's edge, so the page still
loads everything from murrtty.org and the module stays a few kilobytes.
Their addresses name the last commit that changed images/murrtty, so a
new picture has a new address and no cache serves the old one: push that
commit to the public repository first, then build and deploy.

The newest murrtty-vX.Y.Z tag is the release the site offers: @RELEASE@
and @RELEASE_URL@ in the pages become its version and its release page,
and /download redirects to its zip. Push the tag (and publish the
release) before building.

Usage statistics: each page view and download by a browser (bots left
out) is written to Workers Analytics Engine (binding VISITS, dataset
murrtty_site) with the page, the referring site's host name, the country
and a coarse browser type. No IP addresses, cookies or full URLs; the
pages' footers say so.

    python build_worker.py <out.js>

writes the module and <out.js>.meta.json, the upload's metadata (main
module, compatibility date, the Analytics Engine binding). Cloudflare's
Workers Builds run it from wrangler.jsonc's build command on each push to
main that touches site/ or images/murrtty/, then `wrangler deploy`; the
metadata file is for deploying by hand through the API.

Routes: / and /code-signing (no .html), /style.css, /icon.png,
/screenshot.png, /download; www.murrtty.org redirects to murrtty.org;
anything else is 404. Every page carries a strict Content-Security-Policy.
"""
import json
import os
import subprocess
import sys
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))

PAGES = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/code-signing': ('code-signing.html', 'text/html; charset=utf-8'),
    '/style.css': ('style.css', 'text/css; charset=utf-8'),
    # RFC 9116; renew its Expires line before it lapses (within a year).
    '/.well-known/security.txt': ('security.txt', 'text/plain; charset=utf-8'),
}

METADATA = {
    'main_module': 'worker.js',
    'compatibility_date': '2026-10-01',
    'bindings': [
        {'type': 'analytics_engine', 'name': 'VISITS', 'dataset': 'murrtty_site'},
    ],
}


def git(*args):
    """git's output, or '' when it fails (no git, no tags in a shallow
    clone)."""
    r = subprocess.run(['git', '-C', here, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ''


def github(path):
    req = urllib.request.Request(
        'https://api.github.com/repos/murr2k/murrtty' + path,
        headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'murrtty-site-build'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def pictures():
    # In a shallow clone (Cloudflare's builds) the oldest commit present
    # stands in for the history before it: it still holds the current
    # pictures, so an address pinned to it is right, only changed sooner.
    images = os.path.join(here, '..', 'images', 'murrtty')
    ref = git('log', '-1', '--format=%H', '--', images)
    if not ref:
        sys.exit('no commit found for images/murrtty')
    raw = f'https://raw.githubusercontent.com/murr2k/murrtty/{ref}/images/murrtty/'
    return {
        '/icon.png': raw + 'icon.png',
        '/screenshot.png': raw + 'screenshot.png',
    }


def release():
    tag = git('describe', '--tags', '--abbrev=0', '--match', 'murrtty-v*')
    if not tag:
        # No tags in the clone: the newest murrtty release on GitHub.
        tags = [r['tag_name'] for r in github('/releases?per_page=20')
                if not r.get('draft') and r['tag_name'].startswith('murrtty-v')]
        if not tags:
            sys.exit('no murrtty-v release found in git or on GitHub')
        tag = tags[0]
    version = tag[len('murrtty-v'):]
    base = 'https://github.com/murr2k/murrtty/releases'
    return {
        'version': version,
        'page': f'{base}/tag/{tag}',
        'zip': f'{base}/download/{tag}/murrtty-{version}-windows-x86_64.zip',
    }


TEMPLATE = r"""// murrtty.org, built by site/build_worker.py; edit the site's files, not this.
const PAGES = __PAGES__;
const PICTURES = __PICTURES__;
const DOWNLOAD = __DOWNLOAD__;

const HEADERS = {
  'Content-Security-Policy': "default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Strict-Transport-Security': 'max-age=31536000',
};

const BOT = /bot|crawl|spider|slurp|preview|scan|monitor|fetch|curl|wget|python|httpclient|okhttp|java\/|go-http|libwww|headless|powershell|facebookexternalhit|embedly|discord|telegram|whatsapp|slack/i;

function browser(ua) {
  if (ua.includes('murrtty-check')) return 'check';
  const name = /Edg\//.test(ua) ? 'Edge'
    : /Firefox\//.test(ua) ? 'Firefox'
    : /Chrome\//.test(ua) ? 'Chrome'
    : /Safari\//.test(ua) ? 'Safari'
    : 'Other';
  return name + (/Mobi|Android|iPhone|iPad/.test(ua) ? ' mobile' : ' desktop');
}

// A page view or download by a browser: the page, the referring site's
// host name, the country and a coarse browser type. No IP addresses,
// cookies or full URLs; bots are left out.
function count(env, request, kind, path) {
  const ua = request.headers.get('User-Agent') || '';
  if (!env || !env.VISITS || request.method !== 'GET' || !ua || BOT.test(ua)) return;
  let ref = '(direct)';
  try {
    const r = request.headers.get('Referer');
    if (r) ref = new URL(r).hostname;
  } catch {}
  env.VISITS.writeDataPoint({
    indexes: [kind],
    blobs: [kind, path, ref, (request.cf && request.cf.country) || '', browser(ua)],
    doubles: [1],
  });
}

export default {
  async fetch(request, env) {
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
    if (path === '/download') {
      count(env, request, 'download', path);
      return Response.redirect(DOWNLOAD, 302);
    }
    const page = PAGES[path];
    if (page) {
      if (page.type.startsWith('text/html')) count(env, request, 'page', path);
      // no-transform: Cloudflare then leaves the page as built (no injected
      // analytics script, which the CSP would block anyway).
      return new Response(request.method === 'HEAD' ? null : page.body, {
        headers: { ...HEADERS, 'Content-Type': page.type, 'Cache-Control': 'public, max-age=3600, no-transform' },
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
    rel = release()
    pages = {}
    for route, (name, kind) in PAGES.items():
        with open(os.path.join(here, name), encoding='utf-8') as f:
            body = f.read()
        body = body.replace('@RELEASE_URL@', rel['page']).replace('@RELEASE@', rel['version'])
        if '@' in body and ('@RELEASE' in body):
            sys.exit(f'{name}: an unknown @RELEASE placeholder is left')
        pages[route] = {'type': kind, 'body': body}
    pics = pictures()
    module = TEMPLATE.replace('__PAGES__', json.dumps(pages, indent=1, ensure_ascii=True))
    module = module.replace('__PICTURES__', json.dumps(pics, indent=1))
    module = module.replace('__DOWNLOAD__', json.dumps(rel['zip']))
    os.makedirs(os.path.dirname(os.path.abspath(sys.argv[1])), exist_ok=True)
    with open(sys.argv[1], 'w', encoding='utf-8', newline='\n') as f:
        f.write(module)
    with open(sys.argv[1] + '.meta.json', 'w', encoding='utf-8', newline='\n') as f:
        json.dump(METADATA, f, indent=1)
    print(f'{sys.argv[1]}: {len(module)} bytes, {len(pages) + len(pics) + 1} routes, '
          f'release {rel["version"]}')


if __name__ == '__main__':
    main()
