#!/usr/bin/env python3
"""
Fixed PPA script for icebreaker design.
Supports CPU parameters, MEM_WORDS, cache size parameters,
and cache module selection (from icache.v).
Includes early functional testing via RISC-V instruction tests.
"""

import subprocess
import re
import csv
import os
import shutil
import argparse

# ---------- Configuration ----------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)   # one level up (main_tues/)

VERILOG_SOURCES = [
    "icebreaker.v",
    "ice40up5k_spram.v",
    "spimemio.v",
    "simpleuart.v",
    "icache.v",
    "dmem_lookahead_buffer.v",
    "picosoc.v",
    os.path.join(PROJECT_ROOT, "picorv32.v")
]
PCF_FILE = "icebreaker.pcf"
TOP_MODULE = "icebreaker"
DEVICE = "up5k"
PACKAGE = "sg48"

# ---------- Load configurations from CSV ----------
def load_configs(csv_file="configs.csv"):
    csv_path = os.path.join(SCRIPT_DIR, csv_file)
    configs = {}
    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.pop('config_name')
            params = {}
            for k, v in row.items():
                try:
                    params[k.upper()] = int(v)
                except ValueError:
                    params[k.upper()] = v
            params['ENABLE_FAST_MUL'] = 0   # does not fit on iCE40
            configs[name] = params
    return configs

CONFIGS = load_configs()

# ---------- Helper functions ----------
def run_cmd(cmd, desc, cwd=None, log_file=None):
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

def copy_test_infrastructure(build_dir):
    """Copy testbench.v, Makefile, firmware/, tests/, scripts/ into build_dir."""
    items = ["testbench.v", "Makefile", "firmware", "tests", "scripts"]
    for item in items:
        src = os.path.join(PROJECT_ROOT, item)
        dst = os.path.join(build_dir, item)
        if os.path.isdir(src):
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)

def override_testbench_params(build_dir, params):
    """Modify testbench.v: set both parameter declarations and instance ports."""
    tb_path = os.path.join(build_dir, "testbench.v")
    if not os.path.exists(tb_path):
        print("  WARNING: testbench.v not found, cannot override parameters")
        return False

    # All parameters we want to propagate to the testbench
    tb_params = [
        "ENABLE_MUL", "ENABLE_DIV", "ENABLE_FAST_MUL", "BARREL_SHIFTER",
        "COMPRESSED_ISA", "ENABLE_COUNTERS", "ENABLE_IRQ",
        "TWO_STAGE_SHIFT", "TWO_CYCLE_COMPARE", "TWO_CYCLE_ALU",
        "ENABLE_REGS_DUALPORT", "ENABLE_COUNTERS64",
        "CATCH_MISALIGN", "CATCH_ILLINSN", "LATCHED_MEM_RDATA",
        "USE_CLK_DIVIDER", "ENABLE_IRQ_QREGS"
    ]

    # 1. Override parameter declarations
    for p in tb_params:
        if p in params:
            pattern = rf'parameter\s+{p}\s*=\s*[01];'
            replacement = f'parameter {p} = {params[p]};'
            replace_in_file(tb_path, pattern, replacement)

    # 2. Override instance port connections
    for p in tb_params:
        if p in params:
            pattern = rf'\.{p}\s*\(\s*[01]\s*\)'
            replacement = f'.{p}({params[p]})'
            replace_in_file(tb_path, pattern, replacement)

    # 3. ENABLE_PCPI is derived from mul/div
    if params.get("ENABLE_MUL", 0) or params.get("ENABLE_DIV", 0):
        replace_in_file(tb_path, r'parameter\s+ENABLE_PCPI\s*=\s*[01];', 'parameter ENABLE_PCPI = 1;')
        replace_in_file(tb_path, r'\.ENABLE_PCPI\(\s*[01]\s*\)', '.ENABLE_PCPI(1)')
    else:
        replace_in_file(tb_path, r'parameter\s+ENABLE_PCPI\s*=\s*[01];', 'parameter ENABLE_PCPI = 0;')
        replace_in_file(tb_path, r'\.ENABLE_PCPI\(\s*[01]\s*\)', '.ENABLE_PCPI(0)')

    return True

def run_tests_for_config(build_dir, timeout_sec=300):
    """Run full test suite and return True if 'ALL TESTS PASSED' appears."""
    env = os.environ.copy()
    try:
        subprocess.run("make clean", cwd=build_dir, shell=True, env=env, check=False, capture_output=True)
        result = subprocess.run(
            "make test TOOLCHAIN_PREFIX=riscv64-unknown-elf-",
            cwd=build_dir, shell=True, env=env,
            timeout=timeout_sec,
            capture_output=True, text=True
        )
        return "ALL TESTS PASSED" in result.stdout
    except Exception as e:
        print(f"  Test error: {e}")
        return False

