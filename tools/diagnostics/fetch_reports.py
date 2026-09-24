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
import shutil
import stat
import sys
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
        raise Problem('The diagnostics service said: ' + str(error or 'no answer') + '.' + hint, 1)
    return answer


def request_page(url, key, since):
    query = {'op': 'read', 'key': key, 'limit': str(PAGE_LIMIT)}
    if since:
        query['since'] = since
    answer = ask(url, query)
    return answer.get('rows') or [], answer.get('next')


def fetch_new_rows(url, key, cursor, keep):
    """Pages through everything after the cursor. Each page is kept, with the cursor moved past it,
    before the next is asked for, so an interrupted run loses nothing and repeats nothing."""
    fetched = []
    since = cursor
    for _ in range(MAX_PAGES):
        rows, following = request_page(url, key, since)
        if rows:
            since = rows[-1].get('receivedAt') or since
            keep(rows, since)
            fetched.extend(rows)
        if not following:
            return fetched
        if not rows and following == since:
            raise Problem('The diagnostics service kept answering the same page; stopping.', 1)
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
    rows = []
    for path in sorted(glob.glob(os.path.join(directory, '*.jsonl'))):
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        continue
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


def cut(text, width):
    text = ' '.join(str(text).split())
    return text if len(text) <= width else text[:width - 1] + '…'


def join_versions(versions, limit=3):
    ordered = sorted(versions, key=version_key, reverse=True)
    shown = ', '.join(ordered[:limit])
    return shown + (' +' + str(len(ordered) - limit) if len(ordered) > limit else '')


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
        title_width = max(20, min(56, width - 70, max(len(p['latest'].get('title') or '') for p in problems)))
        version_width = min(18, max(len('Versions'), max(len(join_versions(p['versions'])) for p in problems)))
        row_format = '  {:<' + str(title_width) + '}  {:<11}  {:>6}  {:>8}  {:<' + str(version_width) + '}  {:<12}  {}'
        lines.append('Problems, newest first')
        lines.append(row_format.format('Problem', 'Kind', 'Times', 'Installs', 'Versions', 'Last seen', 'Trend').rstrip())
        lines.append(row_format.format('─' * title_width, '─' * 11, '─' * 6, '─' * 8, '─' * version_width, '─' * 12, '─' * 6))
        for problem in problems:
            latest = problem['latest']
            lines.append(row_format.format(
                cut(latest.get('title') or problem['signature'], title_width),
                KINDS.get(problem['kind'], (str(problem['kind']).capitalize(), 0))[0],
                '{:,}'.format(problem['times']),
                len(problem['installs']),
                cut(join_versions(problem['versions']), version_width),
                local(problem['lastSeen']),
                problem['trend']).rstrip())
            if verbose:
                indent = ' ' * 6
                lines.append(indent + 'signature  ' + problem['signature'] + ('   (area ' + latest['area'] + ')' if latest.get('area') else ''))
                if latest.get('message'):
                    lines.append(indent + 'example    ' + cut(latest['message'], max(40, width - 17)))
                lines.append(indent + 'installs   ' + ', '.join(sorted(i for i in problem['installs'] if i)))
                lines.append(indent + 'latest     event ' + str(latest.get('eventId')))
                lines.append('')
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
        lines.append('Also received {} report{}. Launch and health reports only show that FalconMail is running.'.format(
            ' and '.join(parts), '' if total == 1 else 's'))
    return '\n'.join(lines) + '\n'


def render_issues(answer, verbose, width):
    """The Issues tab as the team keeps it: open problems first, with their Status."""
    issues = answer.get('issues') or []
    lines = ['Issues tab, updated ' + (local(parse_time(answer.get('updatedAt')), True) or 'never') + ', local time', '']
    if not issues:
        return '\n'.join(lines + ['No problems listed yet.']) + '\n'
    title_width = max(20, min(56, width - 72, max(len(issue.get('title') or '') for issue in issues)))
    status_width = min(20, max(len('Status'), max(len(issue.get('status') or '') for issue in issues)))
    row_format = '  {:<' + str(title_width) + '}  {:<11}  {:>6}  {:>8}  {:<' + str(status_width) + '}  {}'
    lines.append(row_format.format('Problem', 'Kind', 'Times', 'Installs', 'Status', 'Last seen'))
    lines.append(row_format.format('─' * title_width, '─' * 11, '─' * 6, '─' * 8, '─' * status_width, '─' * 12))
    for issue in issues:
        lines.append(row_format.format(
            cut(issue.get('title') or issue.get('signature') or '', title_width),
            KINDS.get(issue.get('kind'), (str(issue.get('kind') or '').capitalize(), 0))[0],
            '{:,}'.format(int(issue.get('times') or 0)),
            int(issue.get('installs') or 0),
            cut(issue.get('status') or '', status_width),
            local(parse_time(issue.get('lastSeen')))).rstrip())
        if verbose:
            if issue.get('notes'):
                lines.append('      notes      ' + cut(issue['notes'], max(40, width - 17)))
            lines.append('      signature  ' + str(issue.get('signature') or ''))
            lines.append('')
    return '\n'.join(lines) + '\n'


def as_json(summary):
    def iso(when):
        return when.isoformat().replace('+00:00', 'Z') if when else None
    return json.dumps({
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
    }, indent=2, ensure_ascii=False) + '\n'


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
            sys.stdout.write(json.dumps(answer, indent=2, ensure_ascii=False) + '\n' if args.json
                             else render_issues(answer, args.verbose, width))
            return 0
        fetched = []
        saved_to = None
        if not args.no_fetch:
            url, key = load_config(where['config'], where['home'])
            today = datetime.date.today().isoformat()

            def keep(rows, cursor):
                nonlocal saved_to
                saved_to = append_rows(where['reports'], rows, today)
                write_cursor(where['cursor'], cursor)

            fetched = fetch_new_rows(url, key, read_cursor(where['cursor']), keep)

        history = saved_rows(where['reports'])
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
