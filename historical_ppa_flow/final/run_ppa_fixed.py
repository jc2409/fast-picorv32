#!/usr/bin/env python3
"""
PPA script with fixed CSV columns.
"""
import subprocess, re, csv, os, shutil, argparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
VERILOG_SOURCES = [
    "icebreaker.v", "ice40up5k_spram.v", "spimemio.v", "simpleuart.v",
    "icache.v", "dmem_lookahead_buffer.v", "picosoc.v",
    os.path.join(PROJECT_ROOT, "picorv32.v")
]
PCF_FILE = "icebreaker.pcf"
TOP_MODULE = "icebreaker"
DEVICE = "up5k"
PACKAGE = "sg48"

# ---- Fixed column names for ppa_config_fixed.csv ----
PPA_COLUMNS = [
    "config", "luts", "ffs", "brams", "dsps", "carry_cells", "fmax_mhz", "logic_levels",
    "lc_used", "lc_total", "lc_percent", "ram_used", "ram_total", "ram_percent",
    "dsp_used", "dsp_total", "dsp_percent", "io_used", "io_total", "io_percent",
    "pll_used", "pll_total", "pll_percent", "gb_used", "gb_total", "gb_percent",
    "actual_freq_mhz", "functional_test_pass",
    "barrel_shifter", "enable_mul", "enable_div", "enable_counters", "enable_compressed",
    "cache_lines", "cache_words_per_line", "cache_module", "enable_fast_mul"
]

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
                    try:
                        params[k.upper()] = float(v)
                    except ValueError:
                        params[k.upper()] = v
            params['ENABLE_FAST_MUL'] = 0
            configs[name] = params
    return configs

def run_cmd(cmd, desc, cwd=None, log_file=None):
    print(f"  {desc}...", end=" ", flush=True)
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if log_file:
        log_file = os.path.abspath(log_file)
        try:
            with open(log_file, 'w') as f:
                f.write(f"COMMAND: {cmd}\n\nSTDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}")
            print(f"(log: {log_file})", end=" ", flush=True)
        except Exception:
            pass
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

def generate_config_files(config_name, params, build_dir):
    os.makedirs(build_dir, exist_ok=True)
    wrapper_src = os.path.join(SCRIPT_DIR, "icache_wrapper.v")
    if os.path.exists(wrapper_src):
        shutil.copy2(wrapper_src, build_dir)
    for src in VERILOG_SOURCES:
        src_path = src
        if not os.path.isabs(src_path):
            src_path = os.path.join(SCRIPT_DIR, src)
        if not os.path.exists(src_path):
            src_path = os.path.join(SCRIPT_DIR, os.path.basename(src))
        if not os.path.exists(src_path):
            continue
        shutil.copy2(src_path, os.path.join(build_dir, os.path.basename(src)))
    for fname in ["start.s", "group5_benchmark.c", "sections.lds"]:
        src = os.path.join(SCRIPT_DIR, fname)
        if os.path.exists(src):
            shutil.copy2(src, build_dir)

    cache_mod = params.get("CACHE_MODULE", "").lower()
    lookahead_caches = ["icache_multiword_lookahead", "icache_multiword_lookahead_2way"]
    use_wrapper = cache_mod not in lookahead_caches and cache_mod != "none"
    if use_wrapper:
        params["ORIG_CACHE_MODULE"] = cache_mod
        params["CACHE_MODULE"] = "icache_wrapper"

    icebreaker_path = os.path.join(build_dir, "icebreaker.v")
    for param in ["BARREL_SHIFTER", "ENABLE_MUL", "ENABLE_DIV", "ENABLE_FAST_MUL"]:
        if param in params:
            replace_in_file(icebreaker_path, rf'\.{param}\s*\(\s*[01]\s*\)', f'.{param}({params[param]})')

    picosoc_path = os.path.join(build_dir, "picosoc.v")
    if "ENABLE_COUNTERS" in params:
        replace_in_file(picosoc_path, r'(parameter\s+\[0:0\]\s+ENABLE_COUNTERS\s*=\s*)[01];', rf'\g<1>{params["ENABLE_COUNTERS"]};')
    if "ENABLE_IRQ" in params:
        replace_in_file(picosoc_path, r'\.ENABLE_IRQ\(\d+\)', f'.ENABLE_IRQ({params["ENABLE_IRQ"]})')
    if "CACHE_LINES" in params:
        replace_in_file(picosoc_path, r'\.LINES\(\s*\d+\s*\)', f'.LINES({params["CACHE_LINES"]})')
    if "CACHE_WORDS_PER_LINE" in params:
        replace_in_file(picosoc_path, r'\.WORDS_PER_LINE\(\s*\d+\s*\)', f'.WORDS_PER_LINE({params["CACHE_WORDS_PER_LINE"]})')
    if "ENABLE_ICACHE" in params:
        replace_in_file(picosoc_path, r'(parameter\s+ENABLE_ICACHE\s*=\s*)[01];', rf'\g<1>{params["ENABLE_ICACHE"]};')
    if "ENABLE_DMEM_LOOKAHEAD" in params:
        replace_in_file(picosoc_path, r'(parameter\s+ENABLE_DMEM_LOOKAHEAD\s*=\s*)[01];', rf'\g<1>{params["ENABLE_DMEM_LOOKAHEAD"]};')
    if "CACHE_MODULE" in params:
        cache_mod = params["CACHE_MODULE"]
        if cache_mod.lower() == "none":
            replace_in_file(picosoc_path, r'(parameter\s+ENABLE_ICACHE\s*=\s*)[01];', r'\g<1>0;')
        else:
            replace_in_file(picosoc_path, r'(parameter\s+ENABLE_ICACHE\s*=\s*)[01];', r'\g<1>1;')
            replace_in_file(picosoc_path, r'(\b)icache_\w+(?=\s*#\()', rf'\g<1>{cache_mod}')

    picorv32_dest = os.path.join(build_dir, "picorv32.v")
    if not os.path.exists(picorv32_dest):
        return False
    return True

