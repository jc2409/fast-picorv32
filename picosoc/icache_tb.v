`timescale 1 ns / 1 ps
//
// Testbench for the two instruction caches we actually use:
//   icache_multiword_lookahead       - direct mapped, multiword line, lookahead
//   icache_multiword_lookahead_2way  - 2-way, LRU
//
// Same ports on both. The data sits in block RAM, which has a 1 cycle read, so
// the cache uses the lookahead port to start the read a cycle early and stashes
// it in la_cached_*. That's how a hit comes back without stalling. do_fetch()
// drives that one-cycle-early handshake the same way picorv32 does.
//
// On every fetch we check two things:
//   1. the data matches our memory model (mem[addr>>2])
//   2. hit/miss matches a small model that tracks the same tag/valid/LRU state
//      as the RTL
// Since the model tracks LRU too, if the cache ever evicts the wrong way it
// shows up as a hit/miss mismatch a few fetches later.
//
// ASSOC picks the cache (0 = direct mapped, 1 = 2-way). The wrappers at the
// bottom (tb_dm / tb_2way / tb_2way_eqcap) set it - build one with -s <name>.
// Each run goes through memory latency 1 and then 3 to exercise the fill path.
//

module icache_tb #(
    parameter integer ASSOC          = 0,   // 0 = direct-mapped, 1 = 2-way
    parameter integer LINES          = 8,   // sets (per way for 2-way)
    parameter integer WORDS_PER_LINE = 4,
    parameter integer MEM_WORDS      = 1024
);
    localparam integer WORD_SEL_BITS = $clog2(WORDS_PER_LINE);
    localparam integer IDX_BITS      = $clog2(LINES);
    localparam integer OFF           = WORD_SEL_BITS + 2; // index LSB position
    localparam integer TAGSHIFT      = OFF + IDX_BITS;    // tag LSB position

    // total data the cache holds, in words. the 2-way version has two ways, so
    // the same LINES gives it twice the storage of the direct-mapped one. to
    // compare them fairly, give the 2-way half the LINES (see tb_2way_eqcap).
    localparam integer CAP_WORDS  = (ASSOC ? 2 : 1) * LINES * WORDS_PER_LINE;
    localparam integer CAP_LINES  = (ASSOC ? 2 : 1) * LINES;

    // ---- clock / reset ----------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;        // 100 MHz
    reg resetn;

    // ---- DUT <-> CPU signals ----------------------------------------------
    reg         cpu_mem_valid;
    reg         cpu_mem_instr;
    reg  [31:0] cpu_mem_addr;
    reg  [31:0] cpu_mem_wdata;
    reg  [3:0]  cpu_mem_wstrb;
    wire        cpu_mem_ready;
    wire [31:0] cpu_mem_rdata;
    reg         cpu_mem_la_read;
    reg  [31:0] cpu_mem_la_addr;

    // ---- DUT <-> memory signals -------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg         mem_ready;
    reg  [31:0] mem_rdata;

    // ---- bookkeeping ------------------------------------------------------
    integer errors  = 0;
    integer hits    = 0;
    integer misses  = 0;
    integer i;
    integer mem_latency;          // runtime-adjustable fill latency

    // =======================================================================
    // Behavioural memory model
    // =======================================================================
    reg [31:0] mem [0:MEM_WORDS-1];
    integer    lat;

    // fill memory with an address-dependent pattern so a wrong word stands out
    task mem_init;
        integer k;
        begin
            for (k = 0; k < MEM_WORDS; k = k + 1)
                mem[k] = (k ^ (k << 7) ^ (k << 16)) ^ 32'h9E3779B9;
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready <= 1'b0;
            lat       <= 0;
        end else begin
            mem_ready <= 1'b0;
            if (mem_valid && !mem_ready) begin
                if (lat >= mem_latency - 1) begin
                    lat       <= 0;
                    mem_ready <= 1'b1;
                    mem_rdata <= mem[mem_addr[2 +: $clog2(MEM_WORDS)]];
                    if (mem_wstrb[0]) mem[mem_addr[2 +: $clog2(MEM_WORDS)]][ 7: 0] <= mem_wdata[ 7: 0];
                    if (mem_wstrb[1]) mem[mem_addr[2 +: $clog2(MEM_WORDS)]][15: 8] <= mem_wdata[15: 8];
                    if (mem_wstrb[2]) mem[mem_addr[2 +: $clog2(MEM_WORDS)]][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) mem[mem_addr[2 +: $clog2(MEM_WORDS)]][31:24] <= mem_wdata[31:24];
                end else begin
                    lat <= lat + 1;
                end
            end else begin
                lat <= 0;
            end
        end
    end

    // =======================================================================
    // DUT instantiation (only the selected cache is elaborated)
    // =======================================================================
    generate
        if (ASSOC == 0) begin : g_dm
            icache_multiword_lookahead #(
                .LINES(LINES), .WORDS_PER_LINE(WORDS_PER_LINE)
            ) dut (
                .clk(clk), .resetn(resetn),
                .cpu_mem_valid(cpu_mem_valid), .cpu_mem_instr(cpu_mem_instr),
                .cpu_mem_addr(cpu_mem_addr),   .cpu_mem_wdata(cpu_mem_wdata),
                .cpu_mem_wstrb(cpu_mem_wstrb), .cpu_mem_ready(cpu_mem_ready),
                .cpu_mem_rdata(cpu_mem_rdata),
                .cpu_mem_la_read(cpu_mem_la_read), .cpu_mem_la_addr(cpu_mem_la_addr),
                .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_addr(mem_addr),
                .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
                .mem_ready(mem_ready), .mem_rdata(mem_rdata)
            );
        end else begin : g_2way
            icache_multiword_lookahead_2way #(
                .LINES(LINES), .WORDS_PER_LINE(WORDS_PER_LINE)
            ) dut (
                .clk(clk), .resetn(resetn),
                .cpu_mem_valid(cpu_mem_valid), .cpu_mem_instr(cpu_mem_instr),
                .cpu_mem_addr(cpu_mem_addr),   .cpu_mem_wdata(cpu_mem_wdata),
                .cpu_mem_wstrb(cpu_mem_wstrb), .cpu_mem_ready(cpu_mem_ready),
                .cpu_mem_rdata(cpu_mem_rdata),
                .cpu_mem_la_read(cpu_mem_la_read), .cpu_mem_la_addr(cpu_mem_la_addr),
                .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_addr(mem_addr),
                .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
                .mem_ready(mem_ready), .mem_rdata(mem_rdata)
            );
        end
    endgenerate

    // =======================================================================
    // Golden reference model (mirrors the RTL tag/valid/LRU state)
    // =======================================================================
    reg              ref_v_dm [0:LINES-1];   // direct-mapped
    reg [31:0]       ref_t_dm [0:LINES-1];
    reg              ref_v0   [0:LINES-1];    // 2-way
    reg              ref_v1   [0:LINES-1];
    reg [31:0]       ref_t0   [0:LINES-1];
    reg [31:0]       ref_t1   [0:LINES-1];
    reg              ref_lru  [0:LINES-1];

    function [IDX_BITS-1:0] idx_of;
        input [31:0] a;
        idx_of = a[OFF +: IDX_BITS];
    endfunction

    function [31:0] tag_of;
        input [31:0] a;
        tag_of = a >> TAGSHIFT;
    endfunction

    // predict hit using current reference state
    function ref_predict_hit;
        input [31:0] a;
        reg [IDX_BITS-1:0] ix;
        reg [31:0] tg;
        begin
            ix = idx_of(a);
            tg = tag_of(a);
            if (ASSOC == 0)
                ref_predict_hit = ref_v_dm[ix] && (ref_t_dm[ix] == tg);
            else
                ref_predict_hit = (ref_v0[ix] && ref_t0[ix] == tg) ||
                                  (ref_v1[ix] && ref_t1[ix] == tg);
        end
    endfunction

    // update the reference the same way the RTL would on this access
    task ref_update;
        input [31:0] a;
        input        was_hit;
        reg [IDX_BITS-1:0] ix;
        reg [31:0] tg;
        reg way;
        begin
            ix = idx_of(a);
            tg = tag_of(a);
            if (ASSOC == 0) begin
                if (!was_hit) begin
                    ref_v_dm[ix] = 1'b1;
                    ref_t_dm[ix] = tg;
                end
            end else begin
                if (was_hit) begin
                    // hit way becomes MRU -> LRU points at the *other* way
                    if (ref_v0[ix] && ref_t0[ix] == tg) ref_lru[ix] = 1'b1; // replace way1 next
                    else                                ref_lru[ix] = 1'b0; // replace way0 next
                end else begin
                    way = !ref_v0[ix] ? 1'b0 :
                          !ref_v1[ix] ? 1'b1 :
                                        ref_lru[ix];
                    if (!way) begin
                        ref_v0[ix] = 1'b1; ref_t0[ix] = tg; ref_lru[ix] = 1'b1;
                    end else begin
                        ref_v1[ix] = 1'b1; ref_t1[ix] = tg; ref_lru[ix] = 1'b0;
                    end
                end
            end
        end
    endtask

    // =======================================================================
    // Stimulus helpers
    // =======================================================================

    // reset the DUT and clear the reference model together so they stay in sync
    task do_reset;
        begin
            @(negedge clk);
            resetn          = 1'b0;
            cpu_mem_valid   = 1'b0;
            cpu_mem_instr   = 1'b0;
            cpu_mem_addr    = 32'b0;
            cpu_mem_wdata   = 32'b0;
            cpu_mem_wstrb   = 4'b0;
            cpu_mem_la_read = 1'b0;
            cpu_mem_la_addr = 32'b0;
            repeat (4) @(negedge clk);
            resetn = 1'b1;
            @(negedge clk);
            for (i = 0; i < LINES; i = i + 1) begin
                ref_v_dm[i] = 1'b0; ref_t_dm[i] = 32'b0;
                ref_v0[i]   = 1'b0; ref_t0[i]   = 32'b0;
                ref_v1[i]   = 1'b0; ref_t1[i]   = 32'b0;
                ref_lru[i]  = 1'b0;
            end
            hits = 0; misses = 0;
        end
    endtask

    // do one instruction fetch over the lookahead handshake and check it
    task do_fetch;
        input [31:0] addr;
        reg        pred_hit;
        reg        meas_hit;
        reg [31:0] got, exp;
        integer    guard;
        begin
            exp      = mem[addr >> 2];
            pred_hit = ref_predict_hit(addr);

            // cycle 1: put the address on the lookahead port
            @(negedge clk);
            cpu_mem_la_read = 1'b1;
            cpu_mem_la_addr = addr;
            cpu_mem_valid   = 1'b0;
            cpu_mem_instr   = 1'b1;
            cpu_mem_wstrb   = 4'b0;

            // cycle 2: actually request it
            @(negedge clk);
            cpu_mem_la_read = 1'b0;
            cpu_mem_valid   = 1'b1;
            cpu_mem_addr    = addr;
            #1;
            meas_hit = (cpu_mem_ready === 1'b1); // ready already high = hit
            if (meas_hit) begin
                got = cpu_mem_rdata;
                @(negedge clk);                  // let the posedge update LRU
                cpu_mem_valid = 1'b0;
            end else begin
                guard = 0;
                while (cpu_mem_ready !== 1'b1) begin
                    @(negedge clk); #1;
                    guard = guard + 1;
                    if (guard > 1000) begin
                        $display("FATAL: fetch @%08h hung waiting for ready", addr);
                        errors = errors + 1; $finish;
                    end
                end
                got = cpu_mem_rdata;
                @(negedge clk);
                cpu_mem_valid = 1'b0;
            end

            // --- checks ---
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL data  @%08h  got %08h exp %08h", addr, got, exp);
            end
            if (meas_hit !== pred_hit) begin
                errors = errors + 1;
                $display("FAIL h/m   @%08h  measured %s expected %s",
                         addr, meas_hit ? "HIT " : "MISS", pred_hit ? "HIT " : "MISS");
            end
            if (meas_hit) hits = hits + 1; else misses = misses + 1;

            ref_update(addr, pred_hit);
        end
    endtask

    // non-cached passthrough access (store or non-instruction load)
    task do_passthrough;
        input [31:0] addr;
        input [3:0]  wstrb;
        input [31:0] wdata;
        input        check_read;   // 1 => verify rdata == mem[addr]
        reg [31:0] got, exp;
        integer    guard;
        begin
            exp = mem[addr >> 2];
            @(negedge clk);
            cpu_mem_la_read = 1'b0;
            cpu_mem_valid   = 1'b1;
            cpu_mem_instr   = 1'b0;     // not an instruction fetch -> bypass
            cpu_mem_addr    = addr;
            cpu_mem_wstrb   = wstrb;
            cpu_mem_wdata   = wdata;
            guard = 0; #1;
            while (cpu_mem_ready !== 1'b1) begin
                @(negedge clk); #1;
                guard = guard + 1;
                if (guard > 1000) begin
                    $display("FATAL: passthrough @%08h hung", addr);
                    errors = errors + 1; $finish;
                end
            end
            got = cpu_mem_rdata;
            @(negedge clk);
            cpu_mem_valid = 1'b0;
            cpu_mem_wstrb = 4'b0;
            cpu_mem_instr = 1'b0;
            if (check_read && got !== exp) begin
                errors = errors + 1;
                $display("FAIL pass  @%08h  got %08h exp %08h", addr, got, exp);
            end
        end
    endtask

    // assert running miss count equals an expected value
    task expect_misses;
        input integer n;
        input [255:0] label;
        begin
            if (misses !== n) begin
                errors = errors + 1;
                $display("FAIL %0s: misses=%0d expected %0d", label, misses, n);
            end else begin
                $display("  ok  %0s: hits=%0d misses=%0d", label, hits, misses);
            end
        end
    endtask

    // =======================================================================
    // Test sequences
    // =======================================================================
    localparam [31:0] TAG_STEP = (32'd1 << TAGSHIFT); // +1 tag, same index 0

    task test_cold_fill_and_rehit;
        integer w;
        begin
            do_reset;
            // first word misses and fills the whole line; rest of line hits
            for (w = 0; w < WORDS_PER_LINE; w = w + 1)
                do_fetch(w * 4);
            // re-touch the line: every word now hits
            for (w = 0; w < WORDS_PER_LINE; w = w + 1)
                do_fetch(w * 4);
            expect_misses(1, "cold fill + rehit");
        end
    endtask

    task test_sequential_walk;
        integer a;
        begin
            do_reset;
            // walk exactly LINES distinct lines (no aliasing): the first word
            // of each line misses and fills it, every other word hits.
            for (a = 0; a < LINES * WORDS_PER_LINE * 4; a = a + 4)
                do_fetch(a);
            expect_misses(LINES, "sequential walk (one pass over LINES lines)");
        end
    endtask

    task test_conflict;
        begin
            do_reset;
            // two addresses, same index 0, different tags
            do_fetch(32'h0);             // miss
            do_fetch(TAG_STEP);          // miss
            do_fetch(32'h0);
            do_fetch(TAG_STEP);
            do_fetch(32'h0);
            do_fetch(TAG_STEP);
            if (ASSOC == 0)
                expect_misses(6, "conflict (direct-mapped thrash)");
            else
                expect_misses(2, "conflict (2-way keeps both)");
        end
    endtask

    task test_lru_eviction;   // 2-way only
        begin
            do_reset;
            do_fetch(32'h0);            // miss -> way0 (lru=>replace way1)
            do_fetch(TAG_STEP);         // miss -> way1 (lru=>replace way0)
            do_fetch(32'h0);            // hit way0 -> lru=>replace way1
            do_fetch(2*TAG_STEP);       // miss -> replaces way1 (evicts TAG_STEP)
            do_fetch(32'h0);            // hit (way0 survived)
            do_fetch(2*TAG_STEP);       // hit (way1)
            do_fetch(TAG_STEP);         // miss (was evicted)
            expect_misses(4, "2-way LRU eviction");
        end
    endtask

    task test_passthrough;
        reg [31:0] a;
        begin
            do_reset;
            a = 32'h200;
            // store via passthrough, then read back via passthrough
            do_passthrough(a, 4'b1111, 32'hDEADBEEF, 1'b0);
            mem[a >> 2] = 32'hDEADBEEF;             // mirror into model
            do_passthrough(a, 4'b0000, 32'h0, 1'b1); // non-instr load returns stored value
            // a passthrough must NOT populate the cache:
            do_fetch(a);                             // expect MISS (ref says not cached)
            do_fetch(a);                             // now a HIT
            $display("  ok  passthrough bypass (no cache pollution)");
        end
    endtask

    task test_random;
        input integer n;
        integer k;
        reg [31:0] a;
        begin
            do_reset;
            for (k = 0; k < n; k = k + 1) begin
                a = ($random & 32'h3FC); // word-aligned, 0..0x3FC (8x cache size)
                do_fetch(a);
            end
            $display("  ok  random %0d fetches: hits=%0d misses=%0d  hit-rate=%0d.%0d%%  [cap=%0d words / %0d lines]",
                     n, hits, misses,
                     (hits * 100) / n, ((hits * 1000) / n) % 10,
                     CAP_WORDS, CAP_LINES);
        end
    endtask

    // =======================================================================
    // Main
    // =======================================================================
    task run_all;
        begin
            test_cold_fill_and_rehit;
            test_sequential_walk;
            test_conflict;
            if (ASSOC == 1) test_lru_eviction;
            test_passthrough;
            test_random(2000);
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("icache_tb.vcd");
            $dumpvars(0, icache_tb);
        end
        $display("==== icache_tb : %s, LINES=%0d WORDS_PER_LINE=%0d  -> capacity %0d words (%0d lines) ====",
                 ASSOC ? "2-way assoc" : "direct-mapped", LINES, WORDS_PER_LINE,
                 CAP_WORDS, CAP_LINES);
        mem_init;

        mem_latency = 1;
        $display("-- memory latency = 1 --");
        run_all;

        mem_latency = 3;
        $display("-- memory latency = 3 --");
        run_all;

        if (errors == 0)
            $display("==== ALL TESTS PASSED (%s) ====",
                     ASSOC ? "2-way" : "direct-mapped");
        else
            $display("==== FAIL: %0d error(s) (%s) ====",
                     errors, ASSOC ? "2-way" : "direct-mapped");
        $finish;
    end

    // global watchdog
    initial begin
        #5000000;
        $display("FATAL: global timeout");
        $finish;
    end
endmodule

// top wrappers - pick one with iverilog -s
module tb_dm;
    icache_tb #(.ASSOC(0)) u();
endmodule

module tb_2way;
    icache_tb #(.ASSOC(1)) u();   // LINES=8 -> 16 lines / 64 words (2x tb_dm)
endmodule

// 2-way shrunk to the same capacity as tb_dm: half the LINES (4 sets x 2 ways
// = 8 lines, 32 words). Use this against tb_dm so the only thing that changes
// is associativity, not size.
module tb_2way_eqcap;
    icache_tb #(.ASSOC(1), .LINES(4)) u();
endmodule
