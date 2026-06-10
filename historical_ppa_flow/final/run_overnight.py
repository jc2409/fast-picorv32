#!/usr/bin/env python3
import os, sys, csv, time, re, subprocess, serial, serial.tools.list_ports

SERIAL_DEV = "/dev/ttyUSB1"   # change to /dev/ttyUSB0 if needed
BAUD = 115200
BUILD_ROOT = "build_fixed"
CONFIG_CSV = "configs.csv"
RESULT_CSV = "hardware_results_overnight.csv"

BENCHMARKS = {
    "group5": "group5.bin",
    "bubble": "bubble.bin",
    "integral": "integral.bin"
}

def find_serial():
    for port in serial.tools.list_ports.comports():
        if port.vid == 0x0403 and port.pid == 0x6010:
            return port.device
    return None

def capture(bitstream, firmware, dev):
    # Program bitstream and firmware
    subprocess.run(f"iceprog {bitstream}", shell=True, capture_output=True)
    subprocess.run(f"iceprog -o 1M {firmware}", shell=True, capture_output=True)

    # Open serial
    ser = serial.Serial(dev, BAUD, timeout=1)
    time.sleep(3)
    ser.write(b'\r')
    time.sleep(1)
    ser.reset_input_buffer()

    # Read for up to 10 seconds
    output = b""
    start = time.time()
    while time.time() - start < 10:
        if ser.in_waiting:
            output += ser.read(ser.in_waiting)
            text = output.decode(errors='ignore')
            if "CYCLES=0x" in text and "INSTNS=0x" in text:
                cycles = re.search(r'CYCLES=0x([0-9a-fA-F]+)', text).group(1)
                instns = re.search(r'INSTNS=0x([0-9a-fA-F]+)', text).group(1)
                ser.close()
                return int(cycles, 16), int(instns, 16)
        time.sleep(0.05)
    ser.close()
    return None, None

def main():
    dev = SERIAL_DEV if os.path.exists(SERIAL_DEV) else find_serial()
    if not dev:
        print("No serial device found.")
        return
    print(f"Using {dev}")

    with open(CONFIG_CSV) as f:
        configs = list(csv.DictReader(f))

    if not os.path.exists(RESULT_CSV):
        with open(RESULT_CSV, 'w', newline='') as f:
            csv.writer(f).writerow(['config_name', 'benchmark', 'cycles', 'instns', 'cpi'])

    for row in configs:
        name = row['config_name']
        build_dir = os.path.join(BUILD_ROOT, name)
        bitstream = os.path.join(build_dir, "design.bin")
        if not os.path.exists(bitstream):
            print(f"Skipping {name}: no design.bin")
            continue
        print(f"\n=== {name} ===")
        for bench, fname in BENCHMARKS.items():
            firmware = os.path.join(build_dir, fname)
            if not os.path.exists(firmware):
                print(f"  {bench}: missing {fname}")
                continue
            print(f"  {bench}...", end=' ', flush=True)
            cycles, instns = capture(bitstream, firmware, dev)
            if cycles is not None:
                cpi = cycles / instns
                print(f"cycles={cycles}, instns={instns}, CPI={cpi:.4f}")
                with open(RESULT_CSV, 'a', newline='') as f:
                    csv.writer(f).writerow([name, bench, cycles, instns, cpi])
            else:
                print("FAILED")

if __name__ == "__main__":
    main()