def copy_test_infrastructure(build_dir, mem_words):
    tb_src = os.path.join(SCRIPT_DIR, "icebreaker_tb.v")
    tb_dst = os.path.join(build_dir, "testbench.v")
    if os.path.exists(tb_src):
        shutil.copy2(tb_src, tb_dst)
        replace_in_file(tb_dst, r'\.MEM_WORDS\(\s*\d+\s*\)', f'.MEM_WORDS({mem_words})')
    make_src = os.path.join(SCRIPT_DIR, "Makefile")
    make_dst = os.path.join(build_dir, "Makefile")
    if os.path.exists(make_src):
        shutil.copy2(make_src, make_dst)
        replace_in_file(make_dst, r'\.\./picorv32\.v', 'picorv32.v')
    spiflash_src = os.path.join(SCRIPT_DIR, "spiflash.v")
    if os.path.exists(spiflash_src):
        shutil.copy2(spiflash_src, build_dir)

def run_functional_tests(build_dir, timeout_sec=300):
    env = os.environ.copy()
    cross = os.environ.get('CROSS', 'riscv32-unknown-elf-')
    try:
        subprocess.run("make clean", cwd=build_dir, shell=True, env=env, check=False, capture_output=True)
        result = subprocess.run(
            f"make icebsim CROSS={cross}",
            cwd=build_dir, shell=True, env=env, timeout=timeout_sec,
            capture_output=True, text=True
        )
        output = result.stdout + result.stderr
        if "ERROR!" in output or "TRAP" in output:
            return False
        return True
    except Exception as e:
        print(f"  Test error: {e}")
        return False

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
    util = {'lc_used':0,'lc_total':0,'lc_percent':0,'ram_used':0,'ram_total':0,'ram_percent':0,'dsp_used':0,'dsp_total':0,'dsp_percent':0,'io_used':0,'io_total':0,'io_percent':0,'pll_used':0,'pll_total':0,'pll_percent':0,'gb_used':0,'gb_total':0,'gb_percent':0}
    for line in output.splitlines():
        line = line.lstrip()
        if line.startswith('Info:'):
            line = line[5:].lstrip()
        m = re.match(r'(\S+)\s*:\s*(\d+)\s*/\s*(\d+)\s*(\d+)%', line)
        if m:
            res, used, total, pct = m.groups()
            used, total, pct = int(used), int(total), int(pct)
            if res == 'ICESTORM_LC':
                util['lc_used'],util['lc_total'],util['lc_percent'] = used,total,pct
            elif res == 'ICESTORM_RAM':
                util['ram_used'],util['ram_total'],util['ram_percent'] = used,total,pct
            elif res == 'ICESTORM_DSP':
                util['dsp_used'],util['dsp_total'],util['dsp_percent'] = used,total,pct
            elif res == 'SB_IO':
                util['io_used'],util['io_total'],util['io_percent'] = used,total,pct
            elif res == 'ICESTORM_PLL':
                util['pll_used'],util['pll_total'],util['pll_percent'] = used,total,pct
            elif res == 'SB_GB':
                util['gb_used'],util['gb_total'],util['gb_percent'] = used,total,pct
    return util

