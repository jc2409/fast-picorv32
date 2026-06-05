`timescale 1 ns / 1 ps
//
// Testbench for the compact divider (picorv32_pcpi_div).
//
// It's a PCPI coprocessor, so to run a divide we drive pcpi_valid with the
// instruction word and the two operands, wait for pcpi_ready, then read
// pcpi_rd. Every result is compared against the plain reference function
// (golden) below. The two RV32M corner cases worth remembering:
//   divide by zero   ->  div/divu give -1,    rem/remu give the dividend
//   INT_MIN / -1      ->  div gives INT_MIN,   rem gives 0
//
// funct3: 100 div, 101 divu, 110 rem, 111 remu (opcode 0110011, funct7 0000001)
//
module div_tb;
    // ---- clock / reset ----
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn;

    // ---- PCPI interface ----
    reg         pcpi_valid;
    reg  [31:0] pcpi_insn;
    reg  [31:0] pcpi_rs1;
    reg  [31:0] pcpi_rs2;
    wire        pcpi_wr;
    wire [31:0] pcpi_rd;
    wire        pcpi_wait;
    wire        pcpi_ready;

    integer errors = 0;
    integer total  = 0;

    picorv32_pcpi_div dut (
        .clk(clk), .resetn(resetn),
        .pcpi_valid(pcpi_valid), .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1), .pcpi_rs2(pcpi_rs2),
        .pcpi_wr(pcpi_wr), .pcpi_rd(pcpi_rd),
        .pcpi_wait(pcpi_wait), .pcpi_ready(pcpi_ready)
    );

    localparam [2:0] F_DIV = 3'b100, F_DIVU = 3'b101, F_REM = 3'b110, F_REMU = 3'b111;

    // reference result.
    // the signed divide has to go through signed temporaries (sa/sb). if you
    // write it inside a ?: that also has unsigned branches, Verilog makes the
    // whole expression unsigned and you get the wrong answer - got caught by
    // this the first time.
    function [31:0] golden;
        input [2:0]  f3;
        input [31:0] a, b;
        reg signed [31:0] sa, sb;
        begin
            sa = a;
            sb = b;
            case (f3)
                F_DIV : begin
                    if      (b == 32'h0)                             golden = 32'hFFFFFFFF;
                    else if (a == 32'h80000000 && b == 32'hFFFFFFFF) golden = 32'h80000000;
                    else                                             golden = sa / sb;
                end
                F_REM : begin
                    if      (b == 32'h0)                             golden = a;
                    else if (a == 32'h80000000 && b == 32'hFFFFFFFF) golden = 32'h0;
                    else                                             golden = sa % sb;
                end
                F_DIVU: golden = (b == 32'h0) ? 32'hFFFFFFFF : a / b;
                F_REMU: golden = (b == 32'h0) ? a            : a % b;
                default: golden = 32'hx;
            endcase
        end
    endfunction

    function [63:0] opname;
        input [2:0] f3;
        case (f3)
            F_DIV : opname = "div ";
            F_DIVU: opname = "divu";
            F_REM : opname = "rem ";
            F_REMU: opname = "remu";
            default: opname = "????";
        endcase
    endfunction

    // issue one op, wait for completion, check
    task do_op;
        input [2:0]  f3;
        input [31:0] a, b;
        reg   [31:0] got, exp;
        integer guard;
        begin
            @(negedge clk);
            pcpi_insn  = {7'b0000001, 5'b0, 5'b0, f3, 5'b0, 7'b0110011};
            pcpi_rs1   = a;
            pcpi_rs2   = b;
            pcpi_valid = 1'b1;
            guard = 0;
            while (pcpi_ready !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 60) begin
                    $display("FATAL: %0s(%08h,%08h) never completed", opname(f3), a, b);
                    errors = errors + 1; $finish;
                end
            end
            got = pcpi_rd;
            // pcpi_wr must accompany the ready pulse
            if (pcpi_wr !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: pcpi_wr not asserted with ready for %0s", opname(f3));
            end
            @(negedge clk);
            pcpi_valid = 1'b0;
            pcpi_insn  = 32'b0;

            exp = golden(f3, a, b);
            total = total + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s(%08h, %08h) = %08h  expected %08h",
                         opname(f3), a, b, got, exp);
            end
        end
    endtask

    // run all four ops on the same operand pair
    task do_all4;
        input [31:0] a, b;
        begin
            do_op(F_DIV,  a, b);
            do_op(F_DIVU, a, b);
            do_op(F_REM,  a, b);
            do_op(F_REMU, a, b);
        end
    endtask

    integer k;
    reg [2:0]  rf3;
    reg [31:0] ra, rb;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("div_tb.vcd");
            $dumpvars(0, div_tb);
        end
        pcpi_valid = 0; pcpi_insn = 0; pcpi_rs1 = 0; pcpi_rs2 = 0;
        resetn = 0;
        repeat (4) @(negedge clk);
        resetn = 1;
        @(negedge clk);

        $display("==== div_tb : picorv32_pcpi_div ====");

        // ---- directed: representative values & both sign combinations ----
        do_all4(32'd1000,        32'd7);
        do_all4(-32'sd1000,      32'd7);
        do_all4(32'd1000,        -32'sd7);
        do_all4(-32'sd1000,      -32'sd7);
        do_all4(32'd0,           32'd123);     // 0 / x
        do_all4(32'd123,         32'd1);       // x / 1
        do_all4(32'd123,         32'd123);     // x / x
        do_all4(32'hFFFFFFFF,    32'hFFFFFFFF); // -1/-1 signed, big/big unsigned
        do_all4(32'h7FFFFFFF,    32'd2);       // INT_MAX
        do_all4(32'h80000000,    32'd2);       // INT_MIN

        // ---- directed: divide by zero for every op ----
        do_all4(32'd12345,       32'd0);
        do_all4(-32'sd12345,     32'd0);
        do_all4(32'h80000000,    32'd0);

        // ---- directed: signed overflow INT_MIN / -1 ----
        do_op(F_DIV, 32'h80000000, 32'hFFFFFFFF);
        do_op(F_REM, 32'h80000000, 32'hFFFFFFFF);

        // ---- randomized ----
        for (k = 0; k < 4000; k = k + 1) begin
            rf3 = {2'b10, 1'b0} | ($random & 3'b011); // one of 100/101/110/111
            ra  = $random;
            rb  = ($random & 7) == 0 ? 32'h0 : $random; // ~1/8 zero divisor
            do_op(rf3, ra, rb);
        end

        if (errors == 0)
            $display("==== ALL TESTS PASSED (%0d ops) ====", total);
        else
            $display("==== FAIL: %0d error(s) of %0d ops ====", errors, total);
        $finish;
    end

    // watchdog
    initial begin
        #5000000;
        $display("FATAL: global timeout");
        $finish;
    end
endmodule
