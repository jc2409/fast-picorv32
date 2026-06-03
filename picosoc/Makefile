CROSS=riscv32-unknown-elf- #default
#CROSS=/opt/homebrew/opt/riscv-gnu-toolchain/bin/riscv64-unknown-elf- 
CFLAGS=

# ---- iCE40 HX8K Breakout Board ----

hx8ksim: hx8kdemo_tb.vvp hx8kdemo_fw.hex
	vvp -N $< +firmware=hx8kdemo_fw.hex

hx8ksynsim: hx8kdemo_syn_tb.vvp hx8kdemo_fw.hex
	vvp -N $< +firmware=hx8kdemo_fw.hex

hx8kdemo.json: hx8kdemo.v spimemio.v simpleuart.v picosoc.v ../picorv32.v
	yosys -ql hx8kdemo.log -p 'synth_ice40 -top hx8kdemo -json hx8kdemo.json' $^

hx8kdemo_tb.vvp: hx8kdemo_tb.v hx8kdemo.v spimemio.v simpleuart.v picosoc.v ../picorv32.v spiflash.v
	iverilog -g2012 -DNO_ICE40_DEFAULT_ASSIGNMENTS -s testbench -o $@ $^ `yosys-config --datdir`/ice40/cells_sim.v

hx8kdemo_syn_tb.vvp: hx8kdemo_tb.v hx8kdemo_syn.v spiflash.v
	iverilog -g2012 -DNO_ICE40_DEFAULT_ASSIGNMENTS -s testbench -o $@ $^ `yosys-config --datdir`/ice40/cells_sim.v

hx8kdemo_syn.v: hx8kdemo.json
	yosys -p 'read_json hx8kdemo.json; write_verilog hx8kdemo_syn.v'

hx8kdemo.asc: hx8kdemo.pcf hx8kdemo.json
	nextpnr-ice40 --hx8k --package ct256 --asc hx8kdemo.asc --json hx8kdemo.json --pcf hx8kdemo.pcf

hx8kdemo.bin: hx8kdemo.asc
	icetime -d hx8k -c 12 -mtr hx8kdemo.rpt hx8kdemo.asc
	icepack hx8kdemo.asc hx8kdemo.bin

hx8kprog: hx8kdemo.bin hx8kdemo_fw.bin
	iceprog hx8kdemo.bin
	iceprog -o 1M hx8kdemo_fw.bin

hx8kprog_fw: hx8kdemo_fw.bin
	iceprog -o 1M hx8kdemo_fw.bin

hx8kdemo_sections.lds: sections.lds
	$(CROSS)cpp -P -DHX8KDEMO -o $@ $^

hx8kdemo_fw.elf: hx8kdemo_sections.lds start.s firmware.c
	$(CROSS)gcc $(CFLAGS) -DHX8KDEMO -mabi=ilp32 -march=rv32im -Wl,--build-id=none,-Bstatic,-T,hx8kdemo_sections.lds,--strip-debug -ffreestanding -nostdlib -o hx8kdemo_fw.elf start.s firmware.c

hx8kdemo_fw.hex: hx8kdemo_fw.elf
	$(CROSS)objcopy -O verilog hx8kdemo_fw.elf hx8kdemo_fw.hex

hx8kdemo_fw.bin: hx8kdemo_fw.elf
	$(CROSS)objcopy -O binary hx8kdemo_fw.elf hx8kdemo_fw.bin

# ---- iCE40 IceBreaker Board ----

icebsim: icebreaker_tb.vvp icebreaker_fw.hex
	vvp -N $< +firmware=icebreaker_fw.hex

icebsynsim: icebreaker_syn_tb.vvp icebreaker_fw.hex
	vvp -N $< +firmware=icebreaker_fw.hex

icebreaker.json: icebreaker.v ice40up5k_spram.v spimemio.v simpleuart.v icache.v dmem_lookahead_buffer.v picosoc.v ../picorv32.v
	yosys -ql icebreaker.log -p 'synth_ice40 -dsp -top icebreaker -json icebreaker.json' $^

