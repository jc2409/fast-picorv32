
/*
I-Cache for the PicoSoC processor.
Transparent read-only cache for instruction fetch. 
By Kevin Liu

*** This file contains only the final caches used (associative and non-associative version) in the final
iterations of the processor design and verified using the dynamic testbench.

See icache_design_iterations.v for all iterative designs of the cache (some of which containing features
that were tested but not incorporated in the final design).***

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

N.B. When I say "zero-cycle" I mean the memory transaction is stalled by the cache for zero-cycles.
The memory handshake requires one rising edge to complete no matter what. 

*/


/**************************************************************************************************************************/
/*
- *** Multiword Cache with Lookahead (same-cycle hits) ***
   Remove 1-cycle delay for FSM LOOKUP state by using look-ahead interface
   Thus we can return hits same-cycle (or start processing misses next cycle)
   Only need 3 state FSM: states for IDLE, FILL, and RESP. 
   State stays at IDLE 

   Both the tag and data are fetched 1 cycle early using the lookahead interface
   So when the cpu instruction comes back both are already cleanly registered 
   inside the cache ready to be sent back straight away. 

   - Before cycle n-1: lookahead interface has settled combinationaly to the lookahead addr value
                       We read the tag and data array at this index
   - Rising edge for cycle n-1: Block RAM output ports now have the correct value
   - During cycle n-1: the value gets fed into the input for the flops la_cached_tag and _data
   - Rising edge of cycle n: la_cached_tag and la_cached_valid get their new values registered
   - during cycle n: the data and ready gets sent back if it was a hit, CPU completes the transaction next edge

   la_cached_* registers store retrieved tag/data/valid during lookahead cycle for shorter timing path
   
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

    reg [TAG_BITS-1:0] la_cached_tag;
    reg                la_cached_valid;

    wire tag_match   = la_cached_valid && (la_cached_tag == tag); // if tag read during prev cycle = tag on regular cpu interface now
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

    // lookahead cache value/tag/valid flop
    always @(posedge clk) begin
        if (!resetn) begin
            la_cached_value <= 32'b0;
            la_cached_tag   <= {TAG_BITS{1'b0}};
            la_cached_valid <= 1'b0;
        end
        else if (cpu_mem_la_read) begin
            la_cached_value <= data_array[la_cache_read_addr];
            la_cached_tag   <= tag_array[la_index];
            la_cached_valid <= valid_array[la_index];
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

/***************************************************************************************************************
    ASSOCIATIVE CACHE
    (e.g. can do 64 sets, 2 ways per set, same 16 words per line)
    Strictly equal or better CPI-wise to the direct mapped version, the only 
    difference is costs some extra area (and may slightly lower Fmax).

    Associative cache reduces conflict misses because can store two different ways
    (can think of it as more resilient to "hash" collision), even if total size
    is kept the same. 

    Otherwise same as icache_multiword_lookahead

    LINES=64 and WORDS_PER_LINE = 16 corresponds to 64x2x16
    which is the same size as 128x16 direct-mapped (both 2048)
*/