def compile_benchmark(build_dir, freq_hz):
    cross = os.environ.get('CROSS', 'riscv32-unknown-elf-')
    lds_src = os.path.join(build_dir, "sections.lds")
    lds_dst = os.path.join(build_dir, "icebreaker_sections.lds")
    if os.path.exists(lds_src):
        subprocess.run(f"{cross}cpp -P -DICEBREAKER -o {lds_dst} {lds_src}", shell=True, cwd=build_dir, check=False)
    elf = os.path.join(build_dir, "benchmark.elf")
    bin_file = os.path.join(build_dir, "benchmark.bin")
    gcc_cmd = (f"{cross}gcc -DICEBREAKER -DF_CPU={freq_hz} -mabi=ilp32 -march=rv32im "
               f"-ffreestanding -nostdlib -Wl,-Bstatic,-T,icebreaker_sections.lds,--strip-debug "
               f"-o {elf} {os.path.join(build_dir, 'start.s')} {os.path.join(build_dir, 'group5_benchmark.c')}")
    ret = subprocess.run(gcc_cmd, shell=True, cwd=build_dir, capture_output=True)
    if ret.returncode != 0:
        print(f"  Benchmark compilation failed: {ret.stderr.decode()}")
        return False
    subprocess.run(f"{cross}objcopy -O binary {elf} {bin_file}", shell=True, cwd=build_dir, check=False)
    print("  Benchmark firmware compiled successfully")
    return True

