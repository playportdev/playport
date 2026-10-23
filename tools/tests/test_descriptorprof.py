# SPDX-License-Identifier: GPL-3.0-or-later
"""Producer-shaped scrubbed v1 fixtures; no native execution/private logs."""
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import descriptorprof as dp

# Independent wire operation/field lists transcribed from the three producers.
OPERATIONS = {
    'kk': 'pool_create allocate free pool_reset pool_destroy update template_update bind push push_template',
    'dxvk': 'prep spec_data_excluded pool_alloc pool_recycle pool_destroy vk_allocate vk_pool_create vk_reset vk_pool_destroy vk_update vk_template vk_bind',
    'vkd3d': 'prep_graphics prep_compute prep_other copy_resource copy_sampler copy_rtv copy_dsv copy_unknown simple_resource simple_sampler simple_rtv simple_dsv simple_unknown spec_data_excluded vk_update vk_bind vk_push vk_other',
}
WIRE_FIELDS = {
    'kk': 'calls sets write_records write_elements write_bytes copy_records copy_elements copy_bytes dynamic_offsets pool_entries pool_elements pool_bytes failures timed_calls elapsed_ticks max_ticks clock_errors active',
    'dxvk': 'calls completed sets write_records write_elements write_bytes prepared_slots dynamic_offsets failures empty_dirty_mask work_unknown timed_calls inclusive_ticks direct_child_ticks exclusive_ticks max_ticks thread_sum_outer_elapsed_ticks clock_errors nest_errors active',
    'vkd3d': 'calls completed dst_ranges src_ranges requested_elements processed_elements metadata_bytes payload_bytes mapped_copy_calls sets records vk_elements dirty_root_slots table_slots work_unknown failures timed_calls elapsed_ticks direct_child_ticks exclusive_ticks max_ticks thread_sum_outer_elapsed_ticks clock_errors nest_errors active',
}
ENABLED = {
    'kk': 'clock=monotonic_elapsed cpu_clock=unsupported coverage=legacy_entrypoints scopes=disjoint rollback=allocate work=requested inline=bytes push=api_records failures=vk_result_or_command_error_at_exit excluded=layout_template_lifecycle_constants_attachments_shader_loads publication=relaxed_bracketed boundary=timestamp_range final_may_be_incomplete=1',
    'dxvk': 'schema=1 coverage=legacy_sets clock_kind=clock_monotonic cpu_clock=unsupported thread_model=summed_same_thread_scopes union=outermost_thread_sum exclusive=inclusive_minus_direct_children categories=prep,standalone,excluded candidate=sum_prep_category_exclusives_broad_not_fully_removable exclusions=spec_data_constants,renderpass,shader,layout_template_lifetime,heap_buffer_paths native=separate_uncovered_replay_no_cross_layer_subtraction capture=nontransactional active_or_invalid=reject killed_tail=missing denominator=client_submission_requests elapsed_includes=waiting,preemption,diagnostics',
    'vkd3d': 'copy_simple_path=default uncovered_selected_copy=0 coverage=prep_broad_ambiguous_constants_ubo_tracking,copy_cpu_metadata,selected_simple,direct_vk exclusions=separate_constants_redzone,rtv,dsv native=separate_uncovered_replay_no_subtraction capture=nontransactional_all_rows_required errors=override_quiescent killed_tail=missing thread_model=same_thread_nesting_summed_elapsed_no_registry cpu_clock=unsupported denominator=client_execute_requests_not_frames_or_gpu_completions byte_counts=source_copy_assignments_not_memory_traffic additive=sum_exclusive_by_category parent_inclusive=overlapping elapsed_includes=waiting,preemption,diagnostics',
}
DENOMINATOR = {'kk': 'frames', 'dxvk': 'client_submission_requests', 'vkd3d': 'client_execute_requests'}


def record(component, kind, extra='', **identity):
    base = dict(pid=7, device=1, init_ticks=100, hz=1000000000)
    if component != 'kk':
        base.update(module=17, init_ok=1)
    if component == 'vkd3d':
        base['clock_kind'] = 'host_clock_monotonic'
    base.update(identity)
    if component == 'kk' and kind == 'calibration':
        base.pop('init_ticks')
    return '[%s-descriptor] v=1 component=%s kind=%s %s %s' % (
        component, component, kind, ' '.join('%s=%s' % pair for pair in base.items()), extra)


def banner(component, **identity):
    return record(component, 'enabled', ENABLED[component], **identity)


