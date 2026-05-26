
/*
I-Cache for the PicoSoC processor.
Transparent read-only cache for instruction fetch. 
First draft by Kevin Liu 26/05/2026

This cache goes in between the memory interface of the CPU 
and the memory-system side in picosoc.v.
Instruction fetch requests go through the cache first and check for hit/miss, 
returning the data combinationally if its a hit (the request doesn't go beyond the cache)
On a cache miss, or if its not an instruction fetch, we just pass through the 
request to the existing memory system as usual (if it was a cache miss the returned
data is intercepted and stored in the cache).

The memory interface of the CPU is as follows:
	output reg        mem_valid,
	output reg        mem_instr,
	input             mem_ready,

	output reg [31:0] mem_addr,
	output reg [31:0] mem_wdata,
	output reg [ 3:0] mem_wstrb,
	input      [31:0] mem_rdata,

The behaviour is as follows:
    - mem_valid tells the memory system that the current request is valid
    - mem_instr is 1 if it's an instruction fetch, 0 otherwise
    - mem_ready is 1 when the memory system completed the request and returns the data
    
    - mem_addr is the address of the instruction/memory to be accessed
    - mem_wdata is the memory to be written to memory
    - mem_wstrb is whether we are writing or reading: 4'b0000 = reading. Any bit is 1 = writing to that section
    - mem_rdata is the data returned by a read request

    *** Valid is held high and data doesn't change until ready is sent back. ***
    Once valid == 1 and ready == 1 the transaction is considered completed. 


Both the instruction data and load/store requests. These requests are differentiated by picosoc.v:
    - A request is sent to SPI when mem_valid && mem_addr >= 4*MEM_WORDS && mem_addr < 32'h 0200_0000
    - For the MEM_WORDS = 32768 for icebreaker (the max), 4*MEM_WORDS = 32'h 0002_0000
    - and the instruction memory starts at 0010_000 which is always SPI. (We don't have to worry about this
      in the cache implementation)

Cache functionality 
    - To be transparent, this cache should be instantiated attached directly to the CPU memory interface.
    - CPU side ports will be called cpu_mem_*, PicoSoC memory system side will be called mem_*
    - *** THIS VERSION IS THE SIMPLE & LIGHTWEIGHT CACHE WITH 1 WORD PER LINE ***
        - The entire cache is COMBINATIONAL (except for the cache data, tag, and valid registers)
        - All the ports in memory interface is passed straight through the cache module with no delay, except:
            - The valid signal is intercepted if there's a cache hit, and stays at 0 on the memory side
            - The cpu_mem_ready is asserted with zero-cycle delay if there's a cache hit
            - the cpu_mem_rdata is sent back according to the cache stored value with zero delay if there's a cache hit
            - If there's a cache miss, the rdata is read (but not intercepted) on its way back through the cache and stored 
        Note:
            - This implementation assumes the CPU behaves correctly - cpu_mem_instr, addr, wstrb etc must not change 
              once cpu_mem_valid is asserted until the ready is sent back, since we use these signals to mux the 
              values sent back. (This is true by design)
            - There may be glitches in the valid signal sent to the mem_source, but this is fine since the downstream
              logic uses the valid signal synchronously. Just need to make sure timing is fine.

*/


module icache #(
    parameter integer LINES = 32,
    parameter integer IDX_BITS = 5 // set to $clog2(LINES) 
) (
    // Clock and reset
    input clk, 
    input resetn,

    // CPU-side interface
    input             cpu_mem_valid,
    input             cpu_mem_instr,
    input  [31:0]     cpu_mem_addr,
    input  [31:0]     cpu_mem_wdata,
    input  [3:0]      cpu_mem_wstrb,
    output            cpu_mem_ready,
    output     [31:0] cpu_mem_rdata,

    // Memory system interface
    output            mem_valid,
    output            mem_instr,
    output     [31:0] mem_addr,
    output     [31:0] mem_wdata,
    output     [3:0]  mem_wstrb,
    input             mem_ready,
    input      [31:0] mem_rdata
);
    // Memory is byte-addressed. 
    // Memory interface uses 32-bit words, so each word is 4 addresses
    // hence we subtract 2 - the two LSB should always be 00.
    // The good news is that this is true even for compressed instrutctions - 
    // the CPU always requests an aligned 32-bit word and the logic for compressed
    // instructions is dealt with within the CPU. 
    localparam integer TAG_BITS = 32 - 2 - IDX_BITS;
    
    /* Memory structure:
       |  Tag            |   Index   |  0 0
        31              7 6         2   1 0
    */

    reg [31:0]          data_array  [0:LINES-1]; // stores the actual data (instructions)
    reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 

    wire [IDX_BITS-1:0] index        = cpu_mem_addr[IDX_BITS+1:2]; // e.g. INDEX_BITS = 5 -> index = addr[6:2]
    wire [TAG_BITS-1:0] tag          = cpu_mem_addr[31:IDX_BITS+2];

    wire [31:0]         cached_value = data_array[index];

    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = ~tag_match && is_instruction_fetch;

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;
    assign mem_addr  = cpu_mem_addr;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid = cache_hit ? 1'b0 : cpu_mem_valid; // block the pass-through if cache is hit

    assign cpu_mem_rdata = cache_hit ? cached_value : mem_rdata;
    assign cpu_mem_ready = cache_hit ? 1'b1         : mem_ready; // immediately send back cache answer if hit


    /* // State machine to keep track of whether we are waiting for a cache miss 
    // We don't actually need the state machine, though, 
    reg    state; 
    reg    next_state;
    parameter IDLE = 1'b0, PENDING_MISS = 1'b1;

    // State ff 
    always @ (posedge clk) begin
        if(~resetn) begin
            state <= IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition
    always @ (*) begin
        case(state) 
            IDLE: begin
                if(cache_miss && ~mem_ready) next_state = PENDING_MISS;
                else next_state = IDLE;
            end
            PENDING_MISS: begin
                if(mem_ready) next_state = IDLE;
                else next_state = PENDING_MISS;
            end
            default: next_state <= IDLE;
        endcase
    end */

    // data_regs transition
    always@(posedge clk) begin
        if(~resetn) begin
            valid_array <= {LINES{1'b0}};
        end
        else begin
            if(cache_miss && mem_valid && mem_ready) begin
                data_array[index] <= mem_rdata;
                tag_array[index] <= tag;
                valid_array[index] <= 1'b1;
            end
        end
        
    end

endmodule