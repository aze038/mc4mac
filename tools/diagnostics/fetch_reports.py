#!/usr/bin/env python3
"""Fetches new FalconMail diagnostics and prints them grouped by problem, newest first.

The read endpoint's address and key live in ~/.config/falconmail/diagnostics.json, which must be
readable by you alone:

    {"url": "https://script.google.com/macros/s/.../exec", "readKey": "..."}

Every row received since the last run is appended to ~/FalconMailReports/YYYY-MM-DD.jsonl (one JSON
object per line, as the service returns it), and where the run stopped is kept next to the config
in diagnostics.cursor. Run it through fetch-reports.sh.
"""

import argparse
import datetime
import glob
import json
import os
import re
import shutil
import stat
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request

PAGE_LIMIT = 1000
MAX_PAGES = 1000
TIMEOUT_SECONDS = 60
LOOPBACK_HOSTS = ('127.0.0.1', 'localhost', '::1')

KINDS = {
    'crash': ('Crash', 6),
    'hang': ('Hang', 5),
    'cpu': ('CPU', 4),
    'diskwrite': ('Disk writes', 4),
    'error': ('Error', 3),
    'warning': ('Warning', 2),
}
INFO_KINDS = ('launch', 'health')
STACK_KINDS = ('crash', 'hang', 'cpu', 'diskwrite')
# Report text comes from anyone holding the ingest key that ships in public releases. A terminal
# acts on control characters, so none reach the screen: an escape sequence could rename the
# window, hide a column or rewrite the lines above it.
CONTROL = re.compile('[\x00-\x1f\x7f-\x9f]')


class Problem(Exception):
    """Something the owner has to fix before the tool can run; exit_code says what kind."""

    def __init__(self, message, exit_code):
        super().__init__(message)
        self.exit_code = exit_code


# ------------------------------------------------------------------------------------------------
# Configuration and cursor
# ------------------------------------------------------------------------------------------------

def paths():
    home = os.path.expanduser('~')
    config_dir = os.path.join(home, '.config', 'falconmail')
    return {
        'home': home,
        'config': os.path.join(config_dir, 'diagnostics.json'),
        'cursor': os.path.join(config_dir, 'diagnostics.cursor'),
        'reports': os.path.join(home, 'FalconMailReports'),
    }


def tilde(path, home):
    return '~' + path[len(home):] if path.startswith(home + os.sep) else path


def load_config(path, home):
    shown = tilde(path, home)
    if not os.path.exists(path):
        raise Problem(shown + ' is missing. Create it as docs/DIAGNOSTICS_SETUP.md describes.', 2)
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        raise Problem(shown + ' can be read by other users of this Mac, and it holds the read key.\n'
                      'Make it yours alone, then run this again:  chmod 600 ' + shown, 2)
    try:
        with open(path, encoding='utf-8') as handle:
            config = json.load(handle)
    except (OSError, ValueError) as error:
        raise Problem(shown + ' is not valid JSON: ' + str(error), 2)
    url = config.get('url') if isinstance(config, dict) else None
    key = config.get('readKey') if isinstance(config, dict) else None
    if not isinstance(url, str) or not isinstance(key, str) or not url or not key:
        raise Problem(shown + ' needs both "url" and "readKey".', 2)
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in LOOPBACK_HOSTS):
        raise Problem('The url in ' + shown + ' must start with https://, so the read key is never sent in the clear.', 2)
    return url, key


def read_cursor(path):
    try:
        with open(path, encoding='utf-8') as handle:
            return handle.read().strip() or None
    except FileNotFoundError:
        return None


def write_cursor(path, value):
    temporary = path + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as handle:
        handle.write(value + '\n')
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


# ------------------------------------------------------------------------------------------------
# Fetching
# ------------------------------------------------------------------------------------------------

