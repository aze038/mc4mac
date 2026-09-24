"""symbolicate.py against a tiny binary built here, standing in for FalconMail and its dSYM."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(TOOLS, 'symbolicate.py')
# What FalconMail sends for a full-size crash from each source, written by the app's own test
# (CrashReportTests.testTheTriageToolsReadWhatTheAppSends), so these tests read exactly that.
FIXTURE = os.path.join(TOOLS, 'test', 'fixtures', 'trimmed-contexts.json')
SYSTEM_UUID = '11111111-2222-3333-4444-555555555555'
SOURCE = textwrap.dedent('''\
    #include <stdio.h>
    __attribute__((noinline)) int open_message(int x) { return x * 3 + 1; }
    __attribute__((noinline)) int render_reader(int y) { return open_message(y) + 2; }
    int main(int argc, char **argv) { printf("%d\\n", render_reader(argc)); return 0; }
    ''')


def run(home, *args, stdin=None):
    env = dict(os.environ, HOME=home)
    return subprocess.run(['python3', SCRIPT] + list(args), capture_output=True, text=True, env=env, input=stdin, timeout=60)


def metrickit_row(event_id, version, uuid, offsets):
    """A crash row whose context holds a MetricKit call-stack tree: FalconMail's frames, deepest
    first, then one frame in a system library."""
    frame = {'binaryUUID': SYSTEM_UUID, 'offsetIntoBinaryTextSegment': 0x1234, 'binaryName': 'libdyld.dylib', 'sampleCount': 1}
    for offset in reversed(offsets):
        frame = {'binaryUUID': uuid, 'offsetIntoBinaryTextSegment': offset, 'binaryName': 'FalconMail',
                 'sampleCount': 1, 'subFrames': [frame]}
    tree = {'callStackPerThread': True, 'callStacks': [
        {'threadAttributed': True, 'callStackRootFrames': [frame]},
        {'threadAttributed': False, 'callStackRootFrames': [
            {'binaryUUID': SYSTEM_UUID, 'offsetIntoBinaryTextSegment': 0x42, 'binaryName': 'libsystem_kernel.dylib', 'sampleCount': 1}]},
    ]}
    return {
        'eventId': event_id, 'kind': 'crash', 'title': 'FalconMail crashed while opening a message',
        'signature': 'Crash.EXC_BAD_ACCESS@MessageView.swift:88', 'version': version, 'build': '123',
        'os': 'macOS 26.6 (25G5)', 'receivedAt': '2026-09-24T08:00:00.000Z',
        'context': json.dumps({'exception': 'EXC_BAD_ACCESS', 'callStackTree': tree}),
    }


def ips_row(event_id, version, uuid, offsets):
    """A crash row whose context holds an .ips report: a JSON header line, then a JSON body."""
    header = {'app_name': 'FalconMail', 'app_version': version, 'bug_type': '309'}
    body = {
        'usedImages': [
            {'name': 'FalconMail', 'uuid': uuid, 'base': 4294967296, 'path': '~/Applications/FalconMail.app/Contents/MacOS/FalconMail'},
            {'name': 'libsystem_kernel.dylib', 'uuid': SYSTEM_UUID, 'base': 6000000000},
        ],
        'threads': [
            {'id': 1, 'frames': [{'imageIndex': 1, 'imageOffset': 0x42, 'symbol': 'mach_msg2_trap'}]},
            {'id': 2, 'triggered': True, 'queue': 'com.apple.main-thread',
             'frames': [{'imageIndex': 0, 'imageOffset': offset} for offset in offsets]},
        ],
    }
    return {
        'eventId': event_id, 'kind': 'crash', 'title': 'FalconMail crashed while opening a message', 'version': version,
        'receivedAt': '2026-09-24T08:00:00.000Z',
        'context': json.dumps({'ips': json.dumps(header) + '\n' + json.dumps(body)}),
    }


def sent_row(event_id, source, version='9.9.9'):
    """A crash row whose context is what the app sends for a full-size crash from `source`."""
    with open(FIXTURE, encoding='utf-8') as handle:
        context = json.load(handle)[source]
    return {'eventId': event_id, 'kind': 'crash', 'title': 'FalconMail crashed', 'version': version, 'build': '45',
            'receivedAt': '2026-09-24T08:00:00.000Z', 'context': context}


def with_context(row, context):
    row['context'] = json.dumps(context)
    return row


@unittest.skipUnless(all(shutil.which(tool) for tool in ('clang', 'dsymutil', 'atos', 'dwarfdump', 'nm')),
                     'needs the Xcode command line tools')
class SymbolicateWithSymbolsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.mkdtemp(prefix='falcon-symbols-')
        source = os.path.join(cls.build, 'main.c')
        with open(source, 'w') as handle:
            handle.write(SOURCE)
        # Compiled and linked in two steps so the object file, and so the debug information, outlives clang.
        subprocess.run(['clang', '-g', '-O1', '-arch', 'arm64', '-c', source, '-o', os.path.join(cls.build, 'main.o')], check=True)
        binary = os.path.join(cls.build, 'FalconMail')
        subprocess.run(['clang', '-arch', 'arm64', os.path.join(cls.build, 'main.o'), '-o', binary], check=True)
        cls.dsym = os.path.join(cls.build, 'FalconMail.app.dSYM')
        subprocess.run(['dsymutil', binary, '-o', cls.dsym], check=True, capture_output=True)
        uuid = subprocess.run(['dwarfdump', '--uuid', cls.dsym], capture_output=True, text=True, check=True).stdout
        cls.uuid = re.search(r'UUID: ([0-9A-F-]+)', uuid).group(1)
        symbols = subprocess.run(['nm', binary], capture_output=True, text=True, check=True).stdout
        address = {name: int(value, 16) for value, _, name in (line.split() for line in symbols.splitlines() if len(line.split()) == 3)}
        # A return address sits a few bytes into its function; offsets count from the start of __TEXT.
        cls.offsets = [address[name] - 0x100000000 + 4 for name in ('_open_message', '_render_reader', '_main')]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix='falcon-home-')
        self.addCleanup(shutil.rmtree, self.home, True)
        kept = os.path.join(self.home, 'Library', 'Application Support', 'FalconMail Symbols', '1.10.0', 'FalconMail.app.dSYM')
        shutil.copytree(self.dsym, kept)

    def test_a_metrickit_crash_gets_function_names_and_lines(self):
        rows = os.path.join(self.home, 'rows.jsonl')
        with open(rows, 'w') as handle:
            handle.write(json.dumps(metrickit_row('other', '1.10.0', self.uuid, self.offsets[:1])) + '\n')
            handle.write(json.dumps(metrickit_row('m1', '1.10.0', self.uuid, self.offsets)) + '\n')
        result = run(self.home, '--event', 'm1', rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], 'FalconMail crashed while opening a message')
        self.assertIn('event m1', lines[1])
        self.assertIn('Thread 0 (crashed)', result.stdout)
        self.assertRegex(result.stdout, r'0  FalconMail\s+open_message \(main\.c:2\)')
        self.assertRegex(result.stdout, r'1  FalconMail\s+render_reader \(main\.c:3\)')
        self.assertRegex(result.stdout, r'2  FalconMail\s+main \(main\.c:4\)')
        self.assertRegex(result.stdout, r'3  libdyld\.dylib\s+\+ 0x1234')
        self.assertNotIn('Thread 1', result.stdout)
        self.assertIn('1 other thread not shown; add --all-threads to see them.', result.stdout)

    def test_an_ips_crash_on_standard_input_gets_function_names(self):
        result = run(self.home, '-', stdin=json.dumps(ips_row('i1', '1.10.0', self.uuid, self.offsets)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Thread 1 com.apple.main-thread (crashed)', result.stdout)
        self.assertRegex(result.stdout, r'0  FalconMail\s+open_message \(main\.c:2\)')
        self.assertNotIn('mach_msg2_trap', result.stdout)
        every = run(self.home, '--all-threads', '-', stdin=json.dumps(ips_row('i1', '1.10.0', self.uuid, self.offsets)))
        self.assertRegex(every.stdout, r'libsystem_kernel\.dylib\s+mach_msg2_trap')

    def test_symbols_of_another_build_are_not_used(self):
        row = metrickit_row('m2', '1.10.0', '99999999-8888-7777-6666-555555555555', self.offsets)
        result = run(self.home, '-', stdin=json.dumps(row))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('do not match this build', result.stdout)
        self.assertNotIn('open_message', result.stdout)

    def test_the_trimmed_ips_the_app_sends_gets_function_names(self):
        row = sent_row('s1', 'ips', version='1.10.0')
        context = row['context']
        own = next(i for i, image in enumerate(context['usedImages']) if image['name'] == 'FalconMail')
        context['usedImages'][own]['uuid'] = self.uuid
        frames = [frame for frame in context['lastExceptionBacktrace'] if frame.get('imageIndex') == own]
        for frame, offset in zip(frames, self.offsets):
            frame['imageOffset'] = offset
        result = run(self.home, '-', stdin=json.dumps(with_context(row, context)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r'2  FalconMail\s+open_message \(main\.c:2\)')
        self.assertRegex(result.stdout, r'7  FalconMail\s+render_reader \(main\.c:3\)')
        self.assertRegex(result.stdout, r'12  FalconMail\s+main \(main\.c:4\)')
        self.assertIn('… 3 frames left out', result.stdout)
        self.assertNotIn('do not match this build', result.stdout)

    def test_a_metrickit_stack_cut_short_by_the_app_gets_function_names_and_its_gap(self):
        row = metrickit_row('m4', '1.10.0', self.uuid, self.offsets)
        context = json.loads(row['context'])
        context['trimmed'] = True
        stack = context['callStackTree']['callStacks'][0]
        stack['callStackRootFrames'][0]['subFrames'][0]['subFrames'][0].pop('subFrames')
        stack['callStackRootFrames'][0]['subFrames'][0]['subFrames'][0]['subFramesOmitted'] = 1
        result = run(self.home, '-', stdin=json.dumps(with_context(row, context)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r'2  FalconMail\s+main \(main\.c:4\)')
        self.assertIn('… 1 frame left out', result.stdout)
        self.assertNotIn('libdyld', result.stdout)

    def test_rows_are_found_in_the_saved_reports_by_default(self):
        reports = os.path.join(self.home, 'FalconMailReports')
        os.makedirs(reports)
        with open(os.path.join(reports, '2026-09-24.jsonl'), 'w') as handle:
            handle.write(json.dumps(metrickit_row('m3', '1.10.0', self.uuid, self.offsets)) + '\n')
        result = run(self.home, '--event', 'm3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('open_message (main.c:2)', result.stdout)


class SymbolicateWithoutSymbolsTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix='falcon-home-')
        self.addCleanup(shutil.rmtree, self.home, True)

    def test_missing_symbols_leave_offsets_and_say_where_they_were_looked_for(self):
        row = metrickit_row('m1', '9.9.9', 'ABCDEF01-2345-6789-ABCD-EF0123456789', [0x464, 0x470])
        result = run(self.home, '-', stdin=json.dumps(row))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No symbols for this version in ~/Library/Application Support/FalconMail Symbols/9.9.9; "
                      "FalconMail's frames are shown as offsets.", result.stdout)
        self.assertRegex(result.stdout, r'0  FalconMail\s+\+ 0x464')

    def test_a_row_without_a_stack_is_reported(self):
        result = run(self.home, '-', stdin=json.dumps({'eventId': 'x', 'kind': 'error', 'context': '{"attempt":3}'}))
        self.assertEqual(result.returncode, 1)
        self.assertIn('No stack found', result.stderr)

    def test_an_unknown_event_id_is_reported(self):
        result = run(self.home, '--event', 'nope')
        self.assertEqual(result.returncode, 1)
        self.assertIn('No saved report has event ID nope', result.stderr)

    def test_a_version_that_is_not_a_plain_number_is_never_used_as_a_path(self):
        sys.path.insert(0, TOOLS)
        self.addCleanup(sys.path.remove, TOOLS)
        import symbolicate
        searched = []
        with mock.patch.object(symbolicate.glob, 'glob', side_effect=lambda *a, **k: searched.append(a) or []), \
                mock.patch.dict(os.environ, {'HOME': self.home}):
            for version in ('/', '..', '../../..', '1.10/../..', '.hidden', 'x' * 31, ''):
                self.assertEqual(symbolicate.dwarf_files(version), ({}, None), version)
        self.assertEqual(searched, [])

        result = run(self.home, '-', stdin=json.dumps(metrickit_row('m1', '/', 'ABCDEF01-2345-6789-ABCD-EF0123456789', [0x464])))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("The report's version is not a plain version number, so no symbols were looked for", result.stdout)
        self.assertRegex(result.stdout, r'0  FalconMail\s+\+ 0x464')

    def test_control_characters_in_a_report_never_reach_the_terminal(self):
        row = metrickit_row('m1', '1.10\x1b[5m', 'ABCDEF01-2345-6789-ABCD-EF0123456789', [0x464])
        row['title'] = '\x1b]0;owned\x07\x1b[2KFalconMail crashed\nNo stack found'
        tree = json.loads(row['context'])
        tree['callStackTree']['callStacks'][0]['callStackRootFrames'][0]['binaryName'] = 'Falcon\x1b[8mMail'
        row['context'] = json.dumps(tree)
        result = run(self.home, '-', stdin=json.dumps(row))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(re.search('[\x00-\x09\x0b-\x1f\x7f-\x9f]', result.stdout))
        self.assertEqual(result.stdout.splitlines()[0], ']0;owned[2KFalconMail crashedNo stack found')
        self.assertIn('Falcon[8mMail', result.stdout)

    def test_a_context_cut_short_on_arrival_says_so(self):
        row = {'eventId': 't1', 'kind': 'crash', 'title': 'FalconMail crashed', 'version': '1.10.0',
               'context': json.dumps({'truncated': True, 'size': 70000, 'start': '{"callStackTree":{"callSt'})}
        result = run(self.home, '-', stdin=json.dumps(row))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Its context was too large and was cut short on arrival, so the stack is missing.', result.stdout)

    def test_the_trimmed_ips_the_app_sends_shows_where_the_exception_was_raised_and_every_gap(self):
        result = run(self.home, '-', stdin=json.dumps(with_context(sent_row('s2', 'ips'), sent_row('s2', 'ips')['context'])))
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn('The app left part of this report out to fit its size limit; a gap in a stack says how many frames.', out)
        raised = out.index('Where the exception was raised\n')
        crashed = out.index('Thread 0 com.apple.main-thread (crashed)\n')
        self.assertLess(raised, crashed, 'the backtrace comes first')
        self.assertRegex(out[raised:crashed], r'\n\s+0  SystemFramework\d+\s+-\[NSSomeLongSystemClassName')
        self.assertRegex(out[raised:crashed], r'\n\s+2  FalconMail\s+\+ 0x')
        # A gap is counted, and the frames after it keep their numbers in the full stack.
        self.assertRegex(out[crashed:], r'28  SystemFramework\d+  .*\n\s+… 3 frames left out\n\s+32  FalconMail')
        self.assertNotIn('other thread', out, 'the app sends the crashed thread alone')

    def test_the_trimmed_metrickit_tree_the_app_sends_is_read(self):
        result = run(self.home, '-', stdin=json.dumps(with_context(sent_row('s3', 'metrickit'), sent_row('s3', 'metrickit')['context'])))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('29 threads MetricKit did not blame were left out.', result.stdout)
        self.assertIn('Thread 0 (crashed)', result.stdout)
        self.assertRegex(result.stdout, r'59  dyld\s+\+ 0xfa0')

    def test_a_context_kept_as_a_json_string_is_still_read(self):
        row = ips_row('i2', '9.9.9', 'ABCDEF01-2345-6789-ABCD-EF0123456789', [0x464])
        row['context'] = json.dumps(json.loads(row['context'])['ips'])
        result = run(self.home, '-', stdin=json.dumps(row))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Thread 1 com.apple.main-thread (crashed)', result.stdout)


if __name__ == '__main__':
    unittest.main()