def generate_config_files(config_name, params, build_dir):
    """Copy all source files, override parameters in icebreaker.v, picosoc.v, picorv32.v, and testbench.v."""
    os.makedirs(build_dir, exist_ok=True)

    # 1. Copy all Verilog sources
    for src in VERILOG_SOURCES:
        src_path = src
        if not os.path.isabs(src_path):
            src_path = os.path.join(SCRIPT_DIR, src)
        if not os.path.exists(src_path):
            src_path = os.path.join(SCRIPT_DIR, os.path.basename(src))
        if not os.path.exists(src_path):
            print(f"  WARNING: Source {src} not found, skipping")
            continue
        dest = os.path.join(build_dir, os.path.basename(src))
        shutil.copy2(src_path, dest)

    # 2. Override icebreaker.v instance ports (only those that exist as ports)
    icebreaker_path = os.path.join(build_dir, "icebreaker.v")
    icebreaker_ports = ["BARREL_SHIFTER", "ENABLE_MUL", "ENABLE_DIV", "ENABLE_FAST_MUL"]
    for param in icebreaker_ports:
        if param in params:
            pattern = rf'\.{param}\s*\(\s*[01]\s*\)'
            replace_in_file(icebreaker_path, pattern, f'.{param}({params[param]})')
    # Also handle USE_CLK_DIVIDER (integer, not binary) – optional
    if "USE_CLK_DIVIDER" in params:
        pattern = r'(parameter\s+USE_CLK_DIVIDER\s*=\s*)\d+;'
        replace_in_file(icebreaker_path, pattern, rf'\g<1>{params["USE_CLK_DIVIDER"]};')

    # 3. Override picosoc.v parameters (both parameters and ports)
    picosoc_path = os.path.join(build_dir, "picosoc.v")
    # Parameters that appear as 'parameter' in picosoc.v
    if "ENABLE_COUNTERS" in params:
        pattern = r'(parameter\s+\[0:0\]\s+ENABLE_COUNTERS\s*=\s*)[01];'
        replace_in_file(picosoc_path, pattern, rf'\g<1>{params["ENABLE_COUNTERS"]};')
    if "ENABLE_COMPRESSED" in params:
        pattern = r'(parameter\s+\[0:0\]\s+ENABLE_COMPRESSED\s*=\s*)[01];'
        replace_in_file(picosoc_path, pattern, rf'\g<1>{params["ENABLE_COMPRESSED"]};')
    if "ENABLE_IRQ_QREGS" in params:
        pattern = r'(parameter\s+\[0:0\]\s+ENABLE_IRQ_QREGS\s*=\s*)[01];'
        replace_in_file(picosoc_path, pattern, rf'\g<1>{params["ENABLE_IRQ_QREGS"]};')
    # Instance port overrides in picosoc.v (for ENABLE_IRQ)
    if "ENABLE_IRQ" in params:
        replace_in_file(picosoc_path, r'\.ENABLE_IRQ\(\d+\)', f'.ENABLE_IRQ({params["ENABLE_IRQ"]})')
    # Cache parameters
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

    # 4. Override picorv32.v internal parameters (direct file edit)
    picorv32_path = os.path.join(build_dir, "picorv32.v")
    if os.path.exists(picorv32_path):
        internal_params = [
            "TWO_STAGE_SHIFT", "TWO_CYCLE_COMPARE", "TWO_CYCLE_ALU",
            "ENABLE_REGS_DUALPORT", "ENABLE_COUNTERS64",
            "CATCH_MISALIGN", "CATCH_ILLINSN", "LATCHED_MEM_RDATA"
        ]
        for param in internal_params:
            if param in params:
                # Flexible regex: matches "parameter [ 0 : 0 ] PARAM_NAME = 0,"
                pattern = rf'(parameter\s+\[\s*0\s*:\s*0\s*\]\s+{param}\s*=\s*)[01]\s*,'
                replacement = rf'\g<1>{params[param]},'
                replace_in_file(picorv32_path, pattern, replacement)

    # 5. Copy test infrastructure and override testbench parameters
    copy_test_infrastructure(build_dir)
    override_testbench_params(build_dir, params)

    # 6. Verify picorv32.v exists (should be there)
    if not os.path.exists(picorv32_path):
        print(f"  ERROR: picorv32.v not found in build directory!")
        return False
    return True

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

