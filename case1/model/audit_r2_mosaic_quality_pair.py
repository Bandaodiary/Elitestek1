"""Audit frozen, paired Mosaic reports without retraining or opening images.

These metrics describe a quality tradeoff, not an objective aesthetic ranking.
Comparisons to the original float checkpoint include QAT/fine-tuning drift.
"""
import argparse
import copy
import json
import math
from pathlib import Path
import statistics


def report_rows(report,ids,expected_models):
    if report['state']!='complete' or report['images']!=32 or len(set(ids))!=32:
        raise ValueError('incomplete report/partition')
    if report['test_images_read']!=(32 if report['split']=='test' else 0):
        raise ValueError('wrong partition read scope')
    if report['RTL_simulated'] is not False or report['RTL_FPS_measured'] is not False:
        raise ValueError('software report incorrectly claims RTL')
    if set(report['means'])!=set(expected_models) or len(report['rows'])!=32*len(expected_models):
        raise ValueError('wrong model/row coverage')
    groups={}
    for model in expected_models:
        rows=[r for r in report['rows'] if r['model']==model]
        if [r['image'] for r in rows]!=ids:
            raise ValueError('missing, duplicated or reordered paired images')
        metrics=set(report['means'][model])
        if not metrics or any(set(r)-{'model','image'}!=metrics for r in rows):
            raise ValueError('inconsistent metric schema')
        for key,mean in report['means'][model].items():
            values=[r[key] for r in rows]
            if not all(type(x) in (float,int) and math.isfinite(x) for x in values+[mean]):
                raise ValueError('invalid metric')
            if not math.isclose(statistics.fmean(values),mean,rel_tol=0,abs_tol=1e-10):
                raise ValueError('published mean differs from all 32 rows')
        groups[model]=rows
    return groups


def audit_pair(candidate,original,manifest):
    if candidate['split']!=original['split'] or candidate['split'] not in ('val','test'):
        raise ValueError('mixed partitions')
    if manifest['state']!='complete':
        raise ValueError('incomplete dataset')
    ids=[r['ImageID'] for r in manifest['images'] if r['split']==candidate['split']]
    for key in ('float_run','teacher_directory'):
        if Path(candidate[key]).resolve()!=Path(original[key]).resolve():
            raise ValueError('model/teacher provenance differs')
    if (candidate['float_selected_step']!=original['float_selected_step'] or
        Path(candidate['baseline_qat_run']).resolve()!=Path(original['qat_run']).resolve() or
        Path(candidate['qat_run']).resolve()==Path(original['qat_run']).resolve()):
        raise ValueError('candidate/baseline selection differs')
    new=report_rows(candidate,ids,('mosaic_FLOAT','mosaic_INT8','mosaic_BASELINE_INT8'))
    old=report_rows(original,ids,('mosaic_FLOAT','mosaic_INT8'))
    compared=0
    for a,b in (('mosaic_FLOAT','mosaic_FLOAT'),('mosaic_BASELINE_INT8','mosaic_INT8')):
        for left,right in zip(new[a],old[b]):
            for metric,value in left.items():
                if metric in ('image','model'):
                    continue
                if not math.isclose(value,right[metric],rel_tol=0,abs_tol=1e-7):
                    raise ValueError('unchanged baseline/float did not reproduce on the same input')
                compared+=1
    changed={}
    for metric in candidate['means']['mosaic_INT8']:
        before=original['means']['mosaic_INT8'][metric]
        after=candidate['means']['mosaic_INT8'][metric]
        deltas=[a[metric]-b[metric] for a,b in zip(new['mosaic_INT8'],old['mosaic_INT8'])]
        changed[metric]=dict(baseline=before,candidate=after,mean_delta=after-before,
            relative_change=None if before==0 else after/before-1,
            images_increased=sum(x>1e-7 for x in deltas),images_decreased=sum(x< -1e-7 for x in deltas),
            images_equal=sum(abs(x)<=1e-7 for x in deltas),median_delta=statistics.median(deltas))
    return dict(split=candidate['split'],images=32,all_images_retained=True,
        repeated_reference_scalar_checks=compared,baseline_and_float_reproduced=True,
        frozen_float_step=candidate['float_selected_step'],frozen_candidate_QAT_step=candidate['QAT_selected_step'],
        frozen_baseline_QAT_step=original['QAT_selected_step'],metrics=changed,
        teacher_similarity_is_aesthetic_score=False,automatic_replacement_recommended=False,
        original_float_comparison_includes_fine_tuning_drift=True,isolated_quantization_error_measured=False,
        input_images_opened_by_audit=0,new_RTL_results=False,
        test_is_first_blind_project_evaluation=False)


def negative_controls(candidate,original,manifest):
    cases=[]
    for key,value in (('split','val' if candidate['split']=='test' else 'test'),('images',31),
                      ('test_images_read',99),('float_selected_step',-1),('RTL_simulated',True)):
        bad=copy.deepcopy(candidate);bad[key]=value;cases.append((key,bad))
    bad=copy.deepcopy(candidate);bad['rows'][0]['image']='wrong-image';cases.append(('wrong_image',bad))
    bad=copy.deepcopy(candidate);bad['means']['mosaic_INT8']['teacher_mae_u8']+=.1;cases.append(('wrong_mean',bad))
    bad=copy.deepcopy(candidate);bad['baseline_qat_run']=candidate['qat_run'];cases.append(('wrong_baseline',bad))
    # Change the rerun reference AND its mean; aggregate self-consistency alone
    # must not hide a changed baseline relative to the earlier frozen run.
    bad=copy.deepcopy(candidate)
    next(r for r in bad['rows'] if r['model']=='mosaic_BASELINE_INT8')['teacher_mae_u8']+=1
    bad['means']['mosaic_BASELINE_INT8']['teacher_mae_u8']+=1/32
    cases.append(('changed_reference_and_mean',bad))
    for name,bad in cases:
        try:
            audit_pair(bad,original,manifest)
        except (ValueError,KeyError):
            pass
        else:
            raise AssertionError('corrupted paired report accepted: '+name)
    return [name for name,_ in cases]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--dataset-manifest',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    case=Path(__file__).resolve().parents[1]
    root=args.output.resolve()
    if root.exists() or not root.is_relative_to(case/'outputs'):
        raise ValueError('new case1/outputs audit directory required')
    read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
    candidate,original,manifest=map(read,(args.candidate,args.baseline,args.dataset_manifest))
    result=audit_pair(candidate,original,manifest)
    result['corruption_controls_rejected']=negative_controls(candidate,original,manifest)
    result['source_reports']=[str(args.candidate.resolve()),str(args.baseline.resolve())]
    root.mkdir(parents=True)
    (root/'audit.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('C36_MOSAIC_PAIRED_AUDIT_PASS '+json.dumps(result,separators=(',',':')))


if __name__=='__main__':
    main()
