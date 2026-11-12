"""Convert the BS-RoFormer SW 6-stem separator to a guitar-only Core ML mask model.

The app does the STFT/iSTFT (vDSP). The Core ML model maps one stereo STFT
chunk, laid out exactly like BSRoformer.forward after its STFT step,
`(1, frames, freq*channel*complex)`, to the complex guitar mask in the same
layout. Only the guitar mask head (stem index 4) is exported.

Usage (venv prepared by scripts/separation/install-guitar-separator.sh):
    python -I export_bs_roformer.py --msst-src MSST --checkpoint CKPT --config YAML --out DIR
"""

import argparse
import hashlib
import json
import os
import sys

import numpy as np
import torch
import torch.nn as nn

CHECKPOINT_SHA256 = "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"
CONFIG_SHA256 = "f9fada9f94e5ba2d2e4600196299459294bc5f532b314c209cc156ac63e4329b"
CHECKPOINT_SOURCE = "https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed/tree/a443a2985534b3bc815ef54a5d446c6a0390f974"
GUITAR_STEM = 4  # training.instruments: bass, drums, other, vocals, guitar, piano


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class GuitarMask(nn.Module):
    """BSRoformer.forward between the STFT and the complex multiply, guitar head only."""

    def __init__(self, model):
        super().__init__()
        self.band_split = model.band_split
        self.layers = model.layers
        self.final_norm = model.final_norm
        self.head = model.mask_estimators[GUITAR_STEM]

    def forward(self, spectrum):
        # spectrum: (1, t, f*s*c)
        x = self.band_split(spectrum)  # (1, t, bands, d)
        for time_transformer, freq_transformer in self.layers:
            b, t, f, d = x.shape
            x = x.permute(0, 2, 1, 3).reshape(b * f, t, d)
            x = time_transformer(x)
            x = x.reshape(b, f, t, d).permute(0, 2, 1, 3).reshape(b * t, f, d)
            x = freq_transformer(x)
            x = x.reshape(b, t, f, d)
        x = self.final_norm(x)
        return self.head(x)  # (1, t, f*s*c)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--msst-src", required=True)
    p.add_argument("--checkpoint", required=True)
    p.add_argument("--config", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--chunk-samples", type=int, default=None, help="default: config audio.chunk_size")
    p.add_argument("--precision", choices=["float16", "float32"], default="float16")
    args = p.parse_args()

    for path, digest in [(args.checkpoint, CHECKPOINT_SHA256), (args.config, CONFIG_SHA256)]:
        actual = sha256(path)
        if actual != digest:
            sys.exit(f"{path}: sha256 {actual} != pinned {digest}")

    sys.path.insert(0, os.path.abspath(args.msst_src))
    import yaml
    from models.bs_roformer import BSRoformer

    cfg = yaml.load(open(args.config), Loader=yaml.FullLoader)
    model_cfg = dict(cfg["model"])
    model_cfg["flash_attn"] = False  # plain einsum attention converts cleanly
    model = BSRoformer(**model_cfg)
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu"))
    model.eval()

    if model.skip_connection or any(len(block) != 2 for block in model.layers):
        sys.exit("unsupported BS-RoFormer variant (skip connection / linear transformer)")

    n_fft = model_cfg["stft_n_fft"]
    hop = model_cfg["stft_hop_length"]
    chunk = args.chunk_samples or cfg["audio"]["chunk_size"]
    frames = chunk // hop + 1
    width = (n_fft // 2 + 1) * 2 * 2  # freq * stereo * complex

    wrapper = GuitarMask(model).eval()
    example = torch.randn(1, frames, width) * 0.1
    with torch.no_grad():
        reference = wrapper(example).numpy()
        traced = torch.jit.trace(wrapper, example)

    import coremltools as ct

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spectrum", shape=(1, frames, width), dtype=np.float32)],
        outputs=[ct.TensorType(name="mask", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
        skip_model_load=True,  # loading here would start a slow Neural Engine compile
    )
    mlmodel.short_description = "BS-RoFormer SW guitar mask (stereo complex STFT in, complex mask out)."
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(os.path.join(out_dir, "GuitarSeparator.mlpackage"))

    meta = {
        "schemaVersion": 1,
        "model": "BS-RoFormer SW (guitar head)",
        "checkpointSHA256": CHECKPOINT_SHA256,
        "checkpointSource": CHECKPOINT_SOURCE,
        "precision": args.precision,
        "sampleRate": cfg["audio"]["sample_rate"],
        "nFFT": n_fft,
        "hop": hop,
        "chunkSamples": chunk,
        "frames": frames,
        "overlap": cfg["inference"].get("num_overlap", 2),
    }
    with open(os.path.join(out_dir, "separator.json"), "w") as f:
        json.dump(meta, f, indent=1)

    check = ct.models.MLModel(os.path.join(out_dir, "GuitarSeparator.mlpackage"),
                              compute_units=ct.ComputeUnit.CPU_AND_GPU)
    pred = check.predict({"spectrum": example.numpy()})["mask"]
    err = np.abs(pred - reference).max()
    rel = np.linalg.norm(pred - reference) / np.linalg.norm(reference)
    print(f"mask max abs diff {err:.4g}, relative L2 {rel:.4g}")
    print("saved", out_dir)


if __name__ == "__main__":
    main()
