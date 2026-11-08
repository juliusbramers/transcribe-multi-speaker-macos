#!/bin/sh
# Builds MLX's GPU kernels into mlx.metallib next to the tmsm binary.
# `swift build` compiles no Metal sources; without this file MLX fails on first use.
#   scripts/build-metallib.sh [debug|release]   (default: debug)
# Needs the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -eu
cd "$(dirname "$0")/.."

config="${1:-debug}"
case "$config" in debug | release) ;; *)
  echo "usage: $0 [debug|release]" >&2
  exit 2
  ;;
esac

bin="$(swift build -c "$config" --show-bin-path)"
mlx=".build/checkouts/mlx-swift/Source/Cmlx/mlx"
kernels="$mlx/mlx/backend/metal/kernels"
out="$bin/mlx.metallib"
if [ ! -d "$kernels" ]; then
  echo "error: no MLX kernels at $kernels (run swift build first)" >&2
  exit 1
fi

# Rebuild only when a kernel, this script or the toolchain is newer than the library.
if [ -f "$out" ] && [ -z "$(find "$kernels" "$0" -newer "$out" \( -name '*.metal' -o -name '*.h' -o -name "$(basename "$0")" \) | head -n 1)" ]; then
  echo "mlx.metallib is up to date: $out"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/tmsm-metallib.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

# The *_nax kernels need Metal 4 GPUs and SDKs; tmsm targets macOS 15, so they are left out.
n=0
find "$kernels" -name '*.metal' ! -name '*_nax.metal' | LC_ALL=C sort >"$work/sources"
while IFS= read -r src; do
  n=$((n + 1))
  xcrun -sdk macosx metal -x metal -std=metal3.2 -mmacosx-version-min=15.0 -g0 \
    -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
    -I "$kernels" -I "$mlx" -c "$src" -o "$work/$n.air"
done <"$work/sources"
xcrun -sdk macosx metallib "$work"/*.air -o "$work/mlx.metallib"
mv "$work/mlx.metallib" "$out"
echo "Built $out from $n kernels"
