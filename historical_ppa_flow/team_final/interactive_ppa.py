#!/usr/bin/env python3
"""
Interactive configuration generator for PPA runs.
Asks user about each parameter, generates configs.csv, then runs PPA and analysis.
"""

import os
import sys
import subprocess
import csv
from itertools import product

# ---------- Helper: extract cache modules from icache.v ----------
def get_cache_modules(icache_file="icache.v"):
    """Parse icache.v and return a list of module names that start with 'icache'."""
    modules = []
    if not os.path.exists(icache_file):
        print(f"Warning: {icache_file} not found, using default list.")
        return ["icache_zerocycle", "icache", "icache_first_miss_bypass",
                "icache_random_bypass", "icache_multiword", "icache_multiword_first_miss_bypass",
                "icache_multiword_lookahead"]
    with open(icache_file, 'r') as f:
        content = f.read()
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("module icache"):
            parts = line.split()
            if len(parts) >= 2:
                mod_name = parts[1]
                mod_name = mod_name.split('(')[0].split('#')[0].strip()
                if mod_name not in modules:
                    modules.append(mod_name)
    return sorted(modules)

# ---------- Parameter definitions ----------
BINARY_PARAMS = [
    "BARREL_SHIFTER",
    "ENABLE_MUL",
    "ENABLE_DIV",
    "ENABLE_COUNTERS",
    "ENABLE_COMPRESSED",
    "ENABLE_IRQ",                     # fixed missing comma
    "TWO_STAGE_SHIFT",
    "TWO_CYCLE_COMPARE",
    "TWO_CYCLE_ALU",
    "ENABLE_REGS_DUALPORT",
    "ENABLE_COUNTERS64",
    "CATCH_MISALIGN",
    "CATCH_ILLINSN",
    "LATCHED_MEM_RDATA",
    "USE_CLK_DIVIDER",
    "ENABLE_IRQ_QREGS"
]

CACHE_PARAMS = {
    "CACHE_LINES": [16, 32, 64, 128],
    "CACHE_WORDS_PER_LINE": [1, 2, 4, 8, 16],
}

NUMERICAL_PARAM = "MEM_WORDS"

# ---------- User interaction functions ----------
def ask_overwrite_configs():
    if os.path.exists("configs.csv"):
        resp = input("configs.csv already exists. Overwrite? (y/n): ").strip().lower()
        return resp == 'y'
    return True

def ask_binary_param(param):
    while True:
        ans = input(f"Parameter {param}: ").strip().lower()
        if ans in ('0', '1', 'v', 's'):
            return ans
        print("Invalid input. Please enter 0, 1, v, or s.")

def ask_mem_words():
    print(f"\nParameter {NUMERICAL_PARAM} (original value from Verilog is 32768)")
    ans = input("Enter 's' to skip, a single number, or start:end:step: ").strip()
    if ans.lower() == 's':
        return None
    try:
        val = int(ans)
        return [val]
    except ValueError:
        pass
    parts = ans.split(':')
    if len(parts) == 3:
        try:
            start, end, step = int(parts[0]), int(parts[1]), int(parts[2])
            values = []
            cur = start
            while cur <= end:
                values.append(cur)
                cur += step
            if values and values[-1] != end:
                values.append(end)
            return values
        except ValueError:
            pass
    print("Invalid format. Skipping MEM_WORDS.")
    return None

def ask_cache_param(param, options):
    print(f"\nCache parameter {param} (options: {options})")
    ans = input("Enter a specific value, 'v' for all, or 's' to skip: ").strip().lower()
    if ans == 's':
        return None
    if ans == 'v':
        return options
    try:
        val = int(ans)
        if val in options:
            return [val]
        else:
            print(f"Value not in {options}, skipping.")
            return None
    except:
        print("Invalid input, skipping.")
        return None

def ask_cache_module(modules):
    print("\nAvailable cache modules (from icache.v):")
    print("  0: no cache (disable)")
    for i, mod in enumerate(modules, start=1):
        print(f"  {i}: {mod}")
    ans = input("\nEnter index (or comma/space separated list, or range e.g., 1-3): ").strip()
    if ans == '0':
        return ["none"]
    indices = set()
    parts = ans.replace(',', ' ').split()
    for part in parts:
        if '-' in part:
            a, b = part.split('-')
            for idx in range(int(a), int(b)+1):
                if 1 <= idx <= len(modules):
                    indices.add(idx)
        else:
            try:
                idx = int(part)
                if 1 <= idx <= len(modules):
                    indices.add(idx)
            except:
                pass
    if not indices:
        print("No valid selections, defaulting to no cache.")
        return ["none"]
    return [modules[idx-1] for idx in sorted(indices)]