def calibration(component, **identity):
    result = []
    for i in range(16):
        if component == 'kk':
            extra = 'sample=%d reads=6 adjacent_ok=1 adjacent_ticks=0 empty_ok=1 empty_ticks=4' % i
        else:
            extra = ('sample=%d adjacent_begin=110 adjacent_end=110 adjacent_ok=1 scope_begin=112 scope_end=113 scope_ok=1 empty_begin=111 empty_end=114 empty_ok=1 clock_reads=6' % i)
            if component == 'vkd3d':
                extra += ' subtraction=none'
        result.append(record(component, 'calibration', extra, **identity))
    return result


def snapshot(component, serial, *, changes=None, meta=None, **identity):
    """Three disjoint category trees; prep100 = local60 + Vulkan30 + excluded10."""
    categories = ('native',) if component == 'kk' else ('prep', 'standalone', 'excluded')
    values = {(op, cat): dict.fromkeys(WIRE_FIELDS[component].split(), 0)
              for cat in categories for op in OPERATIONS[component].split()}
    if component == 'kk':
        values['update', 'native'].update(calls=serial, timed_calls=serial,
            elapsed_ticks=serial * 100, max_ticks=100, write_elements=serial * 5)
    else:
        prep = 'prep' if component == 'dxvk' else 'prep_graphics'
        values[prep, 'prep'].update(calls=serial, completed=serial, timed_calls=serial,
            **{('inclusive_ticks' if component == 'dxvk' else 'elapsed_ticks'): serial * 100},
            direct_child_ticks=serial * 40, exclusive_ticks=serial * 60, max_ticks=100,
            thread_sum_outer_elapsed_ticks=serial * 100, work_unknown=serial)
        for op, cat, ticks, outer in [('vk_bind', 'prep', 30, 0), ('spec_data_excluded', 'excluded', 10, 0), ('vk_update', 'standalone', 20, 20)]:
            values[op, cat].update(calls=serial, completed=serial, timed_calls=serial,
                **{('inclusive_ticks' if component == 'dxvk' else 'elapsed_ticks'): serial * ticks},
                exclusive_ticks=serial * ticks, max_ticks=ticks,
                thread_sum_outer_elapsed_ticks=serial * outer)
    for key, update in (changes or {}).items():
        values[key].update(update)
    entered = sum(v['calls'] for v in values.values())
    metadata = dict(snapshot=serial, ts_begin=1000 * serial, ts_end=1000 * serial + 2,
        **{DENOMINATOR[component]: serial}, final=0, clock_ok=1, overflow=0,
        quiescent=1, entered_before=entered, completed_before=entered,
        entered_after=entered, completed_after=entered,
        **{('report_errors' if component == 'vkd3d' else 'report_clock_errors'): 0})
    metadata.update(meta or {})
    return [record(component, 'snapshot', ' '.join('%s=%s' % pair for pair in metadata.items())
                   + ' op=' + op + ('' if component == 'kk' else ' category=' + cat)
                   + ' ' + ' '.join('%s=%s' % pair for pair in row.items()), **identity)
            for (op, cat), row in values.items()]


def fixture(component, count=2, **identity):
    return [banner(component, **identity)] + calibration(component, **identity) + [line for n in range(1, count + 1) for line in snapshot(component, n, **identity)]


def analyze(lines, source='synthetic.log'):
    return dp.analyze_sources([(source, lines)])


def reasons(report):
    return json.dumps(report)


