    // ------------------------------------------------------------------
    // AXI byte provenance. Facts originate ONLY at public AR/R handshakes;
    // never from mem[], DUT RAM, emit_valid, or DUT address/beat counters.
    // Independent FIFO tracks full 32-bit addresses (no memory-model alias).
    // Check actual multiplier inputs, then retire the evidence with mac_valid:
    // the streaming filter multiplies on R, but accumulates one cycle later.
    // Thus every consumed byte has a strictly EARLIER accepted R beat.
    // ------------------------------------------------------------------
    `define PE dut.u_burst_dot_product
    integer trace_fd = 0;
    string trace_path;
    integer sb_violations = 0, sb_rbeats = 0, sb_mac_bytes = 0;
    integer sb_stream_bytes = 0, sb_fast_bytes = 0, sb_call = 0;
    integer sb_epoch = 0, sb_ar_no = 0, sb_head = 0, sb_tail = 0;
    integer sb_b [0:15], sb_beat [0:15];
    reg [31:0] sb_addr [0:15];
    bit sb_filter [0:15];
    bit sb_armed = 0, sb_fc_enabled = 0, sb_rv = 0, sb_fv = 0;
    bit sb_running = 0, sb_failed = 0, sb_append = 0;
    reg [31:0] sb_n = 0, sb_a, sb_bptr, sb_key_a, sb_key_n;
    reg [31:0] sb_fc_lo, sb_fc_hi, sb_fc_end;
    integer sb_off = 0, sb_input_floor = 0, sb_filter_floor = 0;
    integer sb_call_bytes = 0, sb_fast_row = 0;
    // Last AXI evidence for each input ring slot / cached filter word.
    reg [31:0] sb_idata [0:1023], sb_iaddr [0:1023];
    integer sb_iseq [0:1023], sb_icycle [0:1023], sb_iepoch [0:1023];
    reg [31:0] sb_fdata [0:32767], sb_faddr [0:32767];
    integer sb_fseq [0:32767], sb_fcycle [0:32767], sb_fepoch [0:32767];
    // Two independent expected MAC pipeline slots: streaming one cycle;
    // cache products -> sum -> accumulator two cycles. Each includes BOTH
    // operands, not just ptr1. A missing/extra MAC pulse is also an error.
    integer sb_count [0:1];
    reg [31:0] sb_sum [0:1];
    bit sb_local [0:1];
    reg [31:0] sb_maddr [0:1][0:63];
    reg [7:0] sb_mdata [0:1][0:63];
    integer sb_mseq [0:1][0:63], sb_mcycle [0:1][0:63];
    wire [31:0] sb_fast_mask;
    genvar ps;
    generate for (ps=0; ps<32; ps=ps+1) begin : provenance_mask
        assign sb_fast_mask[ps] = `PE.flanes[ps].v;
    end endgenerate

    task automatic provenance_check(input bit ok, input string why);
        if (!ok) begin
            sb_violations++;
            check(0, {"AXI_PROVENANCE: ", why});
        end
    endtask

    task automatic provenance_byte(input integer slot, input bit filter_side,
                                    input bit local_path, input [31:0] addr,
                                    input [7:0] actual, input [31:0] bus_addr,
                                    input [31:0] bus_data, input integer bus_seq);
        integer ix, seq, cyc, epoch, floor_cycle, j;
        reg [31:0] word_addr, word_data;
        reg [7:0] expected;
        begin
            word_addr = 0; word_data = 0; seq = 0; cyc = 0; epoch = -1;
            floor_cycle = sb_input_floor;
            if (!filter_side) begin
                ix = ((addr >> 2) - (sb_a >> 2)) % 1024;
                word_addr = sb_iaddr[ix]; word_data = sb_idata[ix];
                seq = sb_iseq[ix]; cyc = sb_icycle[ix]; epoch = sb_iepoch[ix];
            end else if (local_path) begin
                ix = ((addr & 32'hfffffffc) - sb_fc_lo) / 4;
                floor_cycle = sb_filter_floor;
                provenance_check(ix >= 0 && ix < 32768, "filter evidence index outside cache");
                if (ix >= 0 && ix < 32768) begin
                    word_addr = sb_faddr[ix]; word_data = sb_fdata[ix];
                    seq = sb_fseq[ix]; cyc = sb_fcycle[ix]; epoch = sb_fepoch[ix];
                end
            end else begin
                word_addr = bus_addr; word_data = bus_data;
                seq = bus_seq; cyc = cycle_number; epoch = sb_epoch;
                floor_cycle = cycle_number;
            end
            expected = word_data >> (8*addr[1:0]);
            provenance_check(seq > 0 && word_addr === (addr & 32'hfffffffc) &&
                             epoch == sb_epoch && cyc >= floor_cycle &&
                             actual === expected,
                $sformatf("call=%0d ptr%0d addr=%h got=%h Raddr=%h Rdata=%h Rseq=%0d Rcycle=%0d floor=%0d epoch=%0d/%0d",
                          sb_call, filter_side+1, addr, actual, word_addr, expected,
                          seq, cyc, floor_cycle, epoch, sb_epoch));
            // ptr1 / local ptr2 must exist even BEFORE the multiply edge.
            if (!filter_side || local_path)
                provenance_check(cyc < cycle_number, "local byte not from an earlier R beat");
            j = sb_count[slot];
            sb_maddr[slot][j] = addr; sb_mdata[slot][j] = actual;
            sb_mseq[slot][j] = seq; sb_mcycle[slot][j] = cyc;
            sb_count[slot]++;
        end
    endtask

    // Called before the AXI slave mutates its queue. All DUT signals sampled
    // pre-NBA, at the exact edge on which its MAC/storage consume them.
    task automatic provenance_tick;
        integer j, s, ix, pos, term, lane_count, slot;
        reg [31:0] addr, end_addr, fstart, fend;
        reg [7:0] av, bv;
        reg [3:0] mask;
        bit good, filter_beat, hit, full_hit, valid_lane;
        begin
            if (`PE.mac_valid || sb_count[0] != 0) begin
                provenance_check(`PE.mac_valid === (sb_count[0] != 0), "missing/extra MAC retirement");
                provenance_check(`PE.mac_sum === sb_sum[0][21:0], "MAC sum not formed from traced operands");
                for (j=0; j<sb_count[0]; j++) begin
                    provenance_check(sb_mcycle[0][j] < cycle_number, "MAC byte lacks strictly earlier R beat");
                    if (trace_fd) $fdisplay(trace_fd, "M,%0d,%0d,%0d,%h,%h,%0d,%0d,%0d",
                        sb_call, cycle_number, j%2+1, sb_maddr[0][j], sb_mdata[0][j],
                        sb_mseq[0][j], sb_mcycle[0][j], sb_local[0]);
                end
                sb_mac_bytes += sb_count[0]; sb_call_bytes += sb_count[0];
                if (sb_local[0]) sb_fast_bytes += sb_count[0];
                else sb_stream_bytes += sb_count[0];
            end
            sb_count[0] = sb_count[1]; sb_sum[0] = sb_sum[1]; sb_local[0] = sb_local[1];
            for (j=0; j<sb_count[1]; j++) begin
                sb_maddr[0][j] = sb_maddr[1][j]; sb_mdata[0][j] = sb_mdata[1][j];
                sb_mseq[0][j] = sb_mseq[1][j]; sb_mcycle[0][j] = sb_mcycle[1][j];
            end
            sb_count[1] = 0; sb_sum[1] = 0;
            // Retire the OLD command before accepting a back-to-back start;
            // a SET/REUSE done pulse must never terminate the new COMPUTE.
            if (npu_done && sb_running) begin
                provenance_check(sb_head == sb_tail && sb_count[0] == 0 && sb_count[1] == 0,
                                 "done with AXI/MAC evidence pending");
                if (!sb_failed) provenance_check(sb_call_bytes == 2*sb_n, "not exactly N bytes per MAC operand");
                sb_rv = sb_armed && !sb_failed && sb_n != 0 && (sb_n+sb_a[1:0]+3)/4 <= 1024;
                if (sb_failed) sb_fv = 0;
                else if (sb_append) begin sb_fv = 1; sb_fc_hi = sb_fc_end; end
                if (trace_fd) $fdisplay(trace_fd, "D,%0d,%0d,%0d,%0d", sb_call, cycle_number, sb_failed, sb_call_bytes);
                sb_running = 0;
            end
            if (npu_start && dut.state_r == 0) begin
                if (funct3_i[2:0] == 4) begin
                    if (funct7_i == 0 || funct7_i == 5) begin
                        sb_n = rs1_i;
                        sb_off = (funct7_i == 0) ? int'($signed(rs2_i[7:0])) : int'($signed(rs2_i[8:0]));
                    end
                    if (funct7_i == 3 || funct7_i == 4) begin
                        sb_epoch++; sb_rv = 0; sb_fv = 0;
                        sb_armed = rs1_i[0]; sb_fc_enabled = sb_armed && funct7_i == 4;
                        if (trace_fd) $fdisplay(trace_fd, "E,%0d,%0d,%0d,%0d", cycle_number, sb_epoch, funct7_i, rs1_i[0]);
                    end
                    if (funct7_i == 1) begin
                        provenance_check(sb_head == sb_tail && !sb_running && sb_count[0] == 0,
                                         "COMPUTE while provenance pending");
                        sb_call++; sb_ar_no = 0; sb_a = rs1_i; sb_bptr = rs2_i;
                        hit = sb_armed && sb_rv && sb_a == sb_key_a && sb_n == sb_key_n;
                        if (!hit) begin
                            sb_input_floor = cycle_number;
                            sb_key_a = sb_a; sb_key_n = sb_n;
                        end
                        fstart = sb_bptr & 32'hfffffffc;
                        fend = fstart + 4*((sb_n + sb_bptr[1:0] + 3)/4);
                        full_hit = sb_fc_enabled && hit && sb_fv && fstart >= sb_fc_lo &&
                                   fend <= sb_fc_hi && sb_a[1:0] == sb_bptr[1:0] && sb_n != 0;
                        sb_append = !full_hit && sb_fc_enabled && sb_n != 0 &&
                            (!sb_fv || (fstart >= sb_fc_lo && fstart <= sb_fc_hi && fend > sb_fc_hi)) &&
                            (fend - (sb_fv ? sb_fc_lo : fstart) <= 131072);
                        if (sb_append && !sb_fv) begin
                            sb_fc_lo = fstart; sb_fc_hi = fstart; sb_filter_floor = cycle_number;
                        end
                        sb_fc_end = fend;
                        sb_running = 1; sb_failed = 0; sb_call_bytes = 0; sb_fast_row = 0;
                        if (trace_fd) $fdisplay(trace_fd, "C,%0d,%0d,%h,%h,%0d,%0d,%0d,%0d,%0d",
                            sb_call, cycle_number, sb_a, sb_bptr, sb_n, sb_off, sb_epoch, hit, full_hit);
                    end
                end
                if (funct3_i[2:0] == 2) begin sb_epoch++; sb_rv = 0; sb_fv = 0; end
            end
            if (arvalid && arready) begin
                provenance_check(sb_tail-sb_head < 16, "AR trace FIFO overflow");
                ix = sb_tail % 16;
                sb_addr[ix] = araddr; sb_b[ix] = int'(arlen)+1; sb_beat[ix] = 0;
                // Operand identity from independently checked expected AR list,
                // not the DUT descriptor. Address is always from actual AR.
                sb_filter[ix] = exp_filter[sb_ar_no]; sb_ar_no++; sb_tail++;
                if (trace_fd) $fdisplay(trace_fd, "A,%0d,%0d,%h,%0d", sb_call, cycle_number, araddr, int'(arlen)+1);
            end
            good = 0; filter_beat = 0; addr = 0;
            if (rvalid && rready) begin
                provenance_check(sb_head < sb_tail, "R without accepted AR");
                ix = sb_head % 16;
                addr = sb_addr[ix] + 4*sb_beat[ix];
                good = !sb_failed && rresp === 2'b00 &&
                       rlast === (sb_beat[ix] == sb_b[ix]-1) && sb_beat[ix] < sb_b[ix];
                filter_beat = sb_filter[ix];
                sb_rbeats++;
                // EVERY accepted beat, including malformed/error/discarded.
                if (trace_fd) $fdisplay(trace_fd, "R,%0d,%0d,%0d,%h,%h,%0d,%0d,%0d,%0d,%0d",
                    sb_rbeats, sb_call, cycle_number, addr, rdata, rresp, rlast, good, filter_beat, sb_epoch);
                if (!good) sb_failed = 1;
                sb_beat[ix]++;
                if (rlast) sb_head++;
                if (good && !filter_beat) begin
                    end_addr = (sb_a & 32'hfffffffc) + 4*((sb_n + sb_a[1:0] + 3)/4);
                    provenance_check(addr >= (sb_a & 32'hfffffffc) && addr < end_addr,
                                     "ptr1 R outside represented span");
                    ix = ((addr >> 2) - (sb_a >> 2)) % 1024;
                    sb_idata[ix] = rdata; sb_iaddr[ix] = addr;
                    sb_iseq[ix] = sb_rbeats; sb_icycle[ix] = cycle_number; sb_iepoch[ix] = sb_epoch;
                end
                if (good && filter_beat && sb_append) begin
                    ix = (addr - sb_fc_lo)/4;
                    provenance_check(ix >= 0 && ix < 32768, "filter trace write outside cache");
                    if (ix >= 0 && ix < 32768) begin
                        sb_fdata[ix] = rdata; sb_faddr[ix] = addr;
                        sb_fseq[ix] = sb_rbeats; sb_fcycle[ix] = cycle_number; sb_fepoch[ix] = sb_epoch;
                    end
                end
            end
            provenance_check(`PE.emit_valid === good, "DUT used non-AXI/error data or dropped a usable beat");
            if (good) provenance_check(`PE.is_filter === filter_beat, "DUT operand identity differs from AR trace");
            if ((good && filter_beat) || `PE.s1_valid) begin
                provenance_check(!(good && filter_beat && `PE.s1_valid), "stream/cache MAC collision");
                slot = `PE.s1_valid ? 1 : 0;
                provenance_check(sb_count[slot] == 0, "MAC evidence pipeline collision");
                sb_sum[slot] = 0; sb_local[slot] = `PE.s1_valid;
                lane_count = `PE.s1_valid ? 32 : 4;
                mask = 0;
                for (s=0; s<lane_count; s++) begin
                    // Position derives from actual AR/R or our own row cursor,
                    // never filter_received, read_index or s1_k in the DUT.
                    pos = `PE.s1_valid ? 32*sb_fast_row+s-int'(sb_bptr[1:0]) : int'(addr+s-sb_bptr);
                    valid_lane = pos >= 0 && pos < sb_n;
                    if (`PE.s1_valid)
                        provenance_check(sb_fast_mask[s] === valid_lane, "fast lane mask/address mismatch");
                    else mask[s] = valid_lane;
                    if (valid_lane) begin
                        av = `PE.s1_valid ? (`PE.in_q >> (8*s)) : (`PE.input_word >> (8*s));
                        bv = `PE.s1_valid ? (`PE.fc_word_row >> (8*s)) : (rdata >> (8*s));
                        provenance_byte(slot, 0, `PE.s1_valid, sb_a+pos, av, addr, rdata, sb_rbeats);
                        provenance_byte(slot, 1, `PE.s1_valid, sb_bptr+pos, bv, addr, rdata, sb_rbeats);
                        term = (int'($signed(av)) + sb_off) * int'($signed(bv));
                        sb_sum[slot] += term;
                    end
                end
                if (`PE.s1_valid) sb_fast_row++;
                else provenance_check(`PE.lane_valid === mask, "stream lane mask/address mismatch");
            end
        end
    endtask

    task automatic provenance_finish;
        begin
            provenance_check(sb_rbeats == total_beats, "not every accepted R beat logged");
            provenance_check(!sb_running && sb_head == sb_tail && sb_count[0] == 0 && sb_count[1] == 0,
                             "unretired provenance at end of test");
            provenance_check(sb_mac_bytes > 0 && sb_stream_bytes > 0, "vacuous byte scoreboard");
            $display("AXI_SCOREBOARD: R_beats=%0d MAC_bytes=%0d stream_bytes=%0d fast_bytes=%0d violations=%0d",
                     sb_rbeats, sb_mac_bytes, sb_stream_bytes, sb_fast_bytes, sb_violations);
            if (trace_fd) begin $fclose(trace_fd); trace_fd = 0; end
        end
    endtask
    `undef PE

