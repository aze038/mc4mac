#!/usr/bin/env python3
"""Turns the stack in a FalconMail crash or hang report into function names and source lines.

A diagnostics row's context can hold a MetricKit call-stack tree or an .ips crash report. The
frames in FalconMail itself are looked up with atos in the dSYM that the release build keeps at
~/Library/Application Support/FalconMail Symbols/<version>/, matched by the binary's UUID. Frames
in other binaries, and FalconMail's own when its symbols are missing, are shown as offsets.

    symbolicate.py --event <event ID>      a row from ~/FalconMailReports/*.jsonl
    symbolicate.py rows.jsonl              every row with a stack in a file
    symbolicate.py -                       a row or rows on standard input
"""

import argparse
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys

SYMBOLS_DIR = os.path.join('~', 'Library', 'Application Support', 'FalconMail Symbols')


# ------------------------------------------------------------------------------------------------
# Finding stacks in a row
# ------------------------------------------------------------------------------------------------

def decode(value):
    """A JSON value from a string that may hold JSON or an .ips report (a JSON header line, then a
    JSON body); anything else comes back as it was."""
    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text.startswith('{'):
        return value
    try:
        return json.loads(text)
    except ValueError:
        pass
    header, _, body = text.partition('\n')
    try:
        return {'ipsHeader': json.loads(header), 'ipsBody': json.loads(body)}
    except ValueError:
        return value


def find_stacks(value, found=None):
    """Every MetricKit call-stack tree and .ips body anywhere in a decoded context."""
    found = [] if found is None else found
    value = decode(value)
    if isinstance(value, dict):
        if isinstance(value.get('callStacks'), list):
            found.append(('metrickit', value))
            return found
        if isinstance(value.get('threads'), list) and isinstance(value.get('usedImages'), list):
            found.append(('ips', value))
            return found
        for child in value.values():
            find_stacks(child, found)
    elif isinstance(value, list):
        for child in value:
            find_stacks(child, found)
    return found


def metrickit_threads(tree):
    threads = []
    for index, stack in enumerate(tree.get('callStacks') or []):
        frames = []

        def walk(frame, depth):
            frames.append({
                'binary': frame.get('binaryName') or '?',
                'uuid': frame.get('binaryUUID'),
                'offset': frame.get('offsetIntoBinaryTextSegment'),
                'samples': frame.get('sampleCount'),
                'depth': depth,
            })
            for child in frame.get('subFrames') or []:
                walk(child, depth + 1)

        for root in stack.get('callStackRootFrames') or []:
            walk(root, 0)
        # A crash's stack is a chain, one frame under the next; only a sampled hang branches.
        branched = len(stack.get('callStackRootFrames') or []) > 1 or any(
            len(f.get('subFrames') or []) > 1 for f in iter_frames(stack.get('callStackRootFrames') or []))
        if not branched:
            for frame in frames:
                frame['depth'] = 0
        threads.append({'name': 'Thread ' + str(index), 'crashed': bool(stack.get('threadAttributed')), 'frames': frames})
    return threads


def iter_frames(frames):
    for frame in frames:
        yield frame
        yield from iter_frames(frame.get('subFrames') or [])


def ips_threads(body):
    images = body.get('usedImages') or []
    threads = []
    for index, thread in enumerate(body.get('threads') or []):
        frames = []
        for frame in thread.get('frames') or []:
            position = frame.get('imageIndex')
            image = images[position] if isinstance(position, int) and 0 <= position < len(images) else {}
            frames.append({
                'binary': image.get('name') or os.path.basename(image.get('path') or '') or '?',
                'uuid': image.get('uuid'),
                'offset': frame.get('imageOffset'),
                'symbol': frame.get('symbol'),
                'depth': 0,
            })
        name = 'Thread ' + str(index) + (' ' + thread['queue'] if thread.get('queue') else '')
        threads.append({'name': name, 'crashed': bool(thread.get('triggered')), 'frames': frames})
    return threads


# ------------------------------------------------------------------------------------------------
# Symbols
# ------------------------------------------------------------------------------------------------

def normalised_uuid(value):
    return re.sub(r'[^0-9A-F]', '', str(value or '').upper())


