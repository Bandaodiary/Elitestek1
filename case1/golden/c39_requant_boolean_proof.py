"""Exact ROBDD equivalence of the requant arithmetic expressions, not RTL formal.

Enumerate shifts 0..47, symbolically cover every 49-bit unsigned magnitude,
sign and ReLU flag. This strictly includes abs(signed32 * signed18) <= 2**48.
The 52-bit biased addition cannot wrap over this larger domain.
Pipeline/handshake correctness still requires the independent RTL cycle miter.
No solver download, EDA launch, generated simulation database or waveform.
"""
import itertools
import json
import random
import re
import time
from c39_onehot_sources import ROOT, verify


def arithmetic_anchors(candidate=None, baseline=None):
    """Guard the manual translation against changed source expressions.

    These are source-anchor checks, NOT a SystemVerilog parser or formal RTL
    elaboration. They cannot replace cycle miter/whole-host simulation.
    """
    if candidate is None:
        candidate = (ROOT / 'rtl/c39/c39_requant_bank8_narrow.sv').read_text(encoding='utf-8-sig')
    if baseline is None:
        baseline = (ROOT / 'rtl/cnn/c1_requant_bank8_compact.sv').read_text(encoding='utf-8-sig')
    def normalize(text):
        return re.sub(r'\s+', '', re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S))
    anchors = (
        (candidate, (
            "product_q<=$signed(in_acc_s32[c*32+:32])*$signed(in_mult_s18[c*18+:18]);",
            "wire signed [51:0] extended={product_q[50],product_q};",
            "magnitude_q<=product_q[50] ? $unsigned(-extended) : $unsigned(extended);",
            "wire [51:0] shifted=magnitude_q >> magnitude_shift_q;",
            "wire guard_bit=magnitude_shift_q!=0 && ((magnitude_q >> (magnitude_shift_q-1'b1)) & 52'd1)!=0;",
            "quotient_q<={negative_q,|shifted[51:8],guard_bit,shifted[7:0]};",
            "wire [8:0] low_sum={1'b0,quotient_q[7:0]}+{8'd0,quotient_q[8]};",
            "wire [9:0] rounded={quotient_q[10],quotient_q[9] | low_sum[8],low_sum[7:0]};",
            "wire negative=rounded_q[9],overflow=rounded_q[8];",
            "wire [7:0] low=rounded_q[7:0];",
            "wire [7:0] saturated=negative && act_q[3]==1 ? 8'd0 : overflow || (negative ? low>128 : low>127) ? (negative ? 8'h80 : 8'h7f) : negative ? 8'd0-low : low;",
        )),
        (baseline, (
            "if (shift == 0) add_round_bias = magnitude; else begin bias = 52'd1 << (shift - 1'b1); add_round_bias = magnitude + bias; end",
            "shifted_magnitude = biased_magnitude >> shift;",
            "shifted_record = {negative, |shifted_magnitude[51:8], shifted_magnitude[7:0]};",
        )),
    )
    count = 0
    for text, expressions in anchors:
        compact = normalize(text)
        for expression in expressions:
            if compact.count(normalize(expression)) != 1:
                raise ValueError('quant arithmetic source anchor changed: ' + expression)
            count += 1
    return count


