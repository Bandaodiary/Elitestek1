"""C36 trained graph counts plus the complete retained camera/host checks."""
from pathlib import Path
import json
import re

from r2_trained_style_vectors import ROOT,bound_candidate,candidate_nodes,budget
import check_r2_rgb2_host_evidence as baseline

PREFIX='C1_R2_FUSED_RGB2_HOST_SYSTEM_'


def traffic(config,width,height):
    row=budget(candidate_nodes(**config,width=width,height=height),width,height)
    return dict(stages=row['nodes'],macs=row['macs'],features=row['cnn_feature_read_words128'],
                reads=row['cnn_feature_read_words128']+row['cnn_parameter_read_words128'],
                writes=row['cnn_write_words128'])


def check_text(text,config,nn=2,clock_native_override=None,camera_profile='legacy',core_period_ps=6666):
    def model_budget(profile,width,height):
        if profile!='c36_trained_student':
            raise ValueError('wrong trained model identity')
        return traffic(config,width,height)
    result=baseline.run(text,profile='c36_trained_student',prefix=PREFIX,expected_nn=nn,
                        clock_native_override=clock_native_override,model_budget=model_budget,camera_profile=camera_profile,
                        core_period_ps=core_period_ps)
    return dict(result,model_config=config,actual_AXI=True,actual_CPU_IP=False)


def corruption_checks(text,config,nn,clock_native_override=None,camera_profile='legacy'):
    samples=[]
    for name,damaged in (
        ('missing_PASS',text.replace(PREFIX+'PASS ',PREFIX+'OMITTED ',1)),
        ('wrong_graph',text.replace('stage_count=18','stage_count=22',1)),
        ('wrong_ownership_scope',text.replace('fresh_leases=1','fresh_leases=0',1)),
        ('wrong_cpu_checks',text.replace('apb_checks=9','apb_checks=8',1))):
        if damaged==text:
            raise ValueError('corruption did not alter evidence: '+name)
        try:
            check_text(damaged,config,nn,clock_native_override,camera_profile)
        except (ValueError,AssertionError):
            samples.append(name)
        else:
            raise ValueError('corrupted evidence accepted: '+name)
    return samples
