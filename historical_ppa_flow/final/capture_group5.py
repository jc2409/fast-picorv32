#!/usr/bin/env python3
"""
Capture cycles and instructions for group5 benchmark (single configuration).
Assumes build directory exists. Uses raw serial reading.
"""

import serial
import subprocess
import time
import re
import sys

# Configuration (edit these paths as needed)
CONFIG_NAME = "enable_mul_enable_div_enable_counters_01110_freq2775_l64_w16_icache_multiword_lookahead_2way"
BUILD_DIR = f"/home/ed667/final/picosoc/build_fixed/{CONFIG_NAME}"
BITSTREAM = f"{BUILD_DIR}/design.bin"
FIRMWARE = f"{BUILD_DIR}/group5.bin"
SERIAL_DEV = "/dev/ttyUSB1"   # try /dev/ttyUSB0 if fails
BAUD = 115200
TIMEOUT = 30

def try_serial(dev):
    try:
        ser = serial.Serial(dev, BAUD, timeout=1)
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        return ser
    except:
        return None

def main():
    # Try both serial ports
    ser = try_serial(SERIAL_DEV)
    if not ser:
        ser = try_serial("/dev/ttyUSB0")
    if not ser:
        print("ERROR: Could not open serial port.")
        return

    # Program bitstream and firmware
    print("Programming bitstream...")
    subprocess.run(f"iceprog {BITSTREAM}", shell=True, check=True)
    print("Programming firmware...")
    subprocess.run(f"iceprog -o 1M {FIRMWARE}", shell=True, check=True)

    # Wait for board to boot
    time.sleep(3)
    ser.write(b'\r')
    time.sleep(1)
    ser.reset_input_buffer()

    # Read raw data
    output = bytearray()
    start = time.time()
    while time.time() - start < TIMEOUT:
        if ser.in_waiting:
            chunk = ser.read(ser.in_waiting)
            output.extend(chunk)
            text = output.decode(errors='ignore')
            # Look for CYCLES and INSTNS
            cycles_match = re.search(r'CYCLES=0x([0-9a-fA-F]+)', text)
            instns_match = re.search(r'INSTNS=0x([0-9a-fA-F]+)', text)
            if cycles_match and instns_match:
                cycles_hex = "0x" + cycles_match.group(1)
                instns_hex = "0x" + instns_match.group(1)
                cycles = int(cycles_hex, 16)
                instns = int(instns_hex, 16)
                cpi = cycles / instns if instns else 0
                print(f"\nSuccess!")
                print(f"Cycles: {cycles_hex} ({cycles})")
                print(f"Instructions: {instns_hex} ({instns})")
                print(f"CPI: {cpi:.4f}")
                ser.close()
                return
        else:
            time.sleep(0.05)
    print("Timeout: No data received.")
    ser.close()

if __name__ == "__main__":
    main()
