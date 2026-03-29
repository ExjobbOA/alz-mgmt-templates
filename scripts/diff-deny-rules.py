#!/usr/bin/env python3
"""
diff-deny-rules.py — Generate a side-by-side HTML diff report for ALZ policy rule mismatches.

Compares policy rules in a brownfield export against the ALZ library JSON files.
By default shows only Deny-effect mismatches (use --all to see everything).

Usage:
    python3 scripts/diff-deny-rules.py \
        --export state-snapshots/state-sylaviken-brownfield.json \
        --library templates/core/governance/lib/alz \
        --output deny-diff-report.html
"""

import json
import difflib
import argparse
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def sort_json(obj):
    """Recursively sort dict keys so property ordering doesn't cause false diffs."""
    if isinstance(obj, dict):
        return {k: sort_json(v) for k, v in sorted(obj.items())}
    if isinstance(obj, list):
        return [sort_json(i) for i in obj]
    return obj


def normalize_arm_expressions(text: str) -> str:
    """
    Normalize ARM template expression escaping.
    Library JSON uses [[parameters( (escaped for ARM), Azure API returns [parameters(.
    Strip the leading extra [ so both sides compare equal.
    """
    return re.sub(r'\[\[', '[', text)


def pretty(obj) -> str:
    """Serialize + normalize a policy rule object to a consistent string."""
    s = json.dumps(sort_json(obj), indent=2)
    return normalize_arm_expressions(s)


def extract_effect(policy_rule_obj) -> str:
    """
    Extract effect from a library policy rule object.
    Checks policyRule.then.effect first, then parameters.effect.defaultValue.
    Returns lowercase string or '' if not found.
    """
    if not isinstance(policy_rule_obj, dict):
        return ''
    props = policy_rule_obj.get('properties', policy_rule_obj)
    pr = props.get('policyRule', {})
    then = pr.get('then', {})
    effect = then.get('effect', '')
    if effect and not effect.startswith('['):
        return effect.lower()
    # Parameterized effect — check default value
    params = props.get('parameters', {})
    effect_param = params.get('effect', {})
    default_val = effect_param.get('defaultValue', '')
    return default_val.lower() if default_val else ''


def load_library(library_path: Path) -> dict:
    """
    Load all *.alz_policy_definition.json files from the library directory.
    Returns a dict keyed by policy name.
    """
    lib = {}
    for f in library_path.rglob('*.alz_policy_definition.json'):
        try:
            obj = json.loads(f.read_text(encoding='utf-8'))
            name = obj.get('name', f.stem)
            lib[name] = obj
        except Exception as e:
            print(f'[WARN] Could not load {f}: {e}', file=sys.stderr)
    return lib


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

