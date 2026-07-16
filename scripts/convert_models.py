#!/usr/bin/env python3
"""
Batch convert Filter4Free PyTorch models to CoreML (.mlmodel) format.

Usage:
    python scripts/convert_models.py --checkpoints-dir ./pretrained_checkpoints --output-dir ./assets/models

Requirements:
    pip install coremltools torch torchvision pillow numpy opencv-python tqdm

Note: coremltools only runs on macOS. Run this script on a Mac or via CI.
"""

import os
import sys
import argparse
import glob
from pathlib import Path

# Add filter4free to path for model imports
# Try both relative to script (camera_app/filter4free/) and
# relative to repo root (../filter4free/)
_script_dir = os.path.dirname(os.path.abspath(__file__))
for _path in [
    os.path.join(_script_dir, '..', 'filter4free'),
    os.path.join(_script_dir, '..', '..', 'filter4free'),
    os.path.join(_script_dir, '..', 'filter4free_checkpoints'),
]:
    if os.path.isdir(_path):
        sys.path.insert(0, _path)
        break

import torch
import numpy as np
from torchvision.transforms import ToPILImage

try:
    import coremltools as ct
except ImportError:
    print("ERROR: coremltools is required. Install with: pip install coremltools")
    print("NOTE: coremltools only works on macOS.")
    sys.exit(1)

from models import FilterSimulation4, FilterSimulation3, FilterSimulation2


# Map of filter names to their model architectures
# Format: (model_class, input_size, description)
FILTER_CONFIGS = {
    # Fuji filters
    'fuji_acros':              (FilterSimulation4, 480, 'ACROS black & white film simulation'),
    'fuji_classic_chrome':     (FilterSimulation4, 480, 'CLASSIC CHROME film simulation'),
    'fuji_eterna':             (FilterSimulation4, 480, 'ETERNA cinema film simulation'),
    'fuji_eterna_bleach':      (FilterSimulation4, 480, 'ETERNA BLEACH BYPASS simulation'),
    'fuji_classic_neg':        (FilterSimulation4, 480, 'CLASSIC Neg. film simulation'),
    'fuji_pro_neg_hi':         (FilterSimulation4, 480, 'PRO Neg.Hi portrait film'),
    'fuji_nostalgic_neg':      (FilterSimulation4, 480, 'NOSTALGIC Neg. film simulation'),
    'fuji_pro_neg_std':        (FilterSimulation4, 480, 'PRO Neg.Std film simulation'),
    'fuji_astia':              (FilterSimulation4, 480, 'ASTIA slide film simulation'),
    'fuji_provia':             (FilterSimulation4, 480, 'PROVIA slide film simulation'),
    'fuji_velvia':             (FilterSimulation4, 480, 'VELVIA vivid slide film'),
    'fuji_pro400h':            (FilterSimulation4, 480, 'Pro 400H color negative film'),
    'fuji_superia400':         (FilterSimulation4, 480, 'Superia 400 color negative film'),
    'fuji_reala':              (FilterSimulation4, 480, 'Reala color negative film'),

    # Kodak filters
    'kodak_color_plus':        (FilterSimulation4, 480, 'Color Plus 200 film'),
    'kodak_gold200':           (FilterSimulation4, 480, 'Gold 200 warm negative film'),
    'kodak_portra400':         (FilterSimulation4, 480, 'Portra 400 professional portrait film'),
    'kodak_portra160nc':       (FilterSimulation4, 480, 'Portra 160NC neutral color film'),
    'kodak_ultramax400':       (FilterSimulation4, 480, 'UltraMax 400 vivid film'),

    # Olympus filters
    'olympus_vivid':           (FilterSimulation4, 480, 'Olympus VIVID color mode'),

    # Polaroid
    'polaroid':                (FilterSimulation4, 480, 'Polaroid instant film look'),
}

# EDSR-Base x2 super-resolution model config
EDSR_CONFIG = {
    'name': 'edsr_base_x2',
    'input_size': 224,  # 224x224 input → 448x448 output per tile
    'description': 'EDSR-Base x2 super-resolution upscale',
    'n_resblocks': 16,
    'n_feats': 64,
    'scale': 2,
    'res_scale': 1.0,
}


