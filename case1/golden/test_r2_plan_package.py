"""Binding, independent command decode and numerical graph checks for C17."""
import dataclasses
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'model'))
from r2_plan_package import (compile_package, profile_nodes, export_new, verify, nodes_from_manifest,
                             DEFAULT_ARTIFACT, Node, FRAME)
from r2_plan_vectors import infer
from microstyle_quant import integer_infer_rgb, _integer_conv
from generate_microstyle_engine_bitexact_vectors import _image
from export_r2_graph_parameters import build as retained_parameters


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = compile_package(profile_nodes('microstyle24'))
        cls.variant = compile_package(profile_nodes('drop_res1'))

    def test_current_image_exactly_retained_export(self):
        image, info = retained_parameters(DEFAULT_ARTIFACT)
        self.assertEqual(self.base.image, image)
        self.assertEqual(self.base.manifest['transfer_beats128'], info['transfer_beats128'])
        self.assertEqual((len(image), info['active_bytes']), (180224, 37328))

    def test_variant_offsets_follow_plan_not_original_layer_numbers(self):
        m = self.variant.manifest
        self.assertEqual((len(m['steps']), len(m['bindings']), m['image_bytes'], m['active_bytes'], m['transfer_beats128']),
                         (18, 13, 147456, 28496, 1781))
        bound = {r['name']: r for r in m['stages']}
        self.assertEqual(bound['res2.expand1x1']['stage'], 6)
        self.assertEqual(bound['res2.expand1x1']['offset'], 6*8192)
        self.assertEqual(bound['output.conv3x3']['stage'], 16)
        self.assertFalse(m['quality_validated'])
        self.assertFalse(m['topology_retraining_performed'])
        for i in (5, 9, 10, 13, 17):
            self.assertEqual(self.variant.image[i*8192:(i+1)*8192], bytes(8192))

    def test_independent_command_decoder_recovers_bound_arrays(self):
        for package in (self.base, self.variant):
            for stage in package.manifest['stages']:
                commands = {}
                for offset in range(stage['offset'], stage['offset']+stage['commands']*8, 8):
                    v, = struct.unpack_from('<Q', package.image, offset)
                    self.assertEqual(v >> 48, 0)
                    key = ((v >> 46) & 3, (v >> 32) & 0x3fff)
                    self.assertNotIn(key, commands)
                    commands[key] = v & 0xffffffff
                weights, biases, mults, shifts = package.layers[stage['name']]
                for co in range(weights.shape[0]):
                    terms = weights[co].transpose(1, 2, 0).reshape(-1)
                    for k, expected in enumerate(terms):
                        word_address = (co % 8)*256+(co//8)*32+(k//16)*4+(k % 16)//4
                        b = (commands[(1, word_address)] >> ((k % 4)*8)) & 255
                        self.assertEqual(b if b < 128 else b-256, int(expected))
                    b = commands[(2, co)]
                    self.assertEqual(b if b < (1 << 31) else b-(1 << 32), int(biases[co]))
                    q = commands[(3, co)]
                    mult = q & 0x3ffff
                    self.assertEqual(mult if mult < (1 << 17) else mult-(1 << 18), int(mults[co]))
                    self.assertEqual((q >> 18) & 63, int(shifts[co]))

    def test_explicit_renaming_and_binding(self):
        nodes = profile_nodes('drop_res1')
        names = {n.spec.name: f'tensor_{i}' for i, n in enumerate(nodes)} | {FRAME: FRAME}
        renamed = [Node(dataclasses.replace(n.spec, name=names[n.spec.name]), tuple(names[x] for x in n.inputs)) for n in nodes]
        mapping = {names[k]: v for k, v in self.variant.manifest['bindings'].items()}
        package = compile_package(renamed, bindings=mapping)
        self.assertEqual(package.image, self.variant.image)
        self.assertEqual(len(package.manifest['steps']), 18)
        with self.assertRaisesRegex(ValueError, 'binding'):
            compile_package(renamed)

    def test_missing_extra_unknown_and_wrong_shape_bindings(self):
        mapping = dict(self.base.manifest['bindings'])
        first = 'encoder1.conv3x3_s2'
        for changes in ({first: 'absent'}, {'extra': first}, {first: 'encoder2.conv3x3_s2'}):
            with self.assertRaises(ValueError):
                compile_package(profile_nodes('microstyle24'), bindings=mapping | changes)
        del mapping[first]
        with self.assertRaises(ValueError):
            compile_package(profile_nodes('microstyle24'), bindings=mapping)

    def test_source_stride_activation_scale_and_bounds_rejected(self):
        manifest = json.loads((DEFAULT_ARTIFACT/'manifest.json').read_text())
        arena = (DEFAULT_ARTIFACT/manifest['parameter_file']).read_bytes()
        with tempfile.TemporaryDirectory(prefix='c1_r2_bound_unit_', dir=ROOT/'sim') as td:
            p = Path(td)
            (p/manifest['parameter_file']).write_bytes(arena)
            for change in (dict(stride=1), dict(groups=3), dict(activation=0), dict(input_scale=1/127),
                           dict(output_scale=float('nan')), dict(weight_offset=-1), dict(shift_offset=len(arena)),
                           dict(weight_shape=[12, 3, 1, 1])):
                m = json.loads(json.dumps(manifest))
                m['quantized_layers'][0].update(change)
                (p/'manifest.json').write_text(json.dumps(m))
                with self.assertRaises(ValueError):
                    compile_package(profile_nodes('microstyle24'), p)

    def test_residual_scale_and_rgb_grid_rejected(self):
        manifest = json.loads((DEFAULT_ARTIFACT/'manifest.json').read_text())
        with tempfile.TemporaryDirectory(prefix='c1_r2_bound_unit_', dir=ROOT/'sim') as td:
            p = Path(td)
            (p/manifest['parameter_file']).write_bytes((DEFAULT_ARTIFACT/manifest['parameter_file']).read_bytes())
            for name in ('res0.project1x1', 'output.conv3x3'):
                m = json.loads(json.dumps(manifest))
                next(r for r in m['quantized_layers'] if r['name'] == name)['output_scale'] *= 2
                (p/'manifest.json').write_text(json.dumps(m))
                with self.assertRaisesRegex(ValueError, 'residual quantization|RGB conversion'):
                    compile_package(profile_nodes('drop_res1'), p)

    def test_package_roundtrip_refuses_stale_files_and_overwrite(self):
        self.assertEqual(nodes_from_manifest(self.variant.manifest), profile_nodes('drop_res1'))
        with tempfile.TemporaryDirectory(prefix='c1_r2_bound_unit_', dir=ROOT/'sim') as td:
            folder = Path(td)/'package'
            export_new(self.variant, folder)
            verify(self.variant, folder)
            with self.assertRaises(FileExistsError):
                export_new(self.variant, folder)
            for name in ('parameters.bin', 'execution_plan.sv', 'manifest.json'):
                original = (folder/name).read_bytes()
                (folder/name).write_bytes(original+b'bad')
                with self.assertRaisesRegex(ValueError, 'stale/mismatched'):
                    verify(self.variant, folder)
                (folder/name).write_bytes(original)

    def test_current_dag_oracle_equals_retained_integer_network(self):
        for w, h in ((4, 4), (8, 12), (32, 32)):
            rgb = _image(w, h)
            output, tensors = infer(profile_nodes('microstyle24', w, h), self.base.layers, rgb)
            reference, ref_tensors = integer_infer_rgb(rgb, DEFAULT_ARTIFACT, collect=True)
            np.testing.assert_array_equal(output, reference)
            self.assertEqual(set(tensors), set(ref_tensors))
            for name in tensors:
                np.testing.assert_array_equal(tensors[name], ref_tensors[name])

    def test_variant_oracle_equals_independent_two_block_sequence(self):
        nodes = profile_nodes('drop_res1', 32, 32)
        rgb = _image(32, 32)
        output, tensors = infer(nodes, self.variant.layers, rgb)
        specs = {n.spec.name: n.spec for n in nodes}
        recorded = {}
        def conv(name, value):
            s = specs[name]
            v = _integer_conv(value, *self.variant.layers[name], s.stride,
                              s.input_channels if 'depthwise' in name else 1, s.activation)
            recorded[name] = v
            return v
        v = conv('encoder1.conv3x3_s2', (rgb.astype(np.int16)-128).astype(np.int8))
        v = conv('encoder2.conv3x3_s2', v)
        for b in (0, 2):
            skip = v.astype(np.int16)
            v = conv(f'res{b}.expand1x1', v)
            v = conv(f'res{b}.depthwise3x3', v)
            v = conv(f'res{b}.project1x1', v)
            v = np.maximum(np.clip(v.astype(np.int16)+skip, -128, 127), 0).astype(np.int8)
            recorded[f'res{b}.add_relu'] = v
        for b in (1, 2):
            v = np.repeat(np.repeat(v, 2, axis=0), 2, axis=1)
            recorded[f'decoder{b}.upsample2'] = v
            v = conv(f'decoder{b}.depthwise3x3', v)
            v = conv(f'decoder{b}.pointwise1x1', v)
        v = conv('output.conv3x3', v)
        recorded['output.s8_to_rgb'] = (v.astype(np.int16)+128).astype(np.uint8)
        self.assertEqual(set(recorded), set(tensors))
        for name in recorded:
            np.testing.assert_array_equal(recorded[name], tensors[name])
        base, _ = integer_infer_rgb(rgb, DEFAULT_ARTIFACT, collect=False)
        self.assertGreater(np.count_nonzero(base != output), 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
