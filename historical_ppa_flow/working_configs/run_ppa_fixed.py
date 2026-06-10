#!/usr/bin/env python3
"""
Fixed PPA script for icebreaker design.
Supports CPU parameters, MEM_WORDS, cache size parameters,
and cache module selection (from icache.v).
"""

import subprocess
import re
import csv
import os
import shutil
import argparse

# ---------- Configuration ----------
VERILOG_SOURCES = [
    "picosoc/icebreaker.v",          # now relative to project root
    "picosoc/ice40up5k_spram.v",
    "picosoc/spimemio.v",
    "picosoc/simpleuart.v",
    "picosoc/icache.v",
    "picosoc/dmem_lookahead_buffer.v",
    "picosoc/picosoc.v",
    "picorv32.v"                     # at project root
]
PCF_FILE = "picosoc/icebreaker.pcf"
TOP_MODULE = "icebreaker"
DEVICE = "up5k"
PACKAGE = "sg48"

# ---------- Load configurations from CSV ----------
def load_configs(csv_file="configs.csv"):
    configs = {}
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.pop('config_name')
            params = {}
            for k, v in row.items():
                try:
                    params[k.upper()] = int(v)
                except ValueError:
                    params[k.upper()] = v
            params['ENABLE_FAST_MUL'] = 0  # does not fit
            configs[name] = params
    return configs

CONFIGS = load_configs()

# ---------- Helper functions ----------
def run_cmd(cmd, desc, cwd=None, log_file=None):
    """Run shell command, log output to a file."""
    print(f"  {desc}...", end=" ", flush=True)
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if log_file:
        log_file = os.path.abspath(log_file)
        try:
            with open(log_file, 'w') as f:
                f.write(f"COMMAND: {cmd}\n\nSTDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}")
            print(f"(log: {log_file})", end=" ", flush=True)
        except Exception as e:
            print(f"WARNING: failed to write log {log_file}: {e}", flush=True)
    if result.returncode == 0:
        print("OK")
    else:
        print(f"FAIL (code {result.returncode})")
        if log_file:
            print(f"    See log: {log_file}")
    return result.returncode, result.stdout, result.stderr

def replace_in_file(file_path, pattern, replacement):
    """Perform a regex replacement in a file."""
    if not os.path.exists(file_path):
        return False
    with open(file_path, 'r') as f:
        content = f.read()
    new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)
    if new_content != content:
        with open(file_path, 'w') as f:
            f.write(new_content)
        return True
    return False