def process_config(config_name, params, build_root):
    build_dir = os.path.join(build_root, config_name)
    if not generate_config_files(config_name, params, build_dir):
        return None
    pcf_src = os.path.join(SCRIPT_DIR, PCF_FILE)
    if os.path.exists(pcf_src):
        shutil.copy2(pcf_src, build_dir)

    wrapper_file = os.path.join(build_dir, "icache_wrapper.v")
    use_wrapper = os.path.exists(wrapper_file) and params.get("CACHE_MODULE", "") == "icache_wrapper"
    yosys_def = ""
    if use_wrapper:
        orig_cache = params.get("ORIG_CACHE_MODULE", "")
        if orig_cache:
            yosys_def = f"-DCACHE_INNER={orig_cache}"
            caches_with_words_per_line = [
                "icache_multiword", "icache_multiword_first_miss_bypass",
                "icache_multiword_lookahead", "icache_multiword_lookahead_2way"
            ]
            if orig_cache in caches_with_words_per_line:
                yosys_def += " -DHAS_WORDS_PER_LINE"
            print(f"  Using wrapper for cache {orig_cache} (define: {yosys_def})")

    source_files = ["icebreaker.v","ice40up5k_spram.v","spimemio.v","simpleuart.v","icache.v","dmem_lookahead_buffer.v","picosoc.v","picorv32.v"]
    if use_wrapper:
        source_files.insert(4, "icache_wrapper.v")

    yosys_log = os.path.join(build_dir, "yosys_synth.log")
    read_cmd = f"read_verilog {yosys_def} {' '.join(source_files)}" if yosys_def else f"read_verilog {' '.join(source_files)}"
    yosys_cmd = f"yosys -p '{read_cmd}; synth_ice40 -top {TOP_MODULE}; stat -width'"
    rc, stdout, stderr = run_cmd(yosys_cmd, "Yosys synthesis", cwd=build_dir, log_file=yosys_log)
    if rc != 0:
        return None
    luts, ffs, brams, dsps, carry = get_area_from_yosys(stdout+stderr)

    json_file = "design.json"
    json_cmd = f"yosys -q -p '{read_cmd}; synth_ice40 -top {TOP_MODULE} -json {json_file}'"
    rc, _, _ = run_cmd(json_cmd, "Yosys to JSON", cwd=build_dir)
    if rc != 0:
        return None

    asc_file = "design.asc"
    pnr_log = os.path.join(build_dir, "nextpnr.log")
    rc, stdout, stderr = run_cmd(f"nextpnr-ice40 --{DEVICE} --package {PACKAGE} --json {json_file} --pcf {PCF_FILE} --asc {asc_file} --pcf-allow-unconstrained", "NextPNR", cwd=build_dir, log_file=pnr_log)
    if rc != 0:
        return None
    util = parse_nextpnr_utilization(stdout+stderr)

    timing_rpt = "timing.rpt"
    rc, _, _ = run_cmd(f"icetime -d {DEVICE} -mtr {timing_rpt} {asc_file}", "icetime", cwd=build_dir)
    if rc != 0:
        return None
    fmax, logic_levels = get_timing_from_icetime(os.path.join(build_dir, timing_rpt))

    bin_file = os.path.join(build_dir, "design.bin")
    rc, _, _ = run_cmd(f"icepack {asc_file} {bin_file}", "icepack", cwd=build_dir)
    if rc != 0:
        return None

    mem_words = params.get("MEM_WORDS", 32768)
    copy_test_infrastructure(build_dir, mem_words)
    tests_pass = run_functional_tests(build_dir)
    actual_freq_mhz = params.get('ACTUAL_FREQ_MHZ', 27.75)
    if tests_pass:
        freq_hz = int(actual_freq_mhz * 1e6)
        compile_benchmark(build_dir, freq_hz)

    # Build metrics with all columns
    metrics = {
        "config": config_name,
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
        "actual_freq_mhz": actual_freq_mhz,
        "functional_test_pass": 1 if tests_pass else 0,
        "barrel_shifter": params.get("BARREL_SHIFTER", 0),
        "enable_mul": params.get("ENABLE_MUL", 0),
        "enable_div": params.get("ENABLE_DIV", 0),
        "enable_counters": params.get("ENABLE_COUNTERS", 0),
        "enable_compressed": params.get("ENABLE_COMPRESSED", 0),
        "cache_lines": params.get("CACHE_LINES", 0),
        "cache_words_per_line": params.get("CACHE_WORDS_PER_LINE", 0),
        "cache_module": params.get("CACHE_MODULE", "none"),
        "enable_fast_mul": params.get("ENABLE_FAST_MUL", 0),
    }
    return metrics

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', help='Run only this configuration name')
    args = parser.parse_args()
    required = ["icebreaker.v","picosoc.v","icebreaker.pcf","sections.lds","start.s","group5_benchmark.c","icache_wrapper.v","icebreaker_tb.v"]
    missing = [f for f in required if not os.path.exists(os.path.join(SCRIPT_DIR, f))]
    if missing:
        print(f"Missing: {missing}")
        return
    if not os.path.exists(os.path.join(PROJECT_ROOT, "picorv32.v")):
        print("Missing picorv32.v")
        return
    build_root = os.path.join(SCRIPT_DIR, "build_fixed")
    if not args.config and os.path.exists(build_root):
        shutil.rmtree(build_root)
    os.makedirs(build_root, exist_ok=True)
    CONFIGS = load_configs()
    csv_file = os.path.join(SCRIPT_DIR, "ppa_config_fixed.csv")
    write_header = not os.path.exists(csv_file)
    for config_name, params in CONFIGS.items():
        if args.config and config_name != args.config:
            continue
        print(f"\n=== Running {config_name} ===")
        metrics = process_config(config_name, params, build_root)
        if metrics:
            with open(csv_file, 'a', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=PPA_COLUMNS)
                if write_header:
                    writer.writeheader()
                    write_header = False
                writer.writerow(metrics)
            print(f"  LUTs: {metrics['luts']}, Fmax: {metrics['fmax_mhz']:.2f} MHz, Functional test: {'PASS' if metrics['functional_test_pass'] else 'FAIL'}")
        else:
            print(f"  {config_name} failed (synthesis/P&R error).")
    print(f"\nResults saved to {csv_file}")

if __name__ == "__main__":
    main()
