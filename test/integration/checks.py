"""Shared assertion + reporting helpers for the integration suites."""
import re
import subprocess

# Asterisk colourises its console output, and the escapes make excerpts unreadable.
_ANSI = re.compile(r'\x1b\[[0-9;]*m')

_results = []


def _excerpt(got, needle, limit=140):
    """Multi-kilobyte container logs are routinely passed in as `got`. Report the
    line that actually matched rather than the whole haystack."""
    got = got.strip()
    if len(got) <= limit:
        return got
    if needle:
        for line in got.splitlines():
            if needle in line:
                line = line.strip()
                return line if len(line) <= limit else line[:limit] + '...'
    return got[:limit].replace('\n', ' ') + '...'


def check(name, got, want, detail=''):
    """`want` is a substring to find in `got`, or a predicate over it."""
    ok = want(got) if callable(want) else want in got
    shown = _excerpt(got, want if isinstance(want, str) else None)
    _results.append((ok, name, shown))
    print(f'  {"PASS" if ok else "FAIL"}  {name}\n        -> {shown}' + (f'  {detail}' if detail else ''))
    return ok


def absent(name, got, unwanted, detail=''):
    """Assert something did NOT happen. Kept distinct from check() so the
    reported value is the thing searched for, not an empty string."""
    ok = unwanted not in got
    _results.append((ok, name, 'not found' if ok else got.strip()[:120]))
    print(f'  {"PASS" if ok else "FAIL"}  {name}\n        -> '
          f'{"absent, as expected" if ok else got.strip()[:120]}' + (f'  {detail}' if detail else ''))
    return ok


def logs(container):
    p = subprocess.run(['docker', 'logs', container], capture_output=True, text=True)
    return _ANSI.sub('', p.stdout + p.stderr)


def summary(title):
    failed = [r for r in _results if not r[0]]
    print(f'\n{"=" * 62}\n{title}: {len(_results) - len(failed)}/{len(_results)} passed')
    if failed:
        print('FAILED:')
        for _, name, got in failed:
            print(f'  - {name}: {got}')
    return 1 if failed else 0
