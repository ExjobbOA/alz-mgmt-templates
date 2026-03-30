#!/usr/bin/env python3
"""
diff-deny-rules.py — Generate a prioritized HTML diff report for ALZ policy rule mismatches.

Primary mode (--mismatch-info): Compare-BrownfieldState.ps1 passes a JSON file listing every
mismatched policy definition it found. Python just renders diffs — no own mismatch detection.
This eliminates PowerShell/Python JSON serialization divergence for complex DINE templates.

Fallback mode (no --mismatch-info): The script performs its own mismatch detection using
normalized text comparison. Use for standalone operation.

Tier structure (primary mode):
  Tier 1: Assigned Deny/DenyAction — Rule Changed         (highest risk, red)
  Tier 2: Assigned DINE/Modify/Append — Rule Changed      (medium risk, yellow)
  Tier 3: Assigned — No Rule Change after normalization    (false positive from hash, green note)
  Tier 4: Unassigned — Rule Changed                        (low risk, grey table)

Usage (primary — via Compare script):
    python3 scripts/diff-deny-rules.py \
        --export state-snapshots/state-sylaviken-brownfield.json \
        --library templates/core/governance/lib/alz \
        --output deny-diff-report.html \
        --mismatch-info /tmp/mismatches.json

Usage (fallback — standalone):
    python3 scripts/diff-deny-rules.py \
        --export state-snapshots/state-sylaviken-brownfield.json \
        --library templates/core/governance/lib/alz \
        --output deny-diff-report.html
"""

