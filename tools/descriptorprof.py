#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Strict OFFLINE v1 descriptor diagnostic analysis (PLA-431).

Usage: python3 tools/descriptorprof.py [--json] saved.log [other.log ...]
No application is launched. Inputs are read-only; no pp dispatch is added.
Exit 0: usable intervals and no rejected evidence; 1: insufficient; 2: mixed
usable/rejected evidence (malformed/unsupported records are always explicit).

Elapsed scopes are not CPU time or a wall union. Prep category EXCLUSIVES form
only a broad candidate envelope, not removable savings; Vulkan children are a
partition, not an addition. Native scopes are separate driver executions (replay
may be uncovered). Never join/subtract/sum components, even at equal frequency.
Requests/drawable signals are NOT presented frames. Presented-frame normalization
and CPU attribution are unsupported. No A2 decision or threshold is implemented.

Policy: both complete boundaries must be quiescent with fully matching counts;
ANY historical operation/report error rejects that boundary, including otherwise
clock_ok captures. Per-row history survives partial captures; resets and final
are terminal within an identity. Timing deltas must be feasible for new calls.
No recovery correction or interval max subtraction. Capture brackets bound
observation separation, NOT exact workload event boundaries.
Missing banners reject snapshots; missing calibration/tails stay explicit, never
zero-filled. Calibration is retained raw, never subtracted from elapsed values.
"""

import argparse
import json
import re
from pathlib import Path

U64 = (1 << 64) - 1
CATEGORIES = ('prep', 'standalone', 'excluded')
OPS = {
    'kk': 'pool_create allocate free pool_reset pool_destroy update template_update bind push push_template'.split(),
    'dxvk': 'prep spec_data_excluded pool_alloc pool_recycle pool_destroy vk_allocate vk_pool_create vk_reset vk_pool_destroy vk_update vk_template vk_bind'.split(),
    'vkd3d': 'prep_graphics prep_compute prep_other copy_resource copy_sampler copy_rtv copy_dsv copy_unknown simple_resource simple_sampler simple_rtv simple_dsv simple_unknown spec_data_excluded vk_update vk_bind vk_push vk_other'.split(),
}
FIELDS = {
    'kk': 'calls sets write_records write_elements write_bytes copy_records copy_elements copy_bytes dynamic_offsets pool_entries pool_elements pool_bytes failures timed_calls elapsed_ticks max_ticks clock_errors active'.split(),
    'dxvk': 'calls completed sets write_records write_elements write_bytes prepared_slots dynamic_offsets failures empty_dirty_mask work_unknown timed_calls inclusive_ticks direct_child_ticks exclusive_ticks max_ticks thread_sum_outer_elapsed_ticks clock_errors nest_errors active'.split(),
    'vkd3d': 'calls completed dst_ranges src_ranges requested_elements processed_elements metadata_bytes payload_bytes mapped_copy_calls sets records vk_elements dirty_root_slots table_slots work_unknown failures timed_calls elapsed_ticks direct_child_ticks exclusive_ticks max_ticks thread_sum_outer_elapsed_ticks clock_errors nest_errors active'.split(),
}
DENOM = {'kk': 'frames', 'dxvk': 'client_submission_requests', 'vkd3d': 'client_execute_requests'}
LABEL = {'kk': 'successful_submit_drawable_signals', 'dxvk': 'client_submission_requests', 'vkd3d': 'client_execute_requests'}
COMMON = 'v component kind pid device hz'.split()
BRACKET = 'snapshot ts_begin ts_end final clock_ok overflow quiescent entered_before completed_before entered_after completed_after'.split()
CAL = 'sample adjacent_begin adjacent_end adjacent_ok scope_begin scope_end scope_ok empty_begin empty_end empty_ok clock_reads'.split()
BANNERS = {
    'kk': dict(item.split('=', 1) for item in (
        'clock=monotonic_elapsed cpu_clock=unsupported coverage=legacy_entrypoints scopes=disjoint rollback=allocate '
        'work=requested inline=bytes push=api_records failures=vk_result_or_command_error_at_exit '
        'excluded=layout_template_lifecycle_constants_attachments_shader_loads publication=relaxed_bracketed '
        'boundary=timestamp_range final_may_be_incomplete=1').split()),
    'dxvk': dict(item.split('=', 1) for item in (
        'schema=1 coverage=legacy_sets cpu_clock=unsupported thread_model=summed_same_thread_scopes '
        'union=outermost_thread_sum exclusive=inclusive_minus_direct_children categories=prep,standalone,excluded '
        'candidate=sum_prep_category_exclusives_broad_not_fully_removable '
        'exclusions=spec_data_constants,renderpass,shader,layout_template_lifetime,heap_buffer_paths '
        'native=separate_uncovered_replay_no_cross_layer_subtraction capture=nontransactional active_or_invalid=reject '
        'killed_tail=missing denominator=client_submission_requests elapsed_includes=waiting,preemption,diagnostics').split()),
    'vkd3d': dict(item.split('=', 1) for item in (
        'coverage=prep_broad_ambiguous_constants_ubo_tracking,copy_cpu_metadata,selected_simple,direct_vk '
        'exclusions=separate_constants_redzone,rtv,dsv native=separate_uncovered_replay_no_subtraction '
        'capture=nontransactional_all_rows_required errors=override_quiescent killed_tail=missing '
        'thread_model=same_thread_nesting_summed_elapsed_no_registry cpu_clock=unsupported '
        'denominator=client_execute_requests_not_frames_or_gpu_completions byte_counts=source_copy_assignments_not_memory_traffic '
        'additive=sum_exclusive_by_category parent_inclusive=overlapping elapsed_includes=waiting,preemption,diagnostics').split()),
}
COPY_PATHS = set('default descriptor_buffer_16_16_4 descriptor_buffer_64_64_32 embedded_64_16_packed embedded_32_16_planar embedded_32_32_planar embedded_128_32_planar embedded_generic unrecognized'.split())
BOOLS = set('init_ok final clock_ok overflow quiescent adjacent_ok scope_ok empty_ok uncovered_selected_copy'.split())
STRINGS = {'component', 'kind', 'op', 'category', 'clock_kind', 'copy_simple_path', 'subtraction'}
MARKER = re.compile(r'\[(kk|dxvk|vkd3d)-descriptor\]\s+(.*)$')


def identity_keys(component, kind):
    if component == 'kk':
        return [] if kind == 'calibration' else ['init_ticks']
    return ['module', 'init_ticks', 'init_ok'] + (['clock_kind'] if component == 'vkd3d' else [])


def schema(component, kind):
    keys = set(COMMON + identity_keys(component, kind))
    if kind == 'enabled':
        keys.update(BANNERS[component])
        if component == 'dxvk':
            keys.add('clock_kind')
        if component == 'vkd3d':
            keys.update(['copy_simple_path', 'uncovered_selected_copy'])
    elif kind == 'calibration':
        keys.update('sample reads adjacent_ok adjacent_ticks empty_ok empty_ticks'.split() if component == 'kk' else CAL)
        if component == 'vkd3d':
            keys.add('subtraction')
    elif kind == 'snapshot':
        keys.update(BRACKET + FIELDS[component] + ['op', DENOM[component], error_field(component)])
        if component != 'kk':
            keys.add('category')
    else:
        raise ValueError('unsupported kind')
    return keys


def error_field(component):
    return 'report_errors' if component == 'vkd3d' else 'report_clock_errors'


def parse_record(line):
    """None for ordinary logs; malformed diagnostic markers always raise."""
    match = MARKER.search(line.rstrip())
    if not match:
        if '-descriptor' in line:
            raise ValueError('malformed or unsupported diagnostic marker')
        return None
    component, payload = match.groups()
    values = {}
    for token in payload.split():
        if token.count('=') != 1:
            raise ValueError('malformed key=value token')
        key, value = token.split('=')
        if not key or not value or key in values:
            raise ValueError('empty or duplicate key: ' + key)
        values[key] = value
    if values.get('v') != '1' or values.get('component') != component:
        raise ValueError('unsupported version/component')
    kind = values.get('kind')
    expected = schema(component, kind)
    if set(values) != expected:
        raise ValueError('schema keys missing=' + ','.join(sorted(expected - values.keys()))
                         + ' unknown=' + ','.join(sorted(values.keys() - expected)))
    fixed = BANNERS[component] if kind == 'enabled' else {}
    for key, value in list(values.items()):
        if key in fixed:
            if value != fixed[key]:
                raise ValueError('unsupported banner ' + key)
            if value.isdecimal():
                values[key] = int(value)
        elif key not in STRINGS:
            if not re.fullmatch(r'[0-9]+', value) or len(value) > 20 or int(value) > U64:
                raise ValueError('invalid unsigned u64: ' + key)
            values[key] = int(value)
            if key in BOOLS and values[key] > 1:
                raise ValueError('invalid boolean: ' + key)
    if kind == 'enabled' and component == 'vkd3d':
        if values['copy_simple_path'] not in COPY_PATHS:
            raise ValueError('unsupported copy path')
        if values['uncovered_selected_copy'] != int(values['copy_simple_path'] == 'unrecognized'):
            raise ValueError('inconsistent copy coverage')
    if kind == 'calibration':
        if values['sample'] >= 16 or values.get('reads', values.get('clock_reads')) != 6:
            raise ValueError('invalid calibration index/reads')
        if component == 'vkd3d' and values['subtraction'] != 'none':
            raise ValueError('unsupported calibration subtraction')
        if component != 'kk':
            for prefix in ('adjacent', 'scope', 'empty'):
                if values[prefix + '_ok'] and values[prefix + '_end'] < values[prefix + '_begin']:
                    raise ValueError('invalid calibration bracket')
    if kind == 'snapshot':
        if values['op'] not in OPS[component] or (component != 'kk' and values['category'] not in CATEGORIES):
            raise ValueError('unsupported operation/category')
    return values


def calibration_reasons(record):
    """Check emitted flag implications without correcting or subtracting samples."""
    reasons = [key + '=0' for key in ('adjacent_ok', 'scope_ok', 'empty_ok')
               if record.get(key, 1) == 0]
    if record['component'] == 'kk':
        # KK exposes durations only, and emits zero for each failed bracket.
        for prefix in ('adjacent', 'empty'):
            if not record[prefix + '_ok'] and record[prefix + '_ticks']:
                reasons.append('failed ' + prefix + ' sample has nonzero ticks')
    elif record['empty_ok']:
        if not record['scope_ok']:
            reasons.append('empty_ok requires scope_ok')
        # Unlike DXVK, vkd3d explicitly includes containment in empty_ok.
        if record['component'] == 'vkd3d' and not (
                record['empty_begin'] <= record['scope_begin']
                <= record['scope_end'] <= record['empty_end']):
            reasons.append('empty_ok contradicts scope containment')
    return reasons


def stream_key(record):
    return tuple(record.get(k) for k in ('component', 'pid', 'module', 'device', 'init_ticks'))


def snapshot_metadata(record):
    row_keys = set(FIELDS[record['component']] + ['op', 'category'])
    return {k: v for k, v in record.items() if k not in row_keys}


def validate_snapshot(component, snapshot, banner):
    reasons = snapshot['reasons']
    rows, meta = snapshot['rows'], snapshot['metadata']
    expected = {(op, cat) for op in OPS[component] for cat in (CATEGORIES if component != 'kk' else ('native',))}
    if set(rows) != expected:
        reasons.append('incomplete row set: %d/%d' % (len(rows), len(expected)))
    if not banner:
        reasons.append('missing enabled banner: coverage/clock configuration unavailable')
    else:
        for key in ('hz', 'init_ok', 'clock_kind'):
            if key in meta and meta[key] != banner.get(key):
                reasons.append('changed identity/units: ' + key)
    if not meta['hz'] or not meta['device'] or not meta['pid'] or (component != 'kk' and not meta['module']):
        reasons.append('invalid identity/frequency')
    if (component == 'kk' and (not meta['init_ticks'] or meta['hz'] != 1000000000)) or meta.get('init_ok', 1) != 1:
        reasons.append('invalid initialization/units')
    clock = meta.get('clock_kind', (banner or {}).get('clock_kind'))
    if component != 'kk' and clock not in ('qpc', 'clock_monotonic', 'host_clock_monotonic'):
        reasons.append('unsupported clock kind')
    if not meta['snapshot'] or meta['ts_end'] < meta['ts_begin'] or meta['ts_begin'] < meta['init_ticks']:
        reasons.append('invalid serial/capture timestamps')
    if not meta['clock_ok'] or meta[error_field(component)]:
        reasons.append('capture clock/report errors (historical errors rejected)')
    if clock in ('clock_monotonic', 'host_clock_monotonic') and meta['hz'] != 1000000000:
        reasons.append('invalid monotonic clock frequency')
    if meta['overflow'] or U64 in meta.values() or any(v == U64 for row in rows.values() for v in row.values()):
        reasons.append('saturation/overflow')
    seqs = [meta[k] for k in ('entered_before', 'completed_before', 'entered_after', 'completed_after')]
    if not meta['quiescent'] or len(set(seqs)) != 1:
        reasons.append('unsafe concurrent/unbalanced capture boundary')
    if sum(row['calls'] for row in rows.values()) != meta['entered_after']:
        reasons.append('row calls do not match capture sequence')
    for key, row in rows.items():
        tag = '/'.join(key)
        if row['active'] or row['timed_calls'] != row['calls'] or row.get('completed', row['calls']) != row['calls']:
            reasons.append(tag + ': active/incomplete timing or completion')
        if row['clock_errors'] or row.get('nest_errors', 0):
            reasons.append(tag + ': operation errors override capture (historical errors rejected)')
        if row['failures'] > row['calls']:
            reasons.append(tag + ': failures exceed calls')
        elapsed = row['elapsed_ticks' if component != 'dxvk' else 'inclusive_ticks']
        if row['max_ticks'] > elapsed or elapsed > row['max_ticks'] * row['timed_calls'] or (not row['timed_calls'] and (elapsed or row['max_ticks'])):
            reasons.append(tag + ': inconsistent cumulative max/elapsed')
        if component != 'kk':
            if elapsed != row['direct_child_ticks'] + row['exclusive_ticks'] or row['thread_sum_outer_elapsed_ticks'] > elapsed:
                reasons.append(tag + ': nesting identity/outer sum invalid')
            if component == 'vkd3d' and key[0] in ('copy_rtv', 'copy_dsv', 'simple_rtv', 'simple_dsv', 'spec_data_excluded') and key[1] != 'excluded' and row['calls']:
                reasons.append(tag + ': excluded operation in candidate category')
            if key[0] == 'spec_data_excluded' and key[1] != 'excluded' and row['calls']:
                reasons.append(tag + ': excluded operation miscategorized')
    if component != 'kk' and sum(row['exclusive_ticks'] for row in rows.values()) != sum(row['thread_sum_outer_elapsed_ticks'] for row in rows.values()):
        reasons.append('exclusive total does not match outer-thread-sum (incomplete nesting attribution)')
    snapshot['valid'] = not reasons


def summarize_interval(component, first, last):
    a, b = first['metadata'], last['metadata']
    result = {'from_snapshot': a['snapshot'], 'to_snapshot': b['snapshot'],
              'lines': [first['lines'], last['lines']], 'valid': False, 'reasons': [],
              'capture_brackets_ticks': [[a['ts_begin'], a['ts_end']], [b['ts_begin'], b['ts_end']]]}
    reasons = result['reasons']
    if not first['valid'] or not last['valid']:
        reasons.append('invalid boundary; see snapshot reasons')
    if b['snapshot'] != a['snapshot'] + 1:
        reasons.append('missing/reset/out-of-order snapshot serial')
    if a['final']:
        reasons.append('snapshot after orderly final')
    if b['ts_begin'] < a['ts_end']:
        reasons.append('decreasing/overlapping capture timestamps')
    for key in ('hz', 'init_ok', 'clock_kind'):
        if a.get(key) != b.get(key):
            reasons.append('changed identity/units: ' + key)
    for key in (DENOM[component], error_field(component), 'entered_before', 'completed_before', 'entered_after', 'completed_after'):
        if b[key] < a[key]:
            reasons.append('decreasing cumulative ' + key)
    deltas = []
    for key in first['rows'].keys() & last['rows'].keys():
        old, new = first['rows'][key], last['rows'][key]
        for field in FIELDS[component]:
            if field != 'active' and new[field] < old[field]:
                reasons.append('/'.join(key) + ': decreasing ' + field)
        delta = {field: new[field] - old[field] for field in FIELDS[component] if field not in ('max_ticks', 'active')}
        delta.update(op=key[0], category=key[1], cumulative_max_ticks_bound=new['max_ticks'])
        tag = '/'.join(key) + ': '
        if delta['timed_calls'] != delta['calls'] or delta.get('completed', delta['calls']) != delta['calls']:
            reasons.append(tag + 'interval timing/completion mismatch')
        elapsed = delta['inclusive_ticks' if component == 'dxvk' else 'elapsed_ticks']
        if not delta['timed_calls'] and (elapsed or new['max_ticks'] > old['max_ticks']):
            reasons.append(tag + 'zero timed calls with timing additions/maximum increase')
        if elapsed > delta['timed_calls'] * new['max_ticks']:
            reasons.append(tag + 'interval elapsed exceeds timed calls times ending maximum')
        if new['max_ticks'] > old['max_ticks'] and new['max_ticks'] > elapsed:
            reasons.append(tag + 'increased maximum exceeds new elapsed')
        if component != 'kk' and (elapsed != delta['direct_child_ticks'] + delta['exclusive_ticks']
                or delta['thread_sum_outer_elapsed_ticks'] > elapsed):
            reasons.append(tag + 'interval nesting identity/outer sum invalid')
        deltas.append(delta)
    if reasons:
        return result
    hz = b['hz']
    result.update(valid=True, hz=hz, units='raw ticks; elapsed seconds=ticks/hz', rows=sorted(deltas, key=lambda r: (r['category'], r['op'])))
    lower, upper = b['ts_begin'] - a['ts_end'], b['ts_end'] - a['ts_begin']
    result['observation_separation'] = {'lower_ticks': lower, 'upper_ticks': upper,
        'lower_seconds': lower / hz, 'upper_seconds': upper / hz,
        'duration_denominator': 'insufficient (quantized zero)' if not lower else 'observation only, not event-time alignment',
        'event_time_alignment': 'unknown; quiescence is capture consistency only; active work is never bounded by completed maxima'}
    count = b[DENOM[component]] - a[DENOM[component]]
    result['workload'] = {'label': LABEL[component], 'delta': count, 'presented_frames': 'unsupported',
                          'normalization': 'unsupported; zero workload count' if not count else 'no independently aligned presented-frame evidence'}
    totals = {}
    for category in ('native',) if component == 'kk' else CATEGORIES:
        selected = [r for r in deltas if r['category'] == category]
        field = 'elapsed_ticks' if component == 'kk' else 'exclusive_ticks'
        ticks = sum(r[field] for r in selected)
        totals[category] = {'ticks': ticks, 'elapsed_seconds': ticks / hz}
        if component != 'kk':
            vk = sum(r[field] for r in selected if r['op'].startswith('vk_'))
            totals[category].update(vulkan_exclusive_ticks=vk, non_vulkan_exclusive_ticks=ticks - vk)
    result['category_elapsed'] = totals
    result['interpretation'] = 'native disjoint driver executions; replay may be uncovered' if component == 'kk' else 'prep is broad candidate exclusive envelope; standalone/excluded separate, not automatically removable'
    return result


def analyze_sources(sources):
    """sources: iterable of (display identity, iterable of text lines). No I/O mutation."""
    report = {'status': 'insufficient', 'issues': [], 'streams': [], 'limits': [
        'Elapsed includes waiting/preemption/diagnostics; not CPU or wall union; thread sums can exceed walltime.',
        'No cross-layer alignment, sum, subtraction, count parity or containment inference.',
        'No elapsed-per-presented-frame, CPU-per-frame, payoff, savings or A2 authorization.',
        'No implicit zero baseline; missing/killed tail remains missing. Historical errors reject boundaries.']}
    for source_index, (source, lines) in enumerate(sources):
        streams, aliases, file_issues = {}, {}, []
        for number, line in enumerate(lines, 1):
            try:
                record = parse_record(line)
                if record is None:
                    continue
                component, kind = record['component'], record['kind']
                key = stream_key(record)
                alias = (component, record['pid'], record.get('module'), record['device'])
                if component == 'kk' and kind == 'calibration':
                    choices = aliases.get(alias, set())
                    if len(choices) != 1:
                        raise ValueError('KK calibration missing/ambiguous enabled lifetime identity')
                    key = next(iter(choices))
                stream = streams.setdefault(key, {'identity': dict(zip(('component', 'pid', 'module', 'device', 'init_ticks'), key)),
                    'source': source, 'source_index': source_index, 'banner': None, 'calibration': [], 'snapshots': [], 'issues': []})
                if kind == 'enabled':
                    aliases.setdefault(alias, set()).add(key)
                    if stream['banner']:
                        stream['issues'].append({'line': number, 'reason': 'duplicate enabled banner/identity reuse'})
                    stream['banner'] = record
                    stream['banner_line'] = number
                elif kind == 'calibration':
                    if any(c['values']['sample'] == record['sample'] for c in stream['calibration']):
                        stream['issues'].append({'line': number, 'reason': 'duplicate calibration sample'})
                    if stream['banner'] and any(record.get(k) != stream['banner'].get(k) for k in ('hz', 'init_ok', 'clock_kind') if k in record):
                        stream['issues'].append({'line': number, 'reason': 'changed calibration identity/units'})
                    stream['calibration'].append({'line': number, 'values': record, 'reasons': calibration_reasons(record)})
                else:
                    snapshots = stream['snapshots']
                    serial = record['snapshot']
                    found = next((s for s in snapshots if s['metadata']['snapshot'] == serial), None)
                    if found is None:
                        found = {'metadata': snapshot_metadata(record), 'rows': {}, 'lines': [], 'reasons': [], 'final_observed': False}
                        snapshots.append(found)
                    elif found is not snapshots[-1]:
                        found['reasons'].append('out-of-order snapshot row')
                    found['final_observed'] |= bool(record['final'])
                    row_key = (record['op'], record.get('category', 'native'))
                    if row_key in found['rows']:
                        found['reasons'].append('duplicate operation/category row')
                    if snapshot_metadata(record) != found['metadata']:
                        found['reasons'].append('inconsistent snapshot metadata/identity/units')
                    found['rows'][row_key] = {k: record[k] for k in FIELDS[component]}
                    found['lines'].append(number)
            except ValueError as exc:
                file_issues.append({'source': source, 'source_index': source_index, 'line': number, 'reason': str(exc)})
        report['issues'].extend(file_issues)
        for stream in streams.values():
            component = stream['identity']['component']
            stream['calibration_status'] = 'complete raw 16 samples' if len(stream['calibration']) == 16 else 'missing/incomplete calibration (%d/16)' % len(stream['calibration'])
            stream['calibration_invalid_samples'] = sum(bool(c['reasons']) for c in stream['calibration'])
            stream['tail_status'] = 'orderly final observed (does not override errors)' if any(s['final_observed'] for s in stream['snapshots']) else 'missing orderly tail; later work unknown'
            if stream['banner'] and stream['banner'].get('uncovered_selected_copy'):
                stream['coverage_status'] = 'selected Simple path uncovered; no complete copy coverage assertion'
            else:
                stream['coverage_status'] = 'only explicit banner coverage; not complete application coverage' if stream['banner'] else 'missing'
            for snapshot in stream['snapshots']:
                if file_issues or stream['issues']:
                    snapshot['reasons'].append('source/stream diagnostic errors; conservative rejection')
                validate_snapshot(component, snapshot, stream['banner'])
            # A reset/clock change cannot start a hidden recovery epoch. Earlier
            # clean intervals remain visible, but this identity never recovers.
            broken_sequence = False
            previous = None
            last_seen_rows = {}
            final_seen = False
            for snapshot in stream['snapshots']:
                meta = snapshot['metadata']
                if previous:
                    old = previous['metadata']
                    broken_sequence |= (meta['snapshot'] <= old['snapshot'] or meta['ts_begin'] < old['ts_end']
                        or any(meta.get(k) != old.get(k) for k in ('hz', 'init_ok', 'clock_kind'))
                        or any(meta[k] < old[k] for k in (DENOM[component], error_field(component),
                            'entered_before', 'completed_before', 'entered_after', 'completed_after')))
                # Missing rows never erase evidence or establish a fresh baseline.
                for key, row in snapshot['rows'].items():
                    old_row = last_seen_rows.get(key)
                    if old_row and any(row[field] < old_row[field] for field in FIELDS[component] if field != 'active'):
                        broken_sequence = True
                    last_seen_rows[key] = row
                if final_seen:
                    snapshot['reasons'].append('snapshot after orderly final; terminal within this identity')
                    snapshot['valid'] = False
                final_seen |= snapshot['final_observed']
                if broken_sequence:
                    snapshot['reasons'].append('cumulative reset/order/units violation; no recovery within this identity')
                    snapshot['valid'] = False
                broken_sequence |= bool(meta['overflow']) or U64 in meta.values() or any(
                    v == U64 for row in snapshot['rows'].values() for v in row.values())
                previous = snapshot
            stream['intervals'] = [summarize_interval(component, a, b) for a, b in zip(stream['snapshots'], stream['snapshots'][1:])]
            # JSON uses row arrays; tuple keys remain internal only until validation ends.
            for snapshot in stream['snapshots']:
                snapshot['rows'] = [dict(op=k[0], category=k[1], **v) for k, v in sorted(snapshot['rows'].items())]
            report['streams'].append(stream)
    intervals = [i for s in report['streams'] for i in s['intervals']]
    usable = sum(i['valid'] for i in intervals)
    rejected = bool(report['issues']) or any(s['issues'] or any(not b['valid'] for b in s['snapshots']) or not s['intervals'] for s in report['streams']) or any(not i['valid'] for i in intervals)
    report['usable_intervals'] = usable
    report['status'] = ('mixed' if rejected else 'ok') if usable else 'insufficient'
    return report


def text_report(report):
    lines = ['Descriptor diagnostics: %s; usable intervals=%d' % (report['status'], report['usable_intervals'])]
    if not report['streams']:
        lines.append('INSUFFICIENT: no supported native descriptor telemetry; missing is not zero work')
    for issue in report['issues']:
        lines.append('%s:%s: INVALID/UNSUPPORTED %s' % (issue['source'], issue['line'], issue['reason']))
    for stream in report['streams']:
        lines.append('%s input=%d identity=%s' % (stream['source'], stream['source_index'], stream['identity']))
        lines.append('  ' + stream['calibration_status'] + '; invalid samples=%d; ' % stream['calibration_invalid_samples'] + stream['tail_status'])
        lines.append('  ' + stream['coverage_status'])
        if stream['banner']:
            lines.append('  coverage=%s exclusions=%s clock=%s selected_copy=%s' % (
                stream['banner']['coverage'], stream['banner'].get('exclusions', stream['banner'].get('excluded')),
                stream['banner'].get('clock_kind', stream['banner'].get('clock')), stream['banner'].get('copy_simple_path', 'not applicable')))
        for sample in stream['calibration']:
            if sample['reasons']:
                lines.append('  calibration line %d: INVALID %s' % (sample['line'], '; '.join(sample['reasons'])))
        for issue in stream['issues']:
            lines.append('  line %d: %s' % (issue['line'], issue['reason']))
        for snapshot in stream['snapshots']:
            lines.append('  snapshot %d rows=%d lines=%s..%s: %s' % (snapshot['metadata']['snapshot'], len(snapshot['rows']), min(snapshot['lines']), max(snapshot['lines']), 'valid capture (not exact event boundary)' if snapshot['valid'] else '; '.join(snapshot['reasons'])))
        if not stream['intervals']:
            lines.append('  INSUFFICIENT: two consecutive valid complete snapshots required; no zero baseline')
        for interval in stream['intervals']:
            lines.append('  interval %d..%d: %s' % (interval['from_snapshot'], interval['to_snapshot'], 'usable' if interval['valid'] else 'REJECTED ' + '; '.join(interval['reasons'])))
            if interval['valid']:
                for key in ('observation_separation', 'workload', 'category_elapsed'):
                    lines.append('    %s: %s' % (key, interval[key]))
    lines.extend(report['limits'])
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--json', action='store_true', help='structured raw integers, units, validity, reasons and line provenance')
    parser.add_argument('logs', nargs='+', type=Path, help='saved logs (separate input identities, never merged)')
    args = parser.parse_args(argv)
    sources = []
    try:
        for path in args.logs:
            with path.open(encoding='utf-8', errors='strict') as handle:
                sources.append((str(path), handle.readlines()))
    except (OSError, UnicodeError) as exc:
        parser.exit(2, 'Cannot read saved log: %s\n' % exc)
    report = analyze_sources(sources)
    print(json.dumps(report, indent=2, sort_keys=True) if args.json else text_report(report))
    return {'ok': 0, 'insufficient': 1, 'mixed': 2}[report['status']]


if __name__ == '__main__':
    raise SystemExit(main())
