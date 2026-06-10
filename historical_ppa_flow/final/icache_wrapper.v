// Wrapper that adds lookahead ports for caches that don't have them.
// If HAS_WORDS_PER_LINE is defined, pass WORDS_PER_LINE to inner cache.
module icache_wrapper #(
    parameter LINES = 16,
    parameter WORDS_PER_LINE = 4
) (
    input clk,
    input resetn,
    input             cpu_mem_valid,
    input             cpu_mem_instr,
    input  [31:0]     cpu_mem_addr,
    input  [31:0]     cpu_mem_wdata,
    input  [3:0]      cpu_mem_wstrb,
    output            cpu_mem_ready,
    output     [31:0] cpu_mem_rdata,
    input             cpu_mem_la_read,
    input      [31:0] cpu_mem_la_addr,
    output            mem_valid,
    output            mem_instr,
    output     [31:0] mem_addr,
    output     [31:0] mem_wdata,
    output     [3:0]  mem_wstrb,
    input             mem_ready,
    input      [31:0] mem_rdata
);
`ifdef HAS_WORDS_PER_LINE
    `CACHE_INNER #(
        .LINES(LINES),
        .WORDS_PER_LINE(WORDS_PER_LINE)
    ) inner (
        .clk(clk),
        .resetn(resetn),
        .cpu_mem_valid(cpu_mem_valid),
        .cpu_mem_instr(cpu_mem_instr),
        .cpu_mem_addr(cpu_mem_addr),
        .cpu_mem_wdata(cpu_mem_wdata),
        .cpu_mem_wstrb(cpu_mem_wstrb),
        .cpu_mem_ready(cpu_mem_ready),
        .cpu_mem_rdata(cpu_mem_rdata),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_ready(mem_ready),
        .mem_rdata(mem_rdata)
    );
`else
    `CACHE_INNER #(
        .LINES(LINES)
    ) inner (
        .clk(clk),
        .resetn(resetn),
        .cpu_mem_valid(cpu_mem_valid),
        .cpu_mem_instr(cpu_mem_instr),
        .cpu_mem_addr(cpu_mem_addr),
        .cpu_mem_wdata(cpu_mem_wdata),
        .cpu_mem_wstrb(cpu_mem_wstrb),
        .cpu_mem_ready(cpu_mem_ready),
        .cpu_mem_rdata(cpu_mem_rdata),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_ready(mem_ready),
        .mem_rdata(mem_rdata)
    );
`endif
endmodule
