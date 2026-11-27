"""Check the Web page using the temporary container's own login credential."""
import http.cookiejar
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def authenticate(engine, container, origin, output_directory):
    target = urllib.parse.urlsplit(origin)
    if target.scheme != 'http' or target.hostname not in {'127.0.0.1', 'localhost', '::1'}:
        raise ValueError('The smoke test only authenticates its local test server.')
    logs = subprocess.check_output([engine, 'logs', container], text=True, stderr=subprocess.STDOUT)
    logs = re.sub(r'\x1b\[[0-9;]*m', '', logs)
    links = re.findall(r'dsh web:\s+(https?://\S+)', logs)
    queries = [urllib.parse.urlsplit(link).query for link in links]
    queries = [query for query in queries if 'token' in urllib.parse.parse_qs(query)]
    if not queries:
        raise RuntimeError('The test server did not publish its login URL.')
    login_url = urllib.parse.urlunsplit((target.scheme, target.netloc, '/', queries[-1], ''))
    directory = Path(output_directory)
    directory.mkdir(parents=True, exist_ok=True)
    cookies_file = directory / 'cookies.txt'
    cookies = http.cookiejar.MozillaCookieJar(str(cookies_file))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(cookies))
    try:
        with opener.open(login_url, timeout=15) as response:
            if response.status != 200:
                raise RuntimeError(f'Authenticated Web returned HTTP {response.status}.')
            body = response.read()
    except urllib.error.HTTPError as error:
        # Do not include the login URL or cookie values in failure output.
        raise RuntimeError(f'Authenticated Web returned HTTP {error.code}.') from None
    if not body:
        raise RuntimeError('Authenticated Web returned an empty page.')
    (directory / 'index.html').write_bytes(body)
    cookies.save(ignore_discard=True, ignore_expires=True)
    cookies_file.chmod(0o600)
    if not cookies:
        raise RuntimeError('The test server did not issue a browser session cookie.')
    print(f'Authenticated Web returned HTTP 200; saved {len(cookies)} temporary cookie(s).')


if __name__ == '__main__':
    authenticate(*sys.argv[1:])
