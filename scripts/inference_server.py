"""
Filter4Free Neural Inference Server

Loads PyTorch film simulation models and serves filter inference via HTTP.
Flutter app sends image → server runs neural network → returns filtered image.

Usage:
    pip install flask torch torchvision pillow numpy opencv-python
    python scripts/inference_server.py

Endpoints:
    POST /filter  - Apply a named film filter to an uploaded image
    GET  /filters - List available filters
    GET  /health  - Server health check
"""

import sys
import os
import io
import json

from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
import cv2

# Add filter4free to path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FILTER4FREE_DIR = os.path.join(SCRIPT_DIR, '..', '..', 'filter4free')
sys.path.insert(0, FILTER4FREE_DIR)
from models import FilterSimulation4

app = Flask(__name__)
CORS(app)

# ── Configuration ──

CHECKPOINT_ROOT = os.path.join(FILTER4FREE_DIR, 'gui', 'static', 'checkpoints')

# Map filter names to checkpoint paths
FILTER_MAP = {
    # Fuji
    'ACROS':               'fuji/acros/filmcnn.pth',
    'ASTIA':               'fuji/astia/filmcnn.pth',
    'CLASSIC CHROME':      'fuji/classic-chrome/filmcnn.pth',
    'CLASSIC Neg.':        'fuji/classic-neg/filmcnn.pth',
    'ETERNA':              'fuji/enerna/filmcnn.pth',
    'ETERNA BLEACH BYPASS':'fuji/eb/filmcnn.pth',
    'PRO Neg.Hi':          'fuji/neghi/filmcnn.pth',
    'PRO Neg.Std':         'fuji/negstd/filmcnn.pth',
    'NOSTALGIC Neg.':      'fuji/nostalgic-neg/filmcnn.pth',
    'Pro 400H':            'fuji/pro400h/filmcnn.pth',
    'PROVIA':              'fuji/provia/filmcnn.pth',
    'reala':               'fuji/reala/filmcnn.pth',
    'Superia 400':         'fuji/superia400/filmcnn.pth',
    'VELVIA':              'fuji/velvia/filmcnn.pth',

    # Kodak
    'Color Plus':          'kodak/colorplus/filmcnn.pth',
    'Gold 200':            'kodak/gold200/filmcnn.pth',
    'Portra 400':          'kodak/portra400/filmcnn.pth',
    'Portra 160NC':        'kodak/portra160nc/filmcnn.pth',
    'UltraMax 400':        'kodak/ultramax400/filmcnn.pth',

    # Olympus
    'VIVID':               'olympus/vivid/filmcnn.pth',

    # Polaroid
    'Polaroid':            'other/polaroid/filmcnn.pth',
}

# ── Model Cache ──

_model_cache = {}
_device = torch.device('cpu')

def get_model(filter_name):
    """Load and cache a FilterSimulation4 model."""
    if filter_name in _model_cache:
        return _model_cache[filter_name]

    rel_path = FILTER_MAP.get(filter_name)
    if not rel_path:
        return None

    ckpt_path = os.path.join(CHECKPOINT_ROOT, rel_path)
    if not os.path.exists(ckpt_path):
        print(f"  WARNING: Checkpoint not found: {ckpt_path}")
        return None

    model = FilterSimulation4()
    state = torch.load(ckpt_path, map_location=_device, weights_only=True)
    model.load_state_dict(state)
    model.eval()
    _model_cache[filter_name] = model

    print(f"  Loaded: {filter_name} ({ckpt_path})")
    return model