def generate_configs(binary_choices, mem_words_values, cache_lines_vals, cache_words_vals, cache_modules):
    """Generate configs.csv with unique config names that include cache parameters."""
    # Filter out parameters where user chose 's' (skip)
    active_params = [p for p in BINARY_PARAMS if binary_choices[p] != 's']
    # Build binary combinations only for active parameters
    if active_params:
        binary_lists = []
        for p in active_params:
            choice = binary_choices[p]
            if choice == '0':
                vals = [0]
            elif choice == '1':
                vals = [1]
            else:  # 'v'
                vals = [0, 1]
            binary_lists.append(vals)
        combos = list(product(*binary_lists))
    else:
        # No active binary parameters – create one empty combo
        combos = [()]
        active_params = []

    rows = []
    for combo in combos:
        row = {}
        name_parts = []
        suffix_parts = []
        for i, p in enumerate(active_params):
            val = combo[i]
            row[p.lower()] = val
            if val:
                name_parts.append(p.lower())
            suffix_parts.append(str(val))
        name = "_".join(name_parts) if name_parts else "baseline"
        suffix = "".join(suffix_parts) if suffix_parts else ""
        row['config_name'] = f"{name}_{suffix}" if suffix else name
        rows.append(row)

    # Expand with MEM_WORDS (if any)
    if mem_words_values is not None:
        new_rows = []
        for r in rows:
            for mw in mem_words_values:
                nr = r.copy()
                nr['mem_words'] = mw
                nr['config_name'] = f"{r['config_name']}_mem{mw}"
                new_rows.append(nr)
        rows = new_rows

    # Expand with CACHE_LINES
    if cache_lines_vals is not None:
        new_rows = []
        for r in rows:
            for cl in cache_lines_vals:
                nr = r.copy()
                nr['cache_lines'] = cl
                nr['config_name'] = f"{r['config_name']}_l{cl}"
                new_rows.append(nr)
        rows = new_rows

    # Expand with CACHE_WORDS_PER_LINE
    if cache_words_vals is not None:
        new_rows = []
        for r in rows:
            for cw in cache_words_vals:
                nr = r.copy()
                nr['cache_words_per_line'] = cw
                nr['config_name'] = f"{r['config_name']}_w{cw}"
                new_rows.append(nr)
        rows = new_rows

    # Expand with cache module (string)
    final_rows = []
    for r in rows:
        for mod in cache_modules:
            nr = r.copy()
            nr['cache_module'] = mod
            mod_safe = "nocache" if mod == "none" else mod
            nr['config_name'] = f"{r['config_name']}_{mod_safe}"
            final_rows.append(nr)
    rows = final_rows

    # Write CSV – only include columns for active binary parameters
    fieldnames = ['config_name']
    fieldnames.extend([p.lower() for p in active_params])
    if mem_words_values is not None:
        fieldnames.append('mem_words')
    if cache_lines_vals is not None:
        fieldnames.append('cache_lines')
    if cache_words_vals is not None:
        fieldnames.append('cache_words_per_line')
    fieldnames.append('cache_module')
    with open('configs.csv', 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    return len(rows)

def run_ppa(continue_on_fail=False):
    """Run run_ppa_fixed.py from the project root directory."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    print("\nRunning PPA script from project root...")
    cmd = ['python3', 'picosoc/run_ppa_fixed.py']
    if continue_on_fail:
        cmd.append('--continue-on-test-fail')
    result = subprocess.run(cmd, cwd=project_root, capture_output=False)
    return result.returncode == 0

def run_analysis():
    print("\nRunning analysis script...")
    result = subprocess.run(['python3', 'analyse_ppa.py'], capture_output=False)
    return result.returncode == 0

def main():
    if not ask_overwrite_configs():
        print("Using existing configs.csv.")
        if input("\nRun PPA with existing configs.csv? (y/n): ").strip().lower() != 'y':
            print("Exiting.")
            return
        if not run_ppa():
            print("PPA failed.")
            return
        if input("\nRun analysis? (y/n): ").strip().lower() == 'y':
            run_analysis()
        return

    # Binary parameters
    print("\n=== Configure binary parameters ===")
    print("0 (fixed 0), 1 (fixed 1), v (variable), s (skip / use default)")
    binary_choices = {p: ask_binary_param(p) for p in BINARY_PARAMS}

    # MEM_WORDS
    mem_words_values = ask_mem_words()

    # Cache size parameters (lines and words per line)
    print("\n=== Configure cache size parameters ===")
    cache_lines_vals = ask_cache_param("CACHE_LINES", CACHE_PARAMS["CACHE_LINES"])
    cache_words_vals = ask_cache_param("CACHE_WORDS_PER_LINE", CACHE_PARAMS["CACHE_WORDS_PER_LINE"])

    # Cache module selection
    modules = get_cache_modules()
    cache_modules = ask_cache_module(modules)

    # Generate configs
    n_configs = generate_configs(binary_choices, mem_words_values,
                                 cache_lines_vals, cache_words_vals, cache_modules)
    print(f"\nGenerated {n_configs} configurations in configs.csv")
    confirm = input("\nProceed to run PPA for all these configurations? (y/n): ").strip().lower()
    if confirm != 'y':
        print("Exiting without running PPA.")
        return

    # Ask about test failure behaviour
    continue_on_fail_input = input("\nIf functional tests fail for a configuration, should we still run synthesis/P&R? (y/n): ").strip().lower()
    continue_on_fail = (continue_on_fail_input == 'y')

    if not run_ppa(continue_on_fail):
        print("PPA failed.")
        return

    if input("\nRun analysis? (y/n): ").strip().lower() == 'y':
        run_analysis()

    print("\nAll done.")

if __name__ == "__main__":
    main()