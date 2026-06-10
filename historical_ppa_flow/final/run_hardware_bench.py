#!/usr/bin/env python3
"""
Hardware benchmark with fixed CSV columns.
"""
import os, sys, csv, time, argparse, subprocess
import serial
import serial.tools.list_ports

SERIAL_DEV = "/dev/ttyUSB1"
BAUD = 115200
TIMEOUT = 15
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
BUILD_ROOT = os.path.join(PROJECT_DIR, "build_fixed")
CONFIG_CSV = os.path.join(PROJECT_DIR, "configs.csv")
RESULT_CSV = os.path.join(PROJECT_DIR, "hardware_results.csv")

# ---- Fixed column names ----
HW_COLUMNS = [
    "config_name", "barrel_shifter", "enable_mul", "enable_div", "enable_counters",
    "enable_compressed", "actual_freq_mhz", "cache_lines", "cache_words_per_line",
    "cache_module", "cycles", "instns", "cpi"
]

def run_cmd(cmd, cwd=None):
    subprocess.run(cmd, shell=True, cwd=cwd, check=True)

def find_serial_device():
    for port in serial.tools.list_ports.comports():
        if port.vid == 0x0403 and port.pid == 0x6010:
            return port.device
    return None

def read_until_cycles(ser, timeout=TIMEOUT):
    output = ""
    start = time.time()
    while time.time() - start < timeout:
        if ser.in_waiting:
            line = ser.readline().decode(errors='ignore').strip()
            if line:
                print(f"    {line}")
                output += line + "\n"
            if "CYCLES=0x" in output and "INSTNS=0x" in output:
                return output
        else:
            time.sleep(0.1)
    return None

def program_and_capture(bitstream, firmware, serial_dev):
    try:
        ser = serial.Serial(serial_dev, BAUD, timeout=2)
        time.sleep(0.5)
        ser.reset_input_buffer()
    except Exception as e:
        print(f"  Error opening serial: {e}")
        return None
    run_cmd(f"iceprog {bitstream}")
    run_cmd(f"iceprog -o 1M {firmware}")
    time.sleep(8)
    ser.write(b'\r')
    output = read_until_cycles(ser)
    ser.close()
    return output

def parse_cycles_instns(output):
    cycles = instns = None
    for line in output.splitlines():
        if line.startswith("CYCLES=0x"):
            cycles = int(line[9:], 16)
        elif line.startswith("INSTNS=0x"):
            instns = int(line[9:], 16)
    return cycles, instns

def process_single_config(name, serial_dev):
    build_dir = os.path.join(BUILD_ROOT, name)
    bitstream = os.path.join(build_dir, "design.bin")
    firmware = os.path.join(build_dir, "benchmark.bin")
    if not os.path.exists(bitstream) or not os.path.exists(firmware):
        print(f"Skipping {name}: missing design.bin or benchmark.bin")
        return None
    print(f"\n=== Running hardware benchmark for {name} ===")
    output = program_and_capture(bitstream, firmware, serial_dev)
    if output:
        cycles, instns = parse_cycles_instns(output)
        if cycles is not None and instns is not None:
            cpi = cycles / instns if instns else 0
            print(f"  Cycles: {cycles}, Instns: {instns}, CPI: {cpi:.4f}")
            return {'cycles': cycles, 'instns': instns, 'cpi': cpi}
        else:
            print("  Failed to parse cycles/instns")
    else:
        print("  Timeout waiting for serial data")
    return None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', help='Run only this configuration name')
    parser.add_argument('--serial', help='Serial device', default=SERIAL_DEV)
    args = parser.parse_args()
    dev = args.serial
    if not os.path.exists(dev):
        dev = find_serial_device()
        if not dev:
            print("ERROR: Could not find iCEBreaker serial port.")
            return
        print(f"Auto-detected serial device: {dev}")
    else:
        print(f"Using serial device: {dev}")
    if not os.path.exists(CONFIG_CSV):
        print(f"ERROR: {CONFIG_CSV} not found.")
        return
    with open(CONFIG_CSV, 'r') as f:
        configs = list(csv.DictReader(f))
    if args.config:
        configs = [c for c in configs if c['config_name'] == args.config]
        if not configs:
            print(f"Config '{args.config}' not found.")
            return

    results = []
    for row in configs:
        name = row['config_name']
        data = process_single_config(name, dev)
        if data:
            # Build a row with all fixed columns, filling defaults
            out_row = {
                "config_name": name,
                "barrel_shifter": row.get("barrel_shifter", 0),
                "enable_mul": row.get("enable_mul", 0),
                "enable_div": row.get("enable_div", 0),
                "enable_counters": row.get("enable_counters", 0),
                "enable_compressed": row.get("enable_compressed", 0),
                "actual_freq_mhz": row.get("actual_freq_mhz", 27.75),
                "cache_lines": row.get("cache_lines", 0),
                "cache_words_per_line": row.get("cache_words_per_line", 0),
                "cache_module": row.get("cache_module", "none"),
                "cycles": data['cycles'],
                "instns": data['instns'],
                "cpi": data['cpi'],
            }
            results.append(out_row)

    if results:
        mode = 'a' if args.config and os.path.exists(RESULT_CSV) else 'w'
        with open(RESULT_CSV, mode, newline='') as f:
            writer = csv.DictWriter(f, fieldnames=HW_COLUMNS)
            if mode == 'w':
                writer.writeheader()
            writer.writerows(results)
        print(f"\nResults saved to {RESULT_CSV}")
    else:
        print("No successful hardware runs.")

if __name__ == "__main__":
    main()
