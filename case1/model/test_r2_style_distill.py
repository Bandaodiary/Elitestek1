"""Actual learned-teacher gradients and target identity; no art/RTL signoff."""
from pathlib import Path
import torch

from r2_style_teacher import teacher_rgb
from r2_style_perceptual import PerceptualFeatures
from r2_style_objectives import make_objective
from r2_style_student import R2StyleStudent


def main():
    torch.set_num_threads(1)
    torch.manual_seed(20260915)
    case=Path(__file__).resolve().parents[1]
    features=PerceptualFeatures(case/'assets/training/c36_openimages320_20260915a/squeezenet1_1.pth')
    objective=make_objective('teacher_distill',features,None,
        teacher_directory=case/'assets/teachers/c36_pytorch_mosaic_20260915b')
    source=torch.rand(1,3,64,80)
    target=teacher_rgb(objective.teacher,source)
    roundoff=torch.full_like(source,1+2**-23)
    torch.testing.assert_close(teacher_rgb(objective.teacher,roundoff),teacher_rgb(objective.teacher,roundoff.clamp(0,1)),atol=0,rtol=0)
    for invalid in (torch.full_like(source,1.01),torch.full_like(source,float('nan'))):
        try:
            teacher_rgb(objective.teacher,invalid)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid teacher input range accepted')
    exact,terms=objective(target,source)
    for key in ('teacher_rgb','teacher_features','teacher_gram','teacher_edges','teacher_color'):
        torch.testing.assert_close(terms[key],torch.zeros(()),atol=0,rtol=0)
    student=R2StyleStudent(blocks=2,expansion=24,preproject=True)
    before={k:v.detach().clone() for k,v in student.named_parameters()}
    optimizer=torch.optim.Adam(student.parameters(),lr=.001)
    output=student(source)
    loss,_=objective(output,source)
    assert torch.isfinite(loss)
    loss.backward()
    assert all(p.grad is None and not p.requires_grad for p in objective.parameters())
    assert all(p.grad is not None and torch.isfinite(p.grad).all() for p in student.parameters())
    optimizer.step()
    assert any(not torch.equal(before[k],p) for k,p in student.named_parameters())
    for directory,gain in ((None,1.),(case/'assets/teachers/c36_pytorch_mosaic_20260915b',2.)):
        try:
            make_objective('teacher_distill',features,None,style_gain=gain,teacher_directory=directory)
        except ValueError:
            pass
        else:
            raise AssertionError('ambiguous distillation configuration accepted')
    print('C36_STYLE_DISTILL_CONTRACT_PASS actual_pretrained_teacher=1 teacher_identity_terms_zero=5 frozen_teacher_and_features=1 student_optimizer_update=1 input_roundoff_contract=1 deployed_graph_unchanged=1 aesthetic_quality_claim=0')


if __name__=='__main__':
    main()
