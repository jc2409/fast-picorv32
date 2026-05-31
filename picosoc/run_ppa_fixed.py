#!/usr/bin/env python3
"""
Fixed PPA script for icebreaker design.
Runs Yosys, nextpnr, icetime for multiple configurations.
"""

import subprocess
import re
import csv
import os
import shutil
from pathlib import Path

# ---------- Configuration ----------
VERILOG_SOURCES = [
    "icebreaker.v",
    "ice40up5k_spram.v",
    "spimemio.v",
    "simpleuart.v",
    "picosoc.v",
    "../picorv32.v"   # relative to script directory
]
PCF_FILE = "icebreaker.pcf"
TOP_MODULE = "icebreaker"
DEVICE = "up5k"
PACKAGE = "sg48"

# Configurations: parameters to override in icebreaker.v (inside picosoc #(...))
def load_configs(csv_file="configs.csv"):
    configs = {}
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.pop('config_name')
            # Convert all values to integers (or leave as strings, then convert)
            params = {}
            for k, v in row.items():
                # v is a string like "0" or "32768"
                params[k.upper()] = int(v)   # store keys in uppercase to match existing code
            configs[name] = params
    return configs

# In main():
CONFIGS = load_configs()

# ---------- Helper functions ----------
def run_cmd(cmd, desc, cwd=None, log_file=None):
    """Run shell command, log output to file if provided."""
    print(f"  {desc}...", end=" ", flush=True)
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if log_file:
        with open(log_file, 'w') as f:
            f.write(f"COMMAND: {cmd}\n\nSTDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}")
    if result.returncode == 0:
        print("OK")
    else:
        print(f"FAIL (code {result.returncode})")
        if log_file:
            print(f"    See log: {log_file}")
    return result.returncode, result.stdout, result.stderr

def replace_in_file(file_path, pattern, replacement):
    """Perform a regex replacement in a file."""
    with open(file_path, 'r') as f:
        content = f.read()
    new_content = re.sub(pattern, replacement, content)
    if new_content != content:
        with open(file_path, 'w') as f:
            f.write(new_content)
        return True
    return False

def generate_config_files(config_name, params, build_dir):
    """Copy all source files to build_dir, then override parameters in icebreaker.v and picosoc.v."""
    os.makedirs(build_dir, exist_ok=True)

    # 1. Copy all Verilog sources (including ../picorv32.v)
    #    Resolve absolute path of script directory to handle relative paths correctly.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for src in VERILOG_SOURCES:
        # Resolve source path relative to script_dir
        src_path = os.path.join(script_dir, src)
        if not os.path.exists(src_path):
            # Also try relative to current working directory (fallback)
            src_path = src
            if not os.path.exists(src_path):
                print(f"  WARNING: Source {src} not found, skipping")
                continue
        dest = os.path.join(build_dir, os.path.basename(src))
        shutil.copy2(src_path, dest)

    # 2. Override parameters in the copied icebreaker.v (inside picosoc #(...))
    icebreaker_path = os.path.join(build_dir, "icebreaker.v")
    for param, value in params.items():
        if param in ["BARREL_SHIFTER", "ENABLE_MUL", "ENABLE_DIV", "ENABLE_FAST_MUL"]:
            # Replace .PARAM_NAME(0) or .PARAM_NAME(1) with new value
            pattern = rf'\.{param}\s*\(\s*[01]\s*\)'
            replacement = f'.{param}({value})'
            replace_in_file(icebreaker_path, pattern, replacement)

    # 3. Override parameters in picosoc.v (parameter defaults and ENABLE_IRQ)
    picosoc_path = os.path.join(build_dir, "picosoc.v")
    for param, value in params.items():
        if param == "ENABLE_COUNTERS":
            # Replace parameter default lines: parameter [0:0] ENABLE_COUNTERS = 1;
            pattern = rf'(parameter\s+\[0:0\]\s+{param}\s*=\s*)[01];'
            replace_in_file(picosoc_path, pattern, rf'\g<1>{value};')
    # Override ENABLE_IRQ in the picorv32 instantiation
    if "ENABLE_IRQ" in params:
        pattern = r'\.ENABLE_IRQ\(\d+\)'
        replacement = f'.ENABLE_IRQ({params["ENABLE_IRQ"]})'
        replace_in_file(picosoc_path, pattern, replacement)

    # 4. Ensure ../picorv32.v is copied as picorv32.v (already done above)
    #    But verify it exists in build_dir
    picorv32_dest = os.path.join(build_dir, "picorv32.v")
    if not os.path.exists(picorv32_dest):
        print(f"  ERROR: picorv32.v not found in build directory!")
        return False
    return True

def get_area_from_yosys(log_text):
    """Parse Yosys 'stat' output for cell counts."""
    luts = ffs = brams = dsps = carry = 0
    m = re.search(r'SB_LUT4\s+(\d+)', log_text)
    if m: luts = int(m.group(1))
    dff_matches = re.findall(r'SB_DFF\w*\s+(\d+)', log_text)
    ffs = sum(int(x) for x in dff_matches)
    m = re.search(r'SB_RAM40_4K\s+(\d+)', log_text)
    if m: brams = int(m.group(1))
    m = re.search(r'SB_MAC16\s+(\d+)', log_text)
    if m: dsps = int(m.group(1))
    m = re.search(r'SB_CARRY\s+(\d+)', log_text)
    if m: carry = int(m.group(1))
    return luts, ffs, brams, dsps, carry

