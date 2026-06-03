
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

*/

/*
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
    
    Results:
        - Cannot fit entirely in logic/distributed RAM (unless 8 lines - barely fits)
        - 3622 logic cells for 32-bit ram
        - For an 8 line cache (very small) that fits entirely in logic, timing reduces from 
          16.32MHz to 12.84MHz
        - Can build in BRAM for 5% overhead in LCs and 4/8 RAMs
            - However, this is probably not going to work since the block ram expects
              1 cycle delay (I think...)
*/

function integer clog2;
    input integer value;
    integer v;
    begin
        v = value - 1;
        for (clog2 = 0; v > 0; clog2 = clog2 + 1)
            v = v >> 1;
    end
endfunction



module icache_zerocycle #(
    parameter integer LINES = 32,
    parameter integer IDX_BITS = clog2(LINES)
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

    /*(* ram_style = "logic" *)*/ reg [31:0]          data_array  [0:LINES-1]; // stores the actual data (instructions)
    /*(* ram_style = "logic" *)*/ reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 

    wire [IDX_BITS-1:0] index        = cpu_mem_addr[IDX_BITS+1:2]; // e.g. INDEX_BITS = 5 -> index = addr[6:2]
    wire [TAG_BITS-1:0] tag          = cpu_mem_addr[31:IDX_BITS+2];

    wire [31:0]         cached_value = data_array[index];

    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;
    assign mem_addr  = cpu_mem_addr;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid = cache_hit ? 1'b0 : cpu_mem_valid; // block the pass-through if cache is hit

    assign cpu_mem_rdata = cache_hit ? cached_value : mem_rdata;
    assign cpu_mem_ready = cache_hit ? 1'b1         : mem_ready; // immediately send back cache answer if hit


    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
        end
        else begin
            if(cache_miss && mem_valid && mem_ready) begin
                data_array[index] <= mem_rdata;
                tag_array[index] <= tag;
                valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index); // use mask to stop yosys complaining  
            end      
        end
        
    end

endmodule

/**************************************************************************************************************************/
/*
- *** THIS VERSION HAS A ONE-CYCLE DELAY FOR ALL INSTR_FETCH***
  - Uses a FSM
  - This allows using BRAM for the cache - the one-cycle delay is needed since
    block ram lookup is synchronous. 
  - Tag and data both in RAM

  - Functionality:
        Cycle 0:
            state = S_IDLE
            CPU presents instruction fetch address A
            cpu_mem_ready = 0
            next_state = S_LOOKUP

        Rising edge 1:
            state <= S_LOOKUP
            SB_RAM40_4K samples index(A) of data_array and tag_array

        During Cycle 1:
            cached_value is valid for A
            tag_array[index] is valid for A
            if cache_hit, cpu_mem_ready = 1
            cpu_mem_rdata = cached_value

        Rising edge 2:
            CPU accepts the hit response if it's a hit
            state <= S_IDLE
            Otherwise, state <= S_MISS and we wait for memory system ready
*/


