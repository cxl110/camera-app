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
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'filter4free'))

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

    args = parser.parse_args()

    if args.list_filters:
        print("Available filters:")
        for name, (cls, size, desc) in FILTER_CONFIGS.items():
            print(f"  {name:30s} | {cls.__name__:20s} | {size}px | {desc}")
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
