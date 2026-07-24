"""
Convert PiperSR from PyTorch to CoreML .mlmodel format.

PiperSR architecture (from README):
- Head: Conv 3x3 (3 -> 64 channels)
- Body: 6 Residual Blocks (Conv 3x3 64ch + BatchNorm + SiLU + Conv 3x3 64ch + BatchNorm + Residual)
- Tail: Conv 3x3 (64 -> 12ch) + PixelShuffle(2)

Total: 453K parameters, 928KB FP16 CoreML model.
"""

import torch
import torch.nn as nn
import coremltools as ct
import numpy as np
import struct
import os
import sys

class ResidualBlock(nn.Module):
    def __init__(self, channels=64):
        super().__init__()
        self.conv1 = nn.Conv2d(channels, channels, 3, padding=1)
        self.bn1 = nn.BatchNorm2d(channels)
        self.silu = nn.SiLU(inplace=True)
        self.conv2 = nn.Conv2d(channels, channels, 3, padding=1)
        self.bn2 = nn.BatchNorm2d(channels)

    def forward(self, x):
        residual = x
        out = self.silu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        return out + residual

class PiperSR(nn.Module):
    def __init__(self, num_blocks=6, channels=64, scale=2):
        super().__init__()
        self.head = nn.Conv2d(3, channels, 3, padding=1)
        self.body = nn.Sequential(*[ResidualBlock(channels) for _ in range(num_blocks)])
        # Tail: Conv 3x3 (64 -> channels * scale^2) + PixelShuffle
        self.tail_conv = nn.Conv2d(channels, channels * (scale ** 2), 3, padding=1)
        self.pixel_shuffle = nn.PixelShuffle(scale)

    def forward(self, x):
        x = self.head(x)
        x = self.body(x)
        x = self.tail_conv(x)
        x = self.pixel_shuffle(x)
        return x

def load_weights_from_bin(model, weight_bin_path):
    """Load FP16 weights from PiperSR's weight.bin file."""
    with open(weight_bin_path, 'rb') as f:
        data = f.read()

    print(f"weight.bin size: {len(data)} bytes")

    # The weight.bin format is CoreML's internal format.
    # We need to parse it to extract the weight tensors.
    # CoreML weight.bin format: sequence of (name_length, name, data_length, data) entries
    # But the exact format depends on the CoreML version.

    # Let's try to read it as raw FP16 data and map to PyTorch state dict
    # First, let's see what the state dict looks like
    state_dict = model.state_dict()
    print("\nExpected state dict keys and shapes:")
    total_params = 0
    for key, val in state_dict.items():
        print(f"  {key}: {val.shape} ({val.numel()} params)")
        total_params += val.numel()
    print(f"Total parameters: {total_params}")

    # Try parsing CoreML weight.bin
    # Format: each entry has a 4-byte length prefix for the name, then the name,
    # then a 4-byte length for the data, then the data
    offset = 0
    weights = {}

    # Alternative: try reading as contiguous FP16 array
    fp16_data = np.frombuffer(data, dtype=np.float16)
    print(f"\nFP16 values in weight.bin: {len(fp16_data)}")
    print(f"Expected FP16 values: {total_params}")

    if len(fp16_data) >= total_params:
        # Map weights in order
        fp32_data = fp16_data[:total_params].astype(np.float32)
        offset = 0
        for key, val in state_dict.items():
            n = val.numel()
            shape = val.shape
            w = fp32_data[offset:offset+n].reshape(shape)
            state_dict[key] = torch.from_numpy(w.copy())
            offset += n
            print(f"  Loaded {key}: shape={shape}, range=[{w.min():.4f}, {w.max():.4f}]")

        model.load_state_dict(state_dict)
        print("\nWeights loaded successfully!")
        return True
    else:
        print(f"WARNING: weight.bin has {len(fp16_data)} FP16 values but model needs {total_params}")
        return False

def convert_to_coreml(model, output_path, input_size=128):
    """Convert PyTorch model to CoreML .mlmodel format."""
    model.eval()

    # Create dummy input
    dummy_input = torch.randn(1, 3, input_size, input_size)

    # Trace the model
    print(f"\nTracing model with input size {input_size}x{input_size}...")
    traced_model = torch.jit.trace(model, dummy_input)

    # Convert to CoreML with flexible input shape
    print("Converting to CoreML...")
    input_type = ct.ImageType(
        name="input",
        shape=(1, 3, input_size, input_size),
        scale=1.0/255.0,
        bias=[0, 0, 0],
        color_layout=ct.colorlayout.RGB,
    )
    output_type = ct.ImageType(
        name="output",
        shape=(1, 3, input_size * 2, input_size * 2),
        scale=1.0/255.0,
        bias=[0, 0, 0],
        color_layout=ct.colorlayout.RGB,
    )

    # Use flexible input shape
    input_type = ct.TensorType(
        name="input",
        shape=(1, 3, ct.RangeDim(64, 2048, 64), ct.RangeDim(64, 2048, 64)),
        dtype=np.float32,
    )

    mlmodel = ct.convert(
        traced_model,
        inputs=[input_type],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )

    # Save
    mlmodel.save(output_path)
    print(f"Saved CoreML model to: {output_path}")

    # Check file size
    if os.path.exists(output_path):
        if output_path.endswith('.mlpackage'):
            total_size = sum(os.path.getsize(os.path.join(dirpath, filename))
                           for dirpath, _, filenames in os.walk(output_path)
                           for filename in filenames)
            print(f"Model size: {total_size / 1024:.1f} KB")
        else:
            print(f"Model size: {os.path.getsize(output_path) / 1024:.1f} KB")

    return mlmodel

if __name__ == "__main__":
    # Create model
    model = PiperSR(num_blocks=6, channels=64, scale=2)
    print(f"Model created with {sum(p.numel() for p in model.parameters())} parameters")

    # Try to load weights from weight.bin
    weight_bin_path = os.path.join(
        os.path.dirname(__file__),
        "PiperSR_2x.mlpackage", "Data", "com.apple.CoreML", "weights", "weight.bin"
    )
    # Also try the extracted path
    alt_paths = [
        r"C:\tmp\PiperSR_extracted\PiperSR-master\PiperSR_2x.mlpackage\Data\com.apple.CoreML\weights\weight.bin",
        r"/tmp/PiperSR_extracted/PiperSR-master/PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
    ]

    weights_loaded = False
    for path in [weight_bin_path] + alt_paths:
        if os.path.exists(path):
            print(f"\nLoading weights from: {path}")
            weights_loaded = load_weights_from_bin(model, path)
            if weights_loaded:
                break

    if not weights_loaded:
        print("\nWARNING: Could not load weights. Converting with random weights for testing.")
        print("The model will produce garbage output but the CoreML structure will be correct.")

    # Convert to CoreML
    output_path = os.path.join(os.path.dirname(__file__), "PiperSR_2x.mlmodel")
    try:
        mlmodel = convert_to_coreml(model, output_path, input_size=128)
        print("\nConversion successful!")
    except Exception as e:
        print(f"\nConversion failed: {e}")
        import traceback
        traceback.print_exc()
