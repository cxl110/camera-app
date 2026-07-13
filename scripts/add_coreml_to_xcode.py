#!/usr/bin/env python3
"""Add CoreMLPlugin.swift to Xcode project so it gets compiled.

This script modifies project.pbxproj by inserting new entries at
specific positions without modifying existing lines.
"""

import os
import uuid
import sys


def main():
    proj_path = 'ios/Runner.xcodeproj/project.pbxproj'

    if not os.path.exists(proj_path):
        print(f"ERROR: {proj_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(proj_path, 'r') as f:
        lines = f.readlines()

    # Check if already added
    if any('CoreMLPlugin.swift' in line for line in lines):
        print('CoreMLPlugin.swift already in Xcode project')
        return

    file_ref_id = uuid.uuid4().hex[:24].upper()
    build_file_id = uuid.uuid4().hex[:24].upper()

    new_lines = []
    in_pbxbuildfile = False
    in_pbxfileref = False
    in_group = False
    in_sources = False
    in_xcbuildconfig = False

    for i, line in enumerate(lines):
        # Track which section we're in
        if '/* Begin PBXBuildFile section */' in line:
            in_pbxbuildfile = True
        elif '/* End PBXBuildFile section */' in line:
            in_pbxbuildfile = False
        elif '/* Begin PBXFileReference section */' in line:
            in_pbxfileref = True
        elif '/* End PBXFileReference section */' in line:
            in_pbxfileref = False

        new_lines.append(line)

        # Step 1: Add to PBXFileReference section (after Runner-Bridging-Header.h entry)
        if in_pbxfileref and 'Runner-Bridging-Header.h' in line:
            file_ref_entry = (
                f'\t\t{file_ref_id} /* CoreMLPlugin.swift */ = '
                f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                f'path = CoreMLPlugin.swift; sourceTree = "<group>"; }};\n'
            )
            new_lines.append(file_ref_entry)

        # Step 2: Add to PBXBuildFile section (after AppDelegate.swift in Sources entry)
        if in_pbxbuildfile and 'AppDelegate.swift' in line and 'PBXBuildFile' in line:
            build_file_entry = (
                f'\t\t{build_file_id} /* CoreMLPlugin.swift in Sources */ = '
                f'{{isa = PBXBuildFile; fileRef = {file_ref_id} /* CoreMLPlugin.swift */; }};\n'
            )
            new_lines.append(build_file_entry)

        # Step 3: Add file ref to Runner group children
        # After the line ending with 'Runner-Bridging-Header.h */,' (group children entry)
        if line.strip().endswith('/* Runner-Bridging-Header.h */,'):
            group_entry = f'\t\t\t\t{file_ref_id} /* CoreMLPlugin.swift */,\n'
            new_lines.append(group_entry)

        # Step 4: Add build file to PBXSourcesBuildPhase
        # After the line ending with 'SceneDelegate.swift in Sources */,'
        if line.strip().endswith('/* SceneDelegate.swift in Sources */,'):
            source_entry = f'\t\t\t\t\t{build_file_id} /* CoreMLPlugin.swift in Sources */,\n'
            new_lines.append(source_entry)

    with open(proj_path, 'w') as f:
        f.writelines(new_lines)

    print(f'Added CoreMLPlugin.swift to Xcode project')
    print(f'  File ref: {file_ref_id}')
    print(f'  Build file: {build_file_id}')


if __name__ == '__main__':
    main()