#!/usr/bin/env bash
# Install RoughScore's on-device guitar separator (BS-RoFormer SW guitar head, Core ML).
#
# Downloads the pinned checkpoint (~700 MB) and Music-Source-Separation-Training source,
# verifies SHA-256, converts to Core ML and installs into
#   ~/Library/Application Support/RoughScore/Models/GuitarSeparator
# Build files stay in ~/Library/Caches/RoughScore/guitar-separator-build (safe to delete after).
# Needs: uv (https://docs.astral.sh/uv/), curl, ~6 GB free RAM during conversion.
set -euo pipefail

MSST_REVISION=1d4b3c431b37de696b3795ed2018493aacba946f
MSST_SHA256=${MSST_SHA256:-}
HF_REVISION=a443a2985534b3bc815ef54a5d446c6a0390f974
CKPT_SHA256=24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e
YAML_SHA256=f9fada9f94e5ba2d2e4600196299459294bc5f532b314c209cc156ac63e4329b

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="${ROUGHSCORE_SEPARATOR_BUILD:-$HOME/Library/Caches/RoughScore/guitar-separator-build}"
DEST="$HOME/Library/Application Support/RoughScore/Models/GuitarSeparator"
command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 1; }
mkdir -p "$BUILD/ckpt"
cd "$BUILD"

verify() { echo "$2  $1" | shasum -a 256 -c - >/dev/null || { echo "SHA-256 mismatch: $1" >&2; exit 1; }; }
fetch() {  # url path sha
  if [ ! -f "$2" ] || ! echo "$3  $2" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
  fi
  verify "$2" "$3"
}

base="https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed/resolve/$HF_REVISION"
fetch "$base/BS-Rofo-SW-Fixed.ckpt" ckpt/BS-Rofo-SW-Fixed.ckpt "$CKPT_SHA256"
fetch "$base/BS-Rofo-SW-Fixed.yaml" ckpt/BS-Rofo-SW-Fixed.yaml "$YAML_SHA256"

if [ ! -f msst/REVISION ] || [ "$(cat msst/REVISION)" != "$MSST_REVISION" ]; then
  rm -rf msst && mkdir msst
  curl -fL --retry 3 -o msst.tgz "https://github.com/ZFTurbo/Music-Source-Separation-Training/archive/$MSST_REVISION.tar.gz"
  [ -n "$MSST_SHA256" ] && verify msst.tgz "$MSST_SHA256"
  tar xzf msst.tgz -C msst --strip-components=1 && echo "$MSST_REVISION" > msst/REVISION
fi

if [ ! -x .venv/bin/python ]; then
  uv venv -q -p 3.11 .venv
  VIRTUAL_ENV=.venv uv pip install -q torch==2.4.0 coremltools==8.1 "numpy<2" einops==0.8.2 \
    rotary_embedding_torch==0.9.2 beartype==0.23.1 pyyaml packaging
fi

rm -rf out
.venv/bin/python -I "$SCRIPT_DIR/export_bs_roformer.py" --msst-src msst \
  --checkpoint ckpt/BS-Rofo-SW-Fixed.ckpt --config ckpt/BS-Rofo-SW-Fixed.yaml --out out

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST.new" && mkdir "$DEST.new"
cp -R out/GuitarSeparator.mlpackage out/separator.json "$DEST.new/"
rm -rf "$DEST" && mv "$DEST.new" "$DEST"
echo "Installed to $DEST"
