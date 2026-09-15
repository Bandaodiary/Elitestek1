"""Generate disposable full-frame inputs/expected writes for detached xsim."""
import argparse,json
from pathlib import Path
from run_r2_graph_probe import vectors
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--width',type=int,default=640);p.add_argument('--height',type=int,default=480);args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
m=vectors(args.output,args.width,args.height)
(args.output/'metadata.json').write_text(json.dumps(m),encoding='utf-8')
print('C1_R2_STREAM_XSIM_VECTORS '+json.dumps({k:v for k,v in m.items() if k!='frames'}))
