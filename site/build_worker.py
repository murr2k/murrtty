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
release) before building. Cloudflare's clone holds no tags, so there the
release comes from GitHub's API: one request a build, shared with the
release list below, with GITHUB_TOKEN when the build's environment has
one (see github()).

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

Routes: /, /code-signing and /compare (no .html), /style.css, /icon.png,
/screenshot.png, /download; www.murrtty.org redirects to murrtty.org;
anything else is 404. Every page carries a strict Content-Security-Policy.

The release list murrtty's update checks read (roadmap 7.6),
/updates/v1.json, is a static asset beside the module (<out dir>/assets,
wrangler.jsonc's assets directory) with its headers in assets/_headers:
Cloudflare serves it from its edge without running the Worker, so a check
is neither counted nor billed, and an unchanged list answers 304 to the
ETag murrtty sends back. It holds every murrtty-vX.Y.Z release (newest
first; the newest ones' notes in full), built from GitHub's releases, and
nothing that changes between builds of the same releases, so its ETag
only changes with them. Deploying by hand through the API (the metadata
file) leaves the assets out: deploy through Workers Builds.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))

# A release's tag: murrtty-vX.Y.Z, with a pre-release part for the tip
# channel.
RELEASE_TAG = re.compile(r'murrtty-v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?')

PAGES = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/code-signing': ('code-signing.html', 'text/html; charset=utf-8'),
    '/compare': ('compare.html', 'text/html; charset=utf-8'),
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


def rate_limit_wait(e):
    """Seconds until GitHub takes requests again, when `e` is its refusal
    for a rate limit; None for any other error."""
    if e.code not in (403, 429):
        return None
    retry = e.headers.get('Retry-After')
    if retry and retry.strip().isdigit():
        return int(retry.strip())
    if e.headers.get('X-RateLimit-Remaining') == '0':
        reset = e.headers.get('X-RateLimit-Reset', '')
        if reset.isdigit():
            return max(1, int(reset) - int(time.time()) + 1)
        return 3600
    return 60 if e.code == 429 else None


def github(path):
    """GitHub's API for the public repository. Without a token GitHub
    allows 60 requests an hour per address, and Cloudflare's build
    machines share theirs with other builds (a build failed on
    2026-11-03 for it), so a build asks once (`releases`) and sends
    GITHUB_TOKEN when its environment has one: a Workers Builds secret,
    a fine-grained token with no permissions, which reads public
    repositories at 5,000 requests an hour. A refusal for the limit is
    tried once more when the limit resets within five minutes. A token
    GitHub refuses (expired or revoked: 401) is dropped, with a warning,
    and the request made without it, so a lapsed token never stops a
    build that would succeed without one."""
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'murrtty-site-build',
               'X-GitHub-Api-Version': '2022-11-28'}
    token = os.environ.get('GITHUB_TOKEN', '').strip()
    if token:
        headers['Authorization'] = 'Bearer ' + token
    url = 'https://api.github.com/repos/murr2k/murrtty' + path
    waited = False
    while True:
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 401 and token:
                print('warning: GitHub refused GITHUB_TOKEN (expired or revoked?): '
                      'asking without it. Replace the build secret.', file=sys.stderr)
                token = ''
                del headers['Authorization']
                continue
            wait = rate_limit_wait(e)
            if wait is None:
                raise
            if not waited and wait <= 300:
                print(f'GitHub API rate limit ({e.code}): trying again in {wait} s', file=sys.stderr)
                time.sleep(wait)
                waited = True
                continue
            sys.exit(f'GitHub API rate limit ({e.code}, {"with" if token else "without"} a token): '
                     f'it resets in {wait} s. '
                     + ('' if token else 'A GITHUB_TOKEN build secret (a fine-grained token with no '
                        'permissions) raises the limit. ')
                     + 'Retry the build later.')


_releases = None


def releases():
    """GitHub's releases of the public repository, newest first: asked
    for once a build, for the site's release and the update list."""
    global _releases
    if _releases is None:
        _releases = github('/releases?per_page=100')
    return _releases


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
        tags = [r['tag_name'] for r in releases()
                if not r.get('draft') and RELEASE_TAG.fullmatch(r['tag_name'])]
        if not tags:
            sys.exit('no murrtty-v release found in git or on GitHub')
        tag = max(tags, key=lambda t: version_key(t[len('murrtty-v'):]))
    version = tag[len('murrtty-v'):]
    base = 'https://github.com/murr2k/murrtty/releases'
    return {
        'version': version,
        'page': f'{base}/tag/{tag}',
        'zip': f'{base}/download/{tag}/murrtty-{version}-windows-x86_64.zip',
    }


# How many of the newest releases carry their notes in the list (the rest
# link to their pages), and the list's headers.
LIST_NOTES = 10
LIST_HEADERS = """/updates/*
  Cache-Control: public, max-age=3600
  X-Content-Type-Options: nosniff
  Content-Security-Policy: default-src 'none'; frame-ancestors 'none'
  Referrer-Policy: no-referrer
"""


def version_key(version):
    """X.Y.Z[-pre] in release order: a pre-release before its release."""
    core, _, pre = version.partition('-')
    nums = tuple(int(n) for n in core.split('.'))
    return nums + ((1, '') if not pre else (0, pre))


def update_list():
    """The release list: every published murrtty-vX.Y.Z release, newest
    first, with its date, page and files (each architecture's zip and
    installer: address, size, SHA-256 from GitHub's digest)."""
    listed = []
    for r in releases():
        tag = r['tag_name']
        if r.get('draft') or not RELEASE_TAG.fullmatch(tag):
            continue
        version = tag[len('murrtty-v'):]
        files = {}
        for a in r.get('assets', []):
            m = re.fullmatch(r'murrtty-(.+)-windows-(x86_64|aarch64)(-setup\.exe|\.zip)', a['name'])
            if not m or m.group(1) != version:
                continue
            digest = a.get('digest') or ''
            files.setdefault(m.group(2), {})['setup' if m.group(3) == '-setup.exe' else 'zip'] = {
                'name': a['name'],
                'url': a['browser_download_url'],
                'size': a['size'],
                'sha256': digest[len('sha256:'):] if digest.startswith('sha256:') else None,
            }
        listed.append({
            'version': version,
            'tag': tag,
            # murrtty's channels go by the version: X.Y.Z is a release
            # (GitHub's "pre-release" flag marks murrtty's previews).
            'channel': 'tip' if '-' in version else 'stable',
            'preview': bool(r.get('prerelease')),
            'date': (r.get('published_at') or r.get('created_at') or '')[:10],
            'title': r.get('name') or f'murrtty {version}',
            'url': r['html_url'],
            'notes': r.get('body') or '',
            'files': files,
        })
    listed.sort(key=lambda e: version_key(e['version']), reverse=True)
    for e in listed[LIST_NOTES:]:
        del e['notes']
    if not listed:
        sys.exit('no murrtty-v release on GitHub for the update list')
    return {'schema': 1, 'releases': listed}


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
    assets = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'assets')
    os.makedirs(os.path.join(assets, 'updates'), exist_ok=True)
    listing = update_list()
    with open(os.path.join(assets, 'updates', 'v1.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(listing, f, ensure_ascii=True, sort_keys=True, separators=(',', ':'))
    with open(os.path.join(assets, '_headers'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(LIST_HEADERS)
    print(f'{sys.argv[1]}: {len(module)} bytes, {len(pages) + len(pics) + 1} routes, '
          f'release {rel["version"]}; updates/v1.json: {len(listing["releases"])} releases')


if __name__ == '__main__':
    main()