def process_config(config_name, params, build_root, skip_tests=False, continue_on_test_fail=False):
    build_dir = os.path.join(build_root, config_name)
    if not generate_config_files(config_name, params, build_dir):
        return None

    # Run tests (may decide to skip PPA if tests fail and continue_on_test_fail is False)
    tests_passed = False
    if not skip_tests:
        print("  Running smoke tests...")
        tests_passed = run_tests_for_config(build_dir)
        if tests_passed:
            print("  Smoke tests PASSED")
        else:
            print("  Smoke tests FAILED")
            if not continue_on_test_fail:
                print("  Skipping synthesis/P&R for this config (use --continue-on-test-fail to override)")
                # Return minimal metrics with tests_pass=0 and zeros for PPA
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
    pcf_src = os.path.join(SCRIPT_DIR, PCF_FILE)
    if os.path.exists(pcf_src):
        shutil.copy2(pcf_src, build_dir)
    else:
        print(f"  ERROR: PCF file {PCF_FILE} not found")
        return None

    source_files = [
        "icebreaker.v",
        "ice40up5k_spram.v",
        "spimemio.v",
        "simpleuart.v",
        "icache.v",
        "dmem_lookahead_buffer.v",
        "picosoc.v",
        "picorv32.v"
    ]

    # Yosys synthesis
    yosys_log = os.path.join(build_dir, "yosys_synth.log")
    yosys_cmd = f"yosys -p 'read_verilog {' '.join(source_files)}; synth_ice40 -top {TOP_MODULE}; stat -width'"
    rc, stdout, stderr = run_cmd(yosys_cmd, "Yosys synthesis", cwd=build_dir, log_file=yosys_log)
    if rc != 0:
        # Return zeros but record test result
        metrics = {
            "config": config_name,
            "tests_pass": 1 if tests_passed else 0,
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
    log = stdout + stderr
    luts, ffs, brams, dsps, carry = get_area_from_yosys(log)

    # Yosys to JSON
    json_file = "design.json"
    json_cmd = f"yosys -q -p 'read_verilog {' '.join(source_files)}; synth_ice40 -top {TOP_MODULE} -json {json_file}'"
    rc, _, _ = run_cmd(json_cmd, "Yosys to JSON", cwd=build_dir)
    if rc != 0:
        metrics = {
            "config": config_name,
            "tests_pass": 1 if tests_passed else 0,
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

    # nextpnr
    asc_file = "design.asc"
    pnr_log = os.path.join(build_dir, "nextpnr.log")
    pnr_cmd = f"nextpnr-ice40 --{DEVICE} --package {PACKAGE} --json {json_file} --pcf {PCF_FILE} --asc {asc_file} --pcf-allow-unconstrained"
    rc, stdout, stderr = run_cmd(pnr_cmd, "NextPNR", cwd=build_dir, log_file=pnr_log)
    if rc != 0:
        metrics = {
            "config": config_name,
            "tests_pass": 1 if tests_passed else 0,
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
    util = parse_nextpnr_utilization(stdout + stderr)

    # icetime
    timing_rpt = "timing.rpt"
    icetime_cmd = f"icetime -d {DEVICE} -mtr {timing_rpt} {asc_file}"
    rc, _, _ = run_cmd(icetime_cmd, "icetime", cwd=build_dir)
    if rc != 0:
        metrics = {
            "config": config_name,
            "tests_pass": 1 if tests_passed else 0,
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
    fmax, logic_levels = get_timing_from_icetime(os.path.join(build_dir, timing_rpt))

    metrics = {
        "config": config_name,
        "tests_pass": 1 if tests_passed else 0,
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
    parser.add_argument('--skip-tests', action='store_true', help='Skip functional simulation tests (run only PPA)')
    parser.add_argument('--continue-on-test-fail', action='store_true', help='Continue to synthesis/P&R even if functional tests fail')
    args = parser.parse_args()

    required_files = ["icebreaker.v", "picosoc.v", "icebreaker.pcf"]
    missing = [f for f in required_files if not os.path.exists(os.path.join(SCRIPT_DIR, f))]
    if missing:
        print(f"ERROR: Missing required files in {SCRIPT_DIR}: {missing}")
        return
    if not os.path.exists(os.path.join(PROJECT_ROOT, "picorv32.v")):
        print("ERROR: picorv32.v not found in project root.")
        return

    build_root = os.path.join(SCRIPT_DIR, "build_fixed")
    if os.path.exists(build_root):
        shutil.rmtree(build_root)
    os.makedirs(build_root, exist_ok=True)

    results = []
    for config_name, params in CONFIGS.items():
        print(f"\n=== Running {config_name} ===")
        metrics = process_config(config_name, params, build_root, skip_tests=args.skip_tests,continue_on_test_fail=args.continue_on_test_fail)
        if metrics:
            results.append(metrics)
            if metrics.get('tests_pass', 0) == 1:
                print(f"  LUTs: {metrics['luts']}, Fmax: {metrics['fmax_mhz']:.2f} MHz")
            else:
                print(f"  {config_name} failed functional tests.")
        else:
            print(f"  {config_name} failed (synthesis/P&R error).")

    if not results:
        print("No successful runs, exiting.")
        return

    csv_file = os.path.join(SCRIPT_DIR, "ppa_config_fixed.csv")
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