def generate_config_files(config_name, params, build_dir):
    """Copy all source files, then override parameters."""
    os.makedirs(build_dir, exist_ok=True)

    # 1. Copy all Verilog sources
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for src in VERILOG_SOURCES:
        src_path = os.path.join(script_dir, src)
        if not os.path.exists(src_path):
            print(f"  WARNING: Source {src} not found, skipping")
            continue
        dest = os.path.join(build_dir, os.path.basename(src))
        shutil.copy2(src_path, dest)

    # 2. Override CPU parameters in icebreaker.v
    icebreaker_path = os.path.join(build_dir, "icebreaker.v")
    for param in ["BARREL_SHIFTER", "ENABLE_MUL", "ENABLE_DIV", "ENABLE_FAST_MUL"]:
        if param in params:
            pattern = rf'\.{param}\s*\(\s*[01]\s*\)'
            replace_in_file(icebreaker_path, pattern, f'.{param}({params[param]})')

    # 3. Override parameters in picosoc.v
    picosoc_path = os.path.join(build_dir, "picosoc.v")

    if "ENABLE_COUNTERS" in params:
        pattern = r'(parameter\s+\[0:0\]\s+ENABLE_COUNTERS\s*=\s*)[01];'
        replace_in_file(picosoc_path, pattern, rf'\g<1>{params["ENABLE_COUNTERS"]};')
    if "ENABLE_IRQ" in params:
        replace_in_file(picosoc_path, r'\.ENABLE_IRQ\(\d+\)', f'.ENABLE_IRQ({params["ENABLE_IRQ"]})')
    if "CACHE_LINES" in params:
        replace_in_file(picosoc_path, r'\.LINES\(\s*\d+\s*\)', f'.LINES({params["CACHE_LINES"]})')
    if "CACHE_WORDS_PER_LINE" in params:
        replace_in_file(picosoc_path, r'\.WORDS_PER_LINE\(\s*\d+\s*\)', f'.WORDS_PER_LINE({params["CACHE_WORDS_PER_LINE"]})')
    if "ENABLE_ICACHE" in params:
        pattern = r'(parameter\s+ENABLE_ICACHE\s*=\s*)[01];'
        replace_in_file(picosoc_path, pattern, rf'\g<1>{params["ENABLE_ICACHE"]};')
    if "ENABLE_DMEM_LOOKAHEAD" in params:
        pattern = r'(parameter\s+ENABLE_DMEM_LOOKAHEAD\s*=\s*)[01];'
        replace_in_file(picosoc_path, pattern, rf'\g<1>{params["ENABLE_DMEM_LOOKAHEAD"]};')

    if "CACHE_MODULE" in params:
        cache_mod = params["CACHE_MODULE"]
        if cache_mod.lower() == "none":
            replace_in_file(picosoc_path, r'(parameter\s+ENABLE_ICACHE\s*=\s*)[01];', r'\g<1>0;')
        else:
            replace_in_file(picosoc_path, r'(parameter\s+ENABLE_ICACHE\s*=\s*)[01];', r'\g<1>1;')
            pattern = r'(\b)icache_\w+(?=\s*#\()'
            replace_in_file(picosoc_path, pattern, rf'\g<1>{cache_mod}')

    # 4. Verify picorv32.v exists
    picorv32_dest = os.path.join(build_dir, "picorv32.v")
    if not os.path.exists(picorv32_dest):
        print(f"  ERROR: picorv32.v not found in build directory!")
        return False
    return True

