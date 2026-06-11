[![.github/workflows/ci.yml](https://github.com/YosysHQ/picorv32/actions/workflows/ci.yml/badge.svg)](https://github.com/YosysHQ/picorv32/actions/workflows/ci.yml)

Fast PicoRV32 - GB3 Project (Group 5)
=====================================

Andrew Choi, Emma Davis, and Kevin Liu

## Documentation and Results

The documentation folder in our submission contains files detailing things we worked on and changes we made to the processor, how to run the PPA scripts, and as well as data and results. 

## Files Created and Modified

Our submission includes the entire codebase in the source folder to allow easy reproduction of our processor design. 

The following files of the processor's source code were created/modified to implement our changes:

- `picosoc/icache.v`: contains the instruction cache design used in the final processor
- `picosoc/icache_design_iterations.v`: contains older iterations of the instruction cache
- `picosoc/dmem_lookahead_buffer.v`: contains the data memory lookahead module
- `picosoc/picosoc.v`: modified to instantiate the instruction cache and data memory lookahead module
- `picosoc/spimemio.v`: for Quad-SPI DDR flash mode as a hardware default
- `picosoc/icebreaker.v`: routes the 12 MHz crystal through the `SB_PLL40_PAD` PLL to overclock the SoC to 27.75 MHz, with an optional `/2` divider fall-back
- `picorv32.v`: rewrote the `picorv32_pcpi_div` hardware divider into a compact restoring design (about 165 fewer logic cells, same RV32M results) to win back area for the cache

The following files were created to verify our design:

- `picosoc/icache_tb.v`: self-checking testbench for both the direct-mapped and two-way look-ahead caches, with a golden tag/valid/LRU model and a fair equal-capacity hit-rate comparison
- `picosoc/dmem_lookahead_buffer_tb.v`: simulation testbench for the data memory lookahead module
- `div_tb.v`: self-checking testbench for `picorv32_pcpi_div`, comparing against an RV32M golden model over directed and 4000 random operations

The following files were created/modified as part of our workflow:

- `picosoc/Makefile`
- `picosoc/group5_benchmark.c`: secret benchmark for competition
- `picosoc/interactive_ppa.py`, `picosoc/run_ppa_fixed.py`, `picosoc/run_hardware_bench.py`, `run_all.sh`: automation scripts for configuration sweep, PPA, and hardware benchmarking (see the two PPA-related PDFs in the documentation folder)

