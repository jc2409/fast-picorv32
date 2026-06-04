`timescale 1ns / 1ps

module dmem_lookahead_buffer_tb ();

    localparam integer MEM_WORDS = 256;
    localparam integer RAM_ADDR_BITS = 8;
    localparam integer RAM_BYTE_BITS = 10;

    reg clk;
    reg resetn;

    reg         cpu_mem_valid;
    reg         cpu_mem_instr;
    reg [31:0]  cpu_mem_addr;
    reg [31:0]  cpu_mem_wdata;
    reg [3:0]   cpu_mem_wstrb;
    wire        cpu_mem_ready;
    wire [31:0] cpu_mem_rdata;

    reg         cpu_mem_la_read;
    reg [31:0]  cpu_mem_la_addr;

    wire        mem_valid;
    wire        mem_instr;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg         mem_ready;
    reg [31:0]  mem_rdata;

    wire        ram_la_active;
    wire [21:0] ram_la_addr;
    wire        dmem_la_hit;

    reg [31:0] ram [0:MEM_WORDS-1];

    integer errors;
    integer i;

    dmem_lookahead_buffer #(
        .MEM_WORDS(MEM_WORDS),
        .RAM_ADDR_BITS(RAM_ADDR_BITS),
        .RAM_BYTE_BITS(RAM_BYTE_BITS)
    ) dut (
        .clk(clk),
        .resetn(resetn),

        .cpu_mem_valid(cpu_mem_valid),
        .cpu_mem_instr(cpu_mem_instr),
        .cpu_mem_addr(cpu_mem_addr),
        .cpu_mem_wdata(cpu_mem_wdata),
        .cpu_mem_wstrb(cpu_mem_wstrb),
        .cpu_mem_ready(cpu_mem_ready),
        .cpu_mem_rdata(cpu_mem_rdata),

        .cpu_mem_la_read(cpu_mem_la_read),
        .cpu_mem_la_addr(cpu_mem_la_addr),

        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_ready(mem_ready),
        .mem_rdata(mem_rdata),

        .ram_la_active(ram_la_active),
        .ram_la_addr(ram_la_addr),
        .dmem_la_hit(dmem_la_hit)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    /*
        Simple RAM model for test bench purposes - model the bram. 

        If the DUT asks for a lookahead RAM read, this RAM puts the requested
        word into mem_rdata on the next clock edge.

        That means on the following cycle, if the real CPU request matches,
        the DUT can immediately return mem_rdata.
    */
    always @(posedge clk) begin
        if (ram_la_active) begin
            mem_rdata <= ram[ram_la_addr[RAM_ADDR_BITS-1:0]];
        end 
        else if (mem_valid && !mem_instr && mem_wstrb == 4'b0000 &&
                     mem_addr[31:RAM_BYTE_BITS] == 0) begin
            mem_rdata <= ram[mem_addr[RAM_ADDR_BITS+1:2]];
        end
    end

    task wait_clk;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task clear_cpu_signals;
        begin
            cpu_mem_valid   = 0;
            cpu_mem_instr   = 0;
            cpu_mem_addr    = 0;
            cpu_mem_wdata   = 0;
            cpu_mem_wstrb   = 0;
            cpu_mem_la_read = 0;
            cpu_mem_la_addr = 0;
        end
    endtask

    task do_reset;
        begin
            resetn = 0;
            clear_cpu_signals();
            mem_ready = 0;
            mem_rdata = 32'h00000000;

            wait_clk();
            wait_clk();

            resetn = 1;
            wait_clk();
        end
    endtask

    task issue_lookahead;
        input [31:0] addr;
        begin
            cpu_mem_la_read = 1;
            cpu_mem_la_addr = addr;

            wait_clk();

            cpu_mem_la_read = 0;
            cpu_mem_la_addr = 0;
            #1;
        end
    endtask

    task set_real_read;
        input [31:0] addr;
        begin
            cpu_mem_valid = 1;
            cpu_mem_instr = 0;
            cpu_mem_addr  = addr;
            cpu_mem_wstrb = 4'b0000;
            cpu_mem_wdata = 32'h00000000;
            #1;
        end
    endtask

    task set_real_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            cpu_mem_valid = 1;
            cpu_mem_instr = 0;
            cpu_mem_addr  = addr;
            cpu_mem_wstrb = 4'b1111;
            cpu_mem_wdata = data;
            #1;
        end
    endtask

    task set_instr_fetch;
        input [31:0] addr;
        begin
            cpu_mem_valid = 1;
            cpu_mem_instr = 1;
            cpu_mem_addr  = addr;
            cpu_mem_wstrb = 4'b0000;
            cpu_mem_wdata = 32'h00000000;
            #1;
        end
    endtask

    task check_bit;
        input value;
        input expected;
        input [200*8:1] name;
        begin
            if (value === expected) begin
                $display("PASS: %0s = %b", name, expected);
            end else begin
                $display("FAIL: %0s expected %b, got %b",
                         name, expected, value);
                errors = errors + 1;
            end
        end
    endtask

    task check_word;
        input [31:0] value;
        input [31:0] expected;
        input [200*8:1] name;
        begin
            if (value === expected) begin
                $display("PASS: %0s = %08h", name, expected);
            end else begin
                $display("FAIL: %0s expected %08h, got %08h",
                         name, expected, value);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("dmem_lookahead_buffer_tb.vcd");
        $dumpvars(0, dmem_lookahead_buffer_tb);

        errors = 0;

        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            ram[i] = 32'h10000000 + i;
        end

        $display("=== Starting dmem_lookahead_buffer testbench ===");

        do_reset();

        $display("");
        $display("=== TEST 1: After reset, no lookahead hit ===");

        set_real_read(32'h00000020); // word 8
        check_bit(dmem_la_hit, 1'b0, "dmem_la_hit");
        check_bit(cpu_mem_ready, 1'b0, "cpu_mem_ready");
        check_bit(mem_valid, 1'b1, "mem_valid");
        clear_cpu_signals();

        $display("");
        $display("=== TEST 2: Matching lookahead gives hit on next cycle ===");

        issue_lookahead(32'h00000020); // word 8
        set_real_read(32'h00000020);

        check_bit(dmem_la_hit, 1'b1, "dmem_la_hit");
        check_bit(cpu_mem_ready, 1'b1, "cpu_mem_ready");
        check_bit(mem_valid, 1'b0, "mem_valid = 0");
        check_word(cpu_mem_rdata, ram[8], "cpu_mem_rdata");

        clear_cpu_signals();
        wait_clk();

        $display("");
        $display("=== TEST 3: Different real address does not hit ===");
        // If for some reason CPU sends a different address next cycle

        issue_lookahead(32'h00000020); // word 8
        set_real_read(32'h00000024);   // word 9

        check_bit(dmem_la_hit, 1'b0, "dmem_la_hit");
        check_bit(cpu_mem_ready, 1'b0, "cpu_mem_ready");
        check_bit(mem_valid, 1'b1, "mem_valid passed through");
        check_word(mem_addr, 32'h00000024, "mem_addr");

        clear_cpu_signals();
        wait_clk();

        $display("");
        $display("=== TEST 4: Writes do not use lookahead hit ===");

        issue_lookahead(32'h00000020);
        set_real_write(32'h00000020, 32'h11111111);

        check_bit(dmem_la_hit, 1'b0, "dmem_la_hit");
        check_bit(mem_valid, 1'b1, "mem_valid passed through");
        check_word(mem_wdata, 32'h11111111, "mem_wdata");

        clear_cpu_signals();
        wait_clk();

        $display("");
        $display("=== TEST 5: Instruction fetch does not use data lookahead hit ===");

        issue_lookahead(32'h00000020);
        set_instr_fetch(32'h00000020);

        check_bit(dmem_la_hit, 1'b0, "dmem_la_hit");
        check_bit(mem_valid, 1'b1, "mem_valid passed through");
        check_bit(mem_instr, 1'b1, "mem_instr");

        clear_cpu_signals();
        wait_clk();

        $display("");
        $display("=== TEST 6: Out-of-RAM lookahead is ignored ===");

        cpu_mem_la_read = 1;
        cpu_mem_la_addr = 32'h00000400; // just outside 256 words = 1024 bytes

        #1;
        check_bit(ram_la_active, 1'b0, "ram_la_active");

        wait_clk();

        cpu_mem_la_read = 0;
        set_real_read(32'h00000400);

        check_bit(dmem_la_hit, 1'b0, "dmem_la_hit");
        check_bit(mem_valid, 1'b1, "mem_valid passed through");

        clear_cpu_signals();
        wait_clk();

        $display("");
        $display("=== TEST 7: Normal mem_ready still passes through ===");

        mem_ready = 1;
        set_real_read(32'h00000030); // no lookahead needed

        check_bit(dmem_la_hit, 1'b0, "dmem_la_hit");
        check_bit(cpu_mem_ready, 1'b1, "cpu_mem_ready from mem_ready");
        check_bit(mem_valid, 1'b1, "mem_valid");

        clear_cpu_signals();
        mem_ready = 0;
        wait_clk();

        $display("");
        if (errors == 0)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== TESTBENCH FINISHED WITH %0d ERRORS ===", errors);

        $finish;
    end

endmodule