module icache #(
    parameter integer LINES = 32,
    parameter integer IDX_BITS = clog2(LINES)
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

    /*(* ram_style = "logic" *)*/ reg [31:0]          data_array  [0:LINES-1]; // stores the actual data (instructions)
    /*(* ram_style = "logic" *)*/ reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 

    wire [IDX_BITS-1:0] index        = cpu_mem_addr[IDX_BITS+1:2]; // e.g. INDEX_BITS = 5 -> index = addr[6:2]
    wire [TAG_BITS-1:0] tag          = cpu_mem_addr[31:IDX_BITS+2];

    wire [31:0]         cached_value = data_array[index];

    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // State machine signals  
    reg [1:0] state; 
    reg [1:0] next_state;
    parameter S_IDLE = 2'b00, S_LOOKUP = 2'b01, S_MISS = 2'b10;

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;
    assign mem_addr  = cpu_mem_addr;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid =
        (state == S_IDLE && !is_instruction_fetch) ? cpu_mem_valid : // Not an instruction fetch - passthrough
        (state == S_MISS)                          ? cpu_mem_valid : // Miss - pass through (there'll be a 1cycle delay)
                                                    1'b0;            // Looking up - intercept the valid for (at least) 1 cycle

    assign cpu_mem_ready =
        (state == S_IDLE && !is_instruction_fetch) ? mem_ready : // not an instruction fetch - pass through
        (state == S_LOOKUP && cache_hit)           ? 1'b1 :      // cache hit? send back immediately
        (state == S_MISS && mem_ready)             ? 1'b1 :      // waiting for miss result and memory sends it back? send it back 
                                                    1'b0;        // looking up or waiting for miss - don't send back yet

    assign cpu_mem_rdata =
        (state == S_LOOKUP && cache_hit) ? cached_value :
                                        mem_rdata;


    // State ff 
    always @ (posedge clk) begin
        if(!resetn) begin
            state <= S_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition


    always @ (*) begin
        case(state) 
            S_IDLE: begin
                if (is_instruction_fetch) next_state = S_LOOKUP;
                else next_state = S_IDLE;
            end
            S_LOOKUP: begin
                if (cache_hit) next_state = S_IDLE;
                else next_state = S_MISS;
            end
            S_MISS: begin
                if (mem_ready) next_state = S_IDLE;
                else next_state = S_MISS;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end 

    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
        end
        else begin
            if(state == S_MISS && mem_ready) begin
                data_array[index] <= mem_rdata;
                tag_array[index] <= tag;
                valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index); // use mask to stop yosys complaining  
            end      
        end
        
    end

endmodule

/**************************************************************************************************************************/
/*
- *** STICKY CACHE VERSION - 1 CYCLE DELAY (SAME AS ABOVE), FIRST MISS BYPASS ***
    - Same as 1 cycle delay icache except only rewrite the cache slot after already 1 miss
      This means, e.g. if the hotloop is 32 instr and cache is 16 lines, we will still store 
      ideally 16 of the 32 instr in the cache without replacing them each time
      (whereas if we didn't have this the cache would be pointless)
    - Tradeoff is an AREA PENALTY - can't fit 128x1
*/

