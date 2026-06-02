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
	reg_uart_clkdiv = 143; // Baud = 1152060
    reg_7seg = 0x02;       // represents Demo 02
	reg_leds = 0x00;
	set_flash_qspi_flag();
    set_flash_mode_qddr(); // fastest SPI flash
}


#define ARRAY_SIZE 100
unsigned char run_workload(int verbose){
     unsigned char numbers[ARRAY_SIZE] = {
        142,  87, 213,  42, 119,   8, 176,  54, 231,  99,
         12, 165,  74, 201,  33, 150,  88, 245,  19, 111,
        182,  63, 137,  95, 222,   4, 158,  81, 209,  47,
        126,  71, 194,  28, 147, 252,  91,  16, 115, 170,
         58, 239,  83, 132,   2, 205,  67, 149, 226,  38,
        104, 188,  51, 161,  94, 242,  11, 123,  79, 217,
        134,  45, 173,  89, 250,  23, 155,  61, 199, 108,
         31, 140, 212,  76,   7, 185,  53, 167, 234,  92,
        121,  14, 203,  69, 152,  41, 228,  85, 114, 191,
         26, 179,  60, 247,  97, 136,   5, 221,  73, 162
    };

    int i, j, temp;
    // Outer loop tracks the number of passes
    for (i = 0; i < ARRAY_SIZE - 1; i++) {
        // Inner loop performs the adjacent comparisons
        // The last i elements are already in place
        for (j = 0; j < ARRAY_SIZE - i - 1; j++) {
            if (numbers[j] > numbers[j + 1]) {
                // Swap numbers
                temp = numbers[j];
                numbers[j] = numbers[j + 1];
                numbers[j + 1] = temp;
            }
        }
    }

    if (verbose){
        for (i = 0; i < ARRAY_SIZE; i++){
            print_dec(i);
            putchar(':');
            putchar(' ');
            print_dec(numbers[i]);
            print(" 0x");
            print_hex(numbers[i], 2);
            putchar('\n');
        }
    }

    return numbers[ARRAY_SIZE - 1]; // 0xFC = 252
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

    run_workload_timed(); // for the first time, CPI measurement
                          
    while (1) {
        // calculation that produces a unique answer
        reg_7seg = run_workload(0);     // 7-segment display
        reg_leds = leds_value;
        leds_value = leds_value ^ 0x02; // toggle LED1
    }
}
