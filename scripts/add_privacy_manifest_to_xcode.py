#!/usr/bin/env python3
"""Add PrivacyInfo.xcprivacy to the Runner target of the Xcode project.

Apple requires every submitted app to ship a privacy manifest inside its
bundle, and the file has to be referenced from the Runner target's
PBXResourcesBuildPhase or Xcode never copies it into Runner.app.

The project contains TWO resources build phases (Runner and RunnerTests) and
several PBXGroup blocks, so the right one is resolved by name instead of by
position — adding the build file to both phases produces an inconsistent
project ("[Xcodeproj] Consistency issue: no parent for object ...").

Usage:  python scripts/add_privacy_manifest_to_xcode.py
"""

import os
import re
import sys
import uuid

MANIFEST = 'PrivacyInfo.xcprivacy'

BLOCK_RE = re.compile(r'^\t\t([0-9A-F]{24}) /\* (.+?) \*/ = \{$')
END_RE = re.compile(r'^\t\t\};$')


def _blocks(lines):
    """Yield (start_idx, end_idx, uuid, name, body_lines) for every object."""
    i = 0
    while i < len(lines):
        m = BLOCK_RE.match(lines[i].rstrip('\n'))
        if m:
            j = i + 1
            while j < len(lines) and not END_RE.match(lines[j].rstrip('\n')):
                j += 1
            yield i, j, m.group(1), m.group(2), lines[i + 1:j]
            i = j + 1
        else:
            i += 1


def _find_object(lines, isa, name):
    """Return (start, end, uuid, body) of the object with the given isa+name."""
    for start, end, uid, _label, body in _blocks(lines):
        text = ''.join(body)
        if f'isa = {isa};' in text and re.search(rf'^\s*name = {name};$', text, re.M):
            return start, end, uid, body
    return None


def _find_group_by_label(lines, label):
    """Return the PBXGroup block whose header label matches.

    Xcode groups often have no explicit `name = ...` property — the display
    name comes from the header comment instead, so the label is what we can
    rely on.
    """
    for start, end, uid, blk_label, body in _blocks(lines):
        if blk_label == label and 'isa = PBXGroup;' in ''.join(body):
            return start, end, uid, body
    return None


def add_manifest(proj_path, filename):
    with open(proj_path, 'r') as f:
        lines = f.readlines()

    if any(filename in line for line in lines):
        print(f'{filename} already in Xcode project')
        return True

    target = _find_object(lines, 'PBXNativeTarget', 'Runner')
    group = _find_group_by_label(lines, 'Runner')
    if not target or not group:
        print('ERROR: Runner target or Runner group not found', file=sys.stderr)
        return False

    phase_uuid = None
    in_build_phases = False
    for line in target[3]:
        if 'buildPhases = (' in line:
            in_build_phases = True
            continue
        if in_build_phases:
            m = re.search(r'([0-9A-F]{24}) /\* Resources \*/', line)
            if m:
                phase_uuid = m.group(1)
                break
            if line.strip() == ');':
                break
    if not phase_uuid:
        print('ERROR: Runner resources build phase not found', file=sys.stderr)
        return False

    phase = None
    for start, end, uid, _label, body in _blocks(lines):
        if uid == phase_uuid:
            phase = (start, end, body)
            break
    if not phase:
        print('ERROR: resources phase block not found', file=sys.stderr)
        return False

    file_ref_id = uuid.uuid4().hex[:24].upper()
    build_file_id = uuid.uuid4().hex[:24].upper()

    new_lines = []
    in_pbxbuildfile = False
    in_pbxfileref = False
    added_ref = added_build = added_group = added_phase = False

    for i, line in enumerate(lines):
        if '/* Begin PBXBuildFile section */' in line:
            in_pbxbuildfile = True
        elif '/* End PBXBuildFile section */' in line:
            in_pbxbuildfile = False
        elif '/* Begin PBXFileReference section */' in line:
            in_pbxfileref = True
        elif '/* End PBXFileReference section */' in line:
            in_pbxfileref = False

        new_lines.append(line)

        # 1. PBXFileReference (next to the other Runner files)
        if in_pbxfileref and 'Runner-Bridging-Header.h' in line and not added_ref:
            new_lines.append(
                f'\t\t{file_ref_id} /* {filename} */ = '
                f'{{isa = PBXFileReference; lastKnownFileType = text.xml; '
                f'path = {filename}; sourceTree = "<group>"; }};\n'
            )
            added_ref = True

        # 2. PBXBuildFile
        if in_pbxbuildfile and 'AppDelegate.swift' in line and 'PBXBuildFile' in line \
                and not added_build:
            new_lines.append(
                f'\t\t{build_file_id} /* {filename} in Resources */ = '
                f'{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};\n'
            )
            added_build = True

        # 3. Runner group children
        if group[0] < i < group[1] and 'children = (' in line and not added_group:
            new_lines.append(f'\t\t\t\t{file_ref_id} /* {filename} */,\n')
            added_group = True

        # 4. Runner target's resources phase (and only that one)
        if phase[0] < i < phase[1] and 'files = (' in line and not added_phase:
            new_lines.append(f'\t\t\t\t{build_file_id} /* {filename} in Resources */,\n')
            added_phase = True

    if not (added_ref and added_build and added_group and added_phase):
        print('ERROR: could not place all 4 pbxproj entries; project untouched',
              file=sys.stderr)
        return False

    with open(proj_path, 'w') as f:
        f.writelines(new_lines)

    print(f'Added {filename} to Xcode project (Runner target)')
    print(f'  Resources phase: {phase_uuid}')
    print(f'  File ref:       {file_ref_id}')
    print(f'  Build file:     {build_file_id}')
    return True


def main():
    proj_path = 'ios/Runner.xcodeproj/project.pbxproj'
    if not os.path.exists(proj_path):
        print(f'ERROR: {proj_path} not found (run from the project root)',
              file=sys.stderr)
        sys.exit(1)
    if not add_manifest(proj_path, MANIFEST):
        sys.exit(1)


if __name__ == '__main__':
    main()