icebreaker_tb.vvp: icebreaker_tb.v icebreaker.v ice40up5k_spram.v spimemio.v simpleuart.v icache.v dmem_lookahead_buffer.v picosoc.v ../picorv32.v spiflash.v
	iverilog -g2012 -DNO_ICE40_DEFAULT_ASSIGNMENTS -s testbench -o $@ $^ `yosys-config --datdir`/ice40/cells_sim.v

icebreaker_syn_tb.vvp: icebreaker_tb.v icebreaker_syn.v spiflash.v
	iverilog -g2012 -DSYNTH_SIM -DNO_ICE40_DEFAULT_ASSIGNMENTS -s testbench -o $@ $^ `yosys-config --datdir`/ice40/cells_sim.v

icebreaker_syn.v: icebreaker.json
	yosys -p 'read_json icebreaker.json; write_verilog icebreaker_syn.v'

icebreaker.asc: icebreaker.pcf icebreaker.json
	nextpnr-ice40 --freq 16 --seed 46 --up5k --package sg48 --asc icebreaker.asc --pcf icebreaker.pcf --json icebreaker.json

icebreaker.bin: icebreaker.asc
	icetime -d up5k -c 16 -mtr icebreaker.rpt icebreaker.asc
	icepack icebreaker.asc icebreaker.bin

# Try many nextpnr seeds and report the best icetime result

icebreaker_seed_sweep: icebreaker.pcf icebreaker.json

	@rm -rf seed_sweep
	@mkdir -p seed_sweep
	@best_seed=0; best_freq=0; \
	for seed in $$(seq 1 100); do \
		echo "Trying seed $$seed..."; \
		nextpnr-ice40 --freq 16 --seed $$seed --up5k --package sg48 \
			--asc seed_sweep/icebreaker_seed_$$seed.asc \
			--pcf icebreaker.pcf \
			--json icebreaker.json \
			> seed_sweep/nextpnr_seed_$$seed.log 2>&1; \
		freq=$$(icetime -d up5k -mtr seed_sweep/icebreaker_seed_$$seed.rpt \
			seed_sweep/icebreaker_seed_$$seed.asc 2>&1 \
			| tee seed_sweep/icetime_seed_$$seed.log \
			| grep "Timing estimate" \
			| sed -E 's/.*\(([0-9.]+) MHz\).*/\1/'); \
		echo "Seed $$seed: $$freq MHz"; \
		if awk "BEGIN {exit !($$freq > $$best_freq)}"; then \
			best_freq=$$freq; \
			best_seed=$$seed; \
			cp seed_sweep/icebreaker_seed_$$seed.asc seed_sweep/best.asc; \
			cp seed_sweep/icebreaker_seed_$$seed.rpt seed_sweep/best.rpt; \
		fi; \
	done; \
	echo ""; \
	echo "Best seed: $$best_seed"; \
	echo "Best frequency: $$best_freq MHz"; \
	echo "Best ASC: seed_sweep/best.asc"; \
	echo "Best RPT: seed_sweep/best.rpt"

icebprog: icebreaker.bin icebreaker_fw.bin
	iceprog icebreaker.bin
	iceprog -o 1M icebreaker_fw.bin

icebreaker_benchmark.elf: icebreaker_sections.lds start.s benchmark.c
	$(CROSS)gcc $(CFLAGS) -DICEBREAKER -mabi=ilp32 -march=rv32im -Wl,-Bstatic,-T,icebreaker_sections.lds,--strip-debug -ffreestanding -nostdlib -o $@ start.s benchmark.c

icebreaker_benchmark.bin: icebreaker_benchmark.elf
	$(CROSS)objcopy -O binary $< $@

icebprog_benchmark: icebreaker.bin icebreaker_benchmark.bin
	iceprog icebreaker.bin
	iceprog -o 1M icebreaker_benchmark.bin

icebprog_benchmark_only: icebreaker_benchmark.bin
	iceprog -o 1M icebreaker_benchmark.bin

