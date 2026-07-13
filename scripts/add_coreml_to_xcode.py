#!/usr/bin/env python3
"""Add CoreMLPlugin.swift to Xcode project so it gets compiled."""

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

    # 1. Add to PBXFileReference section
    file_ref = (
        f'\t\t{file_ref_id} /* CoreMLPlugin.swift */ = '
        f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        f'path = CoreMLPlugin.swift; sourceTree = "<group>"; }};\n'
    )
    content = content.replace(
        '/* End PBXFileReference section */',
        file_ref + '\t\t/* End PBXFileReference section */'
    )

    # 2. Add to PBXBuildFile section
    build_file = (
        f'\t\t{build_file_id} /* CoreMLPlugin.swift in Sources */ = '
        f'{{isa = PBXBuildFile; fileRef = {file_ref_id} /* CoreMLPlugin.swift */; }};\n'
    )
    content = content.replace(
        '/* End PBXBuildFile section */',
        build_file + '\t\t/* End PBXBuildFile section */'
    )

    # 3. Add to Runner group (after AppDelegate.swift reference)
    content = content.replace(
        'AppDelegate.swift',
        f'AppDelegate.swift,\n\t\t\t\t{file_ref_id} /* CoreMLPlugin.swift */,',
        1
    )

    # 4. Add to Sources build phase
    pattern = r'/\* Begin PBXSourcesBuildPhase section \*/\n(.*?)\n\t\t\t/\* End PBXSourcesBuildPhase section \*/'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        section_content = match.group(1)
        # Find the first '(' in the section (the files array)
        paren_index = section_content.find('(')
        if paren_index >= 0:
            insertion = f'\n\t\t\t\t\t{build_file_id} /* CoreMLPlugin.swift in Sources */,'
            section_content = section_content[:paren_index + 1] + insertion + section_content[paren_index + 1:]
            content = content[:match.start(1)] + section_content + content[match.end(1):]

    with open(proj_path, 'w') as f:
        f.write(content)

    print(f'Added CoreMLPlugin.swift to Xcode project')
    print(f'  File ref: {file_ref_id}')
    print(f'  Build file: {build_file_id}')

if __name__ == '__main__':
    main()