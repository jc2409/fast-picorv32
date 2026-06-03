#!/bin/bash
# ----------------------------------------------------------------------
# Comprehensive "do all" script for RISC-V PPA, tests, and benchmarks
# ----------------------------------------------------------------------
set -e  # stop on first error

# ---------- Configuration ----------
# Toolchain environment (OSS CAD Suite)
if [ -f ~/oss-cad-suite/environment ]; then
    source ~/oss-cad-suite/environment
fi

# Override CROSS in picosoc/Makefile (use the correct toolchain prefix)
export CROSS=riscv32-unknown-elf-

# Directories
TOP_DIR=$(pwd)
PICOSOC_DIR="$TOP_DIR/picosoc"
DHYSTONE_DIR="$TOP_DIR/dhrystone"

# Custom benchmark file (adjust path as needed)
CUSTOM_BENCH_SRC="$PICOSOC_DIR/integral.c"   # assuming you place it there
CUSTOM_BENCH_ELF="$PICOSOC_DIR/integral.elf"
CUSTOM_BENCH_HEX="$PICOSOC_DIR/integral.hex"

# ---------- Helper functions ----------
run_simulation() {
    local desc="$1"
    local sim_cmd="$2"
    echo "=== $desc (simulation) ==="
    eval $sim_cmd
    echo "✓ $desc completed"
}

# ---------- 1. PPA (area & timing) ----------
echo "=== 1. Running PPA automation ==="
cd "$PICOSOC_DIR"
echo "=== Interactive PPA configuration ==="
python3 interactive_ppa.py
# interactive_ppa.py already runs run_ppa_fixed.py and analyse_ppa.py (if confirmed)
echo "✓ PPA results saved in ppa_config_fixed.csv and ppa_analysis_output/"

# ---------- 2. Instruction tests (top‑level 'make test') ----------
cd "$TOP_DIR"
run_simulation "Instruction tests" "make test"

# ---------- 3. Dhrystone benchmark ----------
cd "$DHYSTONE_DIR"
run_simulation "Dhrystone benchmark" "make test"

# ---------- 4. Custom benchmark (e.g., integral) ----------
# First, compile the custom C program using the same toolchain
cd "$PICOSOC_DIR"
if [ -f "$CUSTOM_BENCH_SRC" ]; then
    echo "=== Compiling custom benchmark (integral) ==="
    $CROSS-gcc -mabi=ilp32 -march=rv32im -ffreestanding -nostdlib \
        -Wl,-Bstatic,-T,icebreaker_sections.lds,--strip-debug \
        -o "$CUSTOM_BENCH_ELF" start.s "$CUSTOM_BENCH_SRC"
    $CROSS-objcopy -O verilog "$CUSTOM_BENCH_ELF" "$CUSTOM_BENCH_HEX"

    echo "=== Running custom benchmark in simulation ==="
    # Temporarily replace firmware.hex with custom benchmark hex
    cp icebreaker_fw.hex icebreaker_fw.hex.backup
    cp "$CUSTOM_BENCH_HEX" icebreaker_fw.hex
    make icebsim
    mv icebreaker_fw.hex.backup icebreaker_fw.hex
    echo "✓ Custom benchmark completed"
else
    echo "⚠ Custom benchmark source not found: $CUSTOM_BENCH_SRC"
    echo "   Skipping custom benchmark."
fi

# ---------- 5. (Optional) Hardware run ----------
# Uncomment the following lines when you have the board connected.
# echo "=== Programming FPGA and running on hardware ==="
# cd "$PICOSOC_DIR"
# make icebprog
# # You could also measure power, but that's manual.

echo "========================================="
echo "✅ All simulations completed successfully."
echo "PPA results: $PICOSOC_DIR/ppa_config_fixed.csv"
echo "Analysis plots: $PICOSOC_DIR/ppa_analysis_output/"
echo "========================================="