`timescale 1ns / 1ps

module tb_pipelined_transport;
    reg clk = 0, vin_clk = 0;
    always #10 clk = ~clk;
    always #6.734007 vin_clk = ~vin_clk;
    reg rst_n = 0, vin_de = 0;
    reg [23:0] vin_rgb = 0;
    integer source_frame = 0, sx, sy;
    reg [7:0] gray;
    initial begin
        wait (rst_n);
        repeat (2000) @(negedge vin_clk);
        forever begin
            source_frame = source_frame + 1;
            gray = (source_frame * 17) % 256;
            for (sy = 0; sy < 720; sy = sy + 1) begin
                for (sx = 0; sx < 1280; sx = sx + 1) begin
                    @(negedge vin_clk);
                    vin_de  = 1;
                    vin_rgb = {gray, gray, gray};
                end
                @(negedge vin_clk);
                vin_de = 0;
                repeat (369) @(negedge vin_clk);
            end
            repeat (49500) @(negedge vin_clk);
        end
    end
    reg desc_valid = 0, cancel = 0, cancel_all = 0;
    reg [159:0] crop_meta = 0;
    reg [ 31:0] request_id = 0;
    wire desc_ready,lease_valid,lease_release,t_desc_valid,t_desc_ready,t_busy,t_lease_valid,t_lease_release,t_error,t_cancel;
    wire captured, rejected, retired, busy, motion_known, force_flush;
    wire [3:0] error_code;
    wire [31:0] t_session, t_request, held_frame, origin_session;
    wire [15:0] held_width, held_height;
    wire [159:0] t_meta;
    wire [ 16:0] captured_motion;
    reg lease_gnt = 0, held = 0;
    reg [31:0] lease_frame_id = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            lease_gnt <= 0;
            held <= 0;
            lease_frame_id <= 0;
        end else begin
            lease_gnt <= 0;
            if (lease_valid && !held) begin
                lease_gnt <= 1;
                held <= 1;
                lease_frame_id <= crop_meta[31:0];
            end
            if (lease_release) held <= 0;
        end
    end
    a_descriptor_adapter #(
        .LEASE_TIMEOUT_CYCLES(500),
        .MAX_CAPTURE_CYCLES  (10000000)
    ) adapter (
        .clk(clk),
        .rst_n(rst_n),
        .cancel(cancel),
        .link_session_valid(1'b1),
        .link_session_id(32'd17),
        .desc_valid(desc_valid),
        .desc_ready(desc_ready),
        .session_id(32'd17),
        .request_id(request_id),
        .crop_meta(crop_meta),
        .bbox_done(desc_valid),
        .motion_count(17'd200),
        .lease_valid(lease_valid),
        .lease_gnt(lease_gnt),
        .lease_frame_id(lease_frame_id),
        .lease_width(16'd320),
        .lease_height(16'd240),
        .lease_release(lease_release),
        .reader_idle(1'b1),
        .force_flush(force_flush),
        .t_desc_valid(t_desc_valid),
        .t_desc_ready(t_desc_ready),
        .t_session(t_session),
        .t_request(t_request),
        .t_busy(t_busy),
        .t_meta(t_meta),
        .t_lease_valid(t_lease_valid),
        .held_frame(held_frame),
        .held_width(held_width),
        .held_height(held_height),
        .t_lease_release(t_lease_release),
        .t_error(t_error),
        .t_cancel(t_cancel),
        .captured(captured),
        .rejected(rejected),
        .retired(retired),
        .error_code(error_code),
        .origin_session(origin_session),
        .captured_motion(captured_motion),
        .motion_known(motion_known),
        .busy(busy)
    );
    reg uart_rx = 1;
    wire uart_tx, wire_done, frozen, matched, confirmed_bird, timed_out, failed;
    wire [31:0] matched_session_id, matched_request_id, matched_frame_id, matched_processing_ms;
    wire [15:0] matched_roi_id;
    wire [7:0] matched_status, matched_decision, matched_confidence, matched_flags;
    wire [  2:0] pending_count;
    wire [159:0] packet_meta;
    wire rv, rxerr, rxvalid, packet_error, partial_timeout, reply_box_valid;
    wire [7:0] rxdata, reply_status, reply_decision, reply_confidence, reply_flags;
    wire [31:0] reply_session, reply_request, reply_processing_ms;
    wire [15:0] reply_box_x, reply_box_y, reply_box_w, reply_box_h;
    uart_rx_8n1 #(
        .CLOCK_HZ(50000000),
        .BAUD(1500000)
    ) rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx(uart_rx),
        .data(rxdata),
        .valid(rxvalid),
        .framing_error(rxerr)
    );
    roi_result_rx #(
        .GAP_CYCLES(1000000),
        .PACKET_CYCLES(5000000)
    ) decoder (
        .clk(clk),
        .rst_n(rst_n),
        .clear(cancel_all),
        .byte_valid(rxvalid),
        .byte_error(rxerr),
        .byte_data(rxdata),
        .reply_valid(rv),
        .packet_error(packet_error),
        .partial_timeout(partial_timeout),
        .reply_session(reply_session),
        .reply_request(reply_request),
        .reply_status(reply_status),
        .reply_decision(reply_decision),
        .reply_confidence(reply_confidence),
        .reply_flags(reply_flags),
        .processing_ms(reply_processing_ms),
        .reply_box_valid(reply_box_valid),
        .reply_box_x(reply_box_x),
        .reply_box_y(reply_box_y),
        .reply_box_w(reply_box_w),
        .reply_box_h(reply_box_h)
    );
    member_b_transport #(
        .CLOCK_HZ(50000000),
        .BAUD(1500000),
        .ROI_HIRES(1),
        .TX_PACING(1),
        .MAX_INFLIGHT(4)
    ) dut (
        .vin_clk(vin_clk),
        .vin_rst_n(rst_n),
        .vin_de(vin_de),
        .vin_rgb(vin_rgb),
        .clk(clk),
        .rst_n(rst_n),
        .desc_valid(t_desc_valid),
        .desc_ready(t_desc_ready),
        .send_enable(1'b1),
        .session_id(t_session),
        .request_id(t_request),
        .crop_meta(t_meta),
        .lease_valid(t_lease_valid),
        .lease_frame_id(held_frame),
        .lease_width(held_width),
        .lease_height(held_height),
        .lease_release(t_lease_release),
        .reader_idle(1'b1),
        .mem_req_valid(),
        .mem_req_ready(1'b1),
        .mem_frame_id(),
        .mem_pixel_index(),
        .mem_rsp_valid(1'b0),
        .mem_rgb(24'd0),
        .mem_rsp_error(1'b0),
        .mem_rsp_ready(),
        .reader_flush(),
        .resend(1'b0),
        .cancel(t_cancel),
        .cancel_all(cancel_all),
        .uart_tx(uart_tx),
        .wire_done(wire_done),
        .busy(t_busy),
        .frozen(frozen),
        .transport_error(t_error),
        .debug_packet_meta(packet_meta),
        .reply_valid(rv),
        .reply_session(reply_session),
        .reply_request(reply_request),
        .reply_status(reply_status),
        .reply_decision(reply_decision),
        .reply_confidence(reply_confidence),
        .reply_flags(reply_flags),
        .reply_processing_ms(reply_processing_ms),
        .reply_box_valid(reply_box_valid),
        .reply_box_x(reply_box_x),
        .reply_box_y(reply_box_y),
        .reply_box_w(reply_box_w),
        .reply_box_h(reply_box_h),
        .matched(matched),
        .confirmed_bird(confirmed_bird),
        .timed_out(timed_out),
        .failed(failed),
        .matched_session_id(matched_session_id),
        .matched_request_id(matched_request_id),
        .matched_frame_id(matched_frame_id),
        .matched_roi_id(matched_roi_id),
        .matched_status(matched_status),
        .matched_decision(matched_decision),
        .matched_confidence(matched_confidence),
        .matched_flags(matched_flags),
        .matched_processing_ms(matched_processing_ms),
        .matched_box_valid(),
        .matched_box_x(),
        .matched_box_y(),
        .matched_box_w(),
        .matched_box_h(),
        .pending_count(pending_count)
    );
    integer
        checks = 0,
        accepts = 0,
        stops = 0,
        match_count = 0,
        crc_errors = 0,
        peak = 0,
        last_req = 0,
        cycles = 0,
        duplex_bytes = 0;
    integer tx_cycles[1:8], rx_cycles[1:8], seen[1:8];
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            cycles = cycles + 1;
            if (captured) accepts = accepts + 1;
            if (wire_done) begin
                stops = stops + 1;
                tx_cycles[t_request] = cycles;
            end
            if (pending_count > peak) peak = pending_count;
            if (packet_error) crc_errors = crc_errors + 1;
            if (rxvalid && dut.g_hires.snapshot.packet_busy) duplex_bytes = duplex_bytes + 1;
            if (matched) begin
                match_count = match_count + 1;
                last_req = matched_request_id;
                rx_cycles[matched_request_id] = cycles;
                seen[matched_request_id] = seen[matched_request_id] + 1;
                if(matched_session_id!=17 || matched_frame_id!=1000+matched_request_id || matched_roi_id!=(matched_request_id-1)%4 || !confirmed_bird)
                    $fatal(1, "WRONG_COMPLETION_ID");
            end
            if (rejected && !cancel) $fatal(1, "ADAPTER_REJECT code=%0d", error_code);
            if (t_error || timed_out || failed || rxerr || partial_timeout)
                $fatal(1, "UNEXPECTED_TRANSPORT_FAULT");
        end
    end
    task ck(input bit cond, input [511:0] msg);
        begin
            checks = checks + 1;
            if (!cond) $fatal(1, "check %0d %s", checks, msg);
        end
    endtask
    function [15:0] crc_add(input [15:0] old, input [7:0] data);
        integer j;
        reg [15:0] c;
        begin
            c = old ^ {data, 8'd0};
            for (j = 0; j < 8; j = j + 1) c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            crc_add = c;
        end
    endfunction
    reg [7:0] packet[0:16421];
    integer nbyte = 0, total = 0, packets = 0, k, output_fd;
    reg [7:0] serial_byte;
    task check_packet;
        integer i, fr, w, h, req;
        reg [15:0] hc, fc;
        begin
            ck(packet[0] == 8'haa && packet[1] == 8'h55 && packet[2] == 1 && packet[3] == 1,
               "image header");
            hc = 16'hffff;
            for (i = 2; i < 14; i = i + 1) hc = crc_add(hc, packet[i]);
            ck({packet[15], packet[14]} == hc, "header CRC");
            fc = 16'hffff;
            for (i = 2; i < total - 2; i = i + 1) fc = crc_add(fc, packet[i]);
            ck({packet[total-1], packet[total-2]} == fc, "image CRC");
            fr  = {packet[19], packet[18], packet[17], packet[16]};
            req = {packet[11], packet[10], packet[9], packet[8]};
            w   = {packet[31], packet[30]};
            h   = {packet[33], packet[32]};
            ck(req == packets + 1 && {packet[7], packet[6], packet[5], packet[4]} == 17,
               "serial images preserve request order");
            ck(total == w * h + 38 && w * h > 0 && w * h <= 16384 && fr > 0 && fr < 1000,
               "real captured frame identity");
            for (i = 36; i < total - 2; i = i + 1)
            ck(packet[i] == (fr * 17) % 256, "pixel belongs to captured immutable image");
            output_fd = $fopen($sformatf("packet_%0d.bin", packets), "wb");
            for (i = 0; i < total; i = i + 1) $fwrite(output_fd, "%c", packet[i]);
            $fclose(output_fd);
            packets = packets + 1;
            $display("IMAGE req=%0d capture_frame=%0d pixels=%0d pending=%0d", req, fr, w * h,
                     pending_count);
        end
    endtask
    initial begin
        wait (rst_n);
        forever begin
            @(negedge uart_tx);
            #990;
            for (k = 0; k < 8; k = k + 1) begin
                serial_byte[k] = uart_tx;
                #660;
            end
            if (uart_tx !== 1'b1) $fatal(1, "TX_STOP_BIT");
            if (nbyte >= 16422) $fatal(1, "IMAGE_OVERSIZE");
            packet[nbyte] = serial_byte;
            nbyte = nbyte + 1;
            if (nbyte == 14) total = 18 + {packet[13], packet[12]};
            if (total != 0 && nbyte == total) begin
                check_packet();
                nbyte = 0;
                total = 0;
            end
        end
    end
    task send_uart(input [7:0] v);
        integer bitn;
        begin
            @(negedge clk);
            uart_rx = 0;
            repeat (33) @(negedge clk);
            for (bitn = 0; bitn < 8; bitn = bitn + 1) begin
                uart_rx = v[bitn];
                repeat (33) @(negedge clk);
            end
            uart_rx = 1;
            repeat (33) @(negedge clk);
        end
    endtask
    task send_reply(input integer req, input integer sid, input bit corrupt);
        reg [ 7:0] reply[0:25];
        reg [15:0] crc;
        integer i, j;
        begin
            reply[0] = 8'haa;
            reply[1] = 8'h55;
            reply[2] = 1;
            reply[3] = 8'h81;
            for (j = 0; j < 4; j = j + 1) begin
                reply[4+j] = sid >> (j * 8);
                reply[8+j] = req >> (j * 8);
            end
            reply[12] = 8;
            reply[13] = 0;
            crc = 16'hffff;
            for (i = 2; i < 14; i = i + 1) crc = crc_add(crc, reply[i]);
            reply[14] = crc[7:0];
            reply[15] = crc[15:8];
            reply[16] = 0;
            reply[17] = 1;
            reply[18] = 90;
            reply[19] = 0;
            reply[20] = 123;
            reply[21] = 0;
            reply[22] = 0;
            reply[23] = 0;
            crc = 16'hffff;
            for (i = 2; i < 24; i = i + 1) crc = crc_add(crc, reply[i]);
            reply[24] = crc[7:0] ^ (corrupt ? 1 : 0);
            reply[25] = crc[15:8];
            for (i = 0; i < 26; i = i + 1) send_uart(reply[i]);
            repeat (10) @(negedge clk);
        end
    endtask
    task offer(input integer req);
        begin
            @(negedge clk);
            crop_meta = 0;
            crop_meta[31:0] = 1000 + req;
            crop_meta[47:32] = (req - 1) % 4;
            crop_meta[63:48] = 320;
            crop_meta[79:64] = 240;
            crop_meta[95:80] = req * 30;
            crop_meta[111:96] = req * 20;
            crop_meta[127:112] = 4;
            crop_meta[143:128] = 3;
            crop_meta[151:144] = 1;
            request_id = req;
            desc_valid = 1;
        end
    endtask
    task accept_offer;
        begin
            do @(posedge clk); while (!desc_ready);
            @(negedge clk);
            desc_valid = 0;
        end
    endtask
    integer req;
    initial begin
        for (req = 1; req <= 8; req = req + 1) begin
            seen[req] = 0;
            tx_cycles[req] = 0;
            rx_cycles[req] = 0;
        end
        repeat (8) @(negedge clk);
        rst_n = 1;
        wait (source_frame == 1 && sy == 30);
        for (req = 1; req <= 4; req = req + 1) begin
            offer(req);
            accept_offer();
            wait (stops == req);
            repeat (30) @(negedge clk);
        end
        ck(pending_count == 4 && peak == 4 && match_count == 0,
           "four real images transmitted before first result");
        wait (!busy);
        ck(!desc_ready && !t_busy, "full result window backpressures without holding image");
        offer(5);
        repeat (100) @(negedge clk);
        ck(accepts == 4 && !desc_ready, "fifth request waits intact");
        send_reply(1, 17, 1);
        send_reply(2, 18, 0);
        ck(match_count == 0 && pending_count == 4 && crc_errors == 1,
           "bad CRC and wrong session cannot free slots");
        fork
            begin
                accept_offer();
            end
            begin
                send_reply(3, 17, 0);
            end
        join
        ck(match_count == 1 && last_req == 3, "third request first completion");
        send_reply(1, 17, 0);
        wait (dut.g_hires.snapshot.packet_busy);
        send_reply(4, 17, 0);
        send_reply(2, 17, 0);
        ck(match_count == 4 && last_req == 2, "out-of-order exact completion during next image TX");
        ck(duplex_bytes >= 26, "physical UART RX operates during IMAGE TX");
        wait (stops == 5);
        repeat (30) @(negedge clk);
        send_reply(5, 17, 0);
        wait (!busy);
        ck(match_count == 5 && pending_count == 0 && accepts == 5 && packets == 5,
           "all transactions drained");
        send_reply(3, 17, 0);
        ck(match_count == 5, "duplicate physical packet ignored");
        for (req = 1; req <= 5; req = req + 1) ck(seen[req] == 1, "one result per request");
        ck(tx_cycles[4] < rx_cycles[3], "four in flight overlap measured");
        $display(
            "PASS TRANSPORT checks=%0d accepts=%0d packets=%0d match_count=%0d peak=%0d fourth_tx=%0d first_reply=%0d cycles",
            checks, accepts, packets, match_count, peak, tx_cycles[4], rx_cycles[3]);
        $finish;
    end
    initial begin
        #500000000;
        $fatal(1, "TRANSPORT_WATCHDOG accepts=%0d packets=%0d matches=%0d pending=%0d state=%0d",
               accepts, packets, match_count, pending_count, adapter.state);
    end
endmodule