def dwarf_files(version):
    """UUID -> (DWARF file, architecture) for every dSYM kept for this version."""
    folder = os.path.join(os.path.expanduser(SYMBOLS_DIR), version)
    found = {}
    if not version or not os.path.isdir(folder) or not shutil.which('dwarfdump'):
        return found, folder
    for path in glob.glob(os.path.join(folder, '**', '*.dSYM', 'Contents', 'Resources', 'DWARF', '*'), recursive=True):
        result = subprocess.run(['dwarfdump', '--uuid', path], capture_output=True, text=True, check=False)
        for match in re.finditer(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', result.stdout):
            found[normalised_uuid(match.group(1))] = (path, match.group(2))
    return found, folder


def symbolicate(threads, dwarfs):
    """Fills in `symbol` for every frame whose binary has a matching dSYM, with one atos call per binary."""
    wanted = {}
    for thread in threads:
        for frame in thread['frames']:
            match = dwarfs.get(normalised_uuid(frame.get('uuid')))
            if match and isinstance(frame.get('offset'), int):
                wanted.setdefault(match, []).append(frame)
    if not wanted or not shutil.which('atos'):
        return 0
    resolved = 0
    for (path, arch), frames in wanted.items():
        offsets = [hex(frame['offset']) for frame in frames]
        result = subprocess.run(['atos', '-arch', arch, '-o', path, '-offset'] + offsets,
                                capture_output=True, text=True, check=False)
        answers = result.stdout.splitlines()
        for frame, offset, answer in zip(frames, offsets, answers):
            # atos echoes an address it cannot place.
            if answer.strip() and answer.strip() != offset:
                frame['symbol'] = re.sub(r' \(in [^)]+\)', '', answer.strip())
                resolved += 1
    return resolved


# ------------------------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------------------------

def local_time(value):
    try:
        moment = datetime.datetime.fromisoformat(str(value).replace('Z', '+00:00')).astimezone()
    except ValueError:
        return str(value or '?')
    return str(moment.day) + moment.strftime(' %b %Y %H:%M')


def describe(frame):
    if frame.get('symbol'):
        return frame['symbol']
    offset = frame.get('offset')
    return '+ ' + hex(offset) if isinstance(offset, int) else '(no offset)'


def render_thread(thread):
    lines = [thread['name'] + (' (crashed)' if thread['crashed'] else '')]
    width = max([len(frame['binary']) for frame in thread['frames']] + [6])
    for number, frame in enumerate(thread['frames']):
        samples = frame.get('samples')
        count = '  ×' + str(samples) if isinstance(samples, int) and samples > 1 else ''
        lines.append('  {:>3}  {}{:<{w}}  {}{}'.format(
            number, '  ' * frame['depth'], frame['binary'], describe(frame), count, w=width))
    return lines


def render_row(row, all_threads):
    stacks = find_stacks(row.get('context'))
    if not stacks:
        return None
    title = row.get('title') or row.get('signature') or 'Untitled report'
    facts = [str(row.get('kind') or '').capitalize(), 'FalconMail ' + str(row.get('version') or '?')
             + (' (' + str(row['build']) + ')' if row.get('build') else ''), str(row.get('os') or ''),
             'received ' + local_time(row.get('receivedAt')), 'event ' + str(row.get('eventId') or '?')]
    lines = [title, ' · '.join(fact for fact in facts if fact), '']

    dwarfs, folder = dwarf_files(str(row.get('version') or ''))
    threads = []
    for kind, value in stacks:
        threads.extend(metrickit_threads(value) if kind == 'metrickit' else ips_threads(value))
    resolved = symbolicate(threads, dwarfs)
    if not dwarfs:
        lines.append('No symbols for this version in ' + folder.replace(os.path.expanduser('~'), '~', 1)
                     + '; FalconMail\'s frames are shown as offsets.')
        lines.append('')
    elif not resolved:
        lines.append('The symbols kept for this version do not match this build; frames are shown as offsets.')
        lines.append('')

    crashed = [thread for thread in threads if thread['crashed']] or threads[:1]
    shown = threads if all_threads else crashed
    for thread in shown:
        lines.extend(render_thread(thread))
        lines.append('')
    hidden = len(threads) - len(shown)
    if hidden:
        lines.append('{} other thread{} not shown; add --all-threads to see them.'.format(hidden, '' if hidden == 1 else 's'))
        lines.append('')
    return '\n'.join(lines)


# ------------------------------------------------------------------------------------------------

def read_rows(sources):
    rows = []
    for source in sources:
        handle = sys.stdin if source == '-' else open(os.path.expanduser(source), encoding='utf-8')
        with handle:
            text = handle.read().strip()
        if not text:
            continue
        try:
            parsed = json.loads(text)
            rows.extend(parsed if isinstance(parsed, list) else [parsed])
        except ValueError:
            rows.extend(json.loads(line) for line in text.splitlines() if line.strip())
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description='Symbolicate the stack in a FalconMail diagnostics row.')
    parser.add_argument('sources', nargs='*', help='JSON or JSONL files of rows, or - for standard input '
                        '(default: every file in ~/FalconMailReports)')
    parser.add_argument('--event', metavar='ID', help='only the row with this event ID')
    parser.add_argument('--all-threads', action='store_true', help='show every thread, not just the one that crashed')
    args = parser.parse_args(argv)

    sources = args.sources or sorted(glob.glob(os.path.join(os.path.expanduser('~'), 'FalconMailReports', '*.jsonl')))
    rows = read_rows(sources)
    if args.event:
        rows = [row for row in rows if row.get('eventId') == args.event][-1:]
        if not rows:
            print('No saved report has event ID ' + args.event + '. Run tools/diagnostics/fetch-reports.sh first.', file=sys.stderr)
            return 1
    outputs = [text for text in (render_row(row, args.all_threads) for row in rows) if text]
    if not outputs:
        print('No stack found in ' + ('that report.' if args.event else 'these reports.'), file=sys.stderr)
        return 1
    sys.stdout.write('\n'.join(outputs))
    return 0


if __name__ == '__main__':
    sys.exit(main())