def convert_edsr_model(checkpoint_path: str, output_path: str, input_size: int = 224,
                       version='1.0', author='CameraApp', description=''):
    """
    Convert EDSR-Base x2 PyTorch model to CoreML .mlmodel format.

    The EDSR model is defined inline in inference_server.py.
    It uses a custom _EDSR class with 16 residual blocks.

    Args:
        checkpoint_path: Path to .pt checkpoint file
        output_path: Path for output .mlmodel file
        input_size: Input image size (square)
        version: Model version string
        author: Author string
        description: Model description
    """
    print(f"\n{'='*60}")
    print(f"Converting: EDSR-Base x2")
    print(f"  Checkpoint: {checkpoint_path}")
    print(f"  Input size: {input_size}x{input_size} → {input_size*2}x{input_size*2}")

    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"  Device: {device}")

    # Import EDSR model definition (added to this script)
    from collections import OrderedDict
    import torch.nn as nn
    import torch.nn.functional as F

    class _EDSR(nn.Module):
        """EDSR-Base x2 super-resolution model.

        Matches the structure of the eugenesiow/edsr-base checkpoint, which
        wraps keys under 'module.' and uses a Sequential for the head, body
        residual blocks, and tail.
        """

        def __init__(self, n_colors=3, n_feats=64, n_resblocks=16, scale=2, res_scale=1.0):
            super().__init__()
            self.res_scale = res_scale

            # Mean shift implemented as 1x1 convolutions to match checkpoint keys
            self.sub_mean = nn.Conv2d(n_colors, n_colors, kernel_size=1, bias=True)
            self.add_mean = nn.Conv2d(n_colors, n_colors, kernel_size=1, bias=True)

            # Head: Sequential wrapping a single conv to match 'head.0'
            self.head = nn.Sequential(
                nn.Conv2d(n_colors, n_feats, kernel_size=3, padding=1)
            )

            # Body: residual blocks. Checkpoint keys are 'body.X.body.0' and 'body.X.body.2'
            self.body = nn.ModuleList([
                nn.Sequential(
                    OrderedDict([
                        ('body_0', nn.Conv2d(n_feats, n_feats, kernel_size=3, padding=1)),
                        ('relu', nn.ReLU(True)),
                        ('body_2', nn.Conv2d(n_feats, n_feats, kernel_size=3, padding=1)),
                    ])
                ) for _ in range(n_resblocks)
            ])
            # Final body conv, checkpoint key 'body.16'
            self.body_last = nn.Conv2d(n_feats, n_feats, kernel_size=3, padding=1)

            # Tail: upscale. Checkpoint keys 'tail.0.0' and 'tail.1'
            self.tail = nn.Sequential(
                OrderedDict([
                    ('tail_0', nn.Sequential(
                        nn.Conv2d(n_feats, n_feats * scale * scale, kernel_size=3, padding=1),
                        nn.PixelShuffle(scale),
                    )),
                    ('tail_1', nn.Conv2d(n_feats, n_colors, kernel_size=3, padding=1)),
                ])
            )

        def forward(self, x):
            # Mean subtraction
            x = self.sub_mean(x)
            # Head
            x = self.head(x)
            # Body with global residual
            residual = x
            for block in self.body:
                x = block(x) * self.res_scale + x
            x = self.body_last(x) + residual
            # Tail
            x = self.tail(x)
            # Mean addition
            x = self.add_mean(x)
            return x

    # Load model
    model = _EDSR(res_scale=EDSR_CONFIG.get('res_scale', 1.0))
    if os.path.exists(checkpoint_path):
        state_dict = torch.load(checkpoint_path, map_location=device, weights_only=True)

        # Remove 'module.' prefix from DataParallel checkpoints
        cleaned = OrderedDict()
        for k, v in state_dict.items():
            new_key = k
            if new_key.startswith('module.'):
                new_key = new_key[7:]
            # Map residual block keys: body.X.body.0 / body.X.body.2 -> body.X.body_0 / body.X.body_2
            new_key = new_key.replace('.body.0.', '.body_0.')
            new_key = new_key.replace('.body.2.', '.body_2.')
            # Checkpoint's body.16 (final conv after residual blocks) maps to model's body_last
            if new_key.startswith('body.16.'):
                new_key = 'body_last.' + new_key[8:]
            # Map tail keys: tail.0.0 -> tail.tail_0.0, tail.1 -> tail.tail_1
            if new_key.startswith('tail.0.'):
                new_key = 'tail.tail_0.' + new_key[7:]
            elif new_key.startswith('tail.1.'):
                new_key = 'tail.tail_1.' + new_key[7:]
            cleaned[new_key] = v

        missing, unexpected = model.load_state_dict(cleaned, strict=False)
        if missing:
            print(f"  Missing keys: {missing[:5]}...")
        if unexpected:
            print(f"  Unexpected keys: {unexpected[:5]}...")
        if not missing and not unexpected:
            print(f"  Loaded checkpoint successfully")
    else:
        print(f"  WARNING: Checkpoint not found: {checkpoint_path}")
        print(f"  Using untrained model weights (random)")
    model.eval()

    # Create traced model
    input_tensor = torch.rand(size=(1, 3, input_size, input_size))
    traced_model = torch.jit.trace(model, input_tensor)

    # Convert to CoreML.
    # NOTE: scale=1.0 (NOT 1/255.0). The EDSR checkpoint was trained on [0,255]
    # input — its sub_mean/add_mean Conv2d layers subtract/add the RGB mean in
    # that range.  Using 1/255 would normalize to [0,1], making sub_mean produce
    # large negative values → near-zero output (very dark image).
    print(f"  Converting to CoreML...")
    mlmodel = ct.convert(
        traced_model,
        convert_to="neuralnetwork",
        source='pytorch',
        inputs=[
            ct.ImageType(
                name="input",
                shape=input_tensor.shape,
                channel_first=True,
                color_layout=ct.colorlayout.RGB,
                scale=1.0,
                bias=[0.0, 0.0, 0.0],
            )
        ],
        outputs=[ct.TensorType(name="output")],
    )

    # Set metadata
    mlmodel.author = author
    mlmodel.version = version
    mlmodel.short_description = description
    mlmodel.user_defined_metadata['model_type'] = 'super_resolution'
    mlmodel.user_defined_metadata['scale'] = '2'

    # Save
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    mlmodel.save(output_path)
    print(f"  Saved to: {output_path}")

    # Compile to .mlmodelc
    try:
        import subprocess
        result = subprocess.run(
            ['xcrun', 'coremlcompiler', 'compile', output_path, os.path.dirname(output_path)],
            capture_output=True, text=True, check=True
        )
        print(f"  Compiled to .mlmodelc")
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"  Compilation skipped (xcrun not available or failed)")

    return output_path


