#include <stdint.h>
#include <stdbool.h>

#ifdef ICEBREAKER
#  define MEM_TOTAL 0x20000 /* 128 KB */
#else
#  error "Set -DICEBREAKER when compiling this C source file"
#endif

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

void flashio(uint8_t *data, int len, uint8_t wrencmd) {
	uint32_t func[&flashio_worker_end - &flashio_worker_begin];

	uint32_t *src_ptr = &flashio_worker_begin;
	uint32_t *dst_ptr = func;

	while (src_ptr != &flashio_worker_end)
		*(dst_ptr++) = *(src_ptr++);

	((void(*)(uint8_t*, uint32_t, uint32_t))func)(data, len, wrencmd);
}

#ifdef ICEBREAKER
void set_flash_qspi_flag() {
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

void set_flash_mode_spi() {
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00000000;
}

void set_flash_mode_dual() {
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00400000;
}

void set_flash_mode_quad() {
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00240000;
}

void set_flash_mode_qddr() {
	reg_spictrl = (reg_spictrl & ~0x007f0000) | 0x00670000;
}

void enable_flash_crm() {
	reg_spictrl |= 0x00100000;
}

void *memcpy(void *aa, const void *bb, long n) {
	char *a = aa;
	const char *b = bb;
	while (n--) *(a++) = *(b++);
	return aa;
}
#endif

// --------------------------------------------------------
// Utilities for UART

void putchar(char c){
	if (c == '\n')
		putchar('\r');
	reg_uart_data = c;
}

void print(const char *p){
	while (*p)
		putchar(*(p++));
}

void print_hex(uint32_t v, int digits){
	for (int i = 7; i >= 0; i--) {
		char c = "0123456789abcdef"[(v >> (4*i)) & 15];
		if (c == '0' && i >= digits) continue;
		putchar(c);
		digits = i;
	}
}

void print_dec(uint32_t v){ // works up to 999 only
	if (v >= 1000) {
		print(">=1000");
		return;
	}

	if      (v >= 900) { putchar('9'); v -= 900; }
	else if (v >= 800) { putchar('8'); v -= 800; }
	else if (v >= 700) { putchar('7'); v -= 700; }
	else if (v >= 600) { putchar('6'); v -= 600; }
	else if (v >= 500) { putchar('5'); v -= 500; }
	else if (v >= 400) { putchar('4'); v -= 400; }
	else if (v >= 300) { putchar('3'); v -= 300; }
	else if (v >= 200) { putchar('2'); v -= 200; }
	else if (v >= 100) { putchar('1'); v -= 100; }

	if      (v >= 90) { putchar('9'); v -= 90; }
	else if (v >= 80) { putchar('8'); v -= 80; }
	else if (v >= 70) { putchar('7'); v -= 70; }
	else if (v >= 60) { putchar('6'); v -= 60; }
	else if (v >= 50) { putchar('5'); v -= 50; }
	else if (v >= 40) { putchar('4'); v -= 40; }
	else if (v >= 30) { putchar('3'); v -= 30; }
	else if (v >= 20) { putchar('2'); v -= 20; }
	else if (v >= 10) { putchar('1'); v -= 10; }
	else putchar('0');

	if      (v >= 9) { putchar('9'); v -= 9; }
	else if (v >= 8) { putchar('8'); v -= 8; }
	else if (v >= 7) { putchar('7'); v -= 7; }
	else if (v >= 6) { putchar('6'); v -= 6; }
	else if (v >= 5) { putchar('5'); v -= 5; }
	else if (v >= 4) { putchar('4'); v -= 4; }
	else if (v >= 3) { putchar('3'); v -= 3; }
	else if (v >= 2) { putchar('2'); v -= 2; }
	else if (v >= 1) { putchar('1'); v -= 1; }
	else putchar('0');
}

void setup_picosoc(void){
	reg_uart_clkdiv = 163; //163; // Baud ~= 115200 for 12 MHz
	reg_7seg = 0x02;       // represents Demo 02
	reg_leds = 0x00;
	set_flash_qspi_flag();
	set_flash_mode_qddr(); // fastest SPI flash
}

// --------------------------------------------------------
// Cache-footprint polynomial/sine surface benchmark
//
// Workload:
//   sum over x,y of many small polynomial kernels.
//   Some polynomial terms are multiplied by values from a sine LUT.
//
// Justification:
//   The hot instruction footprint is deliberately large to fill our large cache
//   (which is largest clean power of 2 cache that will fit on the BRAM)
//   We use sine_lut for a lot of lw instructions (take advantage of
//   dmem lookahead)
//   This particular combination also has set-associative cache
//   beating direct-mapped cache by a lot.

#define NX 48
#define NY 48

static const int8_t sine_lut[256] = {
       0,    3,    6,    9,   12,   16,   19,   22,   25,   28,   31,   34,   37,   40,   43,   46,
      49,   51,   54,   57,   60,   63,   65,   68,   71,   73,   76,   78,   81,   83,   85,   88,
      90,   92,   94,   96,   98,  100,  102,  104,  106,  107,  109,  111,  112,  113,  115,  116,
     117,  118,  120,  121,  122,  122,  123,  124,  125,  125,  126,  126,  126,  127,  127,  127,
     127,  127,  127,  127,  126,  126,  126,  125,  125,  124,  123,  122,  122,  121,  120,  118,
     117,  116,  115,  113,  112,  111,  109,  107,  106,  104,  102,  100,   98,   96,   94,   92,
      90,   88,   85,   83,   81,   78,   76,   73,   71,   68,   65,   63,   60,   57,   54,   51,
      49,   46,   43,   40,   37,   34,   31,   28,   25,   22,   19,   16,   12,    9,    6,    3,
       0,   -3,   -6,   -9,  -12,  -16,  -19,  -22,  -25,  -28,  -31,  -34,  -37,  -40,  -43,  -46,
     -49,  -51,  -54,  -57,  -60,  -63,  -65,  -68,  -71,  -73,  -76,  -78,  -81,  -83,  -85,  -88,
     -90,  -92,  -94,  -96,  -98, -100, -102, -104, -106, -107, -109, -111, -112, -113, -115, -116,
    -117, -118, -120, -121, -122, -122, -123, -124, -125, -125, -126, -126, -126, -127, -127, -127,
    -127, -127, -127, -127, -126, -126, -126, -125, -125, -124, -123, -122, -122, -121, -120, -118,
    -117, -116, -115, -113, -112, -111, -109, -107, -106, -104, -102, -100,  -98,  -96,  -94,  -92,
     -90,  -88,  -85,  -83,  -81,  -78,  -76,  -73,  -71,  -68,  -65,  -63,  -60,  -57,  -54,  -51,
     -49,  -46,  -43,  -40,  -37,  -34,  -31,  -28,  -25,  -22,  -19,  -16,  -12,   -9,   -6,   -3
};

__attribute__((noinline, used))
static uint32_t poly_00(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 2*x2 + 1*y2 + 1*xy + 3*x + 5*y + 17;
    int32_t t = (1*(int32_t)x + 2*(int32_t)y + 7) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z)); // prevent too clever assembly
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_01(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 5*x2 + 6*y2 + 8*xy + 14*x + 18*y + 54;
    int32_t t = (4*(int32_t)x + 7*(int32_t)y + 14) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_02(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 8*x2 + 11*y2 + 2*xy + 25*x + 31*y + 91;
    int32_t t = (7*(int32_t)x + 12*(int32_t)y + 21) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_03(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 11*x2 + 16*y2 + 9*xy + 13*x + 15*y + 128;
    int32_t t = (10*(int32_t)x + 4*(int32_t)y + 11) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_04(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 14*x2 + 2*y2 + 3*xy + 24*x + 28*y + 165;
    int32_t t = (2*(int32_t)x + 9*(int32_t)y + 18) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_05(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 17*x2 + 7*y2 + 10*xy + 12*x + 12*y + 202;
    int32_t t = (5*(int32_t)x + 14*(int32_t)y + 8) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_06(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 3*x2 + 12*y2 + 4*xy + 23*x + 25*y + 239;
    int32_t t = (8*(int32_t)x + 6*(int32_t)y + 15) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_07(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 6*x2 + 17*y2 + 11*xy + 11*x + 9*y + 276;
    int32_t t = (11*(int32_t)x + 11*(int32_t)y + 22) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_08(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 9*x2 + 3*y2 + 5*xy + 22*x + 22*y + 313;
    int32_t t = (3*(int32_t)x + 3*(int32_t)y + 12) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_09(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 12*x2 + 8*y2 + 12*xy + 10*x + 6*y + 350;
    int32_t t = (6*(int32_t)x + 8*(int32_t)y + 19) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_10(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 15*x2 + 13*y2 + 6*xy + 21*x + 19*y + 387;
    int32_t t = (9*(int32_t)x + 13*(int32_t)y + 9) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_11(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 18*x2 + 18*y2 + 13*xy + 9*x + 32*y + 424;
    int32_t t = (1*(int32_t)x + 5*(int32_t)y + 16) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_12(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 4*x2 + 4*y2 + 7*xy + 20*x + 16*y + 461;
    int32_t t = (4*(int32_t)x + 10*(int32_t)y + 23) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_13(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 7*x2 + 9*y2 + 1*xy + 8*x + 29*y + 498;
    int32_t t = (7*(int32_t)x + 2*(int32_t)y + 13) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_14(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 10*x2 + 14*y2 + 8*xy + 19*x + 13*y + 535;
    int32_t t = (10*(int32_t)x + 7*(int32_t)y + 20) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_15(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 13*x2 + 19*y2 + 2*xy + 7*x + 26*y + 572;
    int32_t t = (2*(int32_t)x + 12*(int32_t)y + 10) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_16(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 16*x2 + 5*y2 + 9*xy + 18*x + 10*y + 609;
    int32_t t = (5*(int32_t)x + 4*(int32_t)y + 17) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_17(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 2*x2 + 10*y2 + 3*xy + 6*x + 23*y + 646;
    int32_t t = (8*(int32_t)x + 9*(int32_t)y + 7) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}

__attribute__((noinline, used))
static uint32_t poly_18(uint32_t x, uint32_t y, int32_t s){
    uint32_t x2 = x*x;
    uint32_t y2 = y*y;
    uint32_t xy = x*y;
    uint32_t z = 5*x2 + 15*y2 + 10*xy + 17*x + 7*y + 683;
    int32_t t = (11*(int32_t)x + 14*(int32_t)y + 14) * s;
    z += (uint32_t)t;
    __asm__ volatile ("" : "+r"(z));
    return z;
}



__attribute__((noinline))
unsigned char run_workload(int verbose){
    uint32_t acc = 0;

    for (uint32_t y = 0; y < NY; y++) {
        for (uint32_t x = 0; x < NX; x++) {
            uint32_t z = 0;

            z += poly_00(x, y, sine_lut[(1*x + 3*y + 0) & 255]);
            z += poly_01(x, y, sine_lut[(2*x + 5*y + 11) & 255]);
            z += poly_02(x, y, sine_lut[(3*x + 7*y + 22) & 255]);
            z += poly_03(x, y, sine_lut[(4*x + 9*y + 33) & 255]);
            z += poly_04(x, y, sine_lut[(5*x + 4*y + 44) & 255]);
            z += poly_05(x, y, sine_lut[(1*x + 6*y + 55) & 255]);
            z += poly_06(x, y, sine_lut[(2*x + 8*y + 66) & 255]);
            z += poly_07(x, y, sine_lut[(3*x + 3*y + 77) & 255]);
            z += poly_08(x, y, sine_lut[(4*x + 5*y + 88) & 255]);
            z += poly_09(x, y, sine_lut[(5*x + 7*y + 99) & 255]);
            z += poly_10(x, y, sine_lut[(1*x + 9*y + 110) & 255]);
            z += poly_11(x, y, sine_lut[(2*x + 4*y + 121) & 255]);
            z += poly_12(x, y, sine_lut[(3*x + 6*y + 132) & 255]);
            z += poly_13(x, y, sine_lut[(4*x + 8*y + 143) & 255]);
            z += poly_14(x, y, sine_lut[(5*x + 3*y + 154) & 255]);
            z += poly_15(x, y, sine_lut[(1*x + 5*y + 165) & 255]);
            z += poly_16(x, y, sine_lut[(2*x + 7*y + 176) & 255]);
            z += poly_17(x, y, sine_lut[(3*x + 9*y + 187) & 255]);
            z += poly_18(x, y, sine_lut[(4*x + 4*y + 198) & 255]);


            /* Compiler barrier: keeps the computation as an actual loop. */
            __asm__ volatile ("" : "+r"(z), "+r"(acc));
            acc += z;
        }
    }

    /* Fold 32-bit checksum to 8 bits for reg_7seg. */
    acc ^= acc >> 16;
    acc ^= acc >> 8;

    if (verbose) {
        print("Result: 0x");
        print_hex((unsigned char)acc, 2);
        putchar('\n');
    }

    return (unsigned char)acc; // expected 0x32
}

unsigned char run_workload_timed(){
	uint32_t cycles_begin, cycles_end;
	uint32_t instns_begin, instns_end;

	__asm__ volatile ("rdcycle %0" : "=r"(cycles_begin));
	__asm__ volatile ("rdinstret %0" : "=r"(instns_begin));

	unsigned char x = run_workload(0);

	__asm__ volatile ("rdcycle %0" : "=r"(cycles_end));
	__asm__ volatile ("rdinstret %0" : "=r"(instns_end));

	print("Cycles: 0x");
	print_hex(cycles_end - cycles_begin, 8);
	putchar('\n');
	print("Instns: 0x");
	print_hex(instns_end - instns_begin, 8);
	putchar('\n');

	return x;
}

void main(){
	setup_picosoc();

	unsigned char leds_value = 0x02;

	run_workload_timed();

	while (1) {
		reg_7seg = run_workload(0);     // expected byte value: 0x32
		reg_leds = leds_value;
		leds_value = leds_value ^ 0x02;
	}
}