import json
import difflib
import argparse
import html as html_mod
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
    DINE policies with nested deployment templates can have [[[parameters( (three brackets).
    Replace any run of 2+ consecutive [ with a single [ so all levels normalize to one.
    """
    return re.sub(r'\[{2,}', '[', text)


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


def make_anchor(name: str) -> str:
    return re.sub(r'[^a-zA-Z0-9_-]', '-', name)


def effect_category(effect: str) -> str:
    """Map an effect string to a broad category."""
    e = effect.lower()
    if e in ('deny', 'denyaction'):
        return 'deny'
    if e == 'deployifnotexists':
        return 'dine'
    if e == 'modify':
        return 'modify'
    if e == 'append':
        return 'append'
    if e in ('audit', 'auditifnotexists'):
        return 'audit'
    return 'other'


# ---------------------------------------------------------------------------
# Diff rendering
# ---------------------------------------------------------------------------

def render_unified_diff(bf_text: str, lib_text: str) -> str:
    """Render a unified diff of two normalized rule texts as HTML."""
    bf_lines = bf_text.splitlines()
    lib_lines = lib_text.splitlines()
    diff = list(difflib.unified_diff(
        bf_lines, lib_lines,
        fromfile='Brownfield (current)',
        tofile='ALZ Library (engine)',
        lineterm='',
    ))
    if not diff:
        return '<div class="no-diff">No differences in normalized rule text.</div>'

    rows = []
    for line in diff:
        escaped = html_mod.escape(line)
        if line.startswith('+++') or line.startswith('---'):
            rows.append(f'<div class="dl-file">{escaped}</div>')
        elif line.startswith('@@'):
            rows.append(f'<div class="dl-hunk">{escaped}</div>')
        elif line.startswith('+'):
            rows.append(f'<div class="dl-add">{escaped}</div>')
        elif line.startswith('-'):
            rows.append(f'<div class="dl-del">{escaped}</div>')
        else:
            rows.append(f'<div class="dl-ctx">{escaped}</div>')

    return '<div class="diff-block"><pre class="diff-pre">' + '\n'.join(rows) + '</pre></div>'


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
  *, *::before, *::after {{ box-sizing: border-box; }}
  body {{
    font-family: 'Cascadia Code', 'JetBrains Mono', 'Fira Code', Consolas, monospace;
    font-size: 13px;
    margin: 0;
    padding: 24px 32px;
    background: #0d1117;
    color: #c9d1d9;
    line-height: 1.5;
  }}
  h1 {{ font-size: 20px; color: #58a6ff; margin-bottom: 4px; }}
  h2 {{ font-size: 14px; color: #58a6ff; margin-top: 0; margin-bottom: 12px; }}
  .meta-line {{ color: #8b949e; margin: 2px 0; font-size: 12px; }}
  .meta-line span {{ color: #c9d1d9; }}
  a {{ color: #58a6ff; text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}

  .summary-bar {{
    display: flex;
    gap: 20px;
    flex-wrap: wrap;
    margin: 16px 0 24px;
    padding: 12px 16px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    font-size: 13px;
  }}
  .sum-t1   {{ color: #f85149; font-weight: bold; }}
  .sum-t2   {{ color: #d29922; }}
  .sum-t3   {{ color: #7ee787; }}
  .sum-t4   {{ color: #8b949e; }}
  .sum-total {{ color: #6e7681; margin-left: auto; }}

  #toc {{
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 16px 20px;
    margin-bottom: 32px;
  }}
  #toc h2 {{ color: #58a6ff; font-size: 15px; margin-bottom: 12px; }}
  .toc-tier {{ margin-bottom: 16px; }}
  .toc-tier-header {{
    color: #8b949e;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    margin-bottom: 6px;
    padding-bottom: 4px;
    border-bottom: 1px solid #21262d;
  }}
  #toc ul {{ margin: 0; padding: 0; list-style: none; }}
  #toc li {{ margin: 4px 0; font-size: 12px; }}
  .toc-name {{ color: #58a6ff; }}
  .toc-dname {{ color: #8b949e; }}
  .toc-ver {{ color: #6e7681; font-size: 11px; }}

  .badge {{
    display: inline-block;
    padding: 1px 7px;
    border-radius: 12px;
    font-size: 10px;
    font-weight: bold;
    letter-spacing: 0.04em;
    margin-right: 4px;
    vertical-align: middle;
  }}
  .badge-assigned   {{ background: #3d1f1f; color: #f85149; border: 1px solid #6e1b1b; }}
  .badge-changed    {{ background: #3d2e00; color: #d29922; border: 1px solid #6e5400; }}
  .badge-safe       {{ background: #1a2d1a; color: #7ee787; border: 1px solid #2d5a2d; }}
  .badge-unassigned {{ background: #21262d; color: #8b949e; border: 1px solid #30363d; }}
  .badge-deny       {{ background: #3d1f1f; color: #f85149; border: 1px solid #6e1b1b; }}
  .badge-dine       {{ background: #3d2e00; color: #d29922; border: 1px solid #6e5400; }}
  .badge-modify     {{ background: #2d2d00; color: #c9c91a; border: 1px solid #5a5a00; }}
  .badge-append     {{ background: #1a2d3d; color: #58a6ff; border: 1px solid #1a4d7a; }}
  .badge-audit      {{ background: #1a2d1a; color: #7ee787; border: 1px solid #2d5a2d; }}
  .badge-other      {{ background: #21262d; color: #8b949e; border: 1px solid #30363d; }}

  .card {{
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 16px 20px;
    margin-bottom: 20px;
  }}
  .card-title {{ font-size: 14px; font-weight: bold; color: #c9d1d9; margin-bottom: 8px; }}
  .card-meta {{ color: #8b949e; font-size: 12px; margin: 3px 0; }}
  .card-meta span {{ color: #c9d1d9; }}
  .card-note {{
    margin-top: 10px;
    padding: 8px 12px;
    background: #1c2a1c;
    border: 1px solid #2d5a2d;
    border-radius: 4px;
    color: #7ee787;
    font-size: 12px;
  }}

  .tier-header {{ margin: 32px 0 12px; padding-bottom: 8px; border-bottom: 1px solid #30363d; }}
  .tier-header h2 {{ font-size: 15px; color: #c9d1d9; margin: 0 0 4px; }}
  .tier-header p {{ color: #8b949e; font-size: 12px; margin: 0; }}

  .diff-block {{ margin-top: 12px; border: 1px solid #30363d; border-radius: 4px; overflow: hidden; }}
  .diff-pre {{
    margin: 0;
    padding: 0;
    font-size: 12px;
    line-height: 1.4;
    overflow-x: auto;
    background: #0d1117;
  }}
  .diff-pre div {{ padding: 1px 12px; white-space: pre; }}
  .dl-file {{ background: #161b22; color: #8b949e; }}
  .dl-hunk {{ background: #1c2233; color: #6e90c0; }}
  .dl-add  {{ background: #1a3a1a; color: #7ee787; }}
  .dl-del  {{ background: #3a1a1a; color: #f85149; }}
  .dl-ctx  {{ background: #0d1117; color: #c9d1d9; }}
  .no-diff {{
    padding: 8px 12px;
    color: #7ee787;
    font-size: 12px;
    background: #1c2a1c;
    border-radius: 4px;
    margin-top: 8px;
  }}

  .t4-table {{ width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 8px; }}
  .t4-table th {{
    text-align: left;
    padding: 6px 10px;
    color: #8b949e;
    border-bottom: 1px solid #30363d;
    font-weight: normal;
  }}
  .t4-table td {{ padding: 4px 10px; border-bottom: 1px solid #21262d; color: #c9d1d9; }}
  .t4-table td:last-child {{ color: #8b949e; }}
</style>
</head>
<body>
<h1>ALZ Policy Rule Diff Report</h1>
<p class="meta-line">Brownfield export: <span>{export_file}</span></p>
<p class="meta-line">ALZ library: <span>{library_path}</span></p>
"""

HTML_FOOT = "</body>\n</html>\n"

EFFECT_RISK_NOTES = {
    'deployifnotexists': 'May trigger remediation tasks on existing resources when enforcement mode is active.',
    'modify':            'May change resource properties on the next policy evaluation cycle.',
    'append':            'Adds properties to resources on next update. No immediate impact on existing resources.',
    'audit':             'Informational only — no resource changes.',
    'auditifnotexists':  'Informational only — no resource changes.',
}


def effect_badge_class(effect: str) -> str:
    cat = effect_category(effect)
    return f'badge-{cat}' if cat in ('deny', 'dine', 'modify', 'append', 'audit') else 'badge-other'


def build_html(tier1: list, tier2: list, tier3: list, tier4: list,
               export_file: str, library_path: str) -> str:
    total = len(tier1) + len(tier2) + len(tier3) + len(tier4)
    parts = [HTML_HEAD.format(
        export_file=html_mod.escape(export_file),
        library_path=html_mod.escape(library_path),
    )]

    # Summary bar
    parts.append(
        f'<div class="summary-bar">'
        f'<span class="sum-t1">{len(tier1)} assigned Deny — rule changed</span>'
        f'<span class="sum-t2">{len(tier2)} assigned DINE/Modify — rule changed</span>'
        f'<span class="sum-t3">{len(tier3)} assigned — no rule change (normalization)</span>'
        f'<span class="sum-t4">{len(tier4)} unassigned</span>'
        f'<span class="sum-total">{total} total mismatches</span>'
        f'</div>\n'
    )

    # TOC
    parts.append('<div id="toc"><h2>Table of Contents</h2>\n')

    if tier1:
        parts.append('<div class="toc-tier"><div class="toc-tier-header">Tier 1 — Assigned Deny · Rule Changed</div><ul>\n')
        for e in tier1:
            anchor = make_anchor(e['name'])
            effect_label = e.get('effect', 'DENY').upper()
            badge_cls = effect_badge_class(e.get('effect', ''))
            parts.append(
                f'  <li>'
                f'<span class="badge badge-assigned">ASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'<a href="#{anchor}" class="toc-name">{html_mod.escape(e["name"])}</a> '
                f'<span class="toc-dname">— {html_mod.escape(e.get("display_name", ""))}</span> '
                f'<span class="toc-ver">{html_mod.escape(e.get("bf_version", "?"))} &rarr; {html_mod.escape(e.get("lib_version", "?"))}</span>'
                f'</li>\n'
            )
        parts.append('</ul></div>\n')

    if tier2:
        parts.append('<div class="toc-tier"><div class="toc-tier-header">Tier 2 — Assigned DINE / Modify · Rule Changed</div><ul>\n')
        for e in tier2:
            anchor = make_anchor(e['name'])
            effect_label = e.get('effect', '').upper()
            badge_cls = effect_badge_class(e.get('effect', ''))
            parts.append(
                f'  <li>'
                f'<span class="badge badge-assigned">ASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'<a href="#{anchor}" class="toc-name">{html_mod.escape(e["name"])}</a> '
                f'<span class="toc-dname">— {html_mod.escape(e.get("display_name", ""))}</span> '
                f'<span class="toc-ver">{html_mod.escape(e.get("bf_version", "?"))} &rarr; {html_mod.escape(e.get("lib_version", "?"))}</span>'
                f'</li>\n'
            )
        parts.append('</ul></div>\n')

    if tier3:
        parts.append('<div class="toc-tier"><div class="toc-tier-header">Tier 3 — Assigned · No Rule Change (normalization)</div><ul>\n')
        for e in tier3:
            anchor = make_anchor(e['name'])
            effect_label = e.get('effect', '').upper()
            badge_cls = effect_badge_class(e.get('effect', ''))
            parts.append(
                f'  <li>'
                f'<span class="badge badge-assigned">ASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'<span class="badge badge-safe">NO CHANGE</span>'
                f'<a href="#{anchor}" class="toc-name">{html_mod.escape(e["name"])}</a> '
                f'<span class="toc-dname">— {html_mod.escape(e.get("display_name", ""))}</span>'
                f'</li>\n'
            )
        parts.append('</ul></div>\n')

    if tier4:
        parts.append('<div class="toc-tier"><div class="toc-tier-header">Tier 4 — Unassigned (no current risk)</div><ul>\n')
        for e in tier4:
            anchor = make_anchor(e['name'])
            effect_label = e.get('effect', '').upper()
            badge_cls = effect_badge_class(e.get('effect', ''))
            parts.append(
                f'  <li>'
                f'<span class="badge badge-unassigned">UNASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'<a href="#{anchor}" class="toc-name">{html_mod.escape(e["name"])}</a> '
                f'<span class="toc-dname">— {html_mod.escape(e.get("display_name", ""))}</span> '
                f'<span class="toc-ver">{html_mod.escape(e.get("bf_version", "?"))} &rarr; {html_mod.escape(e.get("lib_version", "?"))}</span>'
                f'</li>\n'
            )
        parts.append('</ul></div>\n')

    parts.append('</div>\n')  # end #toc

    # --- Tier 1: Assigned Deny, rule changed ---
    if tier1:
        parts.append(
            '<div class="tier-header">'
            '<h2>Tier 1 — Assigned Deny · Rule Changed</h2>'
            '<p>These Deny/DenyAction policies are actively assigned and have real rule differences. '
            'Review resource compliance before deploying the engine version.</p>'
            '</div>\n'
        )
        for e in tier1:
            anchor = make_anchor(e['name'])
            effect_label = e.get('effect', 'deny').upper()
            badge_cls = effect_badge_class(e.get('effect', ''))
            diff_html = render_unified_diff(e['bf_rule_text'], e['lib_rule_text'])
            parts.append(
                f'<div class="card" id="{anchor}" style="border-color:#6e1b1b">'
                f'<div class="card-title">'
                f'<span class="badge badge-assigned">ASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'{html_mod.escape(e["name"])}'
                f'</div>'
                f'<div class="card-meta">Display name: <span>{html_mod.escape(e.get("display_name", ""))}</span></div>'
                f'<div class="card-meta">Targets: <span>{html_mod.escape(e.get("targets", ""))}</span></div>'
                f'<div class="card-meta">Version: <span>{html_mod.escape(e.get("bf_version", "?"))}</span>'
                f' &rarr; <span>{html_mod.escape(e.get("lib_version", "?"))}</span></div>'
                f'{diff_html}'
                f'</div>\n'
            )

    # --- Tier 2: Assigned DINE/Modify/other, rule changed ---
    if tier2:
        parts.append(
            '<div class="tier-header">'
            '<h2>Tier 2 — Assigned DINE / Modify · Rule Changed</h2>'
            '<p>These policies are assigned with non-Deny effects and have real rule differences. '
            'They will not block resources but may trigger remediations or modify properties. '
            'Review at your own pace before deploying.</p>'
            '</div>\n'
        )
        for e in tier2:
            anchor = make_anchor(e['name'])
            effect = e.get('effect', '')
            effect_label = effect.upper()
            badge_cls = effect_badge_class(effect)
            note = EFFECT_RISK_NOTES.get(effect.lower(), 'Review before deploying.')
            diff_html = render_unified_diff(e['bf_rule_text'], e['lib_rule_text'])
            parts.append(
                f'<div class="card" id="{anchor}" style="border-color:#6e5400">'
                f'<div class="card-title">'
                f'<span class="badge badge-assigned">ASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'{html_mod.escape(e["name"])}'
                f'</div>'
                f'<div class="card-meta">Display name: <span>{html_mod.escape(e.get("display_name", ""))}</span></div>'
                f'<div class="card-meta">Targets: <span>{html_mod.escape(e.get("targets", ""))}</span></div>'
                f'<div class="card-meta">Version: <span>{html_mod.escape(e.get("bf_version", "?"))}</span>'
                f' &rarr; <span>{html_mod.escape(e.get("lib_version", "?"))}</span></div>'
                f'<div class="card-note" style="background:#2a2000; border-color:#6e5400; color:#d29922">{html_mod.escape(note)}</div>'
                f'{diff_html}'
                f'</div>\n'
            )

    # --- Tier 3: Assigned, no rule change after normalization ---
    if tier3:
        parts.append(
            '<div class="tier-header">'
            '<h2>Tier 3 — Assigned · No Rule Change</h2>'
            '<p>Compare flagged these as mismatches (hash difference), but the normalized rule text '
            'is identical. This is a serialization artifact — no real rule difference exists. '
            'No action needed.</p>'
            '</div>\n'
        )
        for e in tier3:
            anchor = make_anchor(e['name'])
            effect_label = e.get('effect', '').upper()
            badge_cls = effect_badge_class(e.get('effect', ''))
            parts.append(
                f'<div class="card" id="{anchor}">'
                f'<div class="card-title">'
                f'<span class="badge badge-assigned">ASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'<span class="badge badge-safe">NO CHANGE</span>'
                f'{html_mod.escape(e["name"])}'
                f'</div>'
                f'<div class="card-meta">Display name: <span>{html_mod.escape(e.get("display_name", ""))}</span></div>'
                f'<div class="card-meta">Version: <span>{html_mod.escape(e.get("bf_version", "?"))}</span>'
                f' &rarr; <span>{html_mod.escape(e.get("lib_version", "?"))}</span></div>'
                f'<div class="card-note">No rule logic change detected after normalization. '
                f'The hash difference is a serialization artifact only.</div>'
                f'</div>\n'
            )

    # --- Tier 4: Unassigned, diff cards ---
    if tier4:
        parts.append(
            '<div class="tier-header">'
            '<h2>Tier 4 — Unassigned</h2>'
            '<p>These definitions are not currently assigned — no operational risk. '
            'The engine will overwrite them on deploy. Diffs shown for reference.</p>'
            '</div>\n'
        )
        for e in tier4:
            anchor = make_anchor(e['name'])
            effect = e.get('effect', '')
            effect_label = effect.upper()
            badge_cls = effect_badge_class(effect)
            note = EFFECT_RISK_NOTES.get(effect.lower(), 'Review before deploying.')
            diff_html = render_unified_diff(e['bf_rule_text'], e['lib_rule_text'])
            parts.append(
                f'<div class="card" id="{anchor}" style="opacity:0.75">'
                f'<div class="card-title">'
                f'<span class="badge badge-unassigned">UNASSIGNED</span>'
                f'<span class="badge {badge_cls}">{html_mod.escape(effect_label)}</span>'
                f'{html_mod.escape(e["name"])}'
                f'</div>'
                f'<div class="card-meta">Display name: <span>{html_mod.escape(e.get("display_name", ""))}</span></div>'
                f'<div class="card-meta">Targets: <span>{html_mod.escape(e.get("targets", ""))}</span></div>'
                f'<div class="card-meta">Version: <span>{html_mod.escape(e.get("bf_version", "?"))}</span>'
                f' &rarr; <span>{html_mod.escape(e.get("lib_version", "?"))}</span></div>'
                f'<div class="card-note" style="background:#1e2228; border-color:#30363d; color:#8b949e">'
                f'Not assigned — no current impact. {html_mod.escape(note)}</div>'
                f'{diff_html}'
                f'</div>\n'
            )

    parts.append(HTML_FOOT)
    return ''.join(parts)


# ---------------------------------------------------------------------------
# Entry builders
# ---------------------------------------------------------------------------

def build_entry_from_mismatch(mismatch: dict, bf_defs: dict, lib: dict) -> dict | None:
    """
    Build a diff entry from a Compare-supplied mismatch record.
    Returns None if the policy isn't found in lib (e.g. NonStandard classified by Compare).
    """
    name = mismatch.get('Name', '')
    if not name:
        return None

    lib_def = lib.get(name)
    if not lib_def:
        return None  # Not an ALZ library policy

    bf_def = bf_defs.get(name)
    lib_props = lib_def.get('properties', lib_def)
    lib_rule = lib_props.get('policyRule')
    if lib_rule is None:
        return None

    # Effect: prefer what Compare computed (already resolved parameterized effects)
    effect = mismatch.get('Effect', '') or extract_effect(lib_def)
    effect = effect.lower() if effect else ''

    display_name = mismatch.get('DisplayName') or lib_props.get('displayName', bf_def.get('DisplayName', '') if bf_def else '')
    bf_version   = mismatch.get('Version') or (bf_def.get('Version', '(unknown)') if bf_def else '(unknown)')
    lib_version  = lib_props.get('metadata', {}).get('version', '(unknown)')
    is_assigned  = bool(mismatch.get('IsAssigned', False))

    # Extract target resource types from library policyRule.if
    rule_if = lib_rule.get('if', {})
    all_of  = rule_if.get('allOf', rule_if.get('anyOf', []))
    types   = []
    for cond in all_of:
        if isinstance(cond, dict) and cond.get('field') == 'type':
            val = cond.get('equals') or cond.get('in', [])
            if isinstance(val, list):
                types.extend(val)
            elif val:
                types.append(val)
    targets = ', '.join(types) if types else '(not specified)'

    # Build normalized rule text for diff rendering
    bf_rule = bf_def.get('PolicyRule') if bf_def else None
    if bf_rule:
        bf_rule_text = pretty(bf_rule)
    else:
        bf_rule_text = '(PolicyRule not captured in export — re-run Export-BrownfieldState.ps1)'

    lib_rule_text = pretty(lib_rule)
    rule_changed  = (bf_rule_text != lib_rule_text)

    return {
        'name':          name,
        'display_name':  display_name,
        'effect':        effect,
        'targets':       targets,
        'bf_version':    str(bf_version),
        'lib_version':   str(lib_version),
        'bf_rule_text':  bf_rule_text,
        'lib_rule_text': lib_rule_text,
        'assigned':      is_assigned,
        'rule_changed':  rule_changed,
    }


# ---------------------------------------------------------------------------
# Main — primary path (--mismatch-info)
# ---------------------------------------------------------------------------

def main_with_mismatch_info(args, export_path, library_path, output_path):
    mismatch_path = Path(args.mismatch_info)
    if not mismatch_path.exists():
        print(f'[ERROR] Mismatch info file not found: {mismatch_path}', file=sys.stderr)
        sys.exit(1)

    mismatches = json.loads(mismatch_path.read_text(encoding='utf-8'))
    # ConvertTo-Json wraps a single-item array as an object — normalise
    if isinstance(mismatches, dict):
        mismatches = [mismatches]
    if not isinstance(mismatches, list):
        mismatches = []

    print(f'Loading library from: {library_path}')
    lib = load_library(library_path)
    print(f'  {len(lib)} policy definitions loaded')

    # Collect brownfield definitions for rule text lookup
    export = json.loads(export_path.read_text(encoding='utf-8'))
    bf_defs: dict = {}
    for scope_entry in export.get('Scopes', export.get('ManagementGroupScopes', [])):
        for d in scope_entry.get('Resources', scope_entry).get('PolicyDefinitions', []):
            name = d.get('Name', '')
            if name and name not in bf_defs:
                bf_defs[name] = d

    print(f'  {len(bf_defs)} policy definitions in brownfield export')
    print(f'  {len(mismatches)} mismatches reported by Compare script')

    tier1, tier2, tier3, tier4 = [], [], [], []

    for m in mismatches:
        entry = build_entry_from_mismatch(m, bf_defs, lib)
        if entry is None:
            continue

        cat = effect_category(entry['effect'])
        is_assigned  = entry['assigned']
        rule_changed = entry['rule_changed']

        if is_assigned:
            if not rule_changed:
                tier3.append(entry)
            elif cat == 'deny':
                tier1.append(entry)
            else:
                tier2.append(entry)
        else:
            tier4.append(entry)

    tier1.sort(key=lambda e: e['name'])
    tier2.sort(key=lambda e: (e['effect'], e['name']))
    tier3.sort(key=lambda e: e['name'])
    tier4.sort(key=lambda e: (e['effect'], e['name']))

    print(f'  Tier 1 (assigned Deny, rule changed):              {len(tier1)}')
    print(f'  Tier 2 (assigned DINE/Modify, rule changed):       {len(tier2)}')
    print(f'  Tier 3 (assigned, no rule change after normalize): {len(tier3)}')
    print(f'  Tier 4 (unassigned):                               {len(tier4)}')

    if not any([tier1, tier2, tier3, tier4]):
        print('  Nothing to report.')
        sys.exit(0)

    output = build_html(tier1, tier2, tier3, tier4, str(export_path), str(library_path))
    output_path.write_text(output, encoding='utf-8')
    print(f'Report written to: {output_path}')


# ---------------------------------------------------------------------------
# Main — fallback path (standalone, no --mismatch-info)
# ---------------------------------------------------------------------------

def main_standalone(args, export_path, library_path, output_path):
    export = json.loads(export_path.read_text(encoding='utf-8'))

    # Collect assigned policy definition names from export
    assigned_names: set[str] = set()
    psets: dict[str, list[str]] = {}

    for scope_entry in export.get('Scopes', export.get('ManagementGroupScopes', [])):
        resources = scope_entry.get('Resources', scope_entry)
        for ps in resources.get('PolicySetDefinitions', []):
            ps_name = ps.get('Name', '')
            members = [m.split('/')[-1] for m in ps.get('PolicyDefinitions', []) if m]
            if ps_name and members:
                psets[ps_name] = members
        for a in resources.get('PolicyAssignments', []):
            def_id = a.get('PolicyDefinitionId', '')
            if def_id:
                assigned_names.add(def_id.split('/')[-1])

    for name in list(assigned_names):
        for member_id in psets.get(name, []):
            assigned_names.add(member_id.split('/')[-1])

    print(f'Loading library from: {library_path}')
    lib = load_library(library_path)
    print(f'  {len(lib)} policy definitions loaded')

    bf_defs: dict = {}
    for scope_entry in export.get('Scopes', export.get('ManagementGroupScopes', [])):
        for d in scope_entry.get('Resources', scope_entry).get('PolicyDefinitions', []):
            name = d.get('Name', '')
            if name and name not in bf_defs:
                bf_defs[name] = d

    print(f'  {len(bf_defs)} policy definitions in brownfield export')

    entries = []
    for name, bf_def in bf_defs.items():
        lib_def = lib.get(name)
        if not lib_def:
            continue

        bf_rule = bf_def.get('PolicyRule')
        lib_props = lib_def.get('properties', lib_def)
        lib_rule  = lib_props.get('policyRule')
        if lib_rule is None:
            continue

        bf_rule_text_cmp = pretty(bf_rule) if bf_rule else ''
        lib_rule_text_cmp = pretty(lib_rule)
        if bf_rule_text_cmp == lib_rule_text_cmp:
            continue

        effect = extract_effect(lib_def)
        display_name = lib_props.get('displayName', bf_def.get('DisplayName', ''))
        bf_version   = bf_def.get('Version', '(unknown)')
        lib_version  = lib_props.get('metadata', {}).get('version', '(unknown)')

        rule_if = lib_rule.get('if', {})
        all_of  = rule_if.get('allOf', rule_if.get('anyOf', []))
        types   = []
        for cond in all_of:
            if isinstance(cond, dict) and cond.get('field') == 'type':
                val = cond.get('equals') or cond.get('in', [])
                if isinstance(val, list):
                    types.extend(val)
                elif val:
                    types.append(val)
        targets = ', '.join(types) if types else '(not specified)'

        bf_rule_text = pretty(bf_rule) if bf_rule else '(PolicyRule not captured in export)'
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
            'rule_changed':  True,
        })

    is_deny   = lambda e: effect_category(e['effect']) == 'deny'
    is_nondeny = lambda e: not is_deny(e)

    tier1 = sorted([e for e in entries if     e['assigned'] and is_deny(e)],    key=lambda e: e['name'])
    tier2 = sorted([e for e in entries if     e['assigned'] and is_nondeny(e)], key=lambda e: (e['effect'], e['name']))
    tier3: list = []  # No tier 3 in standalone — no hash pre-filter to produce false positives
    tier4 = sorted([e for e in entries if not e['assigned']],                   key=lambda e: (e['effect'], e['name']))

    print(f'  Tier 1 (assigned Deny, rule changed):        {len(tier1)}')
    print(f'  Tier 2 (assigned DINE/Modify, rule changed): {len(tier2)}')
    print(f'  Tier 4 (unassigned):                         {len(tier4)}')

    if not any([tier1, tier2, tier3, tier4]):
        print('  Nothing to report.')
        sys.exit(0)

    output = build_html(tier1, tier2, tier3, tier4, str(export_path), str(library_path))
    output_path.write_text(output, encoding='utf-8')
    print(f'Report written to: {output_path}')


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Generate HTML diff for ALZ policy rule mismatches.')
    parser.add_argument('--export',        required=True,  help='Path to brownfield export JSON')
    parser.add_argument('--library',       required=True,  help='Path to ALZ library directory')
    parser.add_argument('--output',        required=True,  help='Output HTML file path')
    parser.add_argument('--mismatch-info', dest='mismatch_info', default='',
                        help='Path to JSON file from Compare-BrownfieldState.ps1 listing mismatched policies. '
                             'When provided, Compare is the authority — Python only renders diffs.')
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

    if args.mismatch_info:
        main_with_mismatch_info(args, export_path, library_path, output_path)
    else:
        print('[INFO] No --mismatch-info provided — running in standalone mode (own mismatch detection)')
        main_standalone(args, export_path, library_path, output_path)


if __name__ == '__main__':
    main()