def process_image(model, image_bytes, patch_size=448, padding=16):
    """
    Tile-based neural filter inference.

    Same algorithm as Filter4Free's infer.py:
    1. Decode image
    2. Normalize (ImageNet stats)
    3. Split into overlapping patches
    4. Run each patch through the neural network
    5. Reconstruct full output
    6. Unnormalize
    """
    # Decode
    nparr = np.frombuffer(image_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("Cannot decode image")
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

    H, W, C = img.shape
    img_float = img.astype(np.float32) / 255.0

    # ImageNet normalization
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    img_norm = (img_float - mean) / std

    # Pad to patch grid
    pad_h = padding if H % patch_size == 0 else padding + patch_size - (H % patch_size)
    pad_w = padding if W % patch_size == 0 else padding + patch_size - (W % patch_size)

    img_padded = np.pad(img_norm,
                        ((padding, pad_h), (padding, pad_w), (0, 0)),
                        mode='edge')

    pH, pW = img_padded.shape[:2]
    cols = pW // patch_size
    rows = pH // patch_size

    # Extract patches
    eff_size = patch_size + 2 * padding
    patches = np.zeros((rows * cols, 3, eff_size, eff_size), dtype=np.float32)

    for i in range(rows):
        for j in range(cols):
            y_start = i * patch_size
            x_start = j * patch_size
            patch = img_padded[y_start:y_start+eff_size, x_start:x_start+eff_size, :]
            patches[i * cols + j] = patch.transpose(2, 0, 1)

    # Batch inference
    batch_size = 4
    output_patches = []

    with torch.no_grad():
        for b in range(0, len(patches), batch_size):
            batch = torch.from_numpy(patches[b:b+batch_size]).float()
            out = model(batch).cpu().numpy()
            output_patches.append(out)

    output = np.concatenate(output_patches, axis=0)  # [N, 3, eff, eff]

    # Remove padding and reconstruct
    target = np.zeros((rows * patch_size, cols * patch_size, 3), dtype=np.float32)

    for i in range(rows):
        for j in range(cols):
            idx = i * cols + j
            patch = output[idx][:, padding:-padding, padding:-padding]  # [3, ps, ps]
            y = i * patch_size
            x = j * patch_size
            target[y:y+patch_size, x:x+patch_size] = patch.transpose(1, 2, 0)

    # Crop to original size
    target = target[:H, :W]

    # Unnormalize
    unnormalize_mean = np.array([-0.485/0.229, -0.456/0.224, -0.406/0.225], dtype=np.float32)
    unnormalize_std  = np.array([1/0.229, 1/0.224, 1/0.225], dtype=np.float32)
    target = target * unnormalize_std + unnormalize_mean

    # Clip and convert
    result = np.clip(target * 255.0, 0, 255).astype(np.uint8)
    result_bgr = cv2.cvtColor(result, cv2.COLOR_RGB2BGR)

    _, encoded = cv2.imencode('.jpg', result_bgr, [cv2.IMWRITE_JPEG_QUALITY, 95])
    return encoded.tobytes()


# ── Routes ──

@app.route('/health')
def health():
    return jsonify({'status': 'ok', 'models_loaded': len(_model_cache)})


@app.route('/filters')
def list_filters():
    return jsonify({
        'filters': list(FILTER_MAP.keys()),
        'total': len(FILTER_MAP),
    })


@app.route('/filter', methods=['POST'])
def apply_filter():
    """
    Apply a neural film filter to an image.

    Form fields:
        image:  JPEG file upload
        filter: Filter name (e.g., "CLASSIC CHROME")
        preview: "true" for fast low-res preview (optional)

    Returns: JPEG image bytes
    """
    if 'image' not in request.files:
        return jsonify({'error': 'No image file'}), 400

    filter_name = request.form.get('filter', 'CLASSIC CHROME')
    is_preview = request.form.get('preview', 'false').lower() == 'true'

    # Load model
    model = get_model(filter_name)
    if model is None:
        return jsonify({'error': f'Filter not found: {filter_name}'}), 404

    # Read image
    image_bytes = request.files['image'].read()

    # Downsample for preview
    if is_preview:
        nparr = np.frombuffer(image_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        h, w = img.shape[:2]
        max_dim = 1024
        if max(h, w) > max_dim:
            scale = max_dim / max(h, w)
            img = cv2.resize(img, (int(w*scale), int(h*scale)))
            _, encoded = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, 90])
            image_bytes = encoded.tobytes()

    # Process
    try:
        result = process_image(model, image_bytes)
        return send_file(io.BytesIO(result), mimetype='image/jpeg')
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/preload', methods=['POST'])
def preload_models():
    """Preload all filter models into memory."""
    data = request.get_json(silent=True) or {}
    filters = data.get('filters', list(FILTER_MAP.keys()))

    loaded = []
    failed = []
    for name in filters:
        model = get_model(name)
        if model:
            loaded.append(name)
        else:
            failed.append(name)

    return jsonify({'loaded': loaded, 'failed': failed, 'cache_size': len(_model_cache)})


# ── Main ──

if __name__ == '__main__':
    print("=" * 50)
    print("Filter4Free Neural Inference Server")
    print(f"Device: {_device}")
    print(f"Available filters: {len(FILTER_MAP)}")
    print("=" * 50)

    # Get available filters from command line preload arg
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=5000)
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--preload', action='store_true', help='Preload all models on startup')
    args = parser.parse_args()

    if args.preload:
        print("\nPreloading all models...")
        for name in FILTER_MAP:
            get_model(name)
        print(f"Loaded {len(_model_cache)}/{len(FILTER_MAP)} models")

    print(f"\nServer: http://{args.host}:{args.port}")
    print("Endpoints:")
    print("  POST /filter  - Apply film filter")
    print("  GET  /filters - List filters")
    print("  GET  /health  - Server status")
    print("=" * 50)

    app.run(host=args.host, port=args.port, debug=False)