class BDD:
    def __init__(self):
        self.nodes = [(999, 0, 0), (999, 1, 1)]
        self.unique = {}
        self.memo = {}

    def node(self, var, low, high):
        if low == high:
            return low
        key = var, low, high
        if key not in self.unique:
            if len(self.nodes) >= 100000:
                raise RuntimeError('bounded proof node budget exceeded; no equivalence claim')
            self.unique[key] = len(self.nodes)
            self.nodes.append(key)
        return self.unique[key]

    def variable(self, var):
        return self.node(var, 0, 1)

    def op(self, kind, a, b):
        if a > b:
            a, b = b, a
        key = kind, a, b
        if key in self.memo:
            return self.memo[key]
        if a < 2 and b < 2:
            return {'and': a & b, 'or': a | b, 'xor': a ^ b}[kind]
        var = min(self.nodes[a][0], self.nodes[b][0])
        al, ah = self.nodes[a][1:] if self.nodes[a][0] == var else (a, a)
        bl, bh = self.nodes[b][1:] if self.nodes[b][0] == var else (b, b)
        result = self.node(var, self.op(kind, al, bl), self.op(kind, ah, bh))
        self.memo[key] = result
        return result

    def inv(self, value):
        return self.op('xor', value, 1)

    def choose(self, select, yes, no):
        return self.op('or', self.op('and', select, yes), self.op('and', self.inv(select), no))

    def any(self, values):
        result = 0
        for value in values:
            result = self.op('or', result, value)
        return result

    def add(self, a, b):
        if len(a) != len(b):
            raise ValueError('adder widths differ')
        carry, result = 0, []
        for x, y in zip(a, b):
            xy = self.op('xor', x, y)
            result.append(self.op('xor', xy, carry))
            carry = self.op('or', self.op('and', x, y), self.op('and', xy, carry))
        return result

    def evaluate(self, node, assignment):
        while node > 1:
            var, low, high = self.nodes[node]
            node = high if assignment.get(var, 0) else low
        return node

    def witness(self, node):
        if not node:
            raise ValueError('unsatisfiable formula has no witness')
        result = {}
        while node > 1:
            var, low, high = self.nodes[node]
            result[var] = 0 if low else 1
            node = low or high
        return result


def record(bdd, magnitude, shift, mutation=None):
    bias = [0] * 52
    if shift:
        bias[shift - 1] = 1
    biased = bdd.add(magnitude, bias)
    shifted_old = biased[shift:] + [0] * shift
    reference = shifted_old[:8] + [bdd.any(shifted_old[8:])]
    quotient = magnitude[shift:] + [0] * shift
    guard = magnitude[shift - 1] if shift else 0
    if mutation == 'drop_guard':
        guard = 0
    low_sum = bdd.add(quotient[:8] + [0], [guard] + [0] * 8)
    carry = 0 if mutation == 'drop_carry' else low_sum[8]
    candidate = low_sum[:8] + [bdd.op('or', bdd.any(quotient[8:]), carry)]
    return reference, candidate


def activate(bdd, value, negative, relu):
    low, overflow = value[:8], value[8]
    # Positive >127: bit7. Negative >128: bit7 AND any low seven bits.
    beyond = bdd.choose(negative, bdd.op('and', low[7], bdd.any(low[:7])), low[7])
    clip = bdd.op('or', overflow, beyond)
    negated = bdd.add([bdd.inv(v) for v in low], [1] + [0] * 7)
    zero = bdd.op('and', negative, relu)
    result = []
    for bit in range(8):
        limit = negative if bit == 7 else bdd.inv(negative)
        signed = bdd.choose(negative, negated[bit], low[bit])
        result.append(bdd.choose(zero, 0, bdd.choose(clip, limit, signed)))
    return result


def number(bdd, bits, assignment):
    return sum(bdd.evaluate(value, assignment) << i for i, value in enumerate(bits))


def truth_selftest():
    bdd = BDD()
    values = [bdd.variable(i) for i in range(8)]
    added = bdd.add(values[:4] + [0], values[4:] + [0])
    comparisons = 0
    for a, b in itertools.product(range(16), repeat=2):
        assignment = {i: (a if i < 4 else b) >> (i % 4) & 1 for i in range(8)}
        if number(bdd, added, assignment) != a + b:
            raise AssertionError('BDD adder truth-table mismatch')
        for kind, expected in (('and', (a & 1) & (b & 1)), ('or', (a & 1) | (b & 1)),
                               ('xor', (a & 1) ^ (b & 1))):
            if bdd.evaluate(bdd.op(kind, values[0], values[4]), assignment) != expected:
                raise AssertionError('BDD Boolean truth-table mismatch')
        if bdd.op('xor', bdd.op('and', values[0], values[4]), bdd.op('and', values[4], values[0])):
            raise AssertionError('BDD canonical identity mismatch')
        comparisons += 1
    return comparisons