def convert_model(model_class, checkpoint_path, output_path, input_size=480,
                  version='1.0', author='Filter4Free', description=''):
    """
    Convert a PyTorch model to CoreML .mlmodel format.

    Args:
        model_class: PyTorch model class to instantiate
        checkpoint_path: Path to .pth checkpoint file
        output_path: Path for output .mlmodel file
        input_size: Input image size (square)
        version: Model version string
        author: Author string
        description: Model description
    """
    print(f"\n{'='*60}")
    print(f"Converting: {os.path.basename(output_path)}")
    print(f"  Checkpoint: {checkpoint_path}")
    print(f"  Architecture: {model_class.__name__}")
    print(f"  Input size: {input_size}x{input_size}")
    print(f"  Description: {description}")

    # Set device
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"  Device: {device}")

    # Load model
    model = model_class()
    if os.path.exists(checkpoint_path):
        state_dict = torch.load(checkpoint_path, map_location=device, weights_only=True)
        model.load_state_dict(state_dict)
        print(f"  Loaded checkpoint successfully")
    else:
        print(f"  WARNING: Checkpoint not found: {checkpoint_path}")
        print(f"  Using untrained model weights (random)")
    model.eval()

    # Create traced model
    input_tensor = torch.rand(size=(1, 3, input_size, input_size))
    traced_model = torch.jit.trace(model, input_tensor)

    # Convert to CoreML
    print(f"  Converting to CoreML...")
    mlmodel = ct.convert(
        traced_model,
        convert_to="neuralnetwork",  # .mlmodel format
        source='pytorch',
        inputs=[
            ct.ImageType(
                name="input",
                shape=input_tensor.shape,
                channel_first=True,
                color_layout=ct.colorlayout.RGB,
                scale=1 / 255.0,
            )
        ],
        outputs=[ct.TensorType(name="output")],
    )

    # Set metadata
    mlmodel.author = author
    mlmodel.version = version
    mlmodel.short_description = description
    mlmodel.user_defined_metadata['filter_type'] = 'neural_film_simulation'
    mlmodel.user_defined_metadata['framework'] = 'Filter4Free'

    # Save
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    mlmodel.save(output_path)
    print(f"  Saved to: {output_path}")

    # Verify
    try:
        to_pil = ToPILImage()
        img = to_pil(input_tensor.squeeze(0))
        ml_out = mlmodel.predict({"input": img})['output']
        with torch.no_grad():
            torch_out = model(input_tensor).detach().cpu().numpy()
        match = np.allclose(ml_out, torch_out, atol=0.05)
        print(f"  Verification: {'PASSED' if match else 'DIFFERENCE DETECTED'}")
        print(f"  L1 Loss: {np.mean(np.abs(ml_out - torch_out)):.6f}")
    except Exception as e:
        print(f"  Verification skipped: {e}")

    # Compile to .mlmodelc (for faster loading on device)
    try:
        import subprocess
        result = subprocess.run(
            ['xcrun', 'coremlcompiler', 'compile', output_path, os.path.dirname(output_path)],
            capture_output=True, text=True, check=True
        )
        print(f"  Compiled to .mlmodelc")
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"  Compilation skipped (xcrun not available or failed)")

    return output_path