# ---------- Test simulation integration ----------
def run_tests_for_config(build_dir, smoke=True, timeout_sec=300):
    """
    Copy test infrastructure from project root and run simulation.
    Returns True if all selected tests pass, False otherwise.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Project root is where the main Makefile and testbench.v reside.
    # We assume the script is run from the project root (where picorv32.v is).
    root_dir = script_dir   # since we're at root
    test_files = ["testbench.v", "Makefile", "scripts/makehex.py", "firmware", "tests"]
    for item in test_files:
        src = os.path.join(root_dir, item)
        dst = os.path.join(build_dir, item)
        if not os.path.exists(src):
            print(f"  WARNING: Test file {src} missing, skipping tests")
            return False
        if os.path.isdir(src):
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)

    env = os.environ.copy()
    env["TOOLCHAIN_PREFIX"] = "riscv64-unknown-elf-"
    env["CFLAGS"] = "-march=rv32im"

    if smoke:
        make_target = "test_add test_mul test_div test_lw test_sw test_beq"
    else:
        make_target = "test"

    try:
        subprocess.run("make clean", cwd=build_dir, shell=True, env=env, check=False)
        result = subprocess.run(
            f"make {make_target}",
            cwd=build_dir, shell=True, env=env,
            timeout=timeout_sec,
            capture_output=True, text=True
        )
        # Check pass condition
        if smoke:
            # For smoke test, look for each test's "OK" line
            required_oks = ["add..OK", "mul..OK", "div..OK", "lw..OK", "sw..OK", "beq..OK"]
            if all(ok in result.stdout for ok in required_oks):
                return True
        else:
            if "ALL TESTS PASSED" in result.stdout:
                return True
        print(f"  Tests failed in {build_dir}")
        print(result.stdout[-2000:])
        return False
    except subprocess.TimeoutExpired:
        print(f"  Tests timed out after {timeout_sec}s in {build_dir}")
        return False
    except Exception as e:
        print(f"  Error running tests: {e}")
        return False

# ---------- PPA measurement functions (unchanged) ----------
def get_area_from_yosys(log_text):
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

def parse_nextpnr_utilization(output):
    util = {
        'lc_used': 0, 'lc_total': 0, 'lc_percent': 0,
        'ram_used': 0, 'ram_total': 0, 'ram_percent': 0,
        'dsp_used': 0, 'dsp_total': 0, 'dsp_percent': 0,
        'io_used': 0, 'io_total': 0, 'io_percent': 0,
        'pll_used': 0, 'pll_total': 0, 'pll_percent': 0,
        'gb_used': 0, 'gb_total': 0, 'gb_percent': 0,
    }
    for line in output.splitlines():
        line = line.lstrip()
        if line.startswith('Info:'):
            line = line[5:].lstrip()
        m = re.match(r'(\S+)\s*:\s*(\d+)\s*/\s*(\d+)\s*(\d+)%', line)
        if m:
            res, used, total, pct = m.groups()
            used, total, pct = int(used), int(total), int(pct)
            if res == 'ICESTORM_LC':
                util['lc_used'], util['lc_total'], util['lc_percent'] = used, total, pct
            elif res == 'ICESTORM_RAM':
                util['ram_used'], util['ram_total'], util['ram_percent'] = used, total, pct
            elif res == 'ICESTORM_DSP':
                util['dsp_used'], util['dsp_total'], util['dsp_percent'] = used, total, pct
            elif res == 'SB_IO':
                util['io_used'], util['io_total'], util['io_percent'] = used, total, pct
            elif res == 'ICESTORM_PLL':
                util['pll_used'], util['pll_total'], util['pll_percent'] = used, total, pct
            elif res == 'SB_GB':
                util['gb_used'], util['gb_total'], util['gb_percent'] = used, total, pct
    return util

def process_config(config_name, params, build_root, run_tests=True):
    build_dir = os.path.join(build_root, config_name)
    if not generate_config_files(config_name, params, build_dir):
        return None

    # Early test simulation – skip synthesis if tests fail
    if run_tests:
        print("  Running smoke tests...")
        if not run_tests_for_config(build_dir, smoke=True):
            # Record failure with minimal info
            metrics = {
                "config": config_name,
                "tests_pass": 0,
                "luts": 0, "ffs": 0, "brams": 0, "dsps": 0, "carry_cells": 0,
                "fmax_mhz": 0, "logic_levels": 0,
                "lc_used": 0, "lc_total": 0, "lc_percent": 0,
                "ram_used": 0, "ram_total": 0, "ram_percent": 0,
                "dsp_used": 0, "dsp_total": 0, "dsp_percent": 0,
                "io_used": 0, "io_total": 0, "io_percent": 0,
                "pll_used": 0, "pll_total": 0, "pll_percent": 0,
                "gb_used": 0, "gb_total": 0, "gb_percent": 0,
            }
            for k, v in params.items():
                metrics[k.lower()] = v
            return metrics
    else:
        print("  Skipping tests (--skip-tests used)")

    # Copy PCF file
    script_dir = os.path.dirname(os.path.abspath(__file__))
    pcf_src = os.path.join(script_dir, PCF_FILE)
    if not os.path.exists(pcf_src):
        pcf_src = PCF_FILE
    if os.path.exists(pcf_src):
        shutil.copy2(pcf_src, build_dir)
    else:
        print(f"  ERROR: PCF file {PCF_FILE} not found")
        return None

    source_files = [os.path.basename(f) for f in VERILOG_SOURCES]  # after copy
    # Yosys synthesis
    yosys_log = os.path.join(build_dir, "yosys_synth.log")
    yosys_cmd = f"yosys -p 'read_verilog {' '.join(source_files)}; synth_ice40 -top {TOP_MODULE}; stat -width'"
    rc, stdout, stderr = run_cmd(yosys_cmd, "Yosys synthesis", cwd=build_dir, log_file=yosys_log)
    if rc != 0:
        return None
    log = stdout + stderr
    luts, ffs, brams, dsps, carry = get_area_from_yosys(log)

    # Yosys to JSON
    json_file = "design.json"
    json_cmd = f"yosys -q -p 'read_verilog {' '.join(source_files)}; synth_ice40 -top {TOP_MODULE} -json {json_file}'"
    rc, _, _ = run_cmd(json_cmd, "Yosys to JSON", cwd=build_dir)
    if rc != 0:
        return None

    # nextpnr
    asc_file = "design.asc"
    pnr_log = os.path.join(build_dir, "nextpnr.log")
    pnr_cmd = f"nextpnr-ice40 --{DEVICE} --package {PACKAGE} --json {json_file} --pcf {PCF_FILE} --asc {asc_file} --pcf-allow-unconstrained"
    rc, stdout, stderr = run_cmd(pnr_cmd, "NextPNR", cwd=build_dir, log_file=pnr_log)
    if rc != 0:
        return None
    util = parse_nextpnr_utilization(stdout + stderr)

    # icetime
    timing_rpt = "timing.rpt"
    icetime_cmd = f"icetime -d {DEVICE} -mtr {timing_rpt} {asc_file}"
    rc, _, _ = run_cmd(icetime_cmd, "icetime", cwd=build_dir)
    if rc != 0:
        return None
    fmax, logic_levels = get_timing_from_icetime(os.path.join(build_dir, timing_rpt))

    metrics = {
        "config": config_name,
        "tests_pass": 1,
        "luts": luts,
        "ffs": ffs,
        "brams": brams,
        "dsps": dsps,
        "carry_cells": carry,
        "fmax_mhz": fmax,
        "logic_levels": logic_levels,
        "lc_used": util['lc_used'],
        "lc_total": util['lc_total'],
        "lc_percent": util['lc_percent'],
        "ram_used": util['ram_used'],
        "ram_total": util['ram_total'],
        "ram_percent": util['ram_percent'],
        "dsp_used": util['dsp_used'],
        "dsp_total": util['dsp_total'],
        "dsp_percent": util['dsp_percent'],
        "io_used": util['io_used'],
        "io_total": util['io_total'],
        "io_percent": util['io_percent'],
        "pll_used": util['pll_used'],
        "pll_total": util['pll_total'],
        "pll_percent": util['pll_percent'],
        "gb_used": util['gb_used'],
        "gb_total": util['gb_total'],
        "gb_percent": util['gb_percent'],
    }
    for k, v in params.items():
        metrics[k.lower()] = v
    return metrics

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-tests', action='store_true', help='Do not run simulation tests (only PPA)')
    args = parser.parse_args()

    required_files = ["picorv32.v", "testbench.v", "picosoc/icebreaker.v", "picosoc/icebreaker.pcf"]
    missing = [f for f in required_files if not os.path.exists(f)]
    if missing:
        print(f"ERROR: Missing required files: {missing}")
        print("Run this script from the project root directory (e.g., ~/main_tues/)")
        return

    build_root = "build_fixed"
    if os.path.exists(build_root):
        shutil.rmtree(build_root)
    os.makedirs(build_root, exist_ok=True)

    results = []
    for config_name, params in CONFIGS.items():
        print(f"\n=== Running {config_name} ===")
        metrics = process_config(config_name, params, build_root, run_tests=not args.skip_tests)
        if metrics:
            results.append(metrics)
            if metrics.get('tests_pass', 0):
                print(f"  LUTs: {metrics['luts']}, Fmax: {metrics['fmax_mhz']:.2f} MHz")
            else:
                print(f"  Tests failed for {config_name}, recorded as failure.")
        else:
            print(f"  {config_name} failed (synthesis/P&R error).")

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