#!/usr/bin/env python3
"""Turns the stack in a FalconMail crash or hang report into function names and source lines.

A diagnostics row's context can hold a MetricKit call-stack tree or an .ips crash report. The
frames in FalconMail itself are looked up with atos in the dSYM that the release build keeps at
~/Library/Application Support/FalconMail Symbols/<version>/, matched by the binary's UUID. Frames
in other binaries, and FalconMail's own when its symbols are missing, are shown as offsets.

The app sends a crash cut to fit its 16 KB: the crashed thread and, for an uncaught exception,
the backtrace it was raised from. Frames it had to leave out are shown as a gap with their count,
and a runaway recursion as one turn of it and how many frames repeat it.

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
# The version names a folder, and it comes from the report, which anyone holding the public ingest
# key can send: '/' or '..' would point the search at the whole disk.
VERSION = re.compile('[0-9A-Za-z][0-9A-Za-z._-]{0,29}')
# Report text is shown on a terminal, which acts on control characters.
CONTROL = re.compile('[\x00-\x1f\x7f-\x9f]')


# ------------------------------------------------------------------------------------------------
# Finding stacks in a row
# ------------------------------------------------------------------------------------------------

def decode(value):
    """A JSON value from a string that may hold JSON or an .ips report (a JSON header line, then a
    JSON body); anything else comes back as it was."""
    if not isinstance(value, str):
        return value
    text = value.strip()
    if text.startswith('"'):
        # Context the service kept as a JSON string because it was not JSON itself.
        try:
            inner = json.loads(text)
        except ValueError:
            return value
        return decode(inner) if isinstance(inner, str) else inner
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


def omitted(value):
    """How many frames a gap the app left stands for, or 0."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def is_gap(frame):
    """Whether a listed frame stands for others: frames left out, or frames repeating those above."""
    return 'omitted' in frame or 'repeated' in frame


# What the thread MetricKit blames was doing, by the kind of report.
BLAMED = {'crash': 'crashed', 'hang': 'hung', 'cpu': 'using the processor', 'diskwrite': 'writing to disk'}


def metrickit_threads(tree, kind='crash'):
    """The threads of a MetricKit call-stack tree: listed top first under `frames`, as the app sends
    them, or nested a level per frame, as MetricKit writes them and earlier versions of the app
    sent them."""
    threads = []
    per_thread = tree.get('callStackPerThread') is not False
    for index, stack in enumerate(tree.get('callStacks') or []):
        if not isinstance(stack, dict):
            continue
        frames = listed_frames(stack['frames']) if isinstance(stack.get('frames'), list) else nested_frames(stack)
        if omitted(stack.get('framesOmitted')):
            frames.append({'omitted': stack['framesOmitted'], 'depth': 0, 'elsewhere': True})
        blamed = bool(stack.get('threadAttributed'))
        if not per_thread:
            name = 'Every thread, sampled together'
        elif blamed and kind == 'hang':
            name = 'Main thread'
        else:
            name = 'Thread ' + str(index)
        if blamed or not per_thread:
            name += ' (' + BLAMED.get(kind, 'blamed') + ')'
        threads.append({'name': name, 'blamed': blamed or not per_thread, 'frames': frames})
    return threads


def listed_frames(items):
    frames = []
    for item in items:
        if not isinstance(item, dict):
            continue
        depth = item.get('depth')
        depth = depth if isinstance(depth, int) and not isinstance(depth, bool) and 0 <= depth < 1000 else 0
        if omitted(item.get('repeated')):
            frames.append({'repeated': item['repeated'], 'cycle': omitted(item.get('cycle')), 'depth': depth})
        elif omitted(item.get('omitted')):
            frames.append({'omitted': item['omitted'], 'depth': depth})
        else:
            frames.append({
                'binary': item.get('binaryName') or '?',
                'uuid': item.get('binaryUUID'),
                'offset': item.get('offsetIntoBinaryTextSegment'),
                'samples': item.get('sampleCount'),
                'depth': depth,
            })
    return frames