def main():
    started = time.monotonic()
    verify()  # Exact parent/candidate source generation, no source rewriting.
    anchors = arithmetic_anchors()
    source = (ROOT / 'rtl/c39/c39_requant_bank8_narrow.sv').read_text(encoding='utf-8-sig')
    source_negatives = 0
    for old, new in (("+{8'd0,quotient_q[8]}", "+9'd0"),
                     ('quotient_q[9] | low_sum[8]', 'quotient_q[9]'),
                     ('low>128 : low>127', 'low>127 : low>127')):
        if source.count(old) != 1:
            raise ValueError('source negative anchor missing')
        try:
            arithmetic_anchors(source.replace(old, new))
        except ValueError:
            source_negatives += 1
        else:
            raise AssertionError('changed arithmetic source accepted')
    checks = truth_selftest()
    maximum_nodes = 0
    sampled = 0
    failures = {}
    rng = random.Random(390052)
    for shift in range(48):
        bdd = BDD()
        negative, relu = bdd.variable(0), bdd.variable(1)
        magnitude = [bdd.variable(bit + 2) for bit in range(49)] + [0] * 3
        reference, candidate = record(bdd, magnitude, shift)
        ref_output = activate(bdd, reference, negative, relu)
        candidate_output = activate(bdd, candidate, negative, relu)
        if reference != candidate or ref_output != candidate_output:
            raise AssertionError('symbolic expression mismatch at shift ' + str(shift))
        # Independent Python integers cross-check evaluation and sign/saturation.
        for m in [0, 1, (1 << 48), (1 << 49) - 1] + [rng.randrange(1 << 49) for _ in range(12)]:
            for neg, activation in itertools.product((0, 1), repeat=2):
                assignment = {bit + 2: m >> bit & 1 for bit in range(49)}
                assignment.update({0: neg, 1: activation})
                rounded = (m + ((1 << (shift - 1)) if shift else 0)) >> shift
                integer = min(127, max(-128, -rounded if neg else rounded))
                if neg and activation:
                    integer = 0
                if number(bdd, reference, assignment) != (rounded & 255) + (256 if rounded >= 256 else 0):
                    raise AssertionError('symbolic record differs from integer arithmetic')
                if number(bdd, ref_output, assignment) != integer & 255:
                    raise AssertionError('symbolic activation differs from integer arithmetic')
                sampled += 1
        for mutation in ('drop_guard', 'drop_carry'):
            if mutation in failures:
                continue
            _, bad = record(bdd, magnitude, shift, mutation)
            bad_output = activate(bdd, bad, negative, relu)
            difference = bdd.any([bdd.op('xor', x, y) for x, y in zip(ref_output, bad_output)])
            if difference:
                witness = bdd.witness(difference)
                value = number(bdd, magnitude, witness)
                failures[mutation] = dict(shift=shift, magnitude=value,
                    negative=witness.get(0, 0), relu=witness.get(1, 0),
                    expected=number(bdd, ref_output, witness), mutated=number(bdd, bad_output, witness))
        maximum_nodes = max(maximum_nodes, len(bdd.nodes))
    if set(failures) != {'drop_guard', 'drop_carry'}:
        raise AssertionError('symbolic negative controls did not produce counterexamples')
    print('C39_REQUANT_BOOLEAN_PROOF_PASS ' + json.dumps(dict(shifts=48,
        magnitude_bits=49, magnitude_domain='0 <= M < 2**49; superset of abs(signed32*signed18)',
        all_magnitudes_signs_relu_equivalent=True, record_bits=9, output_bits=8,
        RTL_expression_anchor_checks=anchors, source_anchor_mutations_rejected=source_negatives,
        adder_truth_table_checks=checks, independent_integer_checks=sampled,
        symbolic_mutation_counterexamples=failures, peak_nodes_per_shift=maximum_nodes,
        seconds=round(time.monotonic()-started, 3), method='canonical reduced ordered binary decision diagrams',
        RTL_formal_verified=False, pipeline_verified_by_this_proof=False,
        actual_RTL_mutated=False, EDA_launched=False, files_written=False), separators=(',', ':')))


if __name__ == '__main__':
    main()
