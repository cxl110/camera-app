#!/usr/bin/env python3
"""Remove the Flutter Swift Package Manager integration from the Xcode project.

The project was originally migrated from SPM to CocoaPods, but the
`FlutterGeneratedPluginSwiftPackage` references were left behind in
project.pbxproj. `flutter config --no-enable-swift-package-manager` only
changes the tool's behaviour — it does NOT touch the Xcode project, so Xcode
keeps resolving the generated Swift package and links the OLD plugin set
alongside the CocoaPods one. The result is duplicated/stale plugins in the
shipped app (including permission_handler_apple, which is the only piece of
code in the graph with location capability).

This script removes the SPM wiring so the app contains exactly the plugins
that the current pubspec.yaml declares.

Usage:  python scripts/remove_spm_from_xcode.py
"""

import os
import re
import sys

PACKAGE_NAME = 'FlutterGeneratedPluginSwiftPackage'

# Lines that mention the generated package and have to disappear entirely.
DROP_LINE_RE = re.compile(
    r'^\s*\w{24} /\* ' + PACKAGE_NAME + r'( in Frameworks)? \*/'
    r'(,| = \{isa = PBXBuildFile;| = \{isa = PBXFileReference;)'
)
DROP_BLOCK_ISA = ('XCLocalSwiftPackageReference', 'XCSwiftPackageProductDependency')


def _drop_blocks(lines):
    """Remove whole object blocks of the given isa types.

    The block header carries the name (`/* XCLocalSwiftPackageReference
    "FlutterGeneratedPluginSwiftPackage" */ = {`) while the `isa` sits on the
    next line, so both have to be looked at.
    """
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r'^\t\t\w{24} /\* .*' + PACKAGE_NAME + r'.*\*/ = \{$', line.rstrip('\n')):
            # find the end of the block and check its isa
            j = i
            while j < len(lines) and not re.match(r'^\t\t\};$', lines[j].rstrip('\n')):
                j += 1
            body = ''.join(lines[i + 1:j + 1])
            if any(f'isa = {isa};' in body for isa in DROP_BLOCK_ISA):
                i = j + 1
                continue
        out.append(line)
        i += 1
    return out


def _drop_empty_sections(lines):
    """Remove Begin/End markers of sections that ended up empty."""
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r'^\/\* Begin (\w+) section \*\/\n$', lines[i])
        if m and m.group(1) in DROP_BLOCK_ISA:
            isa = m.group(1)
            j = i + 1
            while j < len(lines) and f'/* End {isa} section */' not in lines[j]:
                j += 1
            if j < len(lines):
                body = ''.join(lines[i + 1:j])
                if not body.strip():
                    i = j + 1
                    continue
        out.append(lines[i])
        i += 1
    return out


def _drop_package_lists(lines):
    """Remove the packageReferences / packageProductDependencies entries."""
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r'^\s*(packageReferences|packageProductDependencies) = \($', line.rstrip('\n')):
            # copy the ( ... ); block, minus the package entries
            out.append(line)
            i += 1
            while i < len(lines) and lines[i].strip() != ');':
                if PACKAGE_NAME not in lines[i]:
                    out.append(lines[i])
                i += 1
            out.append(lines[i])  # the ');' line
            i += 1
            continue
        out.append(line)
        i += 1
    return out


def remove_spm(proj_path):
    with open(proj_path, 'r') as f:
        lines = f.readlines()

    if not any(PACKAGE_NAME in line for line in lines):
        print('No SPM integration found — nothing to do')
        return True

    before = sum(1 for line in lines if PACKAGE_NAME in line)
    lines = _drop_blocks(lines)
    lines = _drop_package_lists(lines)
    lines = [line for line in lines
             if not (PACKAGE_NAME in line and
                     (DROP_LINE_RE.match(line) or
                      re.match(r'^\s*\w{24} /\* ' + PACKAGE_NAME + r' \*/,$', line)))]
    lines = _drop_empty_sections(lines)
    after = sum(1 for line in lines if PACKAGE_NAME in line)

    with open(proj_path, 'w') as f:
        f.writelines(lines)

    print(f'Removed SPM integration ({before} -> {after} references)')
    if after:
        print('WARNING: some references remain, check the project manually:')
        for i, line in enumerate(lines):
            if PACKAGE_NAME in line:
                print(f'   {i + 1}: {line.rstrip()}')
    return after == 0


def main():
    proj_path = 'ios/Runner.xcodeproj/project.pbxproj'
    if not os.path.exists(proj_path):
        print(f'ERROR: {proj_path} not found (run from the project root)',
              file=sys.stderr)
        sys.exit(1)
    if not remove_spm(proj_path):
        sys.exit(1)


if __name__ == '__main__':
    main()