def nested_frames(stack):
    """Walked with a list of its own rather than recursion, so no depth runs Python out of stack."""
    frames = []
    work = [(root, 0) for root in reversed(stack.get('callStackRootFrames') or [])]
    while work:
        frame, depth = work.pop()
        if not isinstance(frame, dict):
            continue
        if 'gap' in frame:
            frames.append({'omitted': frame['gap'], 'depth': depth})
            continue
        frames.append({
            'binary': frame.get('binaryName') or '?',
            'uuid': frame.get('binaryUUID'),
            'offset': frame.get('offsetIntoBinaryTextSegment'),
            'samples': frame.get('sampleCount'),
            'depth': depth,
        })
        # What the app left out under a frame is shown after the frames it kept there.
        if omitted(frame.get('subFramesOmitted')):
            work.append(({'gap': frame['subFramesOmitted']}, depth + 1))
        work.extend((child, depth + 1) for child in reversed(frame.get('subFrames') or []))
    # A crash's stack is a chain, one frame under the next; only a sampled hang branches.
    roots = stack.get('callStackRootFrames') or []
    branched = len(roots) > 1 or any(len(f.get('subFrames') or []) > 1 for f in iter_frames(roots))
    if not branched:
        for frame in frames:
            frame['depth'] = 0
    return frames


def iter_frames(frames):
    work = list(reversed(frames))
    while work:
        frame = work.pop()
        if isinstance(frame, dict):
            yield frame
            work.extend(reversed(frame.get('subFrames') or []))


def ips_threads(body):
    images = body.get('usedImages') or []

    def frames_of(listing):
        frames = []
        for frame in listing if isinstance(listing, list) else []:
            if not isinstance(frame, dict):
                continue
            if omitted(frame.get('omitted')):
                frames.append({'omitted': frame['omitted'], 'depth': 0})
                continue
            position = frame.get('imageIndex')
            image = images[position] if isinstance(position, int) and 0 <= position < len(images) else {}
            frames.append({
                'binary': image.get('name') or os.path.basename(image.get('path') or '') or '?',
                'uuid': image.get('uuid'),
                'offset': frame.get('imageOffset'),
                'symbol': frame.get('symbol'),
                'depth': 0,
            })
        return frames

    threads = []
    # Where an uncaught exception was raised: what the crashed thread shows is only how it ended the app.
    if isinstance(body.get('lastExceptionBacktrace'), list):
        threads.append({'name': 'Where the exception was raised', 'blamed': True,
                        'frames': frames_of(body['lastExceptionBacktrace'])})
    for position, thread in enumerate(body.get('threads') or []):
        if not isinstance(thread, dict):
            continue
        # The app sends only the crashed thread, with its number in the report.
        number = thread['index'] if isinstance(thread.get('index'), int) else position
        name = 'Thread ' + str(number)
        if thread.get('queue') == 'com.apple.main-thread':
            name += ', main thread'
        elif thread.get('name') or thread.get('queue'):
            name += ', ' + str(thread.get('name') or thread.get('queue'))
        if thread.get('triggered'):
            name += ' (crashed)'
        threads.append({'name': name, 'blamed': bool(thread.get('triggered')), 'frames': frames_of(thread.get('frames'))})
    return threads


# ------------------------------------------------------------------------------------------------
# Symbols
# ------------------------------------------------------------------------------------------------

def normalised_uuid(value):
    return re.sub(r'[^0-9A-F]', '', str(value or '').upper())


def dwarf_files(version):
    """UUID -> (DWARF file, architecture) for every dSYM kept for this version, and the folder
    looked in: None when the version is not a plain version number, and nothing was looked at."""
    found = {}
    if not VERSION.fullmatch(version or ''):
        return found, None
    folder = os.path.join(os.path.expanduser(SYMBOLS_DIR), version)
    if not os.path.isdir(folder) or not shutil.which('dwarfdump'):
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
            if is_gap(frame):
                continue
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


def plural(count, word):
    return '{:,} {}{}'.format(count, word, '' if count == 1 else 's')


def stands_for(frame):
    """How many frames of the full stack a listed frame takes: a gap or a repeated run all of its
    count, a gap on other branches none."""
    if 'repeated' in frame:
        return frame['repeated']
    if 'omitted' in frame:
        return 0 if frame.get('elsewhere') else frame['omitted']
    return 1


