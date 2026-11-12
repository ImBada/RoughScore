"""Compare the app's separated stem with a reference separation (e.g. PyTorch MSST demix).

    python -I compare.py app_output.caf reference.(npy|wav) [--stem-reference other_stem.wav]

Prints the app-vs-reference SNR per channel; with --stem-reference also SI-SDR of both
against that stem (a rough proxy when it comes from another separator, not ground truth).
"""

import argparse

import numpy as np
import soundfile as sf


def load(path):
    if path.endswith(".npy"):
        return np.load(path).astype(np.float64)
    data, _ = sf.read(path, always_2d=True)
    return data.T.astype(np.float64)


def si_sdr(est, ref):
    a = np.dot(est, ref) / np.dot(ref, ref)
    s = a * ref
    return 10 * np.log10(np.sum(s ** 2) / np.sum((est - s) ** 2))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("app")
    p.add_argument("reference")
    p.add_argument("--stem-reference")
    args = p.parse_args()
    app, ref = load(args.app), load(args.reference)
    n = min(app.shape[1], ref.shape[1])
    stem = load(args.stem_reference)[:, :n] if args.stem_reference else None
    for ch in range(2):
        a, r = app[ch, :n], ref[ch, :n]
        snr = 10 * np.log10(np.sum(r ** 2) / max(np.sum((a - r) ** 2), 1e-20))
        line = f"ch{ch}: app-vs-reference SNR {snr:.1f} dB"
        if stem is not None:
            line += f" | SI-SDR vs stem: app {si_sdr(a, stem[ch]):.2f}, reference {si_sdr(r, stem[ch]):.2f}"
        print(line)


if __name__ == "__main__":
    main()
