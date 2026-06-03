/* 
Lookahead buffer that uses LA interface to register
the data RAM's data (and address checked)
1 cycle early so it can be returned with zero cycle delay.

Register the address previously sent in the lookahead
so when the real request comes, we can doublecheck
that we previously did lookahead and then use that
to issue ready back immediately!
Takes the rdata directly from memory interface
*/

module dmem_lookahead_buffer #(
    parameter integer MEM_WORDS = 256,
    parameter integer RAM_ADDR_BITS = $clog2(MEM_WORDS),
    parameter integer RAM_BYTE_BITS = $clog2(4*MEM_WORDS)
) (
    input clk,
    input resetn,

    // CPU-side interface (probably output of icache)
    input             cpu_mem_valid,
    input             cpu_mem_instr,
    input      [31:0] cpu_mem_addr,
    input      [31:0] cpu_mem_wdata,
    input      [3:0]  cpu_mem_wstrb,
    output            cpu_mem_ready,
    output     [31:0] cpu_mem_rdata,

    // CPU lookahead interface (directly from picorv32)
    input             cpu_mem_la_read,
    input      [31:0] cpu_mem_la_addr,

    // Memory system interface (regular)
    output            mem_valid,
    output            mem_instr,
    output     [31:0] mem_addr,
    output     [31:0] mem_wdata,
    output     [3:0]  mem_wstrb,
    input             mem_ready,
    input      [31:0] mem_rdata,

    // Extra RAM control signals
    // MUXed with the regular memory interface signals
    // in picosoc.v.
    output            ram_la_active,
    output     [21:0] ram_la_addr,
    output            dmem_la_hit
);

    // If the lookahead interface shows a memory address targetting data ram
    wire la_addr_in_ram =
        cpu_mem_la_addr[31:RAM_BYTE_BITS] == 0;

    // If the REGULAR interface shows a memory address targetting data ram
    wire req_addr_in_ram =
        cpu_mem_addr[31:RAM_BYTE_BITS] == 0;

    // Whether current req is a lookahead ram read
    wire la_ram_read =
        cpu_mem_la_read &&
        la_addr_in_ram;

    // Store if we had a lookahead last cycle
    reg la_valid;

    // Store the word in RAM that we got through lookahead last cycle
    // should tell us whether RAM returned data this cycle is good 
    // checked by dmem_la_hit
    reg [RAM_ADDR_BITS-1:0] la_word;

    always @(posedge clk) begin
        if (!resetn) begin
            la_valid <= 1'b0;
            la_word  <= 0;
        end else begin
            la_valid <= la_ram_read;
            la_word  <= cpu_mem_la_addr[RAM_ADDR_BITS+1:2]; // [9:2]
        end
    end

    wire real_ram_read =
        cpu_mem_valid &&
        !cpu_mem_instr &&
        cpu_mem_wstrb == 4'b0000 &&
        req_addr_in_ram;

    assign dmem_la_hit =
        la_valid &&
        real_ram_read &&
        la_word == cpu_mem_addr[RAM_ADDR_BITS+1:2];

    // Most signals pass through directly
    // We control the cpu_mem_ready signal directly to send back quickly
    assign cpu_mem_ready = dmem_la_hit || mem_ready;
    assign cpu_mem_rdata = mem_rdata;

    // Intercept the valid signal going to memory system
    // if we got a hit (can just send back ready directly)
    assign mem_valid = dmem_la_hit ? 1'b0 : cpu_mem_valid;
    assign mem_instr = cpu_mem_instr;
    assign mem_addr  = cpu_mem_addr;
    assign mem_wdata = cpu_mem_wdata;
    assign mem_wstrb = cpu_mem_wstrb;

    assign ram_la_active = la_ram_read;
    assign ram_la_addr   = cpu_mem_la_addr[23:2];

endmodule