def get_timing_from_icetime(rpt_file):
    """Parse icetime report for Fmax (MHz) and logic levels."""
    fmax = 0.0
    levels = 0
    if not os.path.exists(rpt_file):
        return fmax, levels
    with open(rpt_file, 'r') as f:
        text = f.read()
    m = re.search(r'Timing estimate:\s+[\d.]+\s+ns\s+\(([\d.]+)\s+MHz\)', text)
    if not m:
        m = re.search(r'Total path delay:\s+[\d.]+\s+ns\s+\(([\d.]+)\s+MHz\)', text)
    if m:
        fmax = float(m.group(1))
    m = re.search(r'Total number of logic levels:\s+(\d+)', text)
    if m:
        levels = int(m.group(1))
    return fmax, levels

def process_config(config_name, params, build_root):
    """Generate modified sources, run synthesis/P&R/timing, return metrics dict."""
    build_dir = os.path.join(build_root, config_name)
    if not generate_config_files(config_name, params, build_dir):
        return None

    # Also copy the PCF file into the build directory
    pcf_src = os.path.join(os.path.dirname(os.path.abspath(__file__)), PCF_FILE)
    if not os.path.exists(pcf_src):
        pcf_src = PCF_FILE
    if os.path.exists(pcf_src):
        shutil.copy2(pcf_src, build_dir)
    else:
        print(f"  ERROR: PCF file {PCF_FILE} not found")
        return None

    # Source files (basenames only, because cwd=build_dir)
    source_files = [
        "icebreaker.v",
        "ice40up5k_spram.v",
        "spimemio.v",
        "simpleuart.v",
        "picosoc.v",
        "picorv32.v"
    ]

    # ---- Yosys synthesis (already works, keep as is) ----
    yosys_log = os.path.join(build_dir, "yosys_synth.log")
    yosys_cmd = f"yosys -p 'read_verilog {' '.join(source_files)}; synth_ice40 -top {TOP_MODULE}; stat -width'"
    rc, stdout, stderr = run_cmd(yosys_cmd, "Yosys synthesis", cwd=build_dir, log_file=yosys_log)
    if rc != 0:
        print(f"  Yosys failed. Check {yosys_log}")
        return None
    log = stdout + stderr
    luts, ffs, brams, dsps, carry = get_area_from_yosys(log)

    # ---- Yosys to JSON - use only filename ----
    json_file = "design.json"
    json_cmd = f"yosys -q -p 'read_verilog {' '.join(source_files)}; synth_ice40 -top {TOP_MODULE} -json {json_file}'"
    rc, _, _ = run_cmd(json_cmd, "Yosys to JSON", cwd=build_dir)
    if rc != 0:
        return None

    # ---- nextpnr - use basename for json and pcf ----
    asc_file = "design.asc"
    pnr_cmd = f"nextpnr-ice40 --{DEVICE} --package {PACKAGE} --json {json_file} --pcf {PCF_FILE} --asc {asc_file} --pcf-allow-unconstrained"
    rc, _, _ = run_cmd(pnr_cmd, "NextPNR", cwd=build_dir)
    if rc != 0:
        return None

    # ---- icetime - use basename for asc ----
    timing_rpt = "timing.rpt"
    icetime_cmd = f"icetime -d {DEVICE} -mtr {timing_rpt} {asc_file}"
    rc, _, _ = run_cmd(icetime_cmd, "icetime", cwd=build_dir)
    if rc != 0:
        return None
    fmax, logic_levels = get_timing_from_icetime(os.path.join(build_dir, timing_rpt))

    metrics = {
        "config": config_name,
        "luts": luts,
        "ffs": ffs,
        "brams": brams,
        "dsps": dsps,
        "carry_cells": carry,
        "fmax_mhz": fmax,
        "logic_levels": logic_levels,
    }
    for k, v in params.items():
        metrics[k.lower()] = v
    return metrics

# ---------- Main ----------
def main():
    # Ensure we are in the right directory (picosoc/)
    required_files = ["icebreaker.v", "picosoc.v", "icebreaker.pcf"]
    missing = [f for f in required_files if not os.path.exists(f)]
    if missing:
        print(f"ERROR: Missing required files in current directory: {missing}")
        print("Run this script from the picosoc/ directory.")
        return

    # Check that ../picorv32.v exists
    if not os.path.exists("../picorv32.v"):
        print("ERROR: ../picorv32.v not found. Please ensure picorv32.v is in the parent directory.")
        return

    build_root = "build_fixed"
    # Clean previous build? Optional: keep for debugging
    if os.path.exists(build_root):
        shutil.rmtree(build_root)
    os.makedirs(build_root, exist_ok=True)

    results = []
    for config_name, params in CONFIGS.items():
        print(f"\n=== Running {config_name} ===")
        metrics = process_config(config_name, params, build_root)
        if metrics:
            results.append(metrics)
            print(f"  LUTs: {metrics['luts']}, Fmax: {metrics['fmax_mhz']:.2f} MHz")
        else:
            print(f"  {config_name} failed.")

    if not results:
        print("No successful runs, exiting.")
        return

    csv_file = "ppa_config_fixed.csv"
    with open(csv_file, 'w', newline='') as f:
        fieldnames = list(results[0].keys())
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\nResults saved to {csv_file}")
    with open(csv_file, 'r') as f:
        print(f.read())

if __name__ == "__main__":
    main()