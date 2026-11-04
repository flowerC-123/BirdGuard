`timescale 1ns / 1ps
module tb_result_windows #(
    parameter TRUSTED = 0
);
    reg clk = 0;
    always #10 clk = ~clk;
    reg
        rst_n = 0,
        cancel = 0,
        mapping = 1,
        link = 1,
        scene_valid = 0,
        captured = 0,
        capture_error = 0,
        frozen = 1,
        wire_done = 0;
    reg matched = 0, timeout = 0, fault = 0, ready = 1, motion_known = 1;
    reg [31:0] sid = 20, rid = 1, fid = 100, msid = 20, mrid = 1, mf = 100;
    reg [ 15:0] mr = 0;
    reg [223:0] boxes = 0;
    reg [159:0] meta = 0, packet_meta = 0;
    reg [16:0] motion = 0;
    reg [7:0] status = 0, decision = 1, conf = 95, flags = 0;
    reg bv = 0;
    reg [15:0] bx = 0, by = 0, bw = 0, bh = 0;
    wire [ 11:0] labels;
    wire [ 27:0] confs;
    wire [127:0] requests;
    wire [31:0] tf, ts;
    wire live_send, live_reject;
    wire snap_send, snap_reject, timing_valid, matched_patrol, action_bird;
    wire [191:0] payload;
    wire [16:0] matched_motion, action_motion;
    wire [15:0] tx_ms, reply_ms, total_ms;
    integer checks = 0, cases = 0, k, action_count = 0;
    reg [16:0] action_values[0:15];
    reg [55:0] a, b, c, d;
    ccl_result_window #(
        .CLOCK_HZ(10000),
        .TICK_CYCLES(1000),
        .HOLD_TICKS(25),
        .MAX_INFLIGHT(4),
        .TRUSTED_MATCH_CONTEXT(TRUSTED)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cancel(cancel),
        .mapping_valid(mapping),
        .link_valid(link),
        .link_session(sid),
        .scene_valid(scene_valid),
        .scene_frame(fid),
        .scene_boxes(boxes),
        .captured(captured),
        .capture_error(capture_error),
        .motion_known(motion_known),
        .motion_count(motion),
        .meta(meta),
        .session_id(sid),
        .request_id(rid),
        .capture_frozen(frozen),
        .wire_done(wire_done),
        .matched(matched),
        .matched_frame(mf),
        .matched_roi(mr),
        .matched_session(msid),
        .matched_request(mrid),
        .status(status),
        .decision(decision),
        .confidence(conf),
        .flags(flags),
        .box_valid(bv),
        .box_x(bx),
        .box_y(by),
        .box_w(bw),
        .box_h(bh),
        .timed_out(timeout),
        .transport_fault(fault),
        .mailbox_ready(ready),
        .send(live_send),
        .tracked_frame(tf),
        .tracked_session(ts),
        .labels(labels),
        .confidences(confs),
        .requests(requests),
        .association_rejected(live_reject),
        .action_bird(action_bird),
        .action_motion(action_motion)
    );
    result_display_window #(
        .CLOCK_HZ(10000),
        .MAX_INFLIGHT(4),
        .TRUSTED_MATCH_CONTEXT(TRUSTED)
    ) snap (
        .clk(clk),
        .rst_n(rst_n),
        .cancel(cancel),
        .mapping_valid(mapping),
        .link_session_valid(link),
        .link_session_id(sid),
        .captured(captured),
        .capture_error(capture_error),
        .meta(meta),
        .session_id(sid),
        .request_id(rid),
        .motion_count(motion),
        .motion_known(motion_known),
        .wire_done(wire_done),
        .packet_meta(packet_meta),
        .matched(matched),
        .matched_frame(mf),
        .matched_session(msid),
        .matched_request(mrid),
        .matched_roi(mr),
        .status(status),
        .decision(decision),
        .confidence(conf),
        .flags(flags),
        .box_valid(bv),
        .box_x(bx),
        .box_y(by),
        .box_w(bw),
        .box_h(bh),
        .timed_out(timeout),
        .transport_fault(fault),
        .mailbox_ready(ready),
        .send(snap_send),
        .payload(payload),
        .geometry_rejected(snap_reject),
        .matched_motion(matched_motion),
        .matched_patrol(matched_patrol),
        .timing_valid(timing_valid),
        .transmit_ms(tx_ms),
        .reply_ms(reply_ms),
        .total_ms(total_ms)
    );
    always @(posedge clk) begin
        #1;
        if (rst_n && action_bird) begin
            if (action_count >= 16) $fatal(1, "ACTION_OVERFLOW");
            action_values[action_count] = action_motion;
            action_count = action_count + 1;
        end
    end
    task cyc(input integer n);
        begin
            repeat (n) @(negedge clk);
        end
    endtask
    task check(input condition, input [255:0] why);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) $fatal(1, "WINDOW %0s case=%0d labels=%h", why, cases, labels);
        end
    endtask
    function [55:0] box(input integer x, y, w, h);
        begin
            box = {17'd256, 9'(y + h - 1), 9'(y), 10'(x + w - 1), 10'(x), 1'b1};
        end
    endfunction
    task reset;
        begin
            rst_n = 0;
            cancel = 0;
            mapping = 1;
            link = 1;
            scene_valid = 0;
            captured = 0;
            capture_error = 0;
            wire_done = 0;
            matched = 0;
            timeout = 0;
            fault = 0;
            ready = 1;
            motion_known = 1;
            action_count = 0;
            sid = 20;
            msid = 20;
            rid = 1;
            mrid = 1;
            fid = 100;
            mf = 100;
            mr = 0;
            boxes = 0;
            meta = 0;
            packet_meta = 0;
            motion = 0;
            status = 0;
            decision = 1;
            conf = 95;
            flags = 0;
            bv = 0;
            cyc(4);
            rst_n = 1;
            cyc(4);
        end
    endtask
    task scene_start(input integer f, input [223:0] v);
        begin
            fid = f;
            boxes = v;
            scene_valid = 1;
            cyc(1);
            scene_valid = 0;
        end
    endtask
    task scene(input integer f, input [223:0] v);
        begin
            scene_start(f, v);
            cyc(130);
            check(tf == f, "scene published");
        end
    endtask
    task capture(input integer req, f, slot, amount, input [55:0] geom);
        integer x, y, w, h;
        begin
            w = geom[20:11] - geom[10:1] + 1;
            if (w < 73) w = 73;
            h = geom[38:30] - geom[29:21] + 1;
            if (h < 74) h = 74;
            x = geom[10:1] + geom[20:11] + 1;
            x = x >= w ? (x - w) / 2 : 0;
            y = geom[29:21] + geom[38:30] + 1;
            y = y >= h ? (y - h) / 2 : 0;
            if (x + w > 320) x = 320 - w;
            if (y + h > 240) y = 240 - h;
            rid = req;
            motion = amount;
            meta = {
                8'd0, 8'd1, 16'(h), 16'(w), 16'(y), 16'(x), 16'd240, 16'd320, 16'(slot), 32'(f)
            };
            captured = 1;
            cyc(1);
            captured = 0;
            cyc(2);
        end
    endtask
    task seal;
        begin
            packet_meta = meta;
            packet_meta[31:0] = meta[31:0] + 1;
            wire_done = 1;
            cyc(1);
            wire_done = 0;
            cyc(1);
        end
    endtask
    task reply(input integer req, f, slot, dv, amount);
        begin
            mrid = req;
            mf = f;
            mr = slot;
            decision = dv;
            conf = dv ? 95 : 255;
            matched = 1;
            #1;
            check(matched_motion == amount, "own matched motion");
            check(timing_valid, "own timing context");
            check(total_ms == tx_ms + reply_ms, "timing partition");
            cyc(1);
            matched = 0;
        end
    endtask
    task expect_slot(input integer slot, label, req);
        begin
            check(labels[slot*3+:3] === label, "live classification");
            if (label != 0) check(requests[slot*32+:32] === req, "live request identity");
        end
    endtask
    initial begin
        a = box(10, 50, 50, 50);
        b = box(90, 50, 50, 50);
        c = box(170, 50, 50, 50);
        d = box(250, 50, 50, 50);

        reset;
        scene(100, {d, c, b, a});
        capture(1, 100, 0, 101, a);
        seal;
        capture(2, 100, 1, 202, b);
        seal;
        capture(3, 100, 2, 303, c);
        seal;
        capture(4, 100, 3, 404, d);
        seal;
        check(dut.flight_valid == 4'hf && snap.valid == 4'hf, "four in-flight contexts");
        scene(101, {a, b, c, d});
        ready = 0;
        reply(3, 100, 2, 1, 303);
        reply(1, 100, 0, 0, 101);
        reply(4, 100, 3, 1, 404);
        reply(2, 100, 1, 0, 202);
        cyc(140);
        expect_slot(0, 1, 4);
        expect_slot(1, 1, 3);
        expect_slot(2, 2, 2);
        expect_slot(3, 2, 1);
        check(payload[123:92] == 2 && payload[91:60] == 101 && payload[4:2] == 2,
              "SNAP last completion retained");
        check(snap.valid == 0 && dut.flight_valid == 0, "all contexts retired");
        ready = 1;
        cyc(5);
        cases = cases + 1;
        check(action_count == 2, "each admitted positive acts once");
        check(
            (action_values[0]==303&&action_values[1]==404)||(action_values[0]==404&&action_values[1]==303),
            "actions carry original per-request area");

        reset;
        scene(100, {168'd0, a});
        capture(10, 100, 0, 100, a);
        seal;
        scene(101, {168'd0, a});
        capture(11, 101, 0, 200, a);
        seal;
        reply(11, 101, 0, 0, 200);
        cyc(140);
        expect_slot(0, 2, 11);
        reply(10, 100, 0, 1, 100);
        cyc(140);
        expect_slot(0, 2, 11);
        check(action_count == 0, "older positive cannot cause action");
        cases = cases + 1;

        reset;
        scene(100, {112'd0, b, a});
        capture(100, 100, 0, 100, a);
        seal;
        capture(101, 100, 0, 200, a);
        seal;
        capture(102, 100, 1, 300, b);
        seal;
        scene_start(101, {112'd0, b, a});
        reply(102, 100, 1, 1, 300);
        reply(101, 100, 0, 0, 200);
        reply(100, 100, 0, 1, 100);
        cyc(160);
        expect_slot(0, 2, 101);
        expect_slot(1, 1, 102);
        check(action_count == 1 && action_values[0] == 300,
              "completed newer negative suppresses old action");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(110, 100, 0, 100, a);
        seal;
        capture(111, 100, 0, 200, a);
        seal;
        reply(110, 100, 0, 1, 100);
        while (!(dut.state == 0 && dut.queued_valid)) cyc(1);
        reply(111, 100, 0, 0, 200);
        cyc(160);
        expect_slot(0, 2, 111);
        check(action_count == 0, "same-edge newer negative suppresses old action");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(120, 100, 0, 100, a);
        seal;
        capture(121, 100, 0, 200, a);
        reply(120, 100, 0, 1, 100);
        while (!(dut.state == 0 && dut.queued_valid)) cyc(1);
        fault = 1;
        cyc(1);
        fault = 0;
        cyc(160);
        check(labels == 0, "same-edge capture fault revokes cache");
        check(action_count == 0, "same-edge capture fault suppresses action");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(130, 100, 0, 100, a);
        seal;
        reply(130, 100, 0, 1, 100);
        while (!(dut.state == 0 && dut.queued_valid)) cyc(1);
        scene_start(101, 0);
        cyc(160);
        check(labels == 0, "same-edge disappearance revokes cache");
        check(action_count == 0, "same-edge disappearance suppresses action");
        cases = cases + 1;

        reset;
        scene(100, {112'd0, b, a});
        capture(20, 100, 0, 400, a);
        seal;
        scene_start(101, {112'd0, b, a});
        capture(21, 101, 1, 700, b);
        ready = 0;
        fault = 1;
        reply(20, 100, 0, 1, 400);
        fault = 0;
        cyc(140);
        expect_slot(0, 1, 20);
        expect_slot(1, 0, 0);
        check(payload[123:92] == 20, "old matched wins SNAP fault collision");
        check(action_count == 1 && action_values[0] == 400,
              "old success survives other capture fault");
        ready = 1;
        cases = cases + 1;

        reset;
        a = box(40, 40, 110, 80);
        scene(100, {168'd0, a});
        capture(30, 100, 0, 500, a);
        seal;
        capture(31, 100, 0, 600, a);
        seal;
        scene(101, {112'd0, box(100, 40, 50, 80), box(40, 40, 80, 80)});
        reply(31, 100, 0, 1, 600);
        reply(30, 100, 0, 0, 500);
        cyc(140);
        check(labels == 0, "split rejects both live replies");
        check(action_count == 0, "split not actionable");
        cases = cases + 1;

        reset;
        a = box(40, 40, 80, 80);
        scene(100, {168'd0, a});
        capture(40, 100, 0, 900, a);
        seal;
        scene(101, 0);
        scene(102, {168'd0, a});
        reply(40, 100, 0, 1, 900);
        cyc(140);
        check(labels == 0, "no same-place revival");
        check(action_count == 0, "disappeared target not actionable");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(50, 100, 0, 0, a);
        seal;
        mrid = 50;
        mf   = 100;
        mr   = 0;
        #1;
        check(matched_patrol, "known zero motion is actual patrol");
        reply(50, 100, 0, 1, 0);
        cyc(140);
        check(labels == 0 && payload[4:2] == 1, "patrol historical-only");
        check(action_count == 0, "patrol uses separate action path");
        cases = cases + 1;
        motion_known = 0;
        capture(51, 100, 0, 0, a);
        seal;
        motion_known = 1;
        mrid = 51;
        mf = 100;
        mr = 0;
        #1;
        check(!matched_patrol, "unknown zero motion is not patrol");
        reply(51, 100, 0, 1, 0);
        cyc(140);
        check(action_count == 0, "unknown capture cannot act");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(60, 100, 0, 123, a);
        seal;
        mrid = 61;
        mf = 100;
        mr = 0;
        matched = 1;
        cyc(1);
        matched = 0;
        cyc(20);
        check(labels == 0 && snap.valid != 0, "wrong request ignored");
        mrid = 60;
        msid = 21;
        matched = 1;
        cyc(1);
        matched = 0;
        cyc(20);
        check(labels == 0 && snap.valid != 0, "wrong session ignored");
        msid = 20;

        if (!TRUSTED) begin
            mf = 99;
            matched = 1;
            cyc(1);
            matched = 0;
            cyc(20);
            check(labels == 0 && snap.valid != 0, "wrong frame ignored");
            mf = 100;
            mr = 1;
            matched = 1;
            cyc(1);
            matched = 0;
            cyc(20);
            check(labels == 0 && snap.valid != 0, "wrong ROI ignored");
        end
        reply(60, 100, 0, 1, 123);
        cyc(140);
        expect_slot(0, 1, 60);
        cases = cases + 1;

        while (dut.ttl[0] > 1) cyc(1);
        mrid = 60;
        mf = 100;
        mr = 0;
        matched = 1;
        cyc(1);
        matched = 0;
        cyc(1100);
        check(labels == 0, "duplicate no TTL renewal");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(70, 100, 0, 100, a);
        seal;
        capture(71, 100, 0, 200, a);
        seal;
        cancel = 1;
        cyc(1);
        cancel = 0;
        cyc(5);
        check(dut.flight_valid == 0 && snap.valid == 0 && labels == 0 && payload == 0,
              "cancel flush all contexts");
        cases = cases + 1;

        reset;
        a = box(10, 50, 50, 50);
        b = box(90, 50, 50, 50);
        c = box(170, 50, 50, 50);
        d = box(250, 50, 50, 50);
        scene(100, {d, c, b, a});
        capture(80, 100, 0, 100, a);
        seal;
        capture(81, 100, 1, 200, b);
        seal;
        capture(82, 100, 2, 300, c);
        seal;
        capture(83, 100, 3, 400, d);
        seal;
        bv = 1;
        by = 50;
        bw = 10;
        bh = 10;
        bx = 170;
        reply(82, 100, 2, 1, 300);
        bx = 90;
        reply(80, 100, 0, 1, 100);
        check(snap_reject, "wrong bank precise geometry rejected");
        bx = 250;
        reply(83, 100, 3, 1, 400);
        bx = 90;
        reply(81, 100, 1, 1, 200);
        cyc(160);
        expect_slot(0, 0, 0);
        expect_slot(1, 1, 81);
        expect_slot(2, 1, 82);
        expect_slot(3, 1, 83);
        check(action_count == 3, "only own-bank precise positives act");
        cases = cases + 1;

        reset;
        a = box(0, 0, 320, 240);
        scene(100, {168'd0, a});
        capture(90, 100, 0, 76800, a);
        seal;
        bv = 1;
        bx = 0;
        by = 0;
        bw = 320;
        bh = 240;
        reply(90, 100, 0, 1, 76800);
        cyc(160);
        expect_slot(0, 1, 90);
        check(action_count == 1 && action_values[0] == 76800, "full frame area and precise bounds");
        check(payload[1] && payload[47:36] == 1279 && payload[59:48] == 719,
              "full frame SNAP last pixels");
        cases = cases + 1;

        reset;
        a = box(0, 0, 1, 1);
        b = box(319, 0, 1, 1);
        c = box(0, 239, 1, 1);
        d = box(319, 239, 1, 1);
        scene(100, {d, c, b, a});
        capture(100, 100, 0, 101, a);
        seal;
        capture(101, 100, 1, 102, b);
        seal;
        capture(102, 100, 2, 103, c);
        seal;
        capture(103, 100, 3, 104, d);
        seal;
        bv = 1;
        bw = 1;
        bh = 1;
        bx = 319;
        by = 239;
        reply(103, 100, 3, 1, 104);
        bx = 0;
        by = 0;
        reply(100, 100, 0, 1, 101);
        bx = 0;
        by = 239;
        reply(102, 100, 2, 1, 103);
        bx = 319;
        by = 0;
        reply(101, 100, 1, 1, 102);
        cyc(160);
        expect_slot(0, 1, 100);
        expect_slot(1, 1, 101);
        expect_slot(2, 1, 102);
        expect_slot(3, 1, 103);
        check(action_count == 4, "four tiny corner precise positives");
        cases = cases + 1;

        reset;
        a = box(40, 40, 80, 80);
        scene(100, {168'd0, a});
        capture(110, 100, 0, 101, a);
        seal;
        capture(111, 100, 0, 102, a);
        seal;
        capture(112, 100, 0, 103, a);
        seal;
        capture(113, 100, 0, 104, a);
        seal;
        bv = 1;
        bx = 552;
        by = 40;
        bw = 10;
        bh = 10;
        reply(110, 100, 0, 1, 101);
        check(snap_reject, "x high bits rejected");
        bx = 40;
        by = 296;
        reply(111, 100, 0, 1, 102);
        check(snap_reject, "y high bits rejected");
        by = 40;
        bw = 522;
        reply(112, 100, 0, 1, 103);
        check(snap_reject, "width high bits rejected");
        bw = 10;
        bh = 266;
        reply(113, 100, 0, 1, 104);
        check(snap_reject, "height high bits rejected");
        cyc(160);
        check(labels == 0 && action_count == 0 && dut.flight_valid == 0,
              "high bits never authorize action");
        cases = cases + 1;

        reset;
        scene(100, {168'd0, a});
        capture(120, 100, 0, 101, a);
        seal;
        capture(121, 100, 0, 102, a);
        seal;
        bv = 1;
        bx = 511;
        by = 40;
        bw = 511;
        bh = 10;
        reply(120, 100, 0, 1, 101);
        check(snap_reject, "x sum carry rejected");
        bx = 40;
        by = 255;
        bw = 10;
        bh = 255;
        reply(121, 100, 0, 1, 102);
        check(snap_reject, "y sum carry rejected");
        cyc(160);
        check(labels == 0 && action_count == 0, "coordinate sum cannot wrap into crop");
        cases = cases + 1;

        reset;
        a = box(40, 40, 80, 80);
        b = box(160, 40, 80, 80);
        scene(100, {112'd0, b, a});
        capture(200, 100, 0, 321, a);
        packet_meta = meta;
        packet_meta[31:0] = 101;
        wire_done = 1;
        scene_start(101, {112'd0, a, b});
        wire_done = 0;
        check(dut.flight_bound[0] && dut.flight_previous[0], "wire/new scene starts previous");
        cyc(140);
        reply(200, 100, 0, 1, 321);
        cyc(140);
        expect_slot(0, 0, 0);
        expect_slot(1, 1, 200);
        check(action_count == 1 && action_values[0] == 321, "wire/new scene exact area");
        cases = cases + 1;

        reset;
        scene(100, {112'd0, b, a});
        capture(201, 100, 0, 322, a);
        scene_start(101, {112'd0, a, b});
        while (dut.state != 5) cyc(1);
        packet_meta = meta;
        packet_meta[31:0] = 101;
        wire_done = 1;
        cyc(1);
        wire_done = 0;
        check(dut.flight_bound[0] && !dut.flight_previous[0] && dut.flight_slot[0] == 1,
              "wire/MAP_APPLY current mapped slot");
        reply(201, 100, 0, 1, 322);
        cyc(140);
        expect_slot(0, 0, 0);
        expect_slot(1, 1, 201);
        check(action_count == 1 && action_values[0] == 322, "wire/MAP_APPLY exact area");
        cases = cases + 1;

        reset;
        scene(100, {112'd0, b, a});
        capture(202, 100, 0, 323, a);
        scene_start(101, {112'd0, a, b});
        while (dut.state != 5) cyc(1);
        packet_meta = meta;
        packet_meta[31:0] = 101;
        wire_done = 1;
        scene_start(102, {112'd0, b, a});
        wire_done = 0;
        check(dut.flight_valid[0] && !dut.flight_bound[0], "interrupted wire context unbound");
        cyc(140);
        for (k = 103; k <= 114; k = k + 1) scene(k, k % 2 ? {112'd0, a, b} : {112'd0, b, a});
        reply(202, 100, 0, 1, 323);
        cyc(140);
        check(labels == 0 && action_count == 0, "unbound no generation revival");
        cases = cases + 1;

        reset;
        a = box(10, 50, 50, 50);
        b = box(90, 50, 50, 50);
        c = box(170, 50, 50, 50);
        d = box(250, 50, 50, 50);
        scene(100, {d, c, b, a});
        capture(210, 100, 0, 101, a);
        seal;
        capture(211, 100, 1, 102, b);
        seal;
        capture(212, 100, 2, 103, c);
        seal;
        capture(213, 100, 3, 104, d);
        seal;
        for (k = 101; k <= 112; k = k + 1) scene(k, k % 2 ? {a, b, c, d} : {d, c, b, a});
        reply(213, 100, 3, 1, 104);
        reply(211, 100, 1, 1, 102);
        reply(210, 100, 0, 1, 101);
        reply(212, 100, 2, 1, 103);
        cyc(160);
        expect_slot(0, 1, 210);
        expect_slot(1, 1, 211);
        expect_slot(2, 1, 212);
        expect_slot(3, 1, 213);
        check(action_count == 4, "repeated scene generations preserve all four");
        cases = cases + 1;

        reset;
        a = box(40, 40, 80, 80);
        b = box(160, 40, 80, 80);
        scene(100, {112'd0, b, a});
        capture(220, 100, 0, 432, a);
        seal;
        scene_start(101, {112'd0, a, b});
        while (!(dut.state == 4 && dut.direction && dut.row_index == 3)) cyc(1);
        reply(220, 100, 0, 1, 432);
        check(dut.state == 5 && dut.complete_found, "completion ready on MAP_APPLY");
        cyc(160);
        expect_slot(0, 0, 0);
        expect_slot(1, 1, 220);
        check(action_count == 1 && action_values[0] == 432, "terminal MAP_APPLY maps exactly once");
        cases = cases + 1;
        $display("PASS RESULT_WINDOWS cases=%0d checks=%0d trusted=%0d", cases, checks, TRUSTED);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "WATCHDOG");
    end
endmodule
