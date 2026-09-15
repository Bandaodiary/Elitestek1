"""Small CPU float-shape/gradient checks; never called a trained quality test."""
import json
import torch
from torch import nn

from microstyle_model import MicroStyle24
from r2_style_candidates import candidate_nodes,candidates
from r2_style_student import R2StyleStudent,copy_retained_float_baseline
from r2_plan_package import compile_package


def main():
    torch.set_num_threads(1);torch.set_num_interop_threads(1);torch.manual_seed(20260915)
    x=torch.linspace(0,1,2*3*12*16).reshape(2,3,12,16)
    baseline=MicroStyle24().eval();reference=R2StyleStudent(3,48,False).eval()
    copy_retained_float_baseline(reference,baseline)
    with torch.no_grad():
        assert torch.equal(reference(x),baseline(x)),'original float arithmetic changed'
    rows=[]
    for name,config in candidates():
        model=R2StyleStudent(**config).eval()
        nodes=candidate_nodes(**config,width=16,height=12)
        with torch.no_grad():
            output,stages=model(x,return_stages=True)
        assert output.shape==x.shape and torch.isfinite(output).all()
        assert output.min()>=0 and output.max()<=1
        for n in nodes:
            s=n.spec
            assert tuple(stages[s.name].shape)==(2,s.output_channels,s.output_height,s.output_width)
        actual=sum(m.weight.numel() for m in model.modules() if isinstance(m,nn.Conv2d))
        assert actual==sum(n.spec.weight_count for n in nodes)
        rows.append(dict(name=name,convolution_weights=actual,checked_tensor_shapes=len(nodes)))
    # Test that the suggested student's training graph is connected. This is
    # one forward/backward pass, not optimization or image-quality evidence.
    student=R2StyleStudent().train();out=student(x)
    loss=(out-x).square().mean();loss.backward()
    weights=[m.weight for m in student.modules() if isinstance(m,nn.Conv2d)]
    assert all(w.grad is not None and torch.isfinite(w.grad).all() and torch.count_nonzero(w.grad)>0 for w in weights)
    try:compile_package(candidate_nodes(blocks=2,expansion=24,preproject=True))
    except ValueError as exc:
        assert 'bound weight shape mismatch' in str(exc),'unexpected stale-weight rejection'
    else:raise AssertionError('old weight artifact silently accepted for a different student')
    print('C36_STYLE_FLOAT_REFERENCE_PASS '+json.dumps(dict(candidates=len(rows),baseline_float_exact=True,
        connected_trainable_convolutions=len(weights),trained=False,QAT_exported=False,
        stale_weight_binding_rejected=True,quality_validated=False,RTL_simulated=False,rows=rows),separators=(',',':')))


if __name__=='__main__':main()