icebreaker_blink.elf: icebreaker_sections.lds start.s blink.c
	$(CROSS)gcc $(CFLAGS) -DICEBREAKER -mabi=ilp32 -march=rv32im -Wl,-Bstatic,-T,icebreaker_sections.lds,--strip-debug -ffreestanding -nostdlib -o $@ start.s blink.c

icebreaker_blink.bin: icebreaker_blink.elf
	$(CROSS)objcopy -O binary $< $@

icebprog_blink: icebreaker.bin icebreaker_blink.bin
	iceprog icebreaker.bin
	iceprog -o 1M icebreaker_blink.bin

icebprog_fw: icebreaker_fw.bin
	iceprog -o 1M icebreaker_fw.bin

icebreaker_sections.lds: sections.lds
	$(CROSS)cpp -P -DICEBREAKER -o $@ $^

icebreaker_fw.elf: icebreaker_sections.lds start.s firmware.c
	$(CROSS)gcc $(CFLAGS) -DICEBREAKER -mabi=ilp32 -march=rv32im -Wl,-Bstatic,-T,icebreaker_sections.lds,--strip-debug -ffreestanding -nostdlib -o icebreaker_fw.elf start.s firmware.c

icebreaker_fw.hex: icebreaker_fw.elf
	$(CROSS)objcopy -O verilog icebreaker_fw.elf icebreaker_fw.hex

icebreaker_fw.bin: icebreaker_fw.elf
	$(CROSS)objcopy -O binary icebreaker_fw.elf icebreaker_fw.bin

# ---- Testbench for SPI Flash Model ----

spiflash_tb: spiflash_tb.vvp icebreaker_fw.hex
	vvp -N $< +firmware=icebreaker_fw.hex

spiflash_tb.vvp: spiflash.v spiflash_tb.v
	iverilog -s testbench -o $@ $^

# ---- ASIC Synthesis Tests ----

cmos.log: spimemio.v simpleuart.v picosoc.v ../picorv32.v
	yosys -l cmos.log -p 'synth -top picosoc; abc -g cmos2; opt -fast; stat' $^

# ---- I-cache unit testbench (self-checking) ----
# tb_dm   drives icache_multiword_lookahead       (direct-mapped)
# tb_2way drives icache_multiword_lookahead_2way  (2-way, LRU)
# `make icache_test` runs both; each prints "ALL TESTS PASSED" on success.

icache_tb_dm.vvp: icache_tb.v icache.v
	iverilog -g2012 -o $@ -s tb_dm $^

icache_tb_2way.vvp: icache_tb.v icache.v
	iverilog -g2012 -o $@ -s tb_2way $^

icache_test: icache_tb_dm.vvp icache_tb_2way.vvp
	vvp -N icache_tb_dm.vvp
	vvp -N icache_tb_2way.vvp

# ---- Clean ----

clean:
	rm -f icache_tb_dm.vvp icache_tb_2way.vvp icache_tb.vcd
	rm -f testbench.vvp testbench.vcd spiflash_tb.vvp spiflash_tb.vcd
	rm -f hx8kdemo_fw.elf hx8kdemo_fw.hex hx8kdemo_fw.bin cmos.log
	rm -f icebreaker_fw.elf icebreaker_fw.hex icebreaker_fw.bin
	rm -f hx8kdemo.json hx8kdemo.log hx8kdemo.asc hx8kdemo.rpt hx8kdemo.bin
	rm -f hx8kdemo_syn.v hx8kdemo_syn_tb.vvp hx8kdemo_tb.vvp
	rm -f icebreaker.json icebreaker.log icebreaker.asc icebreaker.rpt icebreaker.bin
	rm -f icebreaker_syn.v icebreaker_syn_tb.vvp icebreaker_tb.vvp
	rm -f icebreaker_blink.elf icebreaker_blink.bin icebreaker_benchmark.elf icebreaker_benchmark.bin 

.PHONY: spiflash_tb clean icache_test
.PHONY: hx8kprog hx8kprog_fw hx8ksim hx8ksynsim
.PHONY: icebprog icebprog_fw icebsim icebsynsim
.PHONY: icebreaker_seed_sweep