def batch_convert(checkpoints_dir: str, output_dir: str, skip_existing: bool = True):
    """
    Convert all filters defined in FILTER_CONFIGS.

    Args:
        checkpoints_dir: Directory containing .pth checkpoint files
        output_dir: Directory for output .mlmodel files
        skip_existing: Skip conversion if .mlmodel already exists
    """
    results = {'success': [], 'skipped': [], 'failed': []}

    for filter_name, (model_class, input_size, description) in FILTER_CONFIGS.items():
        output_path = os.path.join(output_dir, f'{filter_name}.mlmodel')

        # Check if already converted
        if skip_existing and os.path.exists(output_path):
            print(f"SKIP: {filter_name}.mlmodel already exists")
            results['skipped'].append(filter_name)
            continue

        # Find checkpoint file
        checkpoint_path = os.path.join(checkpoints_dir, f'{filter_name}.pth')

        # Try alternative naming patterns
        if not os.path.exists(checkpoint_path):
            alt_patterns = [
                f'best-v4-{filter_name}.pth',
                f'best-{filter_name}.pth',
                f'{filter_name}-best.pth',
                f'{filter_name.replace("_", "-")}-best.pth',
            ]
            for pattern in alt_patterns:
                alt_path = os.path.join(checkpoints_dir, pattern)
                if os.path.exists(alt_path):
                    checkpoint_path = alt_path
                    break

        # Try filter4free directory structure: brand/subdir/filmcnn.pth
        if not os.path.exists(checkpoint_path):
            parts = filter_name.split('_', 1)
            if len(parts) == 2:
                brand, subdir = parts
                # Map subdirectory names to filter4free's actual directory names
                subdir_map = {
                    'acros': 'acros',
                    'astia': 'astia',
                    'classic_chrome': 'classic-chrome',
                    'classic_neg': 'classic-neg',
                    'eterna': 'enerna',  # typo in filter4free's directory name
                    'eterna_bleach': 'eb',
                    'pro_neg_hi': 'neghi',
                    'pro_neg_std': 'negstd',
                    'nostalgic_neg': 'nostalgic-neg',
                    'pro400h': 'pro400h',
                    'provia': 'provia',
                    'reala': 'reala',
                    'superia400': 'superia400',
                    'velvia': 'velvia',
                    'color_plus': 'colorplus',
                    'gold200': 'gold200',
                    'portra400': 'portra400',
                    'portra160nc': 'portra160nc',
                    'ultramax400': 'ultramax400',
                    'vivid': 'vivid',
                    'polaroid': 'polaroid',
                }
                actual_subdir = subdir_map.get(subdir, subdir)
                candidate = os.path.join(checkpoints_dir, brand, actual_subdir, 'filmcnn.pth')
                if os.path.exists(candidate):
                    checkpoint_path = candidate
                    print(f"  Found checkpoint at: {candidate}")

        try:
            convert_model(
                model_class=model_class,
                checkpoint_path=checkpoint_path,
                output_path=output_path,
                input_size=input_size,
                description=description,
            )
            results['success'].append(filter_name)
        except Exception as e:
            print(f"FAILED: {filter_name}: {e}")
            results['failed'].append(filter_name)

    # Summary
    print(f"\n{'='*60}")
    print(f"CONVERSION SUMMARY")
    print(f"  Success: {len(results['success'])}")
    print(f"  Skipped: {len(results['skipped'])}")
    print(f"  Failed:  {len(results['failed'])}")

    if results['failed']:
        print(f"\n  Failed filters:")
        for name in results['failed']:
            print(f"    - {name}")

    return results