module icache_multiword_lookahead_2way #(
    parameter integer LINES = 16, // For 2-way cache, this is the number of sets per way
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

    // TOTAL_WORDS is the number of words in one way.
    // Since this is now 2-way associative, total cache data storage is 2 * TOTAL_WORDS.
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

    For 2-way associative cache:
    - index selects a set
    - each set has two possible cache lines: way 0 and way 1
    - both ways are checked for matching tag
    - on a miss, one way is selected for replacement (LRU)
    */
    (* ram_style = "block" *)
    reg [31:0] data_array0 [0:TOTAL_WORDS-1]; // stores the actual data (instructions), way 0
    (* ram_style = "block" *)
    reg [31:0] data_array1 [0:TOTAL_WORDS-1]; // stores the actual data (instructions), way 1

    (* ram_style = "block" *)
    reg [TAG_BITS-1:0]  tag_array0   [0:LINES-1];   // stores the tags for each set, way 0
    (* ram_style = "block" *)
    reg [TAG_BITS-1:0]  tag_array1   [0:LINES-1];   // stores the tags for each set, way 1

    reg [LINES-1:0]     valid_array0; 
    reg [LINES-1:0]     valid_array1; 

    // One replacement bit per set.
    // 0 means replace way 0 next.
    // 1 means replace way 1 next.
    // For a 2-way cache this is enough to implement true LRU.
    reg [LINES-1:0]     lru_array;

    // Way selected for replacement during the current miss fill.
    // 0 = replace/fill way 0
    // 1 = replace/fill way 1
    reg replace_way;


    reg [WORD_SEL_BITS-1:0] fill_offset; // a counter for which word in the line is being filled currently


    wire [WORD_SEL_BITS-1:0] word_sel = cpu_mem_addr[WORD_SEL_BITS+1:2]; // word sel for the actual request
    wire [IDX_BITS-1:0] index = cpu_mem_addr[IDX_BITS+WORD_SEL_BITS+1 : WORD_SEL_BITS+2];
    wire [TAG_BITS-1:0] tag = cpu_mem_addr[31 : IDX_BITS+WORD_SEL_BITS+2];

    // Used later - 1 for bit corresp. to index, 0 elsewhere
    // to prevent Yosys complaining about arr[index]...
    wire [LINES-1:0] index_mask = ({{(LINES-1){1'b0}}, 1'b1} << index);

    // which word in data_array is relevant rn 
    wire [TOTAL_WORD_BITS-1:0] cache_fill_addr = {index, fill_offset}; // which slot is being filled in the cache

    //wire [31:0] cached_value = data_array[cache_read_addr]; 
    // Replaces cached_value, in order to save a set of cache read logic (save area to allow bigger cache)
    reg [31:0] miss_rdata;


    // Useful control signals
    wire is_instruction_fetch = cpu_mem_wstrb == 4'b0000 && cpu_mem_valid && cpu_mem_instr;

    // both ways are checked in parallel.
    // The tag/valid values are read using the lookahead address,
    // then compared against the real request tag in the next cycle.
    // This mirrors the direct-mapped LA data/tag/valid registered-read style.
    reg [TAG_BITS-1:0] la_cached_tag0;
    reg [TAG_BITS-1:0] la_cached_tag1;
    reg                la_cached_valid0;
    reg                la_cached_valid1;

    // tag_match0 and 1 to check whether stored tag values from lookahead = cpu interface tag value 
    wire tag_match0   = la_cached_valid0 && (la_cached_tag0 == tag);
    wire tag_match1   = la_cached_valid1 && (la_cached_tag1 == tag);

    wire tag_match    = tag_match0 || tag_match1; // at least one of the two tags matched
    wire cache_hit    = tag_match && is_instruction_fetch;
    wire cache_miss   = !tag_match && is_instruction_fetch;

    // replace way selection.
    // Prefer invalid ways first. If both ways are valid, use the LRU bit.
    wire replace_way_next =
        !valid_array0[index] ? 1'b0 :
        !valid_array1[index] ? 1'b1 :
                               lru_array[index];


    // Lookahead control signals 
    reg [31:0] la_cached_value0;
    reg [31:0] la_cached_value1;

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
        (state == S_IDLE && cache_hit && tag_match0) ? la_cached_value0 : // if cache hit that means we already fetched the instr from cache using LA last cycle
        (state == S_IDLE && cache_hit && tag_match1) ? la_cached_value1 : // Check both way 0 and way 1 
        (state == S_RESP)                            ? miss_rdata : // if not then we're probably filling the cache. 
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
            valid_array0 <= {LINES{1'b0}};
            valid_array1 <= {LINES{1'b0}};
            lru_array    <= {LINES{1'b0}};
            replace_way   <= 1'b0;
            miss_rdata   <= 32'b0;
        end
        else begin
            // On a cache hit, update LRU.
            // If way 0 hit, way 1 becomes the next replacement candidate.
            // If way 1 hit, way 0 becomes the next replacement candidate.
            if(state == S_IDLE && cache_hit) begin
                if(tag_match0)
                    lru_array <= lru_array | index_mask;
                else if(tag_match1)
                    lru_array <= lru_array & ~index_mask;
            end

            // At the start of a miss, choose which way will be filled.
            // This stays fixed for the whole line fill.
            if(state == S_IDLE && cache_miss) begin
                replace_way <= replace_way_next;
            end

            if(state == S_FILL && mem_ready && !replace_way) begin
                // replace_way = 0
                data_array0[cache_fill_addr] <= mem_rdata;
            end

            if(state == S_FILL && mem_ready && replace_way) begin
                // replace_way = 1
                data_array1[cache_fill_addr] <= mem_rdata;
            end

            if(state == S_FILL && mem_ready) begin
                if (fill_offset == word_sel)
                    miss_rdata <= mem_rdata;            

                if (fill_done) begin
                    if(!replace_way) begin
                        tag_array0[index] <= tag;
                        valid_array0 <= valid_array0 | index_mask;

                        // The way we just filled was just used, so the other way is now LRU.
                        // 1 means replace way 1 next.
                        lru_array <= lru_array | index_mask;
                    end
                    else begin
                        tag_array1[index] <= tag;
                        valid_array1 <= valid_array1 | index_mask;

                        // The way we just filled was just used, so the other way is now LRU.
                        // 0 means replace way 0 next.
                        lru_array <= lru_array & ~index_mask;
                    end
                end
            end
        end
    end

    // lookahead cache value/tag/valid flops
    always @(posedge clk) begin
        if (!resetn) begin
            la_cached_value0 <= 32'b0;
            la_cached_value1 <= 32'b0;
            la_cached_tag0   <= {TAG_BITS{1'b0}};
            la_cached_tag1   <= {TAG_BITS{1'b0}};
            la_cached_valid0 <= 1'b0;
            la_cached_valid1 <= 1'b0;
        end
        else if (cpu_mem_la_read) begin
            la_cached_value0 <= data_array0[la_cache_read_addr];
            la_cached_value1 <= data_array1[la_cache_read_addr];

            la_cached_tag0   <= tag_array0[la_index];
            la_cached_tag1   <= tag_array1[la_index];

            la_cached_valid0 <= valid_array0[la_index];
            la_cached_valid1 <= valid_array1[la_index];
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