def ask(url, query):
    address = url + ('&' if '?' in url else '?') + urllib.parse.urlencode(query)
    # Apps Script answers with a 302 to script.googleusercontent.com; urllib follows it for GET.
    try:
        with urllib.request.urlopen(address, timeout=TIMEOUT_SECONDS) as response:
            answer = json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as error:
        raise Problem('The diagnostics service answered HTTP ' + str(error.code) + '. Try again later.', 1)
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, 'reason', error)
        raise Problem('Could not reach the diagnostics service: ' + str(reason), 1)
    except ValueError:
        raise Problem('The diagnostics service did not answer with JSON. Is the url the web app\'s /exec address?', 1)
    if not isinstance(answer, dict) or answer.get('ok') is not True:
        error = answer.get('error') if isinstance(answer, dict) else None
        hint = ' Check readKey in the config.' if error == 'Not accepted' else ''
        raise Problem('The diagnostics service said: ' + plain(error or 'no answer') + '.' + hint, 1)
    return answer


def request_page(url, key, since):
    query = {'op': 'read', 'key': key, 'limit': str(PAGE_LIMIT)}
    if since:
        query['since'] = since
    answer = ask(url, query)
    return answer.get('rows') or [], answer.get('next')


def later(value, than):
    """Whether one ISO time is after another; no time at all is before every other."""
    moment, before = parse_time(value), parse_time(than)
    return moment is not None and (before is None or moment > before)


def fetch_new_rows(url, key, cursor, keep, known):
    """Pages through everything after the cursor. Each page is kept, with the cursor moved to the
    newest row in it, before the next is asked for, so an interrupted run loses nothing. Rows whose
    event ID is already saved are left out, and a next page that does not move forward is refused
    rather than followed, so a service answering out of order can never loop or go backwards."""
    fetched = []
    since = cursor
    for _ in range(MAX_PAGES):
        rows, following = request_page(url, key, since)
        newest = since
        fresh = []
        for row in rows:
            if later(row.get('receivedAt'), newest):
                newest = row['receivedAt']
            event_id = row.get('eventId')
            if event_id and event_id in known:
                continue
            if event_id:
                known.add(event_id)
            fresh.append(row)
        if fresh or newest != since:
            keep(fresh, newest)
            fetched.extend(fresh)
        if not following:
            return fetched
        if not later(following, since):
            raise Problem('The diagnostics service offered a next page that is not after this one; stopping. '
                          'What was fetched is saved.', 1)
        since = following
    raise Problem('Stopped after ' + str(MAX_PAGES) + ' pages; run again to carry on.', 1)


def append_rows(directory, rows, today):
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, today + '.jsonl')
    with open(path, 'a', encoding='utf-8') as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n')
    return path


def saved_rows(directory):
    """Every saved row once, even if an earlier run saved one twice."""
    rows = []
    seen = set()
    for path in sorted(glob.glob(os.path.join(directory, '*.jsonl'))):
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                event_id = row.get('eventId') if isinstance(row, dict) else None
                if not isinstance(row, dict) or (event_id and event_id in seen):
                    continue
                seen.add(event_id)
                rows.append(row)
    return rows


# ------------------------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------------------------

def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None


def happened(row):
    """When the problem last happened, never later than when it arrived: device clocks can run ahead."""
    received = parse_time(row.get('receivedAt'))
    last = parse_time(row.get('lastAt')) or received
    if received and last:
        return min(last, received)
    return last or received


def version_key(version):
    return [int(part) for part in ''.join(c if c.isdigit() else ' ' for c in str(version)).split()]


