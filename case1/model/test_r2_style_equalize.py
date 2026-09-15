"""Float-function preservation + fork/residual exclusion for all candidate DAGs."""
import json

import torch

from r2_style_candidates import candidates
from r2_style_equalize import equalize_student,exclusive_pairs
from r2_style_quant import fold_student
from r2_style_student import R2StyleStudent


def main():
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    torch.manual_seed(20260915)
    batches=[torch.rand(2,3,32,48),torch.rand(2,3,48,32)]
    rows=[]
    with torch.no_grad():
        for name,config in candidates():
            model=R2StyleStudent(**config)
            # Exercise nontrivial bias and negative pre-activation values.
            for layer in model.layers.values():
                layer[1].bias.uniform_(-.1,.1)
            model=fold_student(model)
            balanced,details=equalize_student(model,batches)
            maximum=0.
            for batch in batches:
                original,reference=model(batch,True)
                result,observed=balanced(batch,True)
                # Compare before the final clamp/round, which might otherwise
                # hide a broken transformation behind output saturation.
                torch.testing.assert_close(reference['output.conv3x3'],observed['output.conv3x3'],rtol=3e-5,atol=3e-6)
                maximum=max(maximum,float((original-result).abs().max()*255))
                assert maximum<=1.001
            pairs=exclusive_pairs(model.nodes)
            assert all('project1x1' not in producer and producer!='output.conv3x3' for producer,_,_ in pairs)
            if config['blocks']:
                assert all(producer!='encoder2.conv3x3_s2' for producer,_,_ in pairs)
            assert all(min(pair['gains'])>0 for pair in details['pairs'])
            rows.append(dict(candidate=name,pairs=len(pairs),max_rgb_code_delta=maximum))
    print('C36_CHANNEL_EQUALIZATION_PASS '+json.dumps(dict(candidates=len(rows),
        pre_clamp_float_function_checked=True,positive_gains=True,residual_and_fork_boundaries_preserved=True,
        RTL_operators_added=0,quality_improvement_proven=False,rows=rows)))


if __name__=='__main__':
    main()
