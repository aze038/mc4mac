"""fetch-reports.sh against a fake diagnostics service on loopback; nothing leaves this Mac."""

import datetime
import http.server
import json
import os
import re
import subprocess
import tempfile
import threading
import unittest
import urllib.parse

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(TOOLS, 'fetch-reports.sh')
READ_KEY = 'r' * 64
INSTALL_X = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F'
INSTALL_Y = '5B1F0D5C-2D7A-4C1E-9E61-7A0C3B8F2D11'


def row(event_id, received, **overrides):
    base = {
        'receivedAt': received, 'install': INSTALL_X, 'title': 'Gmail paused the connection: too many requests',
        'version': '1.10.0', 'build': '123', 'os': 'macOS 26.6 (25G5)', 'hw': 'MacBookPro18,3', 'kind': 'error',
        'signature': 'IMAP.throttled@AccountSyncer.swift:131', 'area': 'IMAP', 'count': 1,
        'firstAt': received, 'lastAt': received, 'message': 'NO [THROTTLED] Too many simultaneous connections',
        'context': '{"attempt":3}', 'account': '{"provider":"google","kind":"gmail","host":"imap.gmail.com","ref":"1a2b3c4d"}',
        'eventId': event_id,
    }
    base.update(overrides)
    return base


class FakeService:
    """Answers op=read like the Apps Script web app: a 302 first, then pages of `page_size` rows
    that never split rows sharing a receivedAt, with `since` exclusive."""

    def __init__(self, rows, page_size=2):
        self.rows = list(rows)
        self.issues = []
        self.page_size = page_size
        # When set, every read is answered with this page, as a service paging out of order would.
        self.fixed_page = None
        self.requests = []
        service = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                query = dict(urllib.parse.parse_qsl(parsed.query))
                if parsed.path.endswith('/exec'):
                    service.requests.append(query)
                    self.send_response(302)
                    self.send_header('Location', '/macros/echo?' + parsed.query)
                    self.end_headers()
                    return
                body = json.dumps(service.answer(query)).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = 'http://127.0.0.1:{}/macros/s/test/exec'.format(self.server.server_address[1])
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def answer(self, query):
        if query.get('op') not in ('read', 'issues') or query.get('key') != READ_KEY:
            return {'ok': False, 'error': 'Not accepted'}
        if query['op'] == 'issues':
            return {'ok': True, 'updatedAt': '2026-09-24T08:00:00.000Z', 'issues': self.issues}
        if self.fixed_page:
            return self.fixed_page
        since = query.get('since') or ''
        rows = sorted((r for r in self.rows if r['receivedAt'] > since), key=lambda r: r['receivedAt'])
        page = rows[:self.page_size]
        while page and len(page) < len(rows) and rows[len(page)]['receivedAt'] == page[-1]['receivedAt']:
            page.append(rows[len(page)])
        more = len(page) < len(rows)
        return {'ok': True, 'rows': page, 'next': page[-1]['receivedAt'] if more else None}

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FetchReportsTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix='falcon-fetch-')
        self.config_dir = os.path.join(self.home, '.config', 'falconmail')
        os.makedirs(self.config_dir)
        self.reports = os.path.join(self.home, 'FalconMailReports')
        self.service = FakeService([
            row('e1', '2026-09-24T03:00:00.000Z', count=3, lastAt='2026-09-24T02:59:00.000Z'),
            row('e2', '2026-09-24T03:00:00.000Z', kind='crash', signature='Crash.EXC_BAD_ACCESS@MessageView.swift:88',
                title='FalconMail crashed while opening a message', install=INSTALL_Y, area='Reader',
                lastAt='2026-09-24T02:30:00.000Z', message='EXC_BAD_ACCESS'),
            row('e3', '2026-09-24T04:00:00.000Z', kind='launch', signature='App.launch', title='FalconMail started'),
            row('e4', '2026-09-24T05:00:00.000Z', count=2, install=INSTALL_Y, version='1.10.1',
                lastAt='2026-09-24T04:40:00.000Z'),
        ])
        self.addCleanup(self.service.close)

    def write_config(self, url=None, key=READ_KEY, mode=0o600):
        path = os.path.join(self.config_dir, 'diagnostics.json')
        with open(path, 'w') as handle:
            json.dump({'url': url or self.service.url, 'readKey': key}, handle)
        os.chmod(path, mode)

    def run_tool(self, *args, columns=140):
        env = {key: value for key, value in os.environ.items() if 'proxy' not in key.lower()}
        env.update({'HOME': self.home, 'TZ': 'Asia/Baku', 'COLUMNS': str(columns), 'no_proxy': '*'})
        return subprocess.run(['bash', SCRIPT] + list(args), capture_output=True, text=True, env=env, timeout=60)

    def saved_lines(self):
        today = datetime.date.today().isoformat()
        with open(os.path.join(self.reports, today + '.jsonl')) as handle:
            return [json.loads(line) for line in handle]

    def cursor(self):
        with open(os.path.join(self.config_dir, 'diagnostics.cursor')) as handle:
            return handle.read().strip()

    # --------------------------------------------------------------------------------------------

    def test_refuses_a_config_other_users_can_read(self):
        self.write_config(mode=0o644)
        result = self.run_tool()
        self.assertEqual(result.returncode, 2)
        self.assertIn('chmod 600 ~/.config/falconmail/diagnostics.json', result.stderr)
        self.assertEqual(self.service.requests, [])

    def test_says_how_to_create_a_missing_config(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 2)
        self.assertIn('~/.config/falconmail/diagnostics.json is missing', result.stderr)
        self.assertIn('docs/DIAGNOSTICS_SETUP.md', result.stderr)

    def test_refuses_to_send_the_key_over_plain_http(self):
        self.write_config(url='http://example.com/macros/s/x/exec')
        result = self.run_tool()
        self.assertEqual(result.returncode, 2)
        self.assertIn('must start with https://', result.stderr)

    def test_first_run_fetches_every_page_and_prints_problems_newest_first(self):
        self.write_config()
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([request.get('since') for request in self.service.requests], [None, '2026-09-24T03:00:00.000Z'])
        self.assertTrue(all(request['limit'] == '1000' for request in self.service.requests))

        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], 'FalconMail diagnostics: 4 reports from 2 installs')
        self.assertEqual(lines[1], 'Received 24 Sep 2026 07:00 to 24 Sep 2026 09:00, local time')
        table = [line for line in lines if line.startswith('  ') and ('Gmail' in line or 'crashed' in line)]
        self.assertEqual(len(table), 2)
        self.assertIn('Gmail paused the connection: too many requests', table[0], 'last seen 08:40 comes first')
        self.assertRegex(table[0], r'Error\s+5\s+2\s+1\.10\.1, 1\.10\.0\s+24 Sep 08:40\s+New$')
        self.assertRegex(table[1], r'FalconMail crashed while opening a message\s+Crash\s+1\s+1\s+1\.10\.0\s+24 Sep 06:30\s+New$')
        self.assertIn('Also received 1 launch report. Launch and health reports only show that FalconMail is running.', result.stdout)
        self.assertNotIn('IMAP.throttled', result.stdout, 'signatures only with -v')
        self.assertNotIn(READ_KEY, result.stdout + result.stderr)
        self.assertIn('Saved to ~/FalconMailReports/', result.stdout)

        self.assertEqual([saved['eventId'] for saved in self.saved_lines()], ['e1', 'e2', 'e3', 'e4'])
        self.assertEqual(self.cursor(), '2026-09-24T05:00:00.000Z')
        self.assertEqual(os.stat(os.path.join(self.config_dir, 'diagnostics.cursor')).st_mode & 0o077, 0)

    def test_later_runs_fetch_only_what_is_new(self):
        self.write_config()
        self.run_tool()
        self.service.rows.append(row('e5', '2026-09-24T06:00:00.000Z'))
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.service.requests[-1].get('since'), '2026-09-24T05:00:00.000Z')
        self.assertTrue(result.stdout.startswith('FalconMail diagnostics: 1 report from 1 install\n'))
        self.assertEqual(len(self.saved_lines()), 5)

        quiet = self.run_tool()
        self.assertEqual(quiet.stdout, 'No new reports.\n')
        self.assertEqual(self.cursor(), '2026-09-24T06:00:00.000Z')
        self.assertEqual(len(self.saved_lines()), 5)

    def test_verbose_shows_signatures_examples_and_event_ids(self):
        self.write_config()
        result = self.run_tool('-v')
        self.assertIn('signature  IMAP.throttled@AccountSyncer.swift:131   (area IMAP)', result.stdout)
        self.assertIn('example    NO [THROTTLED] Too many simultaneous connections', result.stdout)
        self.assertIn('latest     event e2', result.stdout)
        self.assertIn('installs   ' + INSTALL_Y + ', ' + INSTALL_X, result.stdout)

    def test_a_wrong_key_is_reported_without_showing_it(self):
        self.write_config(key='not-the-key')
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn('The diagnostics service said: Not accepted. Check readKey in the config.', result.stderr)
        self.assertNotIn('not-the-key', result.stdout + result.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.config_dir, 'diagnostics.cursor')))

    def test_json_marks_problems_new_back_or_rising_against_saved_reports(self):
        os.makedirs(self.reports)
        history = [row('h{}'.format(day), '2026-09-{:02d}T10:00:00.000Z'.format(day)) for day in range(17, 24)]
        history.append(row('old', '2026-09-01T10:00:00.000Z', signature='SMTP.auth@Sender.swift:40', title='Sending failed'))
        with open(os.path.join(self.reports, '2026-09-23.jsonl'), 'w') as handle:
            handle.writelines(json.dumps(entry) + '\n' for entry in history)
        self.service.rows = [
            row('n1', '2026-09-24T03:00:00.000Z', count=10),
            row('n2', '2026-09-24T03:00:00.000Z', signature='SMTP.auth@Sender.swift:40', title='Sending failed'),
            row('n3', '2026-09-24T03:00:00.000Z', kind='hang', signature='Hang.main@Reader.swift:10', title='FalconMail stopped responding'),
        ]
        self.write_config()
        result = self.run_tool('--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        trends = {problem['signature']: problem['trend'] for problem in summary['problems']}
        self.assertEqual(trends, {
            'IMAP.throttled@AccountSyncer.swift:131': 'Rising',
            'SMTP.auth@Sender.swift:40': 'Back',
            'Hang.main@Reader.swift:10': 'New',
        })
        hang = next(problem for problem in summary['problems'] if problem['kind'] == 'hang')
        self.assertEqual(hang['latestEventId'], 'n3')
        self.assertEqual(hang['installs'], [INSTALL_X])

    def test_issues_shows_the_team_status_and_saves_nothing(self):
        self.service.issues = [
            {'title': 'FalconMail crashed while opening a message', 'kind': 'crash', 'times': 9, 'installs': 4,
             'status': 'Investigating', 'notes': 'Only long threads', 'lastSeen': '2026-09-24T07:55:00.000Z',
             'signature': 'Crash.EXC_BAD_ACCESS@MessageView.swift:88'},
            {'title': 'Gmail paused the connection: too many requests', 'kind': 'error', 'times': 1200, 'installs': 12,
             'status': "Won't fix", 'notes': '', 'lastSeen': '2026-09-24T07:00:00.000Z', 'signature': 'IMAP.throttled'},
        ]
        self.write_config()
        result = self.run_tool('--issues', '-v')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], 'Issues tab, updated 24 Sep 2026 12:00, local time')
        self.assertRegex(result.stdout, r'FalconMail crashed while opening a message\s+Crash\s+9\s+4\s+Investigating\s+24 Sep 11:55')
        self.assertRegex(result.stdout, r"Error\s+1,200\s+12\s+Won't fix")
        self.assertIn('notes      Only long threads', result.stdout)
        self.assertEqual([request['op'] for request in self.service.requests], ['issues'])
        self.assertFalse(os.path.exists(self.reports))
        self.assertFalse(os.path.exists(os.path.join(self.config_dir, 'diagnostics.cursor')))

        as_json = json.loads(self.run_tool('--issues', '--json').stdout)
        self.assertEqual(as_json['issues'][0]['status'], 'Investigating')

    def test_saved_reports_can_be_summarised_offline(self):
        os.makedirs(self.reports)
        with open(os.path.join(self.reports, '2026-09-23.jsonl'), 'w') as handle:
            handle.write(json.dumps(row('s1', '2026-09-23T10:00:00.000Z')) + '\n')
        result = self.run_tool('--no-fetch', '--days', '36500')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('FalconMail diagnostics: 1 report from 1 install', result.stdout)
        self.assertEqual(self.service.requests, [])

    def test_a_next_page_that_does_not_move_forward_is_refused_not_followed(self):
        self.write_config()
        with open(os.path.join(self.config_dir, 'diagnostics.cursor'), 'w') as handle:
            handle.write('2026-09-24T08:00:30.000Z\n')
        # What a tab sorted by Kind gave before the service chose rows by time: older rows, and a
        # next page earlier than the cursor.
        self.service.fixed_page = {'ok': True, 'next': '2026-09-24T08:00:00.000Z', 'rows': [
            row('n7', '2026-09-24T08:07:00.000Z'), row('n1', '2026-09-24T08:01:00.000Z'),
            row('old', '2026-09-24T08:00:00.000Z')]}
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn('not after this one; stopping. What was fetched is saved.', result.stderr)
        self.assertEqual(len(self.service.requests), 1)
        self.assertEqual([saved['eventId'] for saved in self.saved_lines()], ['n7', 'n1', 'old'])
        self.assertEqual(self.cursor(), '2026-09-24T08:07:00.000Z', 'the newest row, not the last one listed')

        again = self.run_tool()
        self.assertEqual(again.returncode, 1)
        self.assertEqual(len(self.saved_lines()), 3, 'rows already saved are not saved again')

    def test_a_row_saved_twice_is_counted_once(self):
        os.makedirs(self.reports)
        with open(os.path.join(self.reports, '2026-09-23.jsonl'), 'w') as handle:
            handle.write(json.dumps(row('s1', '2026-09-23T10:00:00.000Z', count=4)) + '\n')
            handle.write(json.dumps(row('s1', '2026-09-23T10:00:00.000Z', count=4)) + '\n')
        summary = json.loads(self.run_tool('--no-fetch', '--days', '36500', '--json').stdout)
        self.assertEqual(summary['reports'], 1)
        self.assertEqual(summary['problems'][0]['times'], 4)

    def test_control_characters_in_reports_never_reach_the_terminal(self):
        hostile = '\x1b]0;owned\x07\x1b[2KGmail paused\x9b2J'
        self.service.rows = [row('x1', '2026-09-24T03:00:00.000Z', title=hostile, version='1.10\x1b[5m',
                                 message='\x1b[1A\x1b[2KNo new reports.', signature='IMAP.x\x1b[8m@A.swift:1')]
        self.service.issues = [{'title': hostile, 'kind': 'error', 'times': 1, 'installs': 1, 'status': 'New\x1b[8m',
                                'notes': '\x07bell', 'lastSeen': '2026-09-24T03:00:00.000Z', 'signature': 'IMAP.x\x1b[8m'}]
        self.write_config()
        control = re.compile('[\x00-\x09\x0b-\x1f\x7f-\x9f]')
        for args in [(), ('--no-fetch', '-v', '--days', '36500'), ('--issues', '-v'), ('--issues', '--json'),
                     ('--no-fetch', '--days', '36500', '--json')]:
            result = self.run_tool(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(control.search(result.stdout), args)
        table = self.run_tool('--no-fetch', '--days', '36500').stdout
        self.assertIn(']0;owned[2KGmail paused2J', table)
        issues = json.loads(self.run_tool('--issues', '--json').stdout)
        self.assertEqual(issues['issues'][0]['title'], hostile, 'JSON escapes them and keeps the data')

    def test_the_table_fits_the_terminal(self):
        self.service.rows.append(row('e5', '2026-09-24T06:00:00.000Z', version='1.9.9', title='A' * 90))
        self.service.rows.append(row('e6', '2026-09-24T06:00:00.000Z', version='1.10.2'))
        self.service.issues = [{'title': 'B' * 90, 'kind': 'crash', 'times': 9, 'installs': 4, 'status': "Won't fix",
                                'lastSeen': '2026-09-24T07:55:00.000Z', 'signature': 'S'}]
        self.write_config()
        self.run_tool()
        for columns in (80, 100, 120):
            for args in [('--no-fetch', '--days', '36500'), ('--issues',)]:
                output = self.run_tool(*args, columns=columns).stdout
                longest = max(output.splitlines(), key=len)
                self.assertLess(len(longest), columns, '{} at {} columns: {!r}'.format(args, columns, longest))


if __name__ == '__main__':
    unittest.main()