def summarise(rows, history):
    """Groups problem rows by signature and marks each New, Back or Rising against earlier reports."""
    groups = {}
    info = {}
    installs = set()
    received = [parse_time(row.get('receivedAt')) for row in rows]
    received = [at for at in received if at]
    for row in rows:
        installs.add(row.get('install'))
        kind = row.get('kind')
        if kind in INFO_KINDS:
            info[kind] = info.get(kind, 0) + 1
            continue
        signature = row.get('signature') or '(no signature)'
        group = groups.setdefault(signature, {
            'signature': signature, 'kind': kind, 'times': 0, 'installs': set(), 'versions': set(),
            'firstSeen': None, 'lastSeen': None, 'latest': None,
        })
        group['times'] += int(row.get('count') or 1)
        group['installs'].add(row.get('install'))
        if row.get('version'):
            group['versions'].add(row['version'])
        when = happened(row)
        if when and (group['lastSeen'] is None or when >= group['lastSeen']):
            group['lastSeen'] = when
            group['latest'] = row
        first = parse_time(row.get('firstAt')) or when
        if first and when:
            first = min(first, when)
        if first and (group['firstSeen'] is None or first < group['firstSeen']):
            group['firstSeen'] = first
        if KINDS.get(kind, ('', 3))[1] > KINDS.get(group['kind'], ('', 3))[1]:
            group['kind'] = kind

    start = min(received) if received else None
    end = max(received) if received else None
    days = max(((end - start).total_seconds() / 86400) if start else 0, 1)
    current = {row.get('eventId') for row in rows}
    earlier = [row for row in history if row.get('eventId') not in current]
    for group in groups.values():
        group['trend'] = trend(group, earlier, start, days)

    problems = sorted(groups.values(), key=lambda g: (g['lastSeen'] is not None, g['lastSeen'] or 0), reverse=True)
    return {
        'reports': len(rows),
        'installs': len(installs),
        'from': start,
        'to': end,
        'problems': problems,
        'info': info,
    }


def trend(group, earlier, start, days):
    before = [row for row in earlier if row.get('signature') == group['signature']]
    if not before:
        return 'New'
    week_before = [row for row in before if start and parse_time(row.get('receivedAt'))
                   and start - datetime.timedelta(days=7) <= parse_time(row.get('receivedAt')) < start]
    if not week_before:
        return 'Back'
    expected = sum(int(row.get('count') or 1) for row in week_before) / 7 * days
    return 'Rising' if group['times'] >= 3 and group['times'] > 2 * expected else ''


# ------------------------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------------------------

def local(when, with_year=False):
    if not when:
        return ''
    moment = when.astimezone()
    text = str(moment.day) + moment.strftime(' %b')
    return text + (moment.strftime(' %Y') if with_year else '') + moment.strftime(' %H:%M')


def plain(text):
    return CONTROL.sub('', str(text))


def cut(text, width):
    text = plain(' '.join(str(text).split()))
    return text if len(text) <= width else text[:width - 1] + '…'


def screen(lines):
    """The lines as one text for the terminal, with nothing in them a terminal would act on."""
    return '\n'.join(plain(line) for line in lines) + '\n'


def dump_json(value):
    """JSON as the tools print it: readable text, with DEL and C1 control characters escaped
    (json escapes the others), so it is safe on a terminal and still the same data."""
    text = json.dumps(value, indent=2, ensure_ascii=False)
    return re.sub('[\x7f-\x9f]', lambda match: '\\u{:04x}'.format(ord(match.group())), text) + '\n'


def join_versions(versions, limit=3):
    ordered = sorted(versions, key=version_key, reverse=True)
    shown = ', '.join(ordered[:limit])
    return shown + (' +' + str(len(ordered) - limit) if len(ordered) > limit else '')


def kind_label(kind):
    return KINDS.get(kind, (cut(str(kind or '').capitalize(), 11), 0))[0]


def wrapped(text, width):
    """The text on lines of at most `width` characters, broken between words where it can be."""
    text = plain(' '.join(str(text).split()))
    return textwrap.wrap(text, width, break_on_hyphens=False) or ['']


