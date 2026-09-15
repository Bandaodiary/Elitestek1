"""Same-input, same-objective comparison of the three completed float trials.

No test split, INT8, RTL, FPS, or independent aesthetic-signoff claim.
"""
import argparse
import json
import os
from pathlib import Path
import time

from PIL import Image, ImageDraw
import psutil
import torch
from torch.nn import functional as F

from compare_r2_style_models import metrics
from prepare_r2_style_data import save_json
from r2_style_student import R2StyleStudent
from r2_style_perceptual import PerceptualFeatures, StyleObjective
from train_r2_style_student import load_rgb, evaluation_input, image_from_tensor
from train_r2_style_qat import require_float_finished


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    if root.exists():
        raise ValueError('new comparison output required')
    process = psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name == 'nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available < 8*2**30:
        raise RuntimeError('less than 8 GiB free; comparison not started')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    case = Path(__file__).resolve().parents[1]
    runs = dict(base_B='c36_train_b_starry_20260915a', gram3='c36_train_b_starry_stronger_20260915a',
                coarse_palette='c36_train_b_coarsepalette_20260915a')
    models, provenance = {}, {}
    for name, directory in runs.items():
        directory = case/'outputs'/directory
        require_float_finished(directory)
        checkpoint = torch.load(directory/'checkpoint_best.pt', map_location='cpu', weights_only=True)
        model = R2StyleStudent(**checkpoint['model_config']).eval()
        model.load_state_dict(checkpoint['model_state'], strict=True)
        model.requires_grad_(False)
        models[name] = model
        provenance[name] = dict(directory=str(directory), selected_step=checkpoint['step'],
                                config=checkpoint['model_config'], objective=checkpoint['metadata']['config'].get('objective','original'))
    dataset = case/'assets/training/c36_openimages320_20260915a'
    manifest = json.loads((dataset/'manifest.json').read_text(encoding='utf-8'))
    objective = StyleObjective(PerceptualFeatures(dataset/manifest['feature_weights']['file']),
                               load_rgb(case/'assets/styles/starry_night_public_domain.jpg',384)[None])
    root.mkdir(parents=True)
    started = time.monotonic()
    rows = []
    with torch.no_grad():
        for entry in manifest['images']:
            if entry['split'] != 'val':
                continue
            content = evaluation_input(load_rgb(dataset/entry['file']))
            for name, model in models.items():
                _, result = metrics(model, objective, content)
                rows.append(dict(image=entry['ImageID'], model=name, **result))
        for photo in ('astronaut','coffee','rocket'):
            paths = list((case/'assets/images').glob(photo+'.*'))
            if len(paths) != 1:
                raise ValueError('missing/ambiguous public preview asset: '+photo)
            content = F.interpolate(load_rgb(paths[0])[None], size=(480,640),
                                    mode='bilinear', align_corners=False, antialias=True)
            pictures = [('input',content)] + [(name+' FLOAT',model(content)) for name, model in models.items()]
            canvas = Image.new('RGB',(640,528),'white')
            draw = ImageDraw.Draw(canvas)
            for index,(name,pixels) in enumerate(pictures):
                x,y=(index%2)*320,(index//2)*264
                draw.text((x+4,y+4),name,fill='black')
                canvas.paste(image_from_tensor(pixels[0]).resize((320,240),Image.Resampling.LANCZOS),(x,y+24))
            canvas.save(root/(photo+'_float_trials.png'))
    means = {}
    for name in models:
        selected = [r for r in rows if r['model']==name]
        assert len(selected)==32
        means[name]={key:sum(r[key] for r in selected)/32 for key in selected[0] if key not in ('image','model')}
    report=dict(state='complete', elapsed_seconds=time.monotonic()-started, provenance=provenance,
                evaluation='same original RGB SqueezeNet objective, style_gain=1, for every model',
                split='val', images=32, test_images_read=0, preview_inference_shape=[480,640],
                means=means, rows=rows, quantized=False, RTL_simulated=False, aesthetic_quality_validated=False)
    save_json(root/'comparison.json', report)
    print('C36_FLOAT_CANDIDATES_COMPARED '+json.dumps({k:v for k,v in report.items() if k not in ('rows','provenance')}, separators=(',',':')))


if __name__=='__main__':
    main()
