`timescale 1ns / 1ps

module tb_single_transport;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, dv = 0, cancel = 0, rv = 0;
    reg [31:0] sid = 17, rid = 1, fid = 1, reply_rid = 0;
    reg [7:0] flags = 0;
    wire dr, busy, frozen, done, matched, bird, timeout, failed, error, tx, mq, mrr;
    wire [31:0] mf, mi, matched_frame;
    wire [15:0] matched_roi;
    reg mrv = 0;
    wire [159:0] meta = {8'd0, 8'd1, 16'd1, 16'd1, 16'd0, 16'd0, 16'd240, 16'd320, 16'd0, fid};
    member_b_transport #(
        .MAX_INFLIGHT(1),
        .CLOCK_HZ(1000),
        .BAUD(100),
        .READ_TIMEOUT_CYCLES(100),
        .REPLY_SECONDS(6)
    ) dut (
        .vin_clk(clk),
        .vin_rst_n(rst_n),
        .vin_de(1'b0),
        .vin_rgb(24'd0),
        .clk(clk),
        .rst_n(rst_n),
        .desc_valid(dv),
        .desc_ready(dr),
        .send_enable(1'b1),
        .session_id(sid),
        .request_id(rid),
        .crop_meta(meta),
        .lease_valid(1'b1),
        .lease_frame_id(fid),
        .lease_width(16'd320),
        .lease_height(16'd240),
        .lease_release(),
        .reader_idle(1'b1),
        .mem_req_valid(mq),
        .mem_req_ready(1'b1),
        .mem_frame_id(mf),
        .mem_pixel_index(mi),
        .mem_rsp_valid(mrv),
        .mem_rgb(24'h808080),
        .mem_rsp_error(1'b0),
        .mem_rsp_ready(mrr),
        .reader_flush(),
        .resend(1'b0),
        .cancel(cancel),
        .cancel_all(1'b0),
        .uart_tx(tx),
        .wire_done(done),
        .busy(busy),
        .frozen(frozen),
        .transport_error(error),
        .reply_valid(rv),
        .reply_session(32'd17),
        .reply_request(reply_rid),
        .reply_status(8'd0),
        .reply_decision(8'd1),
        .reply_confidence(8'd95),
        .reply_flags(flags),
        .reply_processing_ms(32'd1),
        .reply_box_valid(1'b0),
        .reply_box_x(16'd0),
        .reply_box_y(16'd0),
        .reply_box_w(16'd0),
        .reply_box_h(16'd0),
        .matched(matched),
        .confirmed_bird(bird),
        .timed_out(timeout),
        .failed(failed),
        .matched_frame_id(matched_frame),
        .matched_roi_id(matched_roi)
    );
    wire [7:0] byte_data;
    wire byte_valid, byte_error;
    uart_rx_8n1 #(
        .CLOCK_HZ(1000),
        .BAUD(100)
    ) monitor (
        .clk(clk),
        .rst_n(rst_n),
        .rx(tx),
        .data(byte_data),
        .valid(byte_valid),
        .framing_error(byte_error)
    );
    integer
        cycles = 0, wire_cycle = 0, timeouts = 0, match_count = 0, birds = 0, bytes = 0, checks = 0;
    always @(posedge clk) begin
        mrv <= mq;
        if (rst_n) begin
            cycles = cycles + 1;
            if (done) wire_cycle = cycles;
            if (timeout) timeouts = timeouts + 1;
            if (matched) match_count = match_count + 1;
            if (bird) birds = birds + 1;
            if (byte_valid) bytes = bytes + 1;
            if (error || byte_error)
                $fatal(
                    1,
                    "CAPTURE_OR_UART_ERROR capture=%b uart=%b cycle=%0d tx=%b",
                    error,
                    byte_error,
                    cycles,
                    tx
                );
        end
    end
    task tick(input integer n);
        begin
            repeat (n) @(negedge clk);
        end
    endtask
    task ck(input bit cond, input [511:0] msg);
        begin
            checks = checks + 1;
            if (!cond) $fatal(1, "check %0d %s", checks, msg);
        end
    endtask
    task issue(input integer id);
        begin
            wait (dr);
            rid = id;
            fid = id;
            dv  = 1;
            tick(1);
            dv = 0;
            wait (done);
            tick(1);
        end
    endtask
    task reply(input integer id);
        begin
            reply_rid = id;
            rv = 1;
            tick(1);
            rv = 0;
            tick(3);
        end
    endtask
    initial begin
        tick(5);
        rst_n = 1;
        tick(20);
        issue(1);
        ck(bytes == 39, "COMPLETE_REAL_GRAY8_IMAGE_BYTES");
        ck(busy && frozen && !dr, "SINGLE_IMAGE_HELD_UNTIL_REPLY_OR_DEADLINE");
        tick(5900);
        ck(timeouts == 0 && busy && !dr, "NO_EARLY_TIMEOUT_OR_SECOND_IMAGE");
        wait (timeout);
        tick(1);
        ck(cycles - wire_cycle >= 6000 && cycles - wire_cycle <= 6003,
           "SIX_SECOND_DEADLINE_FROM_PHYSICAL_STOP_BIT");
        tick(15);
        ck(timeouts == 1 && !busy && !frozen && dr, "NO_REPLY_FREES_BUFFER_AND_REOPENS_INPUT");
        issue(2);
        ck(bytes == 78, "SECOND_FULL_IMAGE_AFTER_TIMEOUT");
        reply(1);
        ck(match_count == 0 && birds == 0 && busy, "LATE_OLD_RESULT_CANNOT_COMPLETE_NEW_REQUEST");
        reply(2);
        ck(match_count == 1 && birds == 1 && matched_frame == 2 && matched_roi == 0,
           "NEW_REQUEST_AUTHENTICATES_OWN_IDENTITY");
        tick(15);
        ck(dr && !busy && !frozen, "VALID_REPLY_FREES_SINGLE_IMAGE_BUFFER");
        reply(2);
        ck(match_count == 1 && birds == 1, "DUPLICATE_REPLY_CANNOT_REPLAY_ACTION");
        $display("PASS SINGLE_TIMEOUT checks=%0d bytes=%0d timeouts=%0d match_count=%0d", checks,
                 bytes, timeouts, match_count);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "SINGLE_TIMEOUT_WATCHDOG");
    end
endmodule