def table(rows, columns, width):
    """A plain-language title first, then its figures, fitted to the terminal. `rows` are
    (title, figures, lines shown under it) and `columns` (heading, width, alignment) for the
    figures. One character is kept free, as some terminals wrap a line that fills them exactly.
    A title is always shown whole: one too long for its column goes on over the lines below it,
    in that column, and then a blank line keeps each row apart from the next. When a title would
    get fewer than 30 characters beside its figures, it goes on lines of its own above them."""
    figures = '  '.join('{:' + align + str(size) + '}' for _, size, align in columns)
    beside = width - 1 - 4 - len(figures.format(*[''] * len(columns)))
    headings = [heading for heading, _, _ in columns]
    rules = ['─' * size for _, size, _ in columns]
    lines = []
    if beside >= 30:
        title_width = min(beside, max([20] + [len(wrapped(title, 400)[0]) for title, _, _ in rows]))
        row = '  {:<' + str(title_width) + '}  ' + figures
        lines.append(row.format('Problem', *headings).rstrip())
        lines.append(row.format('─' * title_width, *rules))
        titles = [wrapped(title, title_width) for title, _, _ in rows]
        spaced = any(len(parts) > 1 for parts in titles)
        for index, ((_, values, below), parts) in enumerate(zip(rows, titles)):
            if index and spaced and lines[-1]:
                lines.append('')
            lines.append(row.format(parts[0], *values).rstrip())
            lines.extend('  ' + part for part in parts[1:])
            lines.extend(below)
        return lines
    row = '      ' + figures
    lines.extend(['  Problem', row.format(*headings).rstrip(), row.format(*rules)])
    titles = [wrapped(title, max(20, width - 3)) for title, _, _ in rows]
    spaced = any(len(parts) > 1 for parts in titles)
    for index, ((_, values, below), parts) in enumerate(zip(rows, titles)):
        if index and spaced and lines[-1]:
            lines.append('')
        lines.extend('  ' + part for part in parts)
        lines.append(row.format(*values).rstrip())
        lines.extend(below)
    return lines


def render(summary, verbose, width):
    lines = []
    reports, installs = summary['reports'], summary['installs']
    if not reports:
        return 'No new reports.\n'
    lines.append('FalconMail diagnostics: {} report{} from {} install{}'.format(
        reports, '' if reports == 1 else 's', installs, '' if installs == 1 else 's'))
    lines.append('Received {} to {}, local time'.format(local(summary['from'], True), local(summary['to'], True)))
    lines.append('')

    problems = summary['problems']
    if problems:
        version_width = min(18, max(len('Versions'), max(len(join_versions(p['versions'])) for p in problems)))
        rows = []
        for problem in problems:
            latest = problem['latest']
            below = []
            if verbose:
                indent = ' ' * 6
                below.append(indent + 'signature  ' + problem['signature'] + ('   (area ' + latest['area'] + ')' if latest.get('area') else ''))
                if latest.get('message'):
                    below.append(indent + 'example    ' + cut(latest['message'], max(40, width - 18)))
                below.append(indent + 'installs   ' + ', '.join(sorted(i for i in problem['installs'] if i)))
                below.append(indent + 'latest     event ' + str(latest.get('eventId')))
                below.append('')
            rows.append((latest.get('title') or problem['signature'], [
                kind_label(problem['kind']),
                '{:,}'.format(problem['times']),
                len(problem['installs']),
                cut(join_versions(problem['versions']), version_width),
                local(problem['lastSeen']),
                problem['trend'],
            ], below))
        lines.append('Problems, newest first')
        lines.extend(table(rows, [('Kind', 11, '<'), ('Times', 6, '>'), ('Installs', 8, '>'),
                                  ('Versions', version_width, '<'), ('Last seen', 12, '<'), ('Trend', 6, '<')], width))
        stacks = [p for p in problems if p['kind'] in STACK_KINDS]
        if stacks and not verbose:
            lines.append('')
            lines.append('Crashes and hangs carry stacks: add -v for event IDs, then run')
            lines.append('tools/diagnostics/symbolicate.py --event <event ID>')
    else:
        lines.append('No problems in these reports.')

    if summary['info']:
        parts = ['{} {}'.format(count, kind) for kind, count in sorted(summary['info'].items())]
        total = sum(summary['info'].values())
        if lines[-1]:
            lines.append('')
        lines.extend(textwrap.wrap('Also received {} report{}. Launch and health reports only show that FalconMail is running.'.format(
            ' and '.join(parts), '' if total == 1 else 's'), max(40, width - 1)))
    return screen(lines)


