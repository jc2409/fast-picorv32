#include <stdint.h>
#include <stdbool.h>

#ifdef ICEBREAKER
#  define MEM_TOTAL 0x20000 /* 128 KB */
#elif HX8KDEMO
#  define MEM_TOTAL 0x200 /* 2 KB */
#else
#  error "Set -DICEBREAKER or -DHX8KDEMO when compiling firmware.c"
#endif

// System clock after the PLL and CLK_Divider (icepll -i 12 -o 28 and divided by 2).
#define F_CPU 14062500
#define BAUD  115200

// a pointer to this is a null pointer, but the compiler does not
// know that because "sram" is a linker symbol from sections.lds.
extern uint32_t sram;

#define reg_spictrl (*(volatile uint32_t*)0x02000000)
#define reg_uart_clkdiv (*(volatile uint32_t*)0x02000004)
#define reg_uart_data (*(volatile uint32_t*)0x02000008)
#define reg_leds (*(volatile uint8_t*)0x03000000)
#define reg_7seg (*(volatile uint8_t*)0x03000001)

// --------------------------------------------------------

extern uint32_t flashio_worker_begin;
extern uint32_t flashio_worker_end;

void flashio(uint8_t *data, int len, uint8_t wrencmd)
{
	uint32_t func[&flashio_worker_end - &flashio_worker_begin];

	uint32_t *src_ptr = &flashio_worker_begin;
	uint32_t *dst_ptr = func;

	while (src_ptr != &flashio_worker_end)
		*(dst_ptr++) = *(src_ptr++);

	((void(*)(uint8_t*, uint32_t, uint32_t))func)(data, len, wrencmd);
}

#ifdef ICEBREAKER
void set_flash_qspi_flag()
{
	uint8_t buffer[8];

	// Read Configuration Registers (RDCR1 35h)
	buffer[0] = 0x35;
	buffer[1] = 0x00; // rdata
	flashio(buffer, 2, 0);
	uint8_t sr2 = buffer[1];

	// Write Enable Volatile (50h) + Write Status Register 2 (31h)
	buffer[0] = 0x31;
	buffer[1] = sr2 | 2; // Enable QSPI
	flashio(buffer, 2, 0x50);
}

void set_flash_mode_spi()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00000000;
}

void set_flash_mode_dual()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00400000;
}

void set_flash_mode_quad()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00240000;
}

void set_flash_mode_qddr()
{
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00670000;
}

void enable_flash_crm()
{
	reg_spictrl |= 0x00100000;
}
#endif

// --------------------------------------------------------
// Minimal UART output. A write to reg_uart_data stalls the CPU (via the
// bus wait line) until the transmitter is free, so no busy-wait is needed.

void putchar(char c)
{
	if (c == '\n')
		putchar('\r');
	reg_uart_data = c;
}

void print(const char *p)
{
	while (*p)
		putchar(*(p++));
}

void print_dec(uint32_t v)
{
	char buf[10];
	int n = 0;
	if (v == 0) {
		putchar('0');
		return;
	}
	while (v) {
		buf[n++] = '0' + (v % 10);
		v /= 10;
	}
	while (n)
		putchar(buf[--n]);
}

// --------------------------------------------------------
// Performance measurement: N (instructions), CPI, T.
//
// picorv32 is built with ENABLE_COUNTERS, so rdinstret gives N and rdcycle
// gives elapsed cycles directly -- no hand counting. Reads bracket the
// region as tightly as possible; an LED is toggled just outside the counted
// region so a PicoScope on that pin should read ~ cycles * T.

static inline uint32_t rd_cycle(void)
{
	uint32_t v;
	__asm__ volatile ("rdcycle %0" : "=r"(v));
	return v;
}

static inline uint32_t rd_instret(void)
{
	uint32_t v;
	__asm__ volatile ("rdinstret %0" : "=r"(v));
	return v;
}

#define BENCH_ITERS 10000

void run_benchmark(void)
{
	uint32_t c0, c1, n0, n1;

	// --- 1. Measure the fixed overhead of the counter reads themselves
	//        (empty region) so it can be subtracted from the real result.
	n0 = rd_instret();
	c0 = rd_cycle();
	c1 = rd_cycle();
	n1 = rd_instret();
	uint32_t ov_cycles = c1 - c0;
	uint32_t ov_instr  = n1 - n0;

	// --- 2. Measure the code under test: the blink delay loop.
	//        `volatile i` guarantees the loop is never optimised away,
	//        so N stays meaningful at any -O level.
	reg_leds = 0x02;            // led1 HIGH: scope marker (outside the counted region)

	n0 = rd_instret();
	c0 = rd_cycle();
	for (volatile int i = 0; i < BENCH_ITERS; i++)
		;
	c1 = rd_cycle();
	n1 = rd_instret();

	reg_leds = 0x00;            // scope marker LOW

	// Net figures with the read overhead removed.
	uint32_t N      = (n1 - n0) - ov_instr;
	uint32_t cycles = (c1 - c0) - ov_cycles;

	uint32_t cpi = cycles / N;

	// Execution time. T = 1/F_CPU; total time = cycles * T.
	// T_ps is a compile-time constant (folds, no libgcc). For the runtime
	// product we keep everything in 32-bit: -nostdlib has no __udivdi3, so a
	// 64-bit divide on a variable won't link. time_ns = cycles * 62.745,
	// split as cycles*62745/1000 without overflowing 32 bits.
	uint32_t T_ps    = (uint32_t)(1000000000000ull / F_CPU);   // 62745 ps = 62.745 ns
	uint32_t time_ns = (cycles / 1000u) * T_ps + ((cycles % 1000u) * T_ps) / 1000u;

	print("\n--- performance: blink delay loop ---\n");
	print("iterations  = "); print_dec(BENCH_ITERS); print("\n");
	print("N (instret) = "); print_dec(N);           print("\n");
	print("cycles      = "); print_dec(cycles);      print("\n");
	print("CPI         = "); print_dec(cpi);         print("\n");
	print("T (ps)      = "); print_dec(T_ps);        print("\n");
	print("time (ns)   = "); print_dec(time_ns);     print("   (= N * CPI * T = cycles * T)\n");
	print("read overhead: cycles="); print_dec(ov_cycles);
	print(" instr=");                print_dec(ov_instr); print("\n");
	print("-------------------------------------\n");
}

// --------------------------------------------------------

void setup_picosoc(void){
	reg_uart_clkdiv = F_CPU / BAUD; // 138 at 15.9375 MHz -> 115200 baud
	reg_7seg = 0x05;                // represents GB3 2026
	reg_leds = 0x00;
	set_flash_qspi_flag();
}

#define DELAY_K 10326

void main()
{
	setup_picosoc();

	print("\nGB3 RISC-V @ 15.9375 MHz\n");
	run_benchmark();

	while (1){
		for (int i = 0; i < DELAY_K; i++);
		reg_leds = 0x02;

		for (int i = 0; i < DELAY_K; i++);
		reg_leds = 0x00;
	}
}
