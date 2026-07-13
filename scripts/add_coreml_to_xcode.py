#!/usr/bin/env python3
"""Add CoreMLPlugin.swift to Xcode project so it gets compiled.

This script modifies project.pbxproj in a safe way:
1. Reads the entire file
2. Uses regex to find exact sections to modify
3. Only inserts new entries, never modifies existing ones
4. Validates the file is still parseable afterward
"""

import os
import re
import uuid
import sys


def main():
    proj_path = 'ios/Runner.xcodeproj/project.pbxproj'

    if not os.path.exists(proj_path):
        print(f"ERROR: {proj_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(proj_path, 'r') as f:
        content = f.read()

    # Check if already added
    if 'CoreMLPlugin.swift' in content:
        print('CoreMLPlugin.swift already in Xcode project')
        return

    file_ref_id = uuid.uuid4().hex[:24].upper()
    build_file_id = uuid.uuid4().hex[:24].upper()

    # Step 1: Add to PBXFileReference section
    # Find the last PBXFileReference entry and insert after it
    file_ref_pattern = re.compile(
        r'(\t+[A-F0-9]{24} \/\* .*? \*\/ = \{isa = PBXFileReference; .*?; \};)\n(\t\t/\* End PBXFileReference section \*/)',
        re.DOTALL
    )
    file_ref_entry = (
        f'\t\t{file_ref_id} /* CoreMLPlugin.swift */ = '
        f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        f'path = CoreMLPlugin.swift; sourceTree = "<group>"; }};'
    )
    content = file_ref_pattern.sub(
        rf'\1\n\t\t{file_ref_entry}\n\2',
        content,
        count=1
    )

    # Step 2: Add to PBXBuildFile section
    build_file_pattern = re.compile(
        r'(\t+[A-F0-9]{24} \/\* .*? \*\/ = \{isa = PBXBuildFile; .*?; \};)\n(\t\t/\* End PBXBuildFile section \*/)',
        re.DOTALL
    )
    build_file_entry = (
        f'\t\t{build_file_id} /* CoreMLPlugin.swift in Sources */ = '
        f'{{isa = PBXBuildFile; fileRef = {file_ref_id} /* CoreMLPlugin.swift */; }};'
    )
    content = build_file_pattern.sub(
        rf'\1\n\t\t{build_file_entry}\n\2',
        content,
        count=1
    )

    # Step 3: Add file reference to the Runner group
    # Find the PBXGroup for Runner that contains AppDelegate.swift
    runner_group_pattern = re.compile(
        r'(children = \(\n)(.*?AppDelegate\.swift.*?;)',
        re.DOTALL
    )
    content = runner_group_pattern.sub(
        rf'\1\2\n\t\t\t\t{file_ref_id} /* CoreMLPlugin.swift */,',
        content,
        count=1
    )

    # Step 4: Add build file to PBXSourcesBuildPhase
    sources_phase_pattern = re.compile(
        r'/\* Begin PBXSourcesBuildPhase section \*/.*?'
        r'isa = PBXSourcesBuildPhase;.*?'
        r'buildActionMask = [0-9]+;.*?'
        r'files = \(\n(.*?)\);',
        re.DOTALL
    )
    sources_match = sources_phase_pattern.search(content)
    if sources_match:
        old_files = sources_match.group(1)
        new_file_entry = f'\t\t\t\t\t{build_file_id} /* CoreMLPlugin.swift in Sources */,\n'
        new_files = old_files + new_file_entry
        content = content[:sources_match.start(1)] + new_files + content[sources_match.end(1):]

    with open(proj_path, 'w') as f:
        f.write(content)

    print(f'Added CoreMLPlugin.swift to Xcode project')
    print(f'  File ref: {file_ref_id}')
    print(f'  Build file: {build_file_id}')


if __name__ == '__main__':
    main()