def render_thread(thread):
    lines = [thread['name']]
    width = max([len(frame['binary']) for frame in thread['frames'] if 'binary' in frame] + [6])
    # Wide enough for the last frame's number, so the columns line up however deep the stack.
    digits = max(3, len(str(sum(stands_for(frame) for frame in thread['frames']))))
    gap = ' ' * (digits + 4)
    number = 0
    for frame in thread['frames']:
        indent = '  ' * frame['depth']
        # Frames that stand for others are numbered as in the full stack, so the frames after them
        # keep their places.
        if 'repeated' in frame:
            cycle = frame['cycle']
            above = 'the one above' if cycle == 1 else 'the {} above'.format(cycle) if cycle else 'those above'
            lines.append('{}{}… {} repeating {}'.format(gap, indent, plural(frame['repeated'], 'more frame'), above))
        elif 'omitted' in frame:
            where = ' on other branches' if frame.get('elsewhere') else ''
            lines.append('{}{}… {}{} left out'.format(gap, indent, plural(frame['omitted'], 'frame'), where))
        else:
            samples = frame.get('samples')
            count = '  ×' + str(samples) if isinstance(samples, int) and samples > 1 else ''
            lines.append('  {:>{d}}  {}{:<{w}}  {}{}'.format(number, indent, frame['binary'], describe(frame), count, d=digits, w=width))
        number += stands_for(frame)
    return lines


KINDS = {'crash': 'Crash', 'hang': 'Hang', 'cpu': 'Processor use', 'diskwrite': 'Disk writes'}


def render_row(row, all_threads):
    title = row.get('title') or row.get('signature') or 'Untitled report'
    kind = str(row.get('kind') or '')
    facts = [KINDS.get(kind, kind.capitalize()), 'FalconMail ' + str(row.get('version') or '?')
             + (' (' + str(row['build']) + ')' if row.get('build') else ''), str(row.get('os') or ''),
             'received ' + local_time(row.get('receivedAt')), 'event ' + str(row.get('eventId') or '?')]
    lines = [title, ' · '.join(fact for fact in facts if fact), '']
    stacks = find_stacks(row.get('context'))
    if not stacks:
        context = decode(row.get('context'))
        if isinstance(context, dict) and context.get('truncated') is True:
            lines.append('Its context was too large and was cut short on arrival, so the stack is missing.')
            return screen(lines)
        return None

    dwarfs, folder = dwarf_files(str(row.get('version') or ''))
    threads = []
    left_out = 0
    for source, value in stacks:
        threads.extend(metrickit_threads(value, kind or 'crash') if source == 'metrickit' else ips_threads(value))
        left_out += omitted(value.get('callStacksOmitted'))
    resolved = symbolicate(threads, dwarfs)
    context = decode(row.get('context'))
    if isinstance(context, dict) and context.get('trimmed') is True:
        lines.append('The app left part of this report out to fit its size limit; a gap in a stack says how many frames.')
        if left_out:
            lines.append('{} thread{} MetricKit did not blame {} left out.'.format(
                left_out, '' if left_out == 1 else 's', 'was' if left_out == 1 else 'were'))
        lines.append('')
    if folder is None:
        lines.append('The report\'s version is not a plain version number, so no symbols were looked for; '
                     'FalconMail\'s frames are shown as offsets.')
        lines.append('')
    elif not dwarfs:
        lines.append('No symbols for this version in ' + folder.replace(os.path.expanduser('~'), '~', 1)
                     + '; FalconMail\'s frames are shown as offsets.')
        lines.append('')
    elif not resolved:
        lines.append('The symbols kept for this version do not match this build; frames are shown as offsets.')
        lines.append('')

    blamed = [thread for thread in threads if thread['blamed']] or threads[:1]
    shown = threads if all_threads else blamed
    for thread in shown:
        lines.extend(render_thread(thread))
        lines.append('')
    hidden = len(threads) - len(shown)
    if hidden:
        lines.append('{} other thread{} not shown; add --all-threads to see them.'.format(hidden, '' if hidden == 1 else 's'))
        lines.append('')
    return screen(lines)


def screen(lines):
    """The lines as one text, with nothing in them a terminal would act on."""
    return '\n'.join(CONTROL.sub('', line.replace('\t', ' ')) for line in lines)


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
    parser.add_argument('--all-threads', action='store_true', help='show every thread, not just the one that crashed or hung')
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
