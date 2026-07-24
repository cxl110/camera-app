#!/bin/bash
# PiperSR setup and test script for Mac
# Run this on Mac after SSH connection is established

set -e

echo "=== Step 1: Clone PiperSR ==="
cd /tmp
rm -rf PiperSR
git clone --depth 1 https://github.com/ModelPiper/PiperSR.git 2>&1 || { echo "Clone failed, trying with timeout..."; timeout 120 git clone --depth 1 https://github.com/ModelPiper/PiperSR.git 2>&1; }

echo "=== Step 2: Check model files ==="
ls -la /tmp/PiperSR/PiperSR_2x.mlpackage/
find /tmp/PiperSR -name "*.mlmodel" -o -name "weight.bin" 2>&1

echo "=== Step 3: Try to compile .mlpackage to .mlmodelc ==="
# If .mlpackage is complete (has model.mlmodel inside), we can compile it
# If not, we need to convert from PyTorch

# Check if model.mlmodel exists inside the mlpackage
if [ -f "/tmp/PiperSR/PiperSR_2x.mlpackage/Data/com.apple.CoreML/model.mlmodel" ]; then
    echo "model.mlmodel found! Compiling..."
    xcrun coremlcompiler compile /tmp/PiperSR/PiperSR_2x.mlpackage /tmp/ 2>&1
    echo "Compiled to /tmp/PiperSR_2x.mlmodelc"
else
    echo "model.mlmodel NOT found in .mlpackage"
    echo "Need to convert from PyTorch..."

    # Check if coremltools and torch are available
    python3 -c "import coremltools; print('coremltools:', coremltools.__version__)" 2>&1 || { echo "Installing coremltools..."; pip3 install coremltools 2>&1; }
    python3 -c "import torch; print('torch:', torch.__version__)" 2>&1 || { echo "Installing torch..."; pip3 install torch 2>&1; }

    # Create conversion script
    cat > /tmp/convert_pipersr.py << 'PYEOF'
import torch
import torch.nn as nn
import coremltools as ct
import numpy as np
import os

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
        self.tail_conv = nn.Conv2d(channels, channels * (scale ** 2), 3, padding=1)
        self.pixel_shuffle = nn.PixelShuffle(scale)

    def forward(self, x):
        x = self.head(x)
        x = self.body(x)
        x = self.tail_conv(x)
        x = self.pixel_shuffle(x)
        return x

# Create model
model = PiperSR(num_blocks=6, channels=64, scale=2)
print(f"Model: {sum(p.numel() for p in model.parameters())} parameters")

# Try loading weights from weight.bin
weight_bin = "/tmp/PiperSR/PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
if os.path.exists(weight_bin):
    with open(weight_bin, 'rb') as f:
        data = f.read()
    fp16_data = np.frombuffer(data, dtype=np.float16)
    total_params = sum(p.numel() for p in model.parameters())
    print(f"weight.bin: {len(fp16_data)} FP16 values, model needs {total_params}")

    if len(fp16_data) >= total_params:
        fp32_data = fp16_data[:total_params].astype(np.float32)
        state_dict = model.state_dict()
        offset = 0
        for key, val in state_dict.items():
            n = val.numel()
            w = fp32_data[offset:offset+n].reshape(val.shape)
            state_dict[key] = torch.from_numpy(w.copy())
            offset += n
        model.load_state_dict(state_dict)
        print("Weights loaded from weight.bin!")
    else:
        print("WARNING: weight.bin too small, using random weights")
else:
    print("WARNING: weight.bin not found, using random weights")

# Convert to CoreML
model.eval()
dummy = torch.randn(1, 3, 128, 128)
traced = torch.jit.trace(model, dummy)

# Use flexible input shape
input_type = ct.TensorType(
    name="input",
    shape=(1, 3, ct.RangeDim(64, 2048, 64), ct.RangeDim(64, 2048, 64)),
    dtype=np.float32,
)

mlmodel = ct.convert(
    traced,
    inputs=[input_type],
    outputs=[ct.TensorType(name="output", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS16,
    convert_to="mlprogram",
)

output_path = os.path.expanduser("~/camera_app/assets/models/PiperSR_2x.mlpackage")
mlmodel.save(output_path)
print(f"Saved to: {output_path}")

# Also save as .mlmodel for direct inclusion
mlmodel_path = os.path.expanduser("~/camera_app/assets/models/PiperSR_2x.mlmodel")
mlmodel.save(mlmodel_path)
print(f"Also saved as: {mlmodel_path}")
PYEOF

    python3 /tmp/convert_pipersr.py 2>&1
fi

echo "=== Step 4: Copy test image ==="
cp ~/camera_app/test_images/forTest.jpg /tmp/forTest.jpg 2>/dev/null || echo "No test image found"

echo "=== Step 5: Run Swift test ==="
# Copy test script
# The test script will be uploaded separately

echo "=== Done ==="
