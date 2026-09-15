import unittest
from r2_architecture_budget import plan

class BudgetTest(unittest.TestCase):
    def test_native_work(self):
        for r in (4,6,8):
            c=plan(rows=r)
            self.assertEqual(sum(s['macs'] for s in c['stages']),428236800)
            self.assertEqual(c['old_minimum_cycles'],8928000)
            for s in c['stages']:
                self.assertGreaterEqual(s['array_beats']*r*16,s['macs'])
    def test_tail_mapping(self):
        c=plan(rows=8)
        self.assertEqual(c['stages'][20]['reduction_length'],72)
        self.assertEqual(c['stages'][20]['array_beats'],576000)
        self.assertEqual(c['minimum_cycles'],4396800)
    def test_tile_rounding_not_global_division(self):
        a=plan(rows=6,tile_w=1,tile_h=1);b=plan(rows=6,tile_w=32,tile_h=16)
        self.assertGreater(a['minimum_cycles'],b['minimum_cycles'])
    def test_special_ops(self):
        c=plan()
        self.assertEqual(c['stages'][18]['reduction_length'],9)
        self.assertEqual(sum(s['linear_beats'] for s in c['stages']),172800)
        for i in (14,17,21):self.assertEqual(c['stages'][i]['minimum_cycles'],0)
    def test_invalid(self):
        for kw in ({'rows':0},{'rows':7},{'tile_w':0},{'width':639},{'requant_lanes':0}):
            with self.assertRaises(ValueError):plan(**kw)
    def test_quantizer_not_free(self):
        self.assertEqual(plan(rows=8,requant_lanes=4)['minimum_cycles'],5894400)
        for r in (4,6,8):
            self.assertEqual(plan(rows=r,requant_lanes=r)['minimum_cycles'],plan(rows=r)['minimum_cycles'])
            self.assertGreater(plan(rows=r,requant_lanes=2)['minimum_cycles'],plan(rows=r)['minimum_cycles'])

if __name__=='__main__':unittest.main()