def main():
    parser = argparse.ArgumentParser(
        description='Convert Filter4Free PyTorch models to CoreML'
    )
    parser.add_argument(
        '--checkpoints-dir',
        default='./pretrained_checkpoints',
        help='Directory containing .pth checkpoint files'
    )
    parser.add_argument(
        '--output-dir',
        default='./assets/models',
        help='Output directory for .mlmodel files'
    )
    parser.add_argument(
        '--filter',
        help='Convert a single filter (e.g., fuji_classic_chrome)'
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Force re-conversion even if .mlmodel exists'
    )
    parser.add_argument(
        '--list-filters',
        action='store_true',
        help='List all available filters and exit'
    )
    parser.add_argument(
        '--convert-edsr',
        action='store_true',
        help='Convert EDSR-Base x2 super-resolution model'
    )

    args = parser.parse_args()

    if args.list_filters:
        print("Available filters:")
        for name, (cls, size, desc) in FILTER_CONFIGS.items():
            print(f"  {name:30s} | {cls.__name__:20s} | {size}px | {desc}")
        return

    if args.convert_edsr:
        checkpoint_path = os.path.join(args.checkpoints_dir, 'edsr_base_x2.pt')
        output_path = os.path.join(args.output_dir, 'edsr_base_x2.mlmodel')
        convert_edsr_model(
            checkpoint_path=checkpoint_path,
            output_path=output_path,
            input_size=EDSR_CONFIG['input_size'],
            description=EDSR_CONFIG['description'],
        )
        return

    if args.filter:
        if args.filter not in FILTER_CONFIGS:
            print(f"Unknown filter: {args.filter}")
            print(f"Available: {', '.join(FILTER_CONFIGS.keys())}")
            sys.exit(1)

        model_class, input_size, description = FILTER_CONFIGS[args.filter]
        output_path = os.path.join(args.output_dir, f'{args.filter}.mlmodel')

        checkpoint_path = os.path.join(args.checkpoints_dir, f'{args.filter}.pth')
        if not os.path.exists(checkpoint_path):
            print(f"ERROR: Checkpoint not found: {checkpoint_path}")
            print(f"Place your .pth file in {args.checkpoints_dir}/")
            sys.exit(1)

        convert_model(
            model_class=model_class,
            checkpoint_path=checkpoint_path,
            output_path=output_path,
            input_size=input_size,
            description=description,
        )
    else:
        batch_convert(
            checkpoints_dir=args.checkpoints_dir,
            output_dir=args.output_dir,
            skip_existing=not args.force,
        )


if __name__ == '__main__':
    main()