class DescriptorProf(unittest.TestCase):
    def test_complete_cardinality_and_partition_not_inclusive_double_count(self):
        for component, size in [('kk', 10), ('dxvk', 36), ('vkd3d', 54)]:
            with self.subTest(component=component):
                report = analyze(fixture(component))
                self.assertEqual(report['status'], 'ok')
                stream = report['streams'][0]
                self.assertEqual([len(s['rows']) for s in stream['snapshots']], [size, size])
                interval = stream['intervals'][0]
                self.assertEqual(interval['workload']['delta'], 1)
                self.assertEqual(interval['workload']['presented_frames'], 'unsupported')
                self.assertEqual(interval['observation_separation']['lower_ticks'], 998)
                self.assertEqual(interval['observation_separation']['upper_ticks'], 1002)
                if component == 'kk':
                    self.assertEqual(interval['category_elapsed']['native']['ticks'], 100)
                    self.assertEqual(interval['workload']['label'], 'successful_submit_drawable_signals')
                else:
                    total = interval['category_elapsed']
                    self.assertEqual(total['prep']['ticks'], 90)  # not inclusive100 + child30
                    self.assertEqual(total['prep']['vulkan_exclusive_ticks'], 30)
                    self.assertEqual(total['prep']['non_vulkan_exclusive_ticks'], 60)
                    self.assertEqual(total['excluded']['ticks'], 10)
                    self.assertEqual(total['standalone']['ticks'], 20)
                    row = next(r for r in interval['rows'] if r['op'] in ('prep', 'prep_graphics') and r['category'] == 'prep')
                    self.assertEqual(row['work_unknown'], 1)
                    self.assertNotIn('max_ticks', row)
                    self.assertEqual(row['cumulative_max_ticks_bound'], 100)
                    self.assertEqual(row['exclusive_ticks'], 60)
                self.assertIn('complete raw 16', stream['calibration_status'])

    def test_interleaved_devices_modules_generations_and_separate_files(self):
        a, b = fixture('dxvk'), fixture('dxvk', module=18)
        c, d = fixture('dxvk', device=2), fixture('dxvk', init_ticks=101)
        woven = [x for rows in zip(a, b, c, d) for x in rows]
        report = dp.analyze_sources([('one.log', woven), ('two.log', a)])
        self.assertEqual(len(report['streams']), 5)
        self.assertEqual(report['usable_intervals'], 5)
        self.assertEqual(report['status'], 'ok')
        self.assertEqual({s['source_index'] for s in report['streams']}, {0, 1})

    def test_prefixes_and_no_telemetry(self):
        report = analyze(['2026 INFO prefix: ' + l for l in fixture('kk')])
        self.assertEqual(report['status'], 'ok')
        empty = analyze(['ordinary output', 'nothing measured'])
        self.assertEqual(empty['status'], 'insufficient')
        self.assertIn('missing is not zero', dp.text_report(empty))

    def test_strict_keys_version_kind_marker_and_integer_ranges(self):
        good = snapshot('kk', 1)[0]
        mutations = [good + ' calls=0', good + ' invented=0', good.replace(' sets=0', ''),
            good.replace('v=1', 'v=2'), good.replace('kind=snapshot', 'kind=unsupported'),
            good.replace('[kk-descriptor]', '[other-descriptor]'),
            good.replace('[kk-descriptor]', '[kk-descriptor'), good + ' trailing',
            good.replace('calls=0', 'calls=-1'), good.replace('calls=0', 'calls=1.5'),
            good.replace('calls=0', 'calls=18446744073709551616'), good.replace('calls=0', 'calls='),
            good.replace('clock_ok=1', 'clock_ok=2'), good.replace('op=pool_create', 'op=unknown'),
            good.replace('component=kk', 'component=dxvk')]
        for bad in mutations:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    dp.parse_record(bad)
                report = analyze(fixture('kk') + [bad])
                self.assertEqual(report['usable_intervals'], 0)
                self.assertTrue(report['issues'][0]['line'])

    def test_duplicate_missing_rows_and_metadata_disagreement(self):
        for component in OPERATIONS:
            a, b = snapshot(component, 1), snapshot(component, 2)
            for broken in [b[:-1], b + [b[-1]], b[:1] + [b[1].replace('ts_end=2002', 'ts_end=2003')] + b[2:]]:
                report = analyze([banner(component)] + a + broken)
                self.assertEqual(report['usable_intervals'], 0)
                self.assertIn('lines', report['streams'][0]['snapshots'][-1])

    def test_operation_errors_override_clock_ok_quiescent_and_final(self):
        for component in OPERATIONS:
            op, cat = ('update', 'native') if component == 'kk' else (('prep', 'prep') if component == 'dxvk' else ('prep_graphics', 'prep'))
            fields = {'clock_errors': 1, 'timed_calls': 1}
            if component != 'kk':
                fields['nest_errors'] = 1
            report = analyze([banner(component)] + snapshot(component, 1) + snapshot(component, 2, changes={(op, cat): fields}, meta={'final': 1}))
            self.assertEqual(report['usable_intervals'], 0)
            self.assertIn('operation errors override', reasons(report))
            self.assertIn('incomplete timing', reasons(report))

    def test_invalid_boundaries_state_and_saturation(self):
        for component in OPERATIONS:
            for meta in [{'quiescent': 0}, {'completed_after': 0}, {'entered_before': 0}, {'clock_ok': 0}, {'overflow': 1},
                         {('report_errors' if component == 'vkd3d' else 'report_clock_errors'): 1}, {'ts_begin': 3000}, {'hz': 0}]:
                with self.subTest(component=component, meta=meta):
                    report = analyze([banner(component)] + snapshot(component, 1) + snapshot(component, 2, meta=meta))
                    self.assertEqual(report['usable_intervals'], 0)
            op, cat = ('update', 'native') if component == 'kk' else ('vk_bind', 'prep')
            for changes in [{'active': 1}, {'max_ticks': dp.U64}, {'timed_calls': 0}]:
                report = analyze([banner(component)] + snapshot(component, 1) + snapshot(component, 2, changes={(op, cat): changes}, meta={'final': 1}))
                self.assertEqual(report['usable_intervals'], 0)

    def test_resets_decreases_serial_timestamp_and_units(self):
        for component in OPERATIONS:
            for later in [snapshot(component, 3), snapshot(component, 2, meta={'ts_begin': 999}),
                          snapshot(component, 2, hz=1000), snapshot(component, 2, init_ticks=101),
                          snapshot(component, 2, meta={DENOMINATOR[component]: 0})]:
                report = analyze([banner(component)] + snapshot(component, 1) + later)
                self.assertEqual(report['usable_intervals'], 0)
            op, cat = ('update', 'native') if component == 'kk' else ('vk_bind', 'prep')
            report = analyze([banner(component)] + snapshot(component, 1) + snapshot(component, 2, changes={(op, cat): {'calls': 0, 'timed_calls': 0}}))
            self.assertEqual(report['usable_intervals'], 0)
            self.assertIn('decreasing calls', reasons(report))
            # Serial arrival order, not sorting, is the source of truth.
            report = analyze([banner(component)] + snapshot(component, 2) + snapshot(component, 1))
            self.assertEqual(report['usable_intervals'], 0)

    def test_init_clock_banner_and_configuration(self):
        for component in OPERATIONS:
            report = analyze(snapshot(component, 1) + snapshot(component, 2))
            self.assertEqual(report['usable_intervals'], 0)
            self.assertIn('missing enabled', reasons(report))
            report = analyze(fixture(component, init_ticks=0, **({'init_ok': 0} if component != 'kk' else {})))
            self.assertEqual(report['usable_intervals'], 0)
            report = analyze(fixture(component) + [banner(component)])
            self.assertEqual(report['usable_intervals'], 0)
        for component in ('dxvk', 'vkd3d'):
            report = analyze([s.replace('clock_monotonic', 'unrecognized_clock') for s in fixture(component)])
            self.assertEqual(report['usable_intervals'], 0)
            self.assertIn('unsupported clock kind', reasons(report))
        with self.assertRaises(ValueError):
            dp.parse_record(banner('dxvk').replace('coverage=legacy_sets', 'coverage=all'))
        report = analyze([s.replace('copy_simple_path=default uncovered_selected_copy=0', 'copy_simple_path=unrecognized uncovered_selected_copy=1') for s in fixture('vkd3d')])
        self.assertIn('uncovered', report['streams'][0]['coverage_status'])

    def test_qpc_units_are_converted_only_within_one_component_epoch(self):
        for component in ('dxvk', 'vkd3d'):
            lines = [s.replace('host_clock_monotonic', 'qpc').replace('clock_kind=clock_monotonic', 'clock_kind=qpc')
                     for s in fixture(component, hz=10000000)]
            report = analyze(lines)
            self.assertEqual(report['status'], 'ok')
            interval = report['streams'][0]['intervals'][0]
            self.assertEqual(interval['hz'], 10000000)
            self.assertEqual(interval['category_elapsed']['prep']['elapsed_seconds'], 90 / 10000000)
            self.assertNotIn('cpu_seconds', interval)
        report = dp.analyze_sources([(c + '.log', fixture(c)) for c in OPERATIONS])
        self.assertEqual(report['usable_intervals'], 3)
        self.assertNotIn('category_elapsed', report)  # never aggregate layers
        self.assertNotIn('cpu_clock', report)

    def test_calibration_missing_invalid_raw_and_kk_lifetime_association(self):
        report = analyze([banner('kk')] + snapshot('kk', 1) + snapshot('kk', 2))
        self.assertEqual(report['status'], 'ok')
        self.assertIn('missing/incomplete', report['streams'][0]['calibration_status'])
        report = analyze([banner('kk')] + [s.replace('adjacent_ok=1', 'adjacent_ok=0') for s in calibration('kk')] + snapshot('kk', 1) + snapshot('kk', 2))
        self.assertEqual(report['streams'][0]['calibration'][0]['values']['adjacent_ok'], 0)
        # Missing/ambiguous lifetime must never guess init_ticks from a snapshot.
        for lines in [calibration('kk'), [banner('kk'), banner('kk', init_ticks=101)] + calibration('kk')]:
            self.assertTrue(analyze(lines)['issues'])
        for component in OPERATIONS:
            report = analyze(fixture(component) + [calibration(component)[0]])
            self.assertEqual(report['usable_intervals'], 0)
            self.assertIn('duplicate calibration', reasons(report))
        with self.assertRaises(ValueError):
            dp.parse_record(calibration('dxvk')[0].replace('adjacent_end=110', 'adjacent_end=109'))
        with self.assertRaises(ValueError):
            dp.parse_record(calibration('kk')[0].replace('sample=0', 'sample=16'))

    def test_zero_denominator_equal_capture_ticks_and_quantized_scopes(self):
        for component in OPERATIONS:
            lines = [banner(component)]
            for n in (1, 2):
                empty = snapshot(component, n, meta={'ts_begin': 1000, 'ts_end': 1000, DENOMINATOR[component]: 0})
                # Valid zero-time scopes, including cumulative maximum zero.
                fields = ['elapsed_ticks', 'inclusive_ticks', 'direct_child_ticks', 'exclusive_ticks', 'max_ticks', 'thread_sum_outer_elapsed_ticks']
                for line in empty:
                    parts = line.split()
                    lines.append(' '.join((p.split('=')[0] + '=0') if p.split('=')[0] in fields else p for p in parts))
            report = analyze(lines)
            self.assertEqual(report['status'], 'ok')
            interval = report['streams'][0]['intervals'][0]
            self.assertIn('quantized zero', interval['observation_separation']['duration_denominator'])
            self.assertIn('zero workload', interval['workload']['normalization'])

    def test_mixed_error_intervals_not_averaged_or_recovered(self):
        for component in OPERATIONS:
            error = 'report_errors' if component == 'vkd3d' else 'report_clock_errors'
            lines = fixture(component) + snapshot(component, 3, meta={error: 1}) + snapshot(component, 4, meta={error: 1})
            report = analyze(lines)
            self.assertEqual(report['status'], 'mixed')
            self.assertEqual(report['usable_intervals'], 1)
            self.assertEqual([i['valid'] for i in report['streams'][0]['intervals']], [True, False, False])
            self.assertNotIn('totals', report)

    def test_nested_identities_max_bounds_and_excluded_heap_categories(self):
        for component in ('dxvk', 'vkd3d'):
            for key, fields in [(('vk_bind', 'prep'), {'exclusive_ticks': 31}),
                                (('vk_bind', 'prep'), {'max_ticks': 0}),
                                (('vk_bind', 'prep'), {'thread_sum_outer_elapsed_ticks': 1})]:
                report = analyze([banner(component)] + snapshot(component, 1, changes={key: fields}) + snapshot(component, 2))
                self.assertEqual(report['usable_intervals'], 0)
            report = analyze([banner(component)] + snapshot(component, 1) + snapshot(component, 2, changes={('spec_data_excluded', 'prep'): {'calls': 1}}))
            self.assertEqual(report['usable_intervals'], 0)
        report = analyze([banner('vkd3d')] + snapshot('vkd3d', 1) + snapshot('vkd3d', 2, changes={('simple_rtv', 'prep'): {'calls': 1}}))
        self.assertIn('excluded operation', reasons(report))

    def test_excluded_descendants_and_copy_work_counts_are_not_opportunity(self):
        for component in ('dxvk', 'vkd3d'):
            lines = [banner(component)]
            prep = 'prep' if component == 'dxvk' else 'prep_graphics'
            elapsed = 'inclusive_ticks' if component == 'dxvk' else 'elapsed_ticks'
            for n in (1, 2):
                changes = {
                    (prep, 'prep'): {elapsed: n * 110, 'direct_child_ticks': n * 50,
                                     'max_ticks': 110, 'thread_sum_outer_elapsed_ticks': n * 110},
                    ('spec_data_excluded', 'excluded'): {elapsed: n * 20, 'direct_child_ticks': n * 10, 'max_ticks': 20},
                    ('vk_bind', 'excluded'): {'calls': n, 'completed': n, 'timed_calls': n,
                        elapsed: n * 10, 'exclusive_ticks': n * 10, 'max_ticks': 10},
                }
                if component == 'vkd3d':
                    changes['simple_resource', 'standalone'] = dict(calls=n, completed=n, timed_calls=n,
                        elapsed_ticks=n * 5, exclusive_ticks=n * 5, max_ticks=5,
                        thread_sum_outer_elapsed_ticks=n * 5, requested_elements=n * 4,
                        processed_elements=n * 4, metadata_bytes=n * 16, payload_bytes=0, work_unknown=n)
                lines.extend(snapshot(component, n, changes=changes))
            report = analyze(lines)
            self.assertEqual(report['status'], 'ok')
            interval = report['streams'][0]['intervals'][0]
            self.assertEqual(interval['category_elapsed']['prep']['ticks'], 90)
            self.assertEqual(interval['category_elapsed']['excluded']['ticks'], 20)
            if component == 'vkd3d':
                row = next(r for r in interval['rows'] if r['op'] == 'simple_resource' and r['category'] == 'standalone')
                self.assertEqual((row['requested_elements'], row['processed_elements'], row['metadata_bytes']), (4, 4, 16))
                self.assertEqual((row['payload_bytes'], row['work_unknown']), (0, 1))

    def test_bad_boundary_history_and_sticky_saturation_cannot_recover(self):
        for component in OPERATIONS:
            op, cat = ('update', 'native') if component == 'kk' else ('vk_bind', 'prep')
            report = analyze([banner(component)] + snapshot(component, 1, changes={(op, cat): {'clock_errors': 1}})
                + snapshot(component, 2, changes={(op, cat): {'clock_errors': 1}}))
            self.assertEqual(report['usable_intervals'], 0)
            self.assertTrue(all(not b['valid'] for b in report['streams'][0]['snapshots']))
            report = analyze([banner(component)] + snapshot(component, 1, meta={'overflow': 1})
                + snapshot(component, 2) + snapshot(component, 3))
            self.assertEqual(report['usable_intervals'], 0)
            # A reset cannot silently invent a fresh epoch under unchanged IDs.
            report = analyze(fixture(component) + snapshot(component, 3, meta={DENOMINATOR[component]: 0})
                + snapshot(component, 4, meta={DENOMINATOR[component]: 1}) + snapshot(component, 5, meta={DENOMINATOR[component]: 2}))
            self.assertEqual([i['valid'] for i in report['streams'][0]['intervals']], [True, False, False, False])

    def test_randomized_missing_rows_and_invalid_tokens(self):
        rng = random.Random(431)
        for _ in range(50):
            component = rng.choice(list(OPERATIONS))
            rows = snapshot(component, 2)
            del rows[rng.randrange(len(rows))]
            report = analyze([banner(component)] + snapshot(component, 1) + rows)
            self.assertEqual(report['usable_intervals'], 0)
            bad = snapshot(component, 1)[0] + ' ' + rng.choice(['?', 'calls=00', 'pid=-1', 'v=9', '=1'])
            with self.assertRaises(ValueError):
                dp.parse_record(bad)

    def test_cli_json_text_and_no_data_exit(self):
        root = Path(__file__).resolve().parents[2]
        scratch = root / '.work' / 'agent-notes' / 'kk-parity' / 'tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            path = Path(tmp) / 'scrubbed.log'
            for content, rc in [('\n'.join(fixture('dxvk')), 0), ('nothing', 1),
                                ('\n'.join(fixture('dxvk')) + '\n[bad-descriptor]', 1)]:
                path.write_text(content)
                command = [sys.executable, str(root / 'tools/descriptorprof.py'), '--json', str(path)]
                completed = subprocess.run(command, capture_output=True, text=True, timeout=30)
                self.assertEqual(completed.returncode, rc)
                parsed = json.loads(completed.stdout)
                self.assertEqual(parsed['usable_intervals'], int(rc == 0))
            path.write_text('\n'.join(fixture('kk')))
            completed = subprocess.run([sys.executable, str(root / 'tools/descriptorprof.py'), str(path)], capture_output=True, text=True, timeout=30)
            self.assertEqual(completed.returncode, 0)
            self.assertIn('usable intervals=1', completed.stdout)
            path.write_text('\n'.join(fixture('kk') + snapshot('kk', 3, meta={'overflow': 1})))
            completed = subprocess.run([sys.executable, str(root / 'tools/descriptorprof.py'), '--json', str(path)], capture_output=True, text=True, timeout=30)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(json.loads(completed.stdout)['status'], 'mixed')


if __name__ == '__main__':
    unittest.main()
