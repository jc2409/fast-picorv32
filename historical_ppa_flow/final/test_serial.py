import serial, time, subprocess, sys

dev = "/dev/ttyUSB1"
baud = 115200

# Program the board
subprocess.run(f"iceprog build_fixed/enable_mul_enable_div_enable_counters_01110_freq2775_l64_w16_icache_multiword_lookahead_2way/design.bin", shell=True)
subprocess.run(f"iceprog -o 1M build_fixed/enable_mul_enable_div_enable_counters_01110_freq2775_l64_w16_icache_multiword_lookahead_2way/group5.bin", shell=True)

# Open serial and read for 60 seconds
ser = serial.Serial(dev, baud, timeout=1)
time.sleep(2)
ser.write(b'\r')
start = time.time()
while time.time() - start < 60:
    if ser.in_waiting:
        data = ser.read(ser.in_waiting)
        sys.stdout.buffer.write(data)
        sys.stdout.flush()
    time.sleep(0.1)
ser.close()