HTML_HEAD = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ALZ Policy Rule Diff Report</title>
<style>
  body {{ font-family: monospace; font-size: 13px; margin: 20px; background: #1e1e1e; color: #d4d4d4; }}
  h1 {{ font-size: 18px; color: #9cdcfe; }}
  h2 {{ font-size: 14px; color: #ce9178; margin-top: 40px; border-top: 1px solid #444; padding-top: 10px; }}
  .meta {{ color: #888; margin-bottom: 6px; }}
  .meta span {{ color: #d4d4d4; }}
  a {{ color: #4ec9b0; }}
  table.diff {{ width: 100%; border-collapse: collapse; }}
  table.diff td {{ padding: 2px 6px; vertical-align: top; white-space: pre-wrap; word-break: break-all; }}
  table.diff .diff_header {{ background: #2d2d2d; color: #888; font-size: 11px; }}
  table.diff .diff_next {{ background: #2d2d2d; color: #888; }}
  .diff_add  {{ background: #1a3a1a; color: #b5cea8; }}
  .diff_chg  {{ background: #3a3a1a; color: #dcdcaa; }}
  .diff_sub  {{ background: #3a1a1a; color: #f44747; }}
  #toc {{ background: #252526; padding: 12px 20px; border-radius: 4px; margin-bottom: 30px; }}
  #toc h2 {{ border: none; margin-top: 0; color: #9cdcfe; }}
  #toc ul {{ margin: 0; padding-left: 20px; }}
  #toc li {{ margin: 3px 0; }}
  .badge {{ display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 11px; margin-left: 6px; }}
  .badge-deny {{ background: #6b1a1a; color: #f44747; }}
  .badge-assigned {{ background: #4b1a1a; color: #f88070; }}
</style>
</head>
<body>
<h1>ALZ Policy Rule Diff Report</h1>
<p class="meta">Generated for brownfield export: <span>{export_file}</span></p>
<p class="meta">ALZ library: <span>{library_path}</span></p>
<p class="meta">Policies shown: <span>{count}</span> Deny-effect rule mismatches</p>
"""

HTML_TOC_ENTRY = '  <li><a href="#{anchor}">{name}</a>{badge} &mdash; {display_name} &mdash; version: brownfield <span>{bf_ver}</span> / library <span>{lib_ver}</span></li>\n'

HTML_SECTION = """\
<h2 id="{anchor}">{name}{badge}</h2>
<div class="meta">Display name: <span>{display_name}</span></div>
<div class="meta">Effect: <span>{effect}</span> &nbsp;|&nbsp; Targets: <span>{targets}</span></div>
<div class="meta">Version: brownfield <span>{bf_ver}</span> &rarr; library <span>{lib_ver}</span></div>
{diff_table}
"""

HTML_FOOT = """\
</body>
</html>
"""


def make_anchor(name: str) -> str:
    return re.sub(r'[^a-zA-Z0-9_-]', '-', name)


def make_badge(assigned: bool) -> str:
    if assigned:
        return '<span class="badge badge-assigned">ASSIGNED</span>'
    return '<span class="badge badge-deny">deny</span>'


def build_html(entries: list, export_file: str, library_path: str) -> str:
    parts = [HTML_HEAD.format(
        export_file=export_file,
        library_path=library_path,
        count=len(entries),
    )]

    # Table of contents
    parts.append('<div id="toc"><h2>Table of Contents</h2><ul>\n')
    for e in entries:
        anchor = make_anchor(e['name'])
        badge = make_badge(e.get('assigned', False))
        parts.append(HTML_TOC_ENTRY.format(
            anchor=anchor,
            name=e['name'],
            badge=badge,
            display_name=e.get('display_name', ''),
            bf_ver=e.get('bf_version', '(unknown)'),
            lib_ver=e.get('lib_version', '(unknown)'),
        ))
    parts.append('</ul></div>\n')

    # Diff sections
    differ = difflib.HtmlDiff(wrapcolumn=100)
    for e in entries:
        anchor = make_anchor(e['name'])
        badge = make_badge(e.get('assigned', False))
        bf_lines = e['bf_rule_text'].splitlines()
        lib_lines = e['lib_rule_text'].splitlines()
        diff_table = differ.make_table(
            bf_lines, lib_lines,
            fromdesc='Brownfield (current)', todesc='ALZ Library (engine)',
        )
        parts.append(HTML_SECTION.format(
            anchor=anchor,
            name=e['name'],
            badge=badge,
            display_name=e.get('display_name', ''),
            effect=e.get('effect', ''),
            targets=e.get('targets', '(unknown)'),
            bf_ver=e.get('bf_version', '(unknown)'),
            lib_ver=e.get('lib_version', '(unknown)'),
            diff_table=diff_table,
        ))

    parts.append(HTML_FOOT)
    return ''.join(parts)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Generate HTML diff for ALZ policy rule mismatches.')
    parser.add_argument('--export',  required=True, help='Path to brownfield export JSON')
    parser.add_argument('--library', required=True, help='Path to ALZ library directory')
    parser.add_argument('--output',  required=True, help='Output HTML file path')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--deny-only',     dest='mode', action='store_const', const='deny',
                       help='Show only Deny-effect mismatches (default)')
    group.add_argument('--assigned-only', dest='mode', action='store_const', const='assigned',
                       help='Show only ASSIGNED Deny-effect mismatches')
    group.add_argument('--all',           dest='mode', action='store_const', const='all',
                       help='Show all rule mismatches regardless of effect')
    parser.set_defaults(mode='deny')
    args = parser.parse_args()

    export_path  = Path(args.export)
    library_path = Path(args.library)
    output_path  = Path(args.output)

    if not export_path.exists():
        print(f'[ERROR] Export not found: {export_path}', file=sys.stderr)
        sys.exit(1)
    if not library_path.exists():
        print(f'[ERROR] Library not found: {library_path}', file=sys.stderr)
        sys.exit(1)

    # Load export
    export = json.loads(export_path.read_text(encoding='utf-8'))

    # Collect assigned policy definition names from export
    assigned_names: set[str] = set()
    for scope_entry in export.get('ManagementGroupScopes', []):
        for a in scope_entry.get('PolicyAssignments', []):
            ref = a.get('PolicyDefinitionName') or a.get('PolicyDefinitionReferenceId') or ''
            if ref:
                assigned_names.add(ref)
            # Also pick up definition name from the assignment's definition reference
            def_id = a.get('PolicyDefinitionId', '')
            if def_id:
                assigned_names.add(def_id.split('/')[-1])

    # Load library
    print(f'Loading library from: {library_path}')
    lib = load_library(library_path)
    print(f'  {len(lib)} policy definitions loaded')

    # Collect all brownfield policy definitions across scopes
    bf_defs: dict = {}
    for scope_entry in export.get('ManagementGroupScopes', []):
        for d in scope_entry.get('PolicyDefinitions', []):
            name = d.get('Name', '')
            if name and name not in bf_defs:
                bf_defs[name] = d

    print(f'  {len(bf_defs)} policy definitions in brownfield export')

    # Build diff entries
    entries = []
    for name, bf_def in bf_defs.items():
        lib_def = lib.get(name)
        if not lib_def:
            continue  # Not in library — skip

        bf_hash  = bf_def.get('PolicyRuleHash', '')
        bf_rule  = bf_def.get('PolicyRule')

        # Compute library rule hash for comparison
        lib_props = lib_def.get('properties', lib_def)
        lib_rule  = lib_props.get('policyRule')
        if lib_rule is None:
            continue

        lib_rule_json = json.dumps(sort_json(lib_rule), separators=(',', ':'))
        lib_rule_json = normalize_arm_expressions(lib_rule_json)
        import hashlib
        lib_hash = hashlib.sha256(lib_rule_json.encode()).hexdigest()[:8]

        if bf_hash == lib_hash:
            continue  # No diff

        # Determine effect from library
        effect = extract_effect(lib_def)

        # Apply filter
        if args.mode == 'deny' and effect != 'deny':
            continue
        if args.mode == 'assigned':
            if effect != 'deny':
                continue
            if name not in assigned_names:
                continue

        # Extract metadata
        display_name = lib_props.get('displayName', bf_def.get('DisplayName', ''))
        bf_version   = bf_def.get('Version', '(unknown)')
        lib_version  = lib_props.get('metadata', {}).get('version', '(unknown)')

        # Extract target resource types from library policyRule.if
        rule_if  = lib_rule.get('if', {})
        all_of   = rule_if.get('allOf', rule_if.get('anyOf', []))
        types    = []
        for cond in all_of:
            if isinstance(cond, dict) and cond.get('field') == 'type':
                val = cond.get('equals') or cond.get('in', [])
                if isinstance(val, list):
                    types.extend(val)
                elif val:
                    types.append(val)
        targets = ', '.join(types) if types else '(not specified)'

        # Build rule text for diff
        if bf_rule:
            bf_rule_text = pretty(bf_rule)
        else:
            bf_rule_text = '(PolicyRule not captured in export — re-run Export-BrownfieldState.ps1)'

        lib_rule_text = pretty(lib_rule)

        entries.append({
            'name':          name,
            'display_name':  display_name,
            'effect':        effect,
            'targets':       targets,
            'bf_version':    bf_version,
            'lib_version':   lib_version,
            'bf_rule_text':  bf_rule_text,
            'lib_rule_text': lib_rule_text,
            'assigned':      name in assigned_names,
        })

    # Sort: assigned first, then alphabetical
    entries.sort(key=lambda e: (0 if e.get('assigned') else 1, e['name']))

    print(f'  {len(entries)} Deny-effect rule mismatches found (mode={args.mode})')

    if not entries:
        print('  Nothing to report.')
        sys.exit(0)

    html = build_html(entries, str(export_path), str(library_path))
    output_path.write_text(html, encoding='utf-8')
    print(f'Report written to: {output_path}')


if __name__ == '__main__':
    main()
