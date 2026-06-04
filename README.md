[![.github/workflows/ci.yml](https://github.com/YosysHQ/picorv32/actions/workflows/ci.yml/badge.svg)](https://github.com/YosysHQ/picorv32/actions/workflows/ci.yml)

Benchmark Design
================

The benchmark was designed with the following criteria in mind:

- Our cache is large: the final best-performing cache is 64 sets, 2 ways, and 16 words per line, allowing a total of 2,048 instructions. Therefore, the benchmark should highlight that our processor is performant even with a large benchmark program loop, with close to this many number of instructions, demonstrating advantages over teams who may have implemented a smaller cache.
- Our cache is associative. If possible, the benchmark should be designed to highlight how the associativity reduces conflict misses, such as in situations where the benchmark main loop jumps around in the program file instead of staying in a sequential set of instructions.
- We have data memory lookahead for memory read instructions, so the benchmark should include load instructions (such as using a lookup table).
- It would be nice to have a benchmark that does a task that could be useful in the real-world.

The final benchmark is an iteration of the initial polynomial numerical integration used for preliminary testing. It loops through integrating 19 different 2-D quadratic polynomials sequentially for each x and y coordinate in a 48x48 grid. It also adds an additional "sinusoidal" term to each polynomial based on a mock sin() lookup table, to use additional load instructions. An example of the core code for one of the 19 polynomials is below:

```
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 3*x2 + 11*y2 + 8*xy + 6*x + 32*y + 1497;
    int32_t t = (11*(int32_t)x + 7*(int32_t)y + 15) * sin_val;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
```

This benchmark is large, as intended. The main run_workload loop function is more than 400 instructions long, and the 19 polynomial calculations total to around 1300 instructions (around 69 instructions per polynomial), for a total of 1700 instructions. This is enough to fit in our 2048 instruction cache, but not fit in a smaller 1024 instruction cache. (The number of polynomials was based on testing to find the largest number that could fit in our cache without conflict misses). 

The benchmark also generates a large number of conflict misses for a non-associative cache. This is because due to the length of the polynomial function definitions at the start of the file (there are 64 polynomial definitions included on purpose, even though only 19 are used), the addresses of instructions within the functions to calculate the 4th through the 11th polynomials are made to be exactly 0x4000 = 4096 instructions apart from the main run_workload() function! Therefore, any direct-mapped cache 4096 instructions or smaller would have conflict misses even if there is still capacity in the cache. But a two-way cache would be able to keep both the polynomial instruction and run_workload instruction in its two separate ways. 

Since the benchmark uses a sine LUT (and other parts of the polynomial calculation logic uses load instructions too), more than a quarter of instructions are memory loads, allowing our data memory lookahead interface to improve CPI by around 0.26. 

The figure below shows that before the hot-loop instruction count exceeds the cache size (at around 22 polynomials), the associative cache indeed outperforms the direct-mapped cache, and this is clearly due to avoided conflict misses. Our benchmark, at 19 polynomials, is done at the "sweet-spot" - the largest instruction count supported by the associative cache before noticeable conflict misses. Interestingly, the direct mapped cache outperforms the associative cache for when the number of instructions exceeds the cache capacity. This is a little surprising but not impossible (for an example, consider 8-line direct mapped vs 4x2-way cache for instruction stream 0, 4, 8, 0, 4, 8...).

<img width="670" height="411" alt="image" src="https://github.com/user-attachments/assets/ff917e72-6a0a-40e0-af57-f2866073a92a" />

**Results**

As intended, our benchmark demonstrates the advantage of our full configuration - removing any of the three aforementioned elements (large size, associativity, data lookeahead) noticeably deteriorates performance. 

| Configuration          |     CPI | 
| -----------------------| -------:| 
| 64x2x16 Cache, Associative, Data Lookahead    |  4.7135 |  
| Same, without associativity (128x16 cache)  |  9.5077 |
| Same, without data lookahead   |  4.9738 |
| Same, but cache half the size (32x2x16) | 13.4983 |

Latest Cache + Data Memory Lookahead Buffer Benchmark Data
==========================================================

<img width="770" height="353" alt="image" src="https://github.com/user-attachments/assets/37c2ca74-cc6b-417a-adf2-5db292018b0a" />

Added a data memory lookahead buffer using the picorv32 lookahead interface
so data memory reads take 0 cycles instead of 1. Reduces 1 CPI for each lw 
instruction. Hence, e.g. in the integral benchmark 10/27 instructions in
the hot loop are lw, matching closely with 0.37 CPI savings measured in 
benchmark. 

Similar to the icache, its a transparent interface instantiated in
picosoc.v. 

More documentation coming soon... 


Compact Restoring Divider (area reduction)
==========================================

The `picorv32_pcpi_div` module (the optional `ENABLE_DIV` hardware divider) was
rewritten into a more compact restoring divider. It computes the exact same
RV32M results — `div` / `divu` / `rem` / `remu`, including div-by-zero and the
`INT_MIN / -1` overflow case — in the same ~33 cycles, but uses noticeably less
FPGA/ASIC area.

**Where the area comes from in the old version**

The stock divider held the divisor *pre-shifted left by 31 bits* in a 63-bit
register and shifted it right one place per iteration, while walking a 32-bit
one-hot mask to pick off quotient bits. Each cycle it compared and subtracted
across the full 63-bit divisor. It also kept the dividend and quotient in two
separate 32-bit registers.

```
reg [31:0] dividend;      // 32 FF
reg [62:0] divisor;       // 63 FF  (pre-shifted, shifts right each cycle)
reg [31:0] quotient;      // 32 FF
reg [31:0] quotient_msk;  // 32 FF  (one-hot iteration mask)
reg        running, outsign;          // 2 FF
                          // ≈ 159 FF, 63-bit subtract/compare datapath
```

**What the new compact version does**

Instead, the divisor stays a fixed 32-bit value and the *partial remainder is
shifted left* one bit per step, pulling in the next dividend bit from the top.
The dividend and quotient share a single 32-bit register (`dq`): the dividend
bits shift out the top as quotient bits shift in the bottom. A small 6-bit step
counter replaces the 32-bit one-hot mask.

```
reg [31:0] divisor_q;     // 32 FF  (held fixed, no shifting)
reg [32:0] rem_q;         // 33 FF  (running remainder, +1 bit for the shift)
reg [31:0] dq;            // 32 FF  (dividend out the top, quotient in the bottom)
reg [5:0]  step;          //  6 FF  (binary step counter, not a one-hot mask)
reg        running, outsign;          // 2 FF
                          // ≈ 104 FF, 33-bit subtract datapath
```

**Net effect**

| | Stock divider | Compact divider |
| --- | ---: | ---: |
| Divisor register | 63 bits (pre-shifted) | 32 bits (fixed) |
| Dividend + quotient | 2 × 32-bit registers | 1 shared 32-bit register |
| Iteration counter | 32-bit one-hot mask | 6-bit binary counter |
| Subtract / compare width | 63-bit | 33-bit |
| Total flip-flops | ≈ 159 FF | ≈ 104 FF (~35% fewer) |
| Latency | ~33 cycles | ~33 cycles (unchanged) |

The roughly 55 fewer flip-flops come mostly from dropping the 31 extra divisor
bits, merging dividend and quotient into one register, and replacing the
one-hot mask with a counter. Shrinking the subtractor from 63 to 33 bits also
cuts the combinational logic (LUTs / carry chain) on the critical datapath.

**Measured iCE40 (UP5K) area impact**

Building the full picosoc both ways — *no cache, barrel shifter on, divider on,
fast multiplier on, compressed ISA off* — gives:

| Build | `ICESTORM_LC` used | Utilization (of 5280) |
| --- | ---: | ---: |
| Stock divider  | 4754 | 90% |
| Compact divider | 4589 | 86% |

That is **165 LCs saved (~3.1% of the device)**. It is tempting to expect the
saving to match the ~55-flip-flop figure above, but on iCE40 each
`ICESTORM_LC` bundles one LUT4 *and* one flip-flop, so the LC delta also picks
up the combinational logic the FF count never captures:

| Source | What is removed | ≈ LCs |
| --- | --- | ---: |
| Merged dividend + quotient | 2 × 32-bit regs → 1 × 32-bit (`dq`) | ~32 |
| One-hot mask → counter | 32-bit `quotient_msk` shift-reg → 6-bit `step` | ~24 |
| Divisor 63 → 32 bit | drops 31 register bits + their feeder LUTs | ~31 |
| Subtract/compare 63 → 33 bit | narrower carry chain (combinational only) | ~30 |
| Misc control/mux logic freed | | remainder |

So roughly half the win is registers-with-their-feeder-LUTs and the other half
is combinational logic (mainly collapsing the 63-bit comparator/subtractor to
33 bits and removing the 32-bit one-hot shift register) — which is why the LC
saving lands near ~3× the raw flip-flop count rather than ~1×. The result is in
the expected range, if anything slightly on the better end. Going from 90% to
86% utilization on a nearly-full UP5K is exactly the headroom that helps
place-and-route close timing at the 16.5 MHz target (and leaves room for the
cache).

Caveat: synthesis numbers swing with yosys/nextpnr version, seed, and `abc`
options, so treat ±10–20 LCs as noise. For an apples-to-apples comparison,
synthesize both dividers with the same seed and `--freq`.

Note: this rewrite removed the `RISCV_FORMAL_ALTOPS` shortcut path that the
original divider carried for riscv-formal runs; functional RV32M behaviour is
unchanged.

Overclocking with the on-chip PLL
=================================

The iCEBreaker board only has a **12 MHz crystal**, but the picosoc runs faster
than that by routing the crystal through the iCE40 **`SB_PLL40_PAD`** hard PLL
before it ever reaches the SoC. The PLL multiplies the 12 MHz input up to the
target SoC clock, and that output is named `clk` — every downstream block
(reset logic, 7-segment driver, GPIO, `picosoc`) keeps using `clk` unchanged,
so the PLL is inserted *transparently* between the pad and the core. (The raw
pin must stay a separate net, `clk_in`, because `SB_PLL40_PAD` consumes the pad
and produces the fabric clock as its output.)

**How the PLL frequency is set** (`picosoc/icebreaker.v`):

```verilog
SB_PLL40_PAD #(
    .FEEDBACK_PATH("SIMPLE"),
    .DIVR(4'd0),        // DIVR = 0
    .DIVF(7'b1010111),  // DIVF = 87
    .DIVQ(3'b110),      // DIVQ = 6
    .FILTER_RANGE(3'b001)
) pll ( .PACKAGEPIN(clk_in), .PLLOUTCORE(pll_clk), .LOCK(pll_locked), ... );
```

The output frequency follows the iCE40 PLL equation:

```
F_out = F_in * (DIVF + 1) / ( 2^DIVQ * (DIVR + 1) )
      = 12 MHz * (87 + 1) / ( 2^6 * (0 + 1) )
      = 12 MHz * 88 / 64
      = 16.5 MHz          (VCO = 12 * 88 = 1056 MHz, then /64)
```

You never compute these dividers by hand — generate them with the icestorm
tool and copy the values in:

```
icepll -i 12 -o 16.5      # -i input MHz, -o desired output MHz
```

There is also an optional **/2 clock divider** gated by the
`USE_CLK_DIVIDER` parameter. When set to 1, a toggle flip-flop halves `pll_clk`
before the global buffer, so you can run the PLL at a frequency the fabric can
lock cleanly and still feed the SoC half of it. Both paths drive `clk` through
an `SB_GB` global-buffer so the clock reaches the whole fabric.

`resetn` is held until both the reset counter saturates **and** `pll_locked`
is high, so the SoC only comes out of reset once the PLL has locked.

What to update to adopt a new clock frequency
---------------------------------------------

Changing the SoC clock is not just a one-line edit — the frequency leaks into
firmware timing and into the place-and-route timing constraints. To move to a
new frequency, update **all** of these so they agree:

1. **PLL dividers** in `picosoc/icebreaker.v` — run `icepll -i 12 -o <MHz>` and
   paste the reported `DIVR` / `DIVF` / `DIVQ` (and `FILTER_RANGE`) into the
   `SB_PLL40_PAD` instance.
2. **`USE_CLK_DIVIDER`** in `picosoc/icebreaker.v` — set to `1` if you want the
   SoC to run at half the PLL output (remember to halve the effective frequency
   used in steps 3–5).
3. **`F_CPU`** in `picosoc/blink.c` — this is the *actual SoC clock in Hz*. The
   UART baud divider is derived from it (`reg_uart_clkdiv = F_CPU / BAUD`), so a
   wrong `F_CPU` gives a garbled serial console.
4. **`reg_uart_clkdiv`** in `picosoc/benchmark.c` — this firmware hard-codes the
   divider (e.g. `143` for 12 MHz). Recompute it as `round(F_CPU / BAUD)` for
   the new clock, or it will mis-baud.
5. **Timing constraints** in `picosoc/Makefile` — update the `nextpnr-ice40
   --freq <MHz>` target and the `icetime -c <MHz>` check so place-and-route
   actually optimizes for, and verifies, the new clock.
6. **Confirm timing closes** — after `make`, check the `icetime` / `nextpnr`
   report shows a max frequency **at or above** your target. If it fails, either
   back the frequency off, enable `USE_CLK_DIVIDER`, run the Makefile seed sweep
   to find a better placement, or reduce the critical path (e.g. enable caching
   / the compact divider above to shrink logic depth).

> Heads-up: a few inline comments in `icebreaker.v` and `blink.c` still quote
> older targets (28.125 / 15.9375 / 14.0625 MHz) from earlier overclock
> experiments. The values that actually take effect are the `SB_PLL40_PAD`
> dividers and the `F_CPU` macro, **not** the prose comments — trust the
> numbers above (16.5 MHz with the dividers as currently committed).

Cache Experimentation and Changes
======================================

**Preliminary Results**
 
| Integral Benchmark     |     CPI | 
| -----------------------| -------:| 
| Baseline (No Cache)    |  9.9374 |  
| 128x16 Cache           |  5.9998 |
| 64x16 with lookahead   |  5.0736 |

| Bubble Sort Benchmark  |     CPI | 
| -----------------------| -------:| 
| Baseline (No Cache)    |  10.991 |  
| 128x16 Cache           |  5.5699 |
| 64x16 with lookahead   |  4.5159 |


The file picosoc/icache.v contains the caches Kevin wrote. 
The caches go in between the cpu's memory interface and the memory interface in picosoc.v (where the cache is instantiated), preserving the shape of the interface on both sides.
There are many versions of the cache, with description/rationale. "Good" iterations are marked with (*)

The main one to be used for the final processor is icache_multiword_lookahead.

icache_zerocycle

- This is a very basic cache with no state machine, and entirely combinational (direct pass-through of memory (except when valid signal is intercepted for a cache hit, and returned ifetch data is copied into the cache). While it was useful as a development step, it has little practical use, since putting it on BRAM would require 1-cycle read but putting it on LCs means maximum cache size is too small to be practical.
- One word per line, maximum 8-16 lines on LCs only.

icache (*)

- Basic cache, now with a 1-cycle lookup delay driven by a simple 3-state FSM. Still combinational pass through except for ifetch instructions. If it's an ifetch then we wait a cycle for the BRAM access, then process hit/miss. 
- One word per line, maximum 128 lines (MUX/line select logic gets expensive fast). This is a decent amount - basic polynomial integral benchmark is around 27 lines.

icache_first_miss_bypass

- Same as icache, with a small change: cache lines are only updated upon the second miss (to make the cache "sticky"). This was intended to reduce thrashing for when the cache is too small for the hot-loop (or hot loop has some instructions that are very hot and other instructions that are called once in a while) (e.g. if the hotloop is 32 instructions and the cache is only 16 lines, we would prefer some 16 lines still stay there, instead of constant misses).
- But upon testing the benefit was not high enough to justify the larger LC cost.

icache_random_bypass

- Same idea as first_miss_bypass but we only update cache instructions with a certain probability (e.g. 25% or 50%) every miss. This is intended so that occasional instructions are less likely to be in the cache for a long time and hot instructions can stay in cache more. Also was intended so performance deterioration isn't as sudden.
- Upon testing this was rather ineffective.

icache_multiword (*)

- Based on icache, but a significant architectural change to allow multiple words per line
- This is a valuable change because currently we're limited by maximum number of lines (~128) due to muxing logic, storing tag/valid, etc, but the BRAM still had space (128x1 used 8/30).
- On miss, fill the whole line (multiple words) - so there's a trade-off between cache size (words per line) and # of potentially unnecessary reads
- Has a 4-state FSM for IDLE, LOOKUP (check if hit or miss), FILL, RESP, and an internal counter to keep track of which line is being filled
- Approx largest size that fits is 128x16 (2,048 instructions) - that's massive.

icache_multiword_first_miss_bypass

- Same rationale as icache_first_miss_bypass applied to icache_multiword
- This was ineffective. Costs a lot of extra logic, and when there are multiple words per line and it misses once, it was probably going to miss again anyway.

icache_multiword_lookahead (*)

- The current best cache design
- Same as icache_multiword, but uses the CPU lookahead interface to allow the cache to find the cached data early, so now when the actual ifetch comes we can respond to hits with zero-cycle delay again! Saves close to 1CPI on benchmarks compared to regular multiword cache (but may need smaller cache to fit in additional logic).
- Lookahead also removes the need for the 1-cycle delay LOOKUP state so we only need 3-state FSM
- Largest working size 64x16


Unit Testbenches (I-cache & Compact Divider)
============================================

Two **self-checking** Icarus Verilog testbenches verify the blocks we added.
Both compare the DUT against a golden reference model on directed + randomized
stimulus and print `ALL TESTS PASSED` (and `$finish` with a non-zero error
count on failure), so they drop straight into a regression flow.

Tooling note: these use `iverilog`/`vvp` from the bundled `oss-cad-suite`. If
they are not already on your `PATH`:

```
export PATH="$PWD/../oss-cad-suite/bin:$PATH"   # from picorv32/, adjust as needed
```

I-cache testbench — `picosoc/icache_tb.v`
-----------------------------------------

Exercises the two shipping caches (`icache_multiword_lookahead` and
`icache_multiword_lookahead_2way`) at the port interface. Highlights:

- **Behavioral memory model** with a runtime-adjustable fill latency; every
  suite runs at latency **1 and 3** to stress the fill FSM.
- **Replicates the picorv32 look-ahead protocol** — the look-ahead address is
  presented one cycle *before* the real request, which is exactly what lets the
  cache flop the synchronous block-RAM read into `la_cached_*` in time for a
  single-cycle hit.
- **Golden reference model** mirroring the RTL tag/index/valid state, and for
  the 2-way cache the `lru_array` / `replace_way_next` logic. Each fetch is
  checked two ways: returned data must equal `mem[addr>>2]`, and hit/miss must
  match the model (so any divergence in *which* way is filled surfaces as a
  later hit/miss mismatch).
- **Tests:** cold-fill + re-hit, sequential walk, conflict (direct-mapped
  thrash vs 2-way coexistence), 2-way LRU eviction, passthrough/no-pollution,
  and 2000 randomized fetches per pass.

The TB is parameterized at `LINES=8, WORDS_PER_LINE=4` (small, to force
evictions quickly); bump the params to exercise the production `128x16` / `64x16`
geometries.

Run it:

```
cd picosoc
make icache_test     # builds tb_dm + tb_2way, runs both
```

Divider testbench — `div_tb.v`
------------------------------

Drives `picorv32_pcpi_div` over the PCPI handshake and checks every result
against an exact RV32M golden model — `div`/`divu`/`rem`/`remu`, including
divide-by-zero and the `INT_MIN / -1` overflow case — with directed vectors
(both sign combinations, edge cases) plus **4000 randomized** operations.

Run it (from the `picorv32/` directory):

```
make div_test
```

Results
-------

All checks pass for both blocks (Icarus Verilog 14.0, oss-cad-suite):

| Testbench            | Coverage                                   | Result |
| -------------------- | ------------------------------------------ | ------ |
| `div_tb` (divider)   | 4054 ops (directed + 4000 random)          | **PASS** |
| `icache_tb` direct-mapped | directed + 2000 random × 2 latencies  | **PASS** |
| `icache_tb` 2-way LRU     | directed + 2000 random × 2 latencies  | **PASS** |

#### Capacity vs. associativity (a note on a fair comparison)

`make icache_test` also runs a 2000-fetch random stream and reports the hit
rate. It is tempting to read the direct-mapped vs 2-way numbers as "associativity
helps," but **`LINES` means different things for the two modules**: for the 2-way
cache it is the number of sets *per way*, so the same `LINES` gives the 2-way
cache **twice the total capacity**. The testbench therefore runs three configs —
direct-mapped, 2-way at equal `LINES` (2× capacity), and 2-way at equal capacity
(half the `LINES`):

| Config (same random stream, latency 1) | Capacity | Hits / 2000 | Hit rate |
| --------------------------------------- | -------- | ----------: | -------: |
| direct-mapped, `LINES=8`                | 32 words | 246         | 12.3%    |
| 2-way, `LINES=8` (equal `LINES`)        | 64 words | 479         | 23.9%    |
| 2-way, `LINES=4` (equal capacity)       | 32 words | 237         | 11.8%    |

Two takeaways:

1. The headline ~2× hit rate at equal `LINES` is a **capacity** effect (twice the
   storage), *not* associativity.
2. At **equal capacity**, on a *uniformly random* address stream the two are
   essentially tied (12.3% vs 11.8%) — associativity only pays off when there is
   conflict-miss *structure* to remove (hot lines that collide on the same
   index), which a structureless random stream does not contain.

So this unit testbench validates **functional correctness** (data + hit/miss vs a
golden model, including the 2-way LRU) and **capacity scaling** — it is not the
right vehicle to measure the associativity benefit. That benefit is demonstrated
on a real benchmark with the cache deliberately undersized (~half the
instruction hot-loop): there the 2-way cache cuts conflict misses and measures
**~14% lower CPI** than direct-mapped at the same capacity.

PicoRV32 - A Size-Optimized RISC-V CPU
======================================

PicoRV32 is a CPU core that implements the [RISC-V RV32IMC Instruction Set](http://riscv.org/).
It can be configured as RV32E, RV32I, RV32IC, RV32IM, or RV32IMC core, and optionally
contains a built-in interrupt controller.

Tools (gcc, binutils, etc..) can be obtained via the [RISC-V Website](https://riscv.org/software-status/).
The examples bundled with PicoRV32 expect various RV32 toolchains to be installed in `/opt/riscv32i[m][c]`. See
the [build instructions below](#building-a-pure-rv32i-toolchain) for details.
Many Linux distributions now include the tools for RISC-V (for example
Ubuntu 20.04 has `gcc-riscv64-unknown-elf`). To compile using those set
`TOOLCHAIN_PREFIX` accordingly (eg. `make TOOLCHAIN_PREFIX=riscv64-unknown-elf-`).

PicoRV32 is free and open hardware licensed under the [ISC license](http://en.wikipedia.org/wiki/ISC_license)
(a license that is similar in terms to the MIT license or the 2-clause BSD license).

#### Table of Contents

- [Features and Typical Applications](#features-and-typical-applications)
- [Files in this Repository](#files-in-this-repository)
- [Verilog Module Parameters](#verilog-module-parameters)
- [Cycles per Instruction Performance](#cycles-per-instruction-performance)
- [PicoRV32 Native Memory Interface](#picorv32-native-memory-interface)
- [Pico Co-Processor Interface (PCPI)](#pico-co-processor-interface-pcpi)
- [Custom Instructions for IRQ Handling](#custom-instructions-for-irq-handling)
- [Building a pure RV32I Toolchain](#building-a-pure-rv32i-toolchain)
- [Linking binaries with newlib for PicoRV32](#linking-binaries-with-newlib-for-picorv32)
- [Evaluation: Timing and Utilization on Xilinx 7-Series FPGAs](#evaluation-timing-and-utilization-on-xilinx-7-series-fpgas)


Features and Typical Applications
---------------------------------

- Small (750-2000 LUTs in 7-Series Xilinx Architecture)
- High f<sub>max</sub> (250-450 MHz on 7-Series Xilinx FPGAs)
- Selectable native memory interface or AXI4-Lite master
- Optional IRQ support (using a simple custom ISA)
- Optional Co-Processor Interface

This CPU is meant to be used as auxiliary processor in FPGA designs and ASICs. Due
to its high f<sub>max</sub> it can be integrated in most existing designs without crossing
clock domains. When operated on a lower frequency, it will have a lot of timing
slack and thus can be added to a design without compromising timing closure.

For even smaller size it is possible disable support for registers `x16`..`x31` as
well as `RDCYCLE[H]`, `RDTIME[H]`, and `RDINSTRET[H]` instructions, turning the
processor into an RV32E core.

Furthermore it is possible to choose between a dual-port and a single-port
register file implementation. The former provides better performance while
the latter results in a smaller core.

*Note: In architectures that implement the register file in dedicated memory
resources, such as many FPGAs, disabling the 16 upper registers and/or
disabling the dual-port register file may not further reduce the core size.*

The core exists in three variations: `picorv32`, `picorv32_axi` and `picorv32_wb`.
The first provides a simple native memory interface, that is easy to use in simple
environments. `picorv32_axi` provides an AXI-4 Lite Master interface that can
easily be integrated with existing systems that are already using the AXI
standard. `picorv32_wb` provides a Wishbone master interface.

A separate core `picorv32_axi_adapter` is provided to bridge between the native
memory interface and AXI4. This core can be used to create custom cores that
include one or more PicoRV32 cores together with local RAM, ROM, and
memory-mapped peripherals, communicating with each other using the native
interface, and communicating with the outside world via AXI4.

The optional IRQ feature can be used to react to events from the outside, implement
fault handlers, or catch instructions from a larger ISA and emulate them in
software.

The optional Pico Co-Processor Interface (PCPI) can be used to implement
non-branching instructions in an external coprocessor. Implementations
of PCPI cores that implement the M Standard Extension instructions
`MUL[H[SU|U]]` and `DIV[U]/REM[U]` are included in this package.


Files in this Repository
------------------------

#### README.md

You are reading it right now.

#### picorv32.v

This Verilog file contains the following Verilog modules:

| Module                   | Description                                                           |
| ------------------------ | --------------------------------------------------------------------- |
| `picorv32`               | The PicoRV32 CPU                                                      |
| `picorv32_axi`           | The version of the CPU with AXI4-Lite interface                       |
| `picorv32_axi_adapter`   | Adapter from PicoRV32 Memory Interface to AXI4-Lite                   |
| `picorv32_wb`            | The version of the CPU with Wishbone Master interface                 |
| `picorv32_pcpi_mul`      | A PCPI core that implements the `MUL[H[SU\|U]]` instructions          |
| `picorv32_pcpi_fast_mul` | A version of `picorv32_pcpi_fast_mul` using a single cycle multiplier |
| `picorv32_pcpi_div`      | A PCPI core that implements the `DIV[U]/REM[U]` instructions          |

Simply copy this file into your project.

#### Makefile and testbenches

A basic test environment. Run `make test` to run the standard test bench (`testbench.v`)
in the standard configurations. There are other test benches and configurations. See
the `test_*` make target in the Makefile for details.

Run `make test_ez` to run `testbench_ez.v`, a very simple test bench that does
not require an external firmware .hex file. This can be useful in environments
where the RISC-V compiler toolchain is not available.

*Note: The test bench is using Icarus Verilog. However, Icarus Verilog 0.9.7
(the latest release at the time of writing) has a few bugs that prevent the
test bench from running. Upgrade to the latest github master of Icarus Verilog
to run the test bench.*

#### firmware/

A simple test firmware. This runs the basic tests from `tests/`, some C code, tests IRQ
handling and the multiply PCPI core.

All the code in `firmware/` is in the public domain. Simply copy whatever you can use.

#### tests/

Simple instruction-level tests from [riscv-tests](https://github.com/riscv/riscv-tests).

#### dhrystone/

Another simple test firmware that runs the Dhrystone benchmark.

#### picosoc/

A simple example SoC using PicoRV32 that can execute code directly from a
memory mapped SPI flash.

#### scripts/

Various scripts and examples for different (synthesis) tools and hardware architectures.


Verilog Module Parameters
-------------------------

The following Verilog module parameters can be used to configure the PicoRV32
core.

#### ENABLE_COUNTERS (default = 1)

This parameter enables support for the `RDCYCLE[H]`, `RDTIME[H]`, and
`RDINSTRET[H]` instructions. This instructions will cause a hardware
trap (like any other unsupported instruction) if `ENABLE_COUNTERS` is set to zero.

*Note: Strictly speaking the `RDCYCLE[H]`, `RDTIME[H]`, and `RDINSTRET[H]`
instructions are not optional for an RV32I core. But chances are they are not
going to be missed after the application code has been debugged and profiled.
This instructions are optional for an RV32E core.*

#### ENABLE_COUNTERS64 (default = 1)

This parameter enables support for the `RDCYCLEH`, `RDTIMEH`, and `RDINSTRETH`
instructions. If this parameter is set to 0, and `ENABLE_COUNTERS` is set to 1,
then only the `RDCYCLE`, `RDTIME`, and `RDINSTRET` instructions are available.

#### ENABLE_REGS_16_31 (default = 1)

This parameter enables support for registers the `x16`..`x31`. The RV32E ISA
excludes this registers. However, the RV32E ISA spec requires a hardware trap
for when code tries to access this registers. This is not implemented in PicoRV32.

#### ENABLE_REGS_DUALPORT (default = 1)

The register file can be implemented with two or one read ports. A dual ported
register file improves performance a bit, but can also increase the size of
the core.

#### LATCHED_MEM_RDATA (default = 0)

Set this to 1 if the `mem_rdata` is kept stable by the external circuit after a
transaction. In the default configuration the PicoRV32 core only expects the
`mem_rdata` input to be valid in the cycle with `mem_valid && mem_ready` and
latches the value internally.

This parameter is only available for the `picorv32` core. In the
`picorv32_axi` and `picorv32_wb` core this is implicitly set to 0.

#### TWO_STAGE_SHIFT (default = 1)

By default shift operations are performed in two stages: first shifts in units
of 4 bits and then shifts in units of 1 bit. This speeds up shift operations,
but adds additional hardware. Set this parameter to 0 to disable the two-stage
shift to further reduce the size of the core.

#### BARREL_SHIFTER (default = 0)

By default shift operations are performed by successively shifting by a
small amount (see `TWO_STAGE_SHIFT` above). With this option set, a barrel
shifter is used instead.

#### TWO_CYCLE_COMPARE (default = 0)

This relaxes the longest data path a bit by adding an additional FF stage
at the cost of adding an additional clock cycle delay to the conditional
branch instructions.

*Note: Enabling this parameter will be most effective when retiming (aka
"register balancing") is enabled in the synthesis flow.*

#### TWO_CYCLE_ALU (default = 0)

This adds an additional FF stage in the ALU data path, improving timing
at the cost of an additional clock cycle for all instructions that use
the ALU.

*Note: Enabling this parameter will be most effective when retiming (aka
"register balancing") is enabled in the synthesis flow.*

#### COMPRESSED_ISA (default = 0)

This enables support for the RISC-V Compressed Instruction Set.

#### CATCH_MISALIGN (default = 1)

Set this to 0 to disable the circuitry for catching misaligned memory
accesses.

#### CATCH_ILLINSN (default = 1)

Set this to 0 to disable the circuitry for catching illegal instructions.

The core will still trap on `EBREAK` instructions with this option
set to 0. With IRQs enabled, an `EBREAK` normally triggers an IRQ 1. With
this option set to 0, an `EBREAK` will trap the processor without
triggering an interrupt.

#### ENABLE_PCPI (default = 0)

Set this to 1 to enable the _external_ Pico Co-Processor Interface (PCPI).
The external interface is not required for the internal PCPI cores, such as
`picorv32_pcpi_mul`.

#### ENABLE_MUL (default = 0)

This parameter internally enables PCPI and instantiates the `picorv32_pcpi_mul`
core that implements the `MUL[H[SU|U]]` instructions. The external PCPI
interface only becomes functional when ENABLE_PCPI is set as well.

#### ENABLE_FAST_MUL (default = 0)

This parameter internally enables PCPI and instantiates the `picorv32_pcpi_fast_mul`
core that implements the `MUL[H[SU|U]]` instructions. The external PCPI
interface only becomes functional when ENABLE_PCPI is set as well.

If both ENABLE_MUL and ENABLE_FAST_MUL are set then the ENABLE_MUL setting
will be ignored and the fast multiplier core will be instantiated.

#### ENABLE_DIV (default = 0)

This parameter internally enables PCPI and instantiates the `picorv32_pcpi_div`
core that implements the `DIV[U]/REM[U]` instructions. The external PCPI
interface only becomes functional when ENABLE_PCPI is set as well.

#### ENABLE_IRQ (default = 0)

Set this to 1 to enable IRQs. (see "Custom Instructions for IRQ Handling" below
for a discussion of IRQs)

#### ENABLE_IRQ_QREGS (default = 1)

Set this to 0 to disable support for the `getq` and `setq` instructions. Without
the q-registers, the irq return address will be stored in x3 (gp) and the IRQ
bitmask in x4 (tp), the global pointer and thread pointer registers according
to the RISC-V ABI.  Code generated from ordinary C code will not interact with
those registers.

Support for q-registers is always disabled when ENABLE_IRQ is set to 0.

#### ENABLE_IRQ_TIMER (default = 1)

Set this to 0 to disable support for the `timer` instruction.

Support for the timer is always disabled when ENABLE_IRQ is set to 0.

#### ENABLE_TRACE (default = 0)

Produce an execution trace using the `trace_valid` and `trace_data` output ports.
For a demonstration of this feature run `make test_vcd` to create a trace file
and then run `python3 showtrace.py testbench.trace firmware/firmware.elf` to decode
it.

#### REGS_INIT_ZERO (default = 0)

Set this to 1 to initialize all registers to zero (using a Verilog `initial` block).
This can be useful for simulation or formal verification.

#### MASKED_IRQ (default = 32'h 0000_0000)

A 1 bit in this bitmask corresponds to a permanently disabled IRQ.

#### LATCHED_IRQ (default = 32'h ffff_ffff)

A 1 bit in this bitmask indicates that the corresponding IRQ is "latched", i.e.
when the IRQ line is high for only one cycle, the interrupt will be marked as
pending and stay pending until the interrupt handler is called (aka "pulse
interrupts" or "edge-triggered interrupts").

Set a bit in this bitmask to 0 to convert an interrupt line to operate
as "level sensitive" interrupt.

#### PROGADDR_RESET (default = 32'h 0000_0000)

The start address of the program.

#### PROGADDR_IRQ (default = 32'h 0000_0010)

The start address of the interrupt handler.

#### STACKADDR (default = 32'h ffff_ffff)

When this parameter has a value different from 0xffffffff, then register `x2` (the
stack pointer) is initialized to this value on reset. (All other registers remain
uninitialized.) Note that the RISC-V calling convention requires the stack pointer
to be aligned on 16 bytes boundaries (4 bytes for the RV32I soft float calling
convention).


Cycles per Instruction Performance
----------------------------------

*A short reminder: This core is optimized for size and f<sub>max</sub>, not performance.*

Unless stated otherwise, the following numbers apply to a PicoRV32 with
ENABLE_REGS_DUALPORT active and connected to a memory that can accommodate
requests within one clock cycle.

The average Cycles per Instruction (CPI) is approximately 4, depending on the mix of
instructions in the code. The CPI numbers for the individual instructions can
be found in the table below. The column "CPI (SP)" contains the CPI numbers for
a core built without ENABLE_REGS_DUALPORT.

| Instruction          |  CPI | CPI (SP) |
| ---------------------| ----:| --------:|
| direct jump (jal)    |    3 |        3 |
| ALU reg + immediate  |    3 |        3 |
| ALU reg + reg        |    3 |        4 |
| branch (not taken)   |    3 |        4 |
| memory load          |    5 |        5 |
| memory store         |    5 |        6 |
| branch (taken)       |    5 |        6 |
| indirect jump (jalr) |    6 |        6 |
| shift operations     | 4-14 |     4-15 |

When `ENABLE_MUL` is activated, then a `MUL` instruction will execute
in 40 cycles and a `MULH[SU|U]` instruction will execute in 72 cycles.

When `ENABLE_DIV` is activated, then a `DIV[U]/REM[U]` instruction will
execute in 40 cycles.

When `BARREL_SHIFTER` is activated, a shift operation takes as long as
any other ALU operation.

The following dhrystone benchmark results are for a core with enabled
`ENABLE_FAST_MUL`, `ENABLE_DIV`, and `BARREL_SHIFTER` options.

Dhrystone benchmark results: 0.516 DMIPS/MHz (908 Dhrystones/Second/MHz)

For the Dhrystone benchmark the average CPI is 4.100.

Without using the look-ahead memory interface (usually required for max
clock speed), this results drop to 0.305 DMIPS/MHz and 5.232 CPI.


PicoRV32 Native Memory Interface
--------------------------------

The native memory interface of PicoRV32 is a simple valid-ready interface
that can run one memory transfer at a time:

    output        mem_valid
    output        mem_instr
    input         mem_ready

    output [31:0] mem_addr
    output [31:0] mem_wdata
    output [ 3:0] mem_wstrb
    input  [31:0] mem_rdata

The core initiates a memory transfer by asserting `mem_valid`. The valid
signal stays high until the peer asserts `mem_ready`. All core outputs
are stable over the `mem_valid` period. If the memory transfer is an
instruction fetch, the core asserts `mem_instr`.

#### Read Transfer

In a read transfer `mem_wstrb` has the value 0 and `mem_wdata` is unused.

The memory reads the address `mem_addr` and makes the read value available on
`mem_rdata` in the cycle `mem_ready` is high.

There is no need for an external wait cycle. The memory read can be implemented
asynchronously with `mem_ready` going high in the same cycle as `mem_valid`, or
`mem_ready` being tied to constant 1.

#### Write Transfer

In a write transfer `mem_wstrb` is not 0 and `mem_rdata` is unused. The memory
write the data at `mem_wdata` to the address `mem_addr` and acknowledges the
transfer by asserting `mem_ready`.

The 4 bits of `mem_wstrb` are write enables for the four bytes in the addressed
word. Only the 8 values `0000`, `1111`, `1100`, `0011`, `1000`, `0100`, `0010`,
and `0001` are possible, i.e. no write, write 32 bits, write upper 16 bits,
write lower 16, or write a single byte respectively.

There is no need for an external wait cycle. The memory can acknowledge the
write immediately  with `mem_ready` going high in the same cycle as
`mem_valid`, or `mem_ready` being tied to constant 1.

#### Look-Ahead Interface

The PicoRV32 core also provides a "Look-Ahead Memory Interface" that provides
all information about the next memory transfer one clock cycle earlier than the
normal interface.

    output        mem_la_read
    output        mem_la_write
    output [31:0] mem_la_addr
    output [31:0] mem_la_wdata
    output [ 3:0] mem_la_wstrb

In the clock cycle before `mem_valid` goes high, this interface will output a
pulse on `mem_la_read` or `mem_la_write` to indicate the start of a read or
write transaction in the next clock cycle.

*Note: The signals `mem_la_read`, `mem_la_write`, and `mem_la_addr` are driven
by combinatorial circuits within the PicoRV32 core. It might be harder to
achieve timing closure with the look-ahead interface than with the normal
memory interface described above.*


Pico Co-Processor Interface (PCPI)
----------------------------------

The Pico Co-Processor Interface (PCPI) can be used to implement non-branching
instructions in external cores:

    output        pcpi_valid
    output [31:0] pcpi_insn
    output [31:0] pcpi_rs1
    output [31:0] pcpi_rs2
    input         pcpi_wr
    input  [31:0] pcpi_rd
    input         pcpi_wait
    input         pcpi_ready

When an unsupported instruction is encountered and the PCPI feature is
activated (see ENABLE_PCPI above), then `pcpi_valid` is asserted, the
instruction word itself is output on `pcpi_insn`, the `rs1` and `rs2`
fields are decoded and the values in those registers are output
on `pcpi_rs1` and `pcpi_rs2`.

An external PCPI core can then decode the instruction, execute it, and assert
`pcpi_ready` when execution of the instruction is finished. Optionally a
result value can be written to `pcpi_rd` and `pcpi_wr` asserted. The
PicoRV32 core will then decode the `rd` field of the instruction and
write the value from `pcpi_rd` to the respective register.

When no external PCPI core acknowledges the instruction within 16 clock
cycles, then an illegal instruction exception is raised and the respective
interrupt handler is called. A PCPI core that needs more than a couple of
cycles to execute an instruction, should assert `pcpi_wait` as soon as
the instruction has been decoded successfully and keep it asserted until
it asserts `pcpi_ready`. This will prevent the PicoRV32 core from raising
an illegal instruction exception.


Custom Instructions for IRQ Handling
------------------------------------

*Note: The IRQ handling features in PicoRV32 do not follow the RISC-V
Privileged ISA specification. Instead a small set of very simple custom
instructions is used to implement IRQ handling with minimal hardware
overhead.*

The following custom instructions are only supported when IRQs are enabled
via the `ENABLE_IRQ` parameter (see above).

The PicoRV32 core has a built-in interrupt controller with 32 interrupt inputs. An
interrupt can be triggered by asserting the corresponding bit in the `irq`
input of the core.

When the interrupt handler is started, the `eoi` End Of Interrupt (EOI) signals
for the handled interrupts go high. The `eoi` signals go low again when the
interrupt handler returns.

The IRQs 0-2 can be triggered internally by the following built-in interrupt sources:

| IRQ | Interrupt Source                    |
| ---:| ------------------------------------|
|   0 | Timer Interrupt                     |
|   1 | EBREAK/ECALL or Illegal Instruction |
|   2 | BUS Error (Unalign Memory Access)   |

This interrupts can also be triggered by external sources, such as co-processors
connected via PCPI.

The core has 4 additional 32-bit registers `q0 .. q3` that are used for IRQ
handling. When the IRQ handler is called, the register `q0` contains the return
address and `q1` contains a bitmask of all IRQs to be handled. This means one
call to the interrupt handler needs to service more than one IRQ when more than
one bit is set in `q1`.

When support for compressed instructions is enabled, then the LSB of q0 is set
when the interrupted instruction is a compressed instruction. This can be used if
the IRQ handler wants to decode the interrupted instruction.

Registers `q2` and `q3` are uninitialized and can be used as temporary storage
when saving/restoring register values in the IRQ handler.

All of the following instructions are encoded under the `custom0` opcode. The f3
and rs2 fields are ignored in all this instructions.

See [firmware/custom_ops.S](firmware/custom_ops.S) for GNU assembler macros that
implement mnemonics for this instructions.

See [firmware/start.S](firmware/start.S) for an example implementation of an
interrupt handler assembler wrapper, and [firmware/irq.c](firmware/irq.c) for
the actual interrupt handler.

#### getq rd, qs

This instruction copies the value from a q-register to a general-purpose
register.

    0000000 ----- 000XX --- XXXXX 0001011
    f7      rs2   qs    f3  rd    opcode

Example:

    getq x5, q2

#### setq qd, rs

This instruction copies the value from a general-purpose register to a
q-register.

    0000001 ----- XXXXX --- 000XX 0001011
    f7      rs2   rs    f3  qd    opcode

Example:

    setq q2, x5

#### retirq

Return from interrupt. This instruction copies the value from `q0`
to the program counter and re-enables interrupts.

    0000010 ----- 00000 --- 00000 0001011
    f7      rs2   rs    f3  rd    opcode

Example:

    retirq

#### maskirq

The "IRQ Mask" register contains a bitmask of masked (disabled) interrupts.
This instruction writes a new value to the irq mask register and reads the old
value.

    0000011 ----- XXXXX --- XXXXX 0001011
    f7      rs2   rs    f3  rd    opcode

Example:

    maskirq x1, x2

The processor starts with all interrupts disabled.

An illegal instruction or bus error while the illegal instruction or bus error
interrupt is disabled will cause the processor to halt.

#### waitirq

Pause execution until an interrupt becomes pending. The bitmask of pending IRQs
is written to `rd`.

    0000100 ----- 00000 --- XXXXX 0001011
    f7      rs2   rs    f3  rd    opcode

Example:

    waitirq x1

#### timer

Reset the timer counter to a new value. The counter counts down clock cycles and
triggers the timer interrupt when transitioning from 1 to 0. Setting the
counter to zero disables the timer. The old value of the counter is written to
`rd`.

    0000101 ----- XXXXX --- XXXXX 0001011
    f7      rs2   rs    f3  rd    opcode

Example:

    timer x1, x2


Building a pure RV32I Toolchain
-------------------------------

TL;DR: Run the following commands to build the complete toolchain:

    make download-tools
    make -j$(nproc) build-tools

The default settings in the [riscv-tools](https://github.com/riscv/riscv-tools) build
scripts will build a compiler, assembler and linker that can target any RISC-V ISA,
but the libraries are built for RV32G and RV64G targets. Follow the instructions
below to build a complete toolchain (including libraries) that target a pure RV32I
CPU.

The following commands will build the RISC-V GNU toolchain and libraries for a
pure RV32I target, and install it in `/opt/riscv32i`:

    # Ubuntu packages needed:
    sudo apt-get install autoconf automake autotools-dev curl libmpc-dev \
            libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo \
	    gperf libtool patchutils bc zlib1g-dev git libexpat1-dev

    sudo mkdir /opt/riscv32i
    sudo chown $USER /opt/riscv32i

    git clone https://github.com/riscv/riscv-gnu-toolchain riscv-gnu-toolchain-rv32i
    cd riscv-gnu-toolchain-rv32i
    git checkout 411d134
    git submodule update --init --recursive

    mkdir build; cd build
    ../configure --with-arch=rv32i --prefix=/opt/riscv32i
    make -j$(nproc)

The commands will all be named using the prefix `riscv32-unknown-elf-`, which
makes it easy to install them side-by-side with the regular riscv-tools (those
are using the name prefix `riscv64-unknown-elf-` by default).

Alternatively you can simply use one of the following make targets from PicoRV32's
Makefile to build a `RV32I[M][C]` toolchain. You still need to install all
prerequisites, as described above. Then run any of the following commands in the
PicoRV32 source directory:

| Command                                  | Install Directory  | ISA       |
|:---------------------------------------- |:------------------ |:--------  |
| `make -j$(nproc) build-riscv32i-tools`   | `/opt/riscv32i/`   | `RV32I`   |
| `make -j$(nproc) build-riscv32ic-tools`  | `/opt/riscv32ic/`  | `RV32IC`  |
| `make -j$(nproc) build-riscv32im-tools`  | `/opt/riscv32im/`  | `RV32IM`  |
| `make -j$(nproc) build-riscv32imc-tools` | `/opt/riscv32imc/` | `RV32IMC` |

Or simply run `make -j$(nproc) build-tools` to build and install all four tool chains.

By default calling any of those make targets will (re-)download the toolchain
sources. Run `make download-tools` to download the sources to `/var/cache/distfiles/`
once in advance.

*Note: These instructions are for git rev 411d134 (2018-02-14) of riscv-gnu-toolchain.*


Linking binaries with newlib for PicoRV32
-----------------------------------------

The tool chains (see last section for install instructions) come with a version of
the newlib C standard library.

Use the linker script [firmware/riscv.ld](firmware/riscv.ld) for linking binaries
against the newlib library. Using this linker script will create a binary that
has its entry point at 0x10000. (The default linker script does not have a static
entry point, thus a proper ELF loader would be needed that can determine the
entry point at runtime while loading the program.)

Newlib comes with a few syscall stubs. You need to provide your own implementation
of those syscalls and link your program with this implementation, overwriting the
default stubs from newlib. See `syscalls.c` in [scripts/cxxdemo/](scripts/cxxdemo/)
for an example of how to do that.


Evaluation: Timing and Utilization on Xilinx 7-Series FPGAs
-----------------------------------------------------------

The following evaluations have been performed with Vivado 2017.3.

#### Timing on Xilinx 7-Series FPGAs

The `picorv32_axi` module with enabled `TWO_CYCLE_ALU` has been placed and
routed for Xilinx Artix-7T, Kintex-7T, Virtex-7T, Kintex UltraScale, and Virtex
UltraScale devices in all speed grades. A binary search is used to find the
shortest clock period for which the design meets timing.

See `make table.txt` in [scripts/vivado/](scripts/vivado/).

| Device                    | Device               | Speedgrade | Clock Period (Freq.) |
|:------------------------- |:---------------------|:----------:| --------------------:|
| Xilinx Kintex-7T          | xc7k70t-fbg676-2     | -2         |     2.4 ns (416 MHz) |
| Xilinx Kintex-7T          | xc7k70t-fbg676-3     | -3         |     2.2 ns (454 MHz) |
| Xilinx Virtex-7T          | xc7v585t-ffg1761-2   | -2         |     2.3 ns (434 MHz) |
| Xilinx Virtex-7T          | xc7v585t-ffg1761-3   | -3         |     2.2 ns (454 MHz) |
| Xilinx Kintex UltraScale  | xcku035-fbva676-2-e  | -2         |     2.0 ns (500 MHz) |
| Xilinx Kintex UltraScale  | xcku035-fbva676-3-e  | -3         |     1.8 ns (555 MHz) |
| Xilinx Virtex UltraScale  | xcvu065-ffvc1517-2-e | -2         |     2.1 ns (476 MHz) |
| Xilinx Virtex UltraScale  | xcvu065-ffvc1517-3-e | -3         |     2.0 ns (500 MHz) |
| Xilinx Kintex UltraScale+ | xcku3p-ffva676-2-e   | -2         |     1.4 ns (714 MHz) |
| Xilinx Kintex UltraScale+ | xcku3p-ffva676-3-e   | -3         |     1.3 ns (769 MHz) |
| Xilinx Virtex UltraScale+ | xcvu3p-ffvc1517-2-e  | -2         |     1.5 ns (666 MHz) |
| Xilinx Virtex UltraScale+ | xcvu3p-ffvc1517-3-e  | -3         |     1.4 ns (714 MHz) |

#### Utilization on Xilinx 7-Series FPGAs

The following table lists the resource utilization in area-optimized synthesis
for the following three cores:

- **PicoRV32 (small):** The `picorv32` module without counter instructions,
  without two-stage shifts, with externally latched `mem_rdata`, and without
  catching of misaligned memory accesses and illegal instructions.

- **PicoRV32 (regular):** The `picorv32` module in its default configuration.

- **PicoRV32 (large):** The `picorv32` module with enabled PCPI, IRQ, MUL,
  DIV, BARREL_SHIFTER, and COMPRESSED_ISA features.

See `make area` in [scripts/vivado/](scripts/vivado/).

| Core Variant       | Slice LUTs | LUTs as Memory | Slice Registers |
|:------------------ | ----------:| --------------:| ---------------:|
| PicoRV32 (small)   |        761 |             48 |             442 |
| PicoRV32 (regular) |        917 |             48 |             583 |
| PicoRV32 (large)   |       2019 |             88 |            1085 |