def render_issues(answer, verbose, width):
    """The Issues tab as the team keeps it: open problems first, with their Status."""
    issues = answer.get('issues') or []
    lines = ['Issues tab, updated ' + (local(parse_time(answer.get('updatedAt')), True) or 'never') + ', local time', '']
    if not issues:
        return screen(lines + ['No problems listed yet.'])
    status_width = min(20, max(len('Status'), max(len(cut(issue.get('status') or '', 200)) for issue in issues)))
    rows = []
    for issue in issues:
        below = []
        if verbose:
            if issue.get('notes'):
                below.append('      notes      ' + cut(issue['notes'], max(40, width - 18)))
            below.append('      signature  ' + str(issue.get('signature') or ''))
            below.append('')
        rows.append((issue.get('title') or issue.get('signature') or '', [
            kind_label(issue.get('kind')),
            '{:,}'.format(int(issue.get('times') or 0)),
            int(issue.get('installs') or 0),
            cut(issue.get('status') or '', status_width),
            local(parse_time(issue.get('lastSeen'))),
        ], below))
    lines.extend(table(rows, [('Kind', 11, '<'), ('Times', 6, '>'), ('Installs', 8, '>'),
                              ('Status', status_width, '<'), ('Last seen', 12, '<')], width))
    return screen(lines)


def as_json(summary):
    def iso(when):
        return when.isoformat().replace('+00:00', 'Z') if when else None
    return dump_json({
        'reports': summary['reports'],
        'installs': summary['installs'],
        'from': iso(summary['from']),
        'to': iso(summary['to']),
        'info': summary['info'],
        'problems': [{
            'signature': p['signature'],
            'title': p['latest'].get('title'),
            'kind': p['kind'],
            'times': p['times'],
            'installs': sorted(i for i in p['installs'] if i),
            'versions': sorted(p['versions'], key=version_key, reverse=True),
            'firstSeen': iso(p['firstSeen']),
            'lastSeen': iso(p['lastSeen']),
            'trend': p['trend'] or None,
            'area': p['latest'].get('area'),
            'example': p['latest'].get('message'),
            'latestEventId': p['latest'].get('eventId'),
        } for p in summary['problems']],
    })


# ------------------------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog='fetch-reports.sh',
        description='Fetch new FalconMail diagnostics and print them grouped by problem, newest first.')
    parser.add_argument('-v', '--verbose', action='store_true', help='also show signatures, examples, installs and event IDs')
    parser.add_argument('--days', type=int, metavar='N', help='summarise everything saved in the last N days, not just this run')
    parser.add_argument('--no-fetch', action='store_true', help='do not contact the service; summarise saved reports (implies --days 1)')
    parser.add_argument('--json', action='store_true', help='print the summary as JSON, for the daily triage')
    parser.add_argument('--issues', action='store_true', help='show the Issues tab with the team\'s Status instead; saves nothing')
    args = parser.parse_args(argv)

    where = paths()
    width = shutil.get_terminal_size((120, 24)).columns
    try:
        if args.issues:
            url, key = load_config(where['config'], where['home'])
            answer = ask(url, {'op': 'issues', 'key': key})
            sys.stdout.write(dump_json(answer) if args.json else render_issues(answer, args.verbose, width))
            return 0
        fetched = []
        saved_to = None
        history = saved_rows(where['reports'])
        if not args.no_fetch:
            url, key = load_config(where['config'], where['home'])
            today = datetime.date.today().isoformat()

            def keep(rows, cursor):
                nonlocal saved_to
                if rows:
                    saved_to = append_rows(where['reports'], rows, today)
                if cursor:
                    write_cursor(where['cursor'], cursor)

            known = {row.get('eventId') for row in history if row.get('eventId')}
            fetched = fetch_new_rows(url, key, read_cursor(where['cursor']), keep, known)
            history = history + fetched

        days = args.days or (1 if args.no_fetch else None)
        if days:
            since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
            chosen = [row for row in history if (parse_time(row.get('receivedAt')) or since) >= since]
        else:
            chosen = fetched
        summary = summarise(chosen, history)
    except Problem as problem:
        print(str(problem), file=sys.stderr)
        return problem.exit_code

    if args.json:
        sys.stdout.write(as_json(summary))
    else:
        sys.stdout.write(render(summary, args.verbose, width))
        if saved_to:
            sys.stdout.write('\nSaved to ' + tilde(saved_to, where['home']) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