module icache_first_miss_bypass #(
    parameter integer LINES = 32,
    parameter integer IDX_BITS = clog2(LINES)
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
    localparam integer TAG_BITS = 32 - 2 - IDX_BITS;
    
    /* Memory structure:
       |  Tag            |   Index   |  0 0
        31              7 6         2   1 0
    */

    /*(* ram_style = "logic" *)*/ reg [31:0]          data_array  [0:LINES-1]; // stores the actual data (instructions)
    /*(* ram_style = "logic" *)*/ reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 
    reg [LINES-1:0]     missed_once;

    wire [IDX_BITS-1:0] index        = cpu_mem_addr[IDX_BITS+1:2]; // e.g. INDEX_BITS = 5 -> index = addr[6:2]
    wire [TAG_BITS-1:0] tag          = cpu_mem_addr[31:IDX_BITS+2];

    wire [31:0]         cached_value = data_array[index];

    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // State machine signals  
    reg [1:0] state; 
    reg [1:0] next_state;
    parameter S_IDLE = 2'b00, S_LOOKUP = 2'b01, S_MISS = 2'b10;

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;
    assign mem_addr  = cpu_mem_addr;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid =
        (state == S_IDLE && !is_instruction_fetch) ? cpu_mem_valid : // Not an instruction fetch - passthrough
        (state == S_MISS)                          ? cpu_mem_valid : // Miss - pass through (there'll be a 1cycle delay)
                                                    1'b0;            // Looking up - intercept the valid for (at least) 1 cycle

    assign cpu_mem_ready =
        (state == S_IDLE && !is_instruction_fetch) ? mem_ready : // not an instruction fetch - pass through
        (state == S_LOOKUP && cache_hit)           ? 1'b1 :      // cache hit? send back immediately
        (state == S_MISS && mem_ready)             ? 1'b1 :      // waiting for miss result and memory sends it back? send it back 
                                                    1'b0;        // looking up or waiting for miss - don't send back yet

    assign cpu_mem_rdata =
        (state == S_LOOKUP && cache_hit) ? cached_value :
                                        mem_rdata;


    // State ff 
    always @ (posedge clk) begin
        if(!resetn) begin
            state <= S_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition


    always @ (*) begin
        case(state) 
            S_IDLE: begin
                if (is_instruction_fetch) next_state = S_LOOKUP;
                else next_state = S_IDLE;
            end
            S_LOOKUP: begin
                if (cache_hit) next_state = S_IDLE;
                else next_state = S_MISS;
            end
            S_MISS: begin
                if (mem_ready) next_state = S_IDLE;
                else next_state = S_MISS;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end 

    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
            missed_once <= {LINES{1'b0}};
        end
        else begin
            if (state == S_LOOKUP && cache_hit) begin
                missed_once <= missed_once & ~({{(LINES-1){1'b0}}, 1'b1} << index);                
            end
            if(state == S_MISS && mem_ready) begin
                if (!valid_array[index]) begin
                    // always update if that line is empty
                    data_array[index]  <= mem_rdata;
                    tag_array[index]   <= tag;
                    valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index); 
                    missed_once <= missed_once & ~({{(LINES-1){1'b0}}, 1'b1} << index);                
                end
                else if(missed_once[index]) begin
                    // update only if already missed once (sticky cache)
                    data_array[index] <= mem_rdata;
                    tag_array[index] <= tag;
                    valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index); // use mask to stop yosys complaining  
                    missed_once <= missed_once & ~({{(LINES-1){1'b0}}, 1'b1} << index);                
                end
                else begin
                    // mark as already missed once
                    missed_once <= missed_once | ({{(LINES-1){1'b0}}, 1'b1} << index);                
                end
            end      
        end
        
    end

endmodule

/**************************************************************************************************************************/
/*
- *** STICKY CACHE - 1 CYCLE DELAY (SAME AS ABOVE), "RANDOM" BYPASS  ***
    - Same as 1 cycle delay icache except 50% chance to rewrite whenever miss
    - Same idea as the first miss bypass except smoother deterioration for too
      small cache (16 line cache, 48 instr, still becomes useless for 1-miss bypass)
      Also likely uses less logic (no need for new reg array of size LINES)
*/


module icache_random_bypass #(
    parameter integer LINES = 32,
    parameter integer IDX_BITS = clog2(LINES)
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
    localparam integer TAG_BITS = 32 - 2 - IDX_BITS;
    
    /* Memory structure:
       |  Tag            |   Index   |  0 0
        31              7 6         2   1 0
    */

    /*(* ram_style = "logic" *)*/ reg [31:0]          data_array  [0:LINES-1]; // stores the actual data (instructions)
    /*(* ram_style = "logic" *)*/ reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 

    wire [IDX_BITS-1:0] index        = cpu_mem_addr[IDX_BITS+1:2]; // e.g. INDEX_BITS = 5 -> index = addr[6:2]
    wire [TAG_BITS-1:0] tag          = cpu_mem_addr[31:IDX_BITS+2];

    wire [31:0]         cached_value = data_array[index];

    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // State machine signals  
    reg [1:0] state; 
    reg [1:0] next_state;
    parameter S_IDLE = 2'b00, S_LOOKUP = 2'b01, S_MISS = 2'b10;

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;
    assign mem_addr  = cpu_mem_addr;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid =
        (state == S_IDLE && !is_instruction_fetch) ? cpu_mem_valid : // Not an instruction fetch - passthrough
        (state == S_MISS)                          ? cpu_mem_valid : // Miss - pass through (there'll be a 1cycle delay)
                                                    1'b0;            // Looking up - intercept the valid for (at least) 1 cycle

    assign cpu_mem_ready =
        (state == S_IDLE && !is_instruction_fetch) ? mem_ready : // not an instruction fetch - pass through
        (state == S_LOOKUP && cache_hit)           ? 1'b1 :      // cache hit? send back immediately
        (state == S_MISS && mem_ready)             ? 1'b1 :      // waiting for miss result and memory sends it back? send it back 
                                                    1'b0;        // looking up or waiting for miss - don't send back yet

    assign cpu_mem_rdata =
        (state == S_LOOKUP && cache_hit) ? cached_value :
                                        mem_rdata;

    // LSFR (Linear shift feedback register) to generate "random"-looking string of 1 and 0
    reg [7:0] lfsr;
    wire feedback = lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3];

    always @(posedge clk) begin
        if (!resetn)
            lfsr <= 8'hA5;  // initial seed
        else if (state == S_MISS && mem_ready)            
            lfsr <= {lfsr[6:0], feedback};
    end

    wire allocate_this_miss = (!valid_array[index]) || (lfsr[2:0] == 3'b111);

    
    // State ff 
    always @ (posedge clk) begin
        if(!resetn) begin
            state <= S_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition


    always @ (*) begin
        case(state) 
            S_IDLE: begin
                if (is_instruction_fetch) next_state = S_LOOKUP;
                else next_state = S_IDLE;
            end
            S_LOOKUP: begin
                if (cache_hit) next_state = S_IDLE;
                else next_state = S_MISS;
            end
            S_MISS: begin
                if (mem_ready) next_state = S_IDLE;
                else next_state = S_MISS;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end 

    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
        end
        else begin
            if(state == S_MISS && mem_ready && allocate_this_miss) begin // only update if allocate_this_miss
                data_array[index] <= mem_rdata;
                tag_array[index] <= tag;
                valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index); // use mask to stop yosys complaining  
            end      
        end
        
    end

endmodule

/**************************************************************************************************************************/
/*
- *** Multiple words per line and first-word bypass ***
    - Multiple words per line
    - 4 FSM states: IDLE, LOOKUP (1 cycle), FILL (waiting for IF), RESP (1 cycle, send response)
    - If miss, we go to FILL state and fill all WORDS_PER_LINE cells using the counter fill_offset
      then spend 1 more cycle to lookup the response from cache and send it back (maybe this can be
      improved but it's not a big deal, misses should be rare)
    Largest cache that fits is 128 x 16 = 2048 instr 
*/

module icache_multiword #(
    parameter integer LINES = 16,
    parameter integer IDX_BITS = clog2(LINES),
    parameter integer WORDS_PER_LINE = 4,
    parameter integer WORD_SEL_BITS = clog2(WORDS_PER_LINE)
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
    localparam integer TAG_BITS = 32 - 2 - WORD_SEL_BITS - IDX_BITS;    

    localparam integer TOTAL_WORDS = LINES * WORDS_PER_LINE;
    localparam integer TOTAL_WORD_BITS = IDX_BITS + WORD_SEL_BITS;


    /*
    Address structure (16 line, 4 word per line)
    |        Tag        |   Index   | Word offset | 0 0 |
    31                 8 7         4 3            2 1 0
    byte offset = addr[1:0]
    word offset = selects word within cache line
    index = selects cache line
    tag = identifies memory block

    */

    reg [31:0] data_array [0:TOTAL_WORDS-1]; // stores the actual data (instructions)
    reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 


    reg [WORD_SEL_BITS-1:0] fill_offset; // a counter for which word in the line is being filled currently


    wire [WORD_SEL_BITS-1:0] word_sel = cpu_mem_addr[WORD_SEL_BITS+1:2]; // word sel for the actual request
    wire [IDX_BITS-1:0] index = cpu_mem_addr[IDX_BITS+WORD_SEL_BITS+1 : WORD_SEL_BITS+2];
    wire [TAG_BITS-1:0] tag = cpu_mem_addr[31 : IDX_BITS+WORD_SEL_BITS+2];

    // which word in data_array is relevant rn 
    wire [TOTAL_WORD_BITS-1:0] cache_read_addr = {index, word_sel}; // based on CPU instruction's word_sel
    wire [TOTAL_WORD_BITS-1:0] cache_fill_addr = {index, fill_offset}; // which slot is being filled in the cache

    wire [31:0] cached_value = data_array[cache_read_addr]; 


    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // State machine signals  
    reg [1:0] state; 
    reg [1:0] next_state;
    parameter S_IDLE = 2'b00, S_LOOKUP = 2'b01, S_FILL = 2'b10, S_RESP = 2'b11;

    
    // filling progress - which real memory address is being filled
    wire fill_done = mem_ready && (fill_offset == WORDS_PER_LINE-1);

    wire [31:0] line_base_addr = {cpu_mem_addr[31:WORD_SEL_BITS+2], {WORD_SEL_BITS{1'b0}}, 2'b00}; // line address with word sel bits 0
    wire [31:0] fill_addr = line_base_addr + ({30'b0, fill_offset} << 2); // the addr being filled 

    assign mem_addr = (state == S_FILL) ? fill_addr : cpu_mem_addr; // use fill_addr if we're filling otherwise forward cpu_mem_addr

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid =
        (state == S_IDLE && !is_instruction_fetch) ? cpu_mem_valid : // Not an instruction fetch - passthrough
        (state == S_FILL)                          ? 1'b1 : // Miss - pass through (there'll be a 1cycle delay)
                                                     1'b0;            // Looking up - intercept the valid for (at least) 1 cycle

    assign cpu_mem_ready =
        (state == S_IDLE && !is_instruction_fetch) ? mem_ready : // not an instruction fetch - pass through
        (state == S_LOOKUP && cache_hit)           ? 1'b1 :      // cache hit? send back immediately
        (state == S_RESP             )             ? 1'b1 :      // waiting for miss result and memory sends it back? send it back 
                                                    1'b0;        // looking up or waiting for miss - don't send back yet

    assign cpu_mem_rdata = (state != S_IDLE) ? cached_value : mem_rdata;


    // State ff 
    always @ (posedge clk) begin
        if(!resetn) begin
            state <= S_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition
    always @(*) begin
        case (state)
            S_IDLE: begin
                if (is_instruction_fetch)
                    next_state = S_LOOKUP;
                else
                    next_state = S_IDLE;
            end
            S_LOOKUP: begin
                if (cache_hit)
                    next_state = S_IDLE;
                else
                    next_state = S_FILL;
            end
            S_FILL: begin
                if (fill_done)
                    next_state = S_RESP;
                else
                    next_state = S_FILL;
            end
            S_RESP: begin
                next_state = S_IDLE;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end


    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
        end
        else begin
            if(state == S_FILL && mem_ready) begin
                data_array[cache_fill_addr] <= mem_rdata;                
                if (fill_done) begin
                    tag_array[index] <= tag;
                    valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index);
                end
      
            end      
        end
    end

    // fill counter
    always @(posedge clk) begin
        if (!resetn) begin
            fill_offset <= {WORD_SEL_BITS{1'b0}};
        end else begin
            if (state == S_LOOKUP && cache_miss) begin
                fill_offset <= {WORD_SEL_BITS{1'b0}};
            end else if (state == S_FILL && mem_ready) begin
                if (!fill_done)
                    fill_offset <= fill_offset + 1'b1;
            end
        end
    end

endmodule

/**************************************************************************************************************************/
/*
- *** Multiple words per line, AND first miss bypass ***
*/

module icache_multiword_first_miss_bypass #(
    parameter integer LINES = 16,
    parameter integer IDX_BITS = clog2(LINES),
    parameter integer WORDS_PER_LINE = 4,
    parameter integer WORD_SEL_BITS = clog2(WORDS_PER_LINE)
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
    localparam integer TAG_BITS = 32 - 2 - WORD_SEL_BITS - IDX_BITS;    

    localparam integer TOTAL_WORDS = LINES * WORDS_PER_LINE;
    localparam integer TOTAL_WORD_BITS = IDX_BITS + WORD_SEL_BITS;


    /*
    Address structure (16 line, 4 word per line)
    |        Tag        |   Index   | Word offset | 0 0 |
    31                 8 7         4 3            2 1 0
    byte offset = addr[1:0]
    word offset = selects word within cache line
    index = selects cache line
    tag = identifies memory block

    */

    reg [31:0] data_array [0:TOTAL_WORDS-1]; // stores the actual data (instructions)
    reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 
    reg [LINES-1:0]     missed_once;


    reg [WORD_SEL_BITS-1:0] fill_offset; // a counter for which word in the line is being filled currently


    wire [WORD_SEL_BITS-1:0] word_sel = cpu_mem_addr[WORD_SEL_BITS+1:2]; // word sel for the actual request
    wire [IDX_BITS-1:0] index = cpu_mem_addr[IDX_BITS+WORD_SEL_BITS+1 : WORD_SEL_BITS+2];
    wire [TAG_BITS-1:0] tag = cpu_mem_addr[31 : IDX_BITS+WORD_SEL_BITS+2];

    // which word in data_array is relevant rn 
    wire [TOTAL_WORD_BITS-1:0] cache_read_addr = {index, word_sel}; // based on CPU instruction's word_sel
    wire [TOTAL_WORD_BITS-1:0] cache_fill_addr = {index, fill_offset}; // which slot is being filled in the cache

    wire [31:0] cached_value = data_array[cache_read_addr]; 


    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // State machine signals  
    reg [2:0] state; 
    reg [2:0] next_state;
    parameter S_IDLE = 3'b000, S_LOOKUP = 3'b001, S_FILL = 3'b010, S_RESP = 3'b011, S_FIRSTMISS = 3'b100;

    
    // filling progress - which real memory address is being filled
    wire fill_done = mem_ready && (fill_offset == WORDS_PER_LINE-1);

    wire should_fill = !valid_array[index] || missed_once[index];

    wire [31:0] line_base_addr = {cpu_mem_addr[31:WORD_SEL_BITS+2], {WORD_SEL_BITS{1'b0}}, 2'b00}; // line address with word sel bits 0
    wire [31:0] fill_addr = line_base_addr + ({30'b0, fill_offset} << 2); // the addr being filled 

    assign mem_addr = (state == S_FILL) ? fill_addr : cpu_mem_addr; // use fill_addr if we're filling otherwise forward cpu_mem_addr

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid =
        (state == S_IDLE && !is_instruction_fetch) ? cpu_mem_valid : // Not an instruction fetch - passthrough
        (state == S_FILL)                          ? 1'b1 : // Miss - pass through (there'll be a 1cycle delay)
        (state == S_FIRSTMISS)                     ? cpu_mem_valid :
                                                     1'b0;            // Looking up - intercept the valid for (at least) 1 cycle

    assign cpu_mem_ready =
        (state == S_IDLE && !is_instruction_fetch) ? mem_ready : // not an instruction fetch - pass through
        (state == S_LOOKUP && cache_hit)           ? 1'b1 :      // cache hit? send back immediately
        (state == S_RESP             )             ? 1'b1 :      // waiting for miss result and memory sends it back? send it back 
        (state == S_FIRSTMISS && mem_ready)        ? 1'b1 :
                                                    1'b0;        // looking up or waiting for miss - don't send back yet

    assign cpu_mem_rdata =
        (state == S_LOOKUP && cache_hit) ? cached_value :
        (state == S_RESP)                ? cached_value :
                                           mem_rdata;


    // State ff 
    always @ (posedge clk) begin
        if(!resetn) begin
            state <= S_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition
    always @(*) begin
        case (state)
            S_IDLE: begin
                if (is_instruction_fetch)
                    next_state = S_LOOKUP;
                else
                    next_state = S_IDLE;
            end
            S_LOOKUP: begin
                if (cache_hit)
                    next_state = S_IDLE;
                else if (should_fill)
                    next_state = S_FILL;
                else
                    next_state = S_FIRSTMISS;
            end
            S_FILL: begin
                if (fill_done)
                    next_state = S_RESP;
                else
                    next_state = S_FILL;
            end
            S_RESP: begin
                next_state = S_IDLE;
            end
            S_FIRSTMISS: begin
                if (mem_ready)
                    next_state = S_IDLE;
                else
                    next_state = S_FIRSTMISS;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end


    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
            missed_once <= {LINES{1'b0}};
        end
        else begin
            if (state == S_LOOKUP && cache_hit) begin
                missed_once <= missed_once & ~({{(LINES-1){1'b0}}, 1'b1} << index);                
            end
            if(state == S_FILL && mem_ready) begin
                data_array[cache_fill_addr] <= mem_rdata;                
                if (fill_done) begin
                    tag_array[index] <= tag;
                    valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index);
                    missed_once <= missed_once & ~({{(LINES-1){1'b0}}, 1'b1} << index);                
                end
      
            end
            if(state == S_FIRSTMISS && mem_ready) begin
                missed_once <= missed_once | ({{(LINES-1){1'b0}}, 1'b1} << index);                
            end
        end
    end

    // fill counter
    always @(posedge clk) begin
        if (!resetn) begin
            fill_offset <= {WORD_SEL_BITS{1'b0}};
        end else begin
            if (state == S_LOOKUP && cache_miss) begin
                fill_offset <= {WORD_SEL_BITS{1'b0}};
            end else if (state == S_FILL && mem_ready) begin
                if (!fill_done)
                    fill_offset <= fill_offset + 1'b1;
            end
        end
    end

endmodule

/**************************************************************************************************************************/
/*
- *** Multiword Cache with Lookahead (Zero-cycle hits) ***
   Remove 1-cycle delay for FSM LOOKUP state by using look-ahead interface
   Thus we can return hits zero-cycle and misses with 1-cycle delay
   Only need 3 state FSM: S_LOOKUP no longer needed

   Also made some changes to save area 
   
*/


module icache_multiword_lookahead #(
    parameter integer LINES = 16,
    parameter integer IDX_BITS = clog2(LINES),
    parameter integer WORDS_PER_LINE = 4,
    parameter integer WORD_SEL_BITS = clog2(WORDS_PER_LINE)
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

    	// Look-Ahead Interface
	input            cpu_mem_la_read,
	input     [31:0] cpu_mem_la_addr,

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
    localparam integer TAG_BITS = 32 - 2 - WORD_SEL_BITS - IDX_BITS;    

    localparam integer TOTAL_WORDS = LINES * WORDS_PER_LINE;
    localparam integer TOTAL_WORD_BITS = IDX_BITS + WORD_SEL_BITS;


    /*
    Address structure (16 line, 4 word per line)
    |        Tag        |   Index   | Word offset | 0 0 |
    31                 8 7         4 3            2 1 0
    byte offset = addr[1:0]
    word offset = selects word within cache line
    index = selects cache line
    tag = identifies memory block

    */

    reg [31:0] data_array [0:TOTAL_WORDS-1]; // stores the actual data (instructions)
    reg [TAG_BITS-1:0]  tag_array   [0:LINES-1];   // stores the tags for each line
    reg [LINES-1:0]     valid_array; 


    reg [WORD_SEL_BITS-1:0] fill_offset; // a counter for which word in the line is being filled currently


    wire [WORD_SEL_BITS-1:0] word_sel = cpu_mem_addr[WORD_SEL_BITS+1:2]; // word sel for the actual request
    wire [IDX_BITS-1:0] index = cpu_mem_addr[IDX_BITS+WORD_SEL_BITS+1 : WORD_SEL_BITS+2];
    wire [TAG_BITS-1:0] tag = cpu_mem_addr[31 : IDX_BITS+WORD_SEL_BITS+2];

    // which word in data_array is relevant rn 
    wire [TOTAL_WORD_BITS-1:0] cache_fill_addr = {index, fill_offset}; // which slot is being filled in the cache

    //wire [31:0] cached_value = data_array[cache_read_addr]; 
    // Replaces cached_value, in order to save a set of cache read logic (save area to allow bigger cache)
    reg [31:0] miss_rdata;



    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    wire tag_match   = valid_array[index] && (tag_array[index] == tag);
    wire cache_hit   = tag_match && is_instruction_fetch;
    wire cache_miss  = !tag_match && is_instruction_fetch;

    // Lookahead control signals 
    reg [31:0] la_cached_value;
    wire [WORD_SEL_BITS-1:0] la_word_sel = cpu_mem_la_addr[WORD_SEL_BITS+1:2];
    wire [IDX_BITS-1:0] la_index = cpu_mem_la_addr[IDX_BITS+WORD_SEL_BITS+1 : WORD_SEL_BITS+2];
    wire [TOTAL_WORD_BITS-1:0] la_cache_read_addr = {la_index, la_word_sel};
    

    // State machine signals  
    reg [1:0] state; 
    reg [1:0] next_state;
    parameter S_IDLE = 2'b00, S_FILL = 2'b01, S_RESP = 2'b10;

    
    // filling progress - which real memory address is being filled
    wire fill_done = mem_ready && (fill_offset == WORDS_PER_LINE-1);

    wire [31:0] fill_addr = {cpu_mem_addr[31:WORD_SEL_BITS+2], fill_offset, 2'b00};

    assign mem_addr = (state == S_FILL) ? fill_addr : cpu_mem_addr; // use fill_addr if we're filling otherwise forward cpu_mem_addr

    // Some signals can always be pass-through
    assign mem_instr = cpu_mem_instr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;

    // Combinational logic: for cache hits and for non-instruction-fetch
    assign mem_valid =
        (state == S_IDLE && !is_instruction_fetch) ? cpu_mem_valid : // Not an instruction fetch - passthrough
        (state == S_FILL)                          ? 1'b1 : // Miss - pass through (there'll be a 1cycle delay)
                                                     1'b0;            // Looking up - intercept the valid for (at least) 1 cycle

    assign cpu_mem_ready =
        (state == S_IDLE && !is_instruction_fetch) ? mem_ready : // not an instruction fetch - pass through
        (state == S_IDLE && cache_hit)             ? 1'b1 :      // cache hit? send back immediately
        (state == S_RESP             )             ? 1'b1 :      // waiting for miss result and memory sends it back? send it back 
                                                    1'b0;        // looking up or waiting for miss - don't send back yet

    assign cpu_mem_rdata =
        (state == S_IDLE && cache_hit) ? la_cached_value : // if cache hit that means we already fetched the instr from cache using LA last cycle
        (state == S_RESP)              ? miss_rdata : // if not then we're probably filling the cache. 
                                         mem_rdata; // 


    // State ff 
    always @ (posedge clk) begin
        if(!resetn) begin
            state <= S_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // Next state transition
    always @(*) begin
        case (state)
            S_IDLE: begin
                if (cache_miss)
                    next_state = S_FILL;
                else
                    next_state = S_IDLE;
            end
            S_FILL: begin
                if (fill_done)
                    next_state = S_RESP;
                else
                    next_state = S_FILL;
            end
            S_RESP: begin
                next_state = S_IDLE;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end


    // data_regs transition
    always@(posedge clk) begin
        if(!resetn) begin
            valid_array <= {LINES{1'b0}};
            miss_rdata <= 32'b0;
        end
        else begin
            if(state == S_FILL && mem_ready) begin
                data_array[cache_fill_addr] <= mem_rdata;    
                if (fill_offset == word_sel)
                    miss_rdata <= mem_rdata;            
                if (fill_done) begin
                    tag_array[index] <= tag;
                    valid_array <= valid_array | ({{(LINES-1){1'b0}}, 1'b1} << index);
                end
      
            end      
        end
    end

    // lookahead cache value flop
    always @(posedge clk) begin
        if (!resetn) begin
            la_cached_value <= 32'b0;
        end
        else if (cpu_mem_la_read) begin
            la_cached_value <= data_array[la_cache_read_addr];
        end
    end

    // fill counter
    always @(posedge clk) begin
        if (!resetn) begin
            fill_offset <= {WORD_SEL_BITS{1'b0}};
        end else begin
            if (state == S_IDLE && cache_miss) begin
                fill_offset <= {WORD_SEL_BITS{1'b0}};
            end 
            else if (state == S_FILL && mem_ready) begin
                if (!fill_done)
                    fill_offset <= fill_offset + 1'b1;
            end
        end
    end

endmodule