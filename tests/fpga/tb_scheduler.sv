`timescale 1ns / 1ps
module tb_scheduler;
    parameter  BURST = 4;
    localparam QUOTA = BURST;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0, bbox = 0, force_inspect = 0, ready = 1, drop = 0;
    reg [31:0] frame_id = 1, published = 1, drop_frame = 0;
    reg [9:0] x0 = 20, x1 = 35;
    reg [8:0] y0 = 20, y1 = 35;
    reg [3:0] roi = 0;
    reg [16:0] area = 256, motion = 256;
    wire dv;
    wire [31:0] sid, rid;
    wire [159:0] meta;
    wire [ 16:0] dm;
    wire [ 15:0] dropped;
    wire [  2:0] queued;
    desc_packer #(
        .MIN_AREA(1),
        .MOTION_FIRST(1),
        .COMPACT_ROI(0),
        .PRESERVE_CONTEXT(1)
        , .MOTION_BURST(BURST)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .min_x(x0),
        .max_x(x1),
        .min_y(y0),
        .max_y(y1),
        .target_area(area),
        .roi_id(roi),
        .bbox_valid(bbox),
        .force_inspect(force_inspect),
        .frame_motion_count(motion),
        .frame_id(frame_id),
        .published_frame_id(published),
        .cfg_session_id(32'd1),
        .drop_strobe(drop),
        .drop_frame_id(drop_frame),
        .desc_valid(dv),
        .desc_ready(ready),
        .session_id(sid),
        .request_id(rid),
        .crop_meta(meta),
        .desc_motion_count(dm),
        .dropped(dropped),
        .queued(queued)
    );
    integer targets = 0, patrols = 0, checks = 0, last_req = 0, seen_count = 0, first_new_kind = -1;
    integer seen_frame[0:63], seen_motion[0:63], seen_roi[0:63];
    reg record_first = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            targets = 0;
            patrols = 0;
            last_req = 0;
            seen_count = 0;
            first_new_kind = -1;
        end else if (dv && ready) begin
            if (rid <= last_req || sid != 1) $fatal(1, "IDENTITY_NOT_MONOTONIC");
            last_req = rid;
            if (meta[31:0] != published)
                $fatal(1, "STALE_FRAME_ACCEPTED source=%0d published=%0d", meta[31:0], published);
            if (dm != 0) targets = targets + 1;
            else patrols = patrols + 1;
            seen_frame[seen_count] = meta[31:0];
            seen_motion[seen_count] = dm;
            seen_roi[seen_count] = meta[47:32];
            seen_count = seen_count + 1;
            if (record_first && first_new_kind < 0) first_new_kind = dm != 0;
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
            if (!cond) $fatal(1, "SCHED_EDGE check=%0d %s", checks, msg);
        end
    endtask
    task reset_case;
        begin
            rst_n = 0;
            bbox = 0;
            force_inspect = 0;
            ready = 1;
            drop = 0;
            frame_id = 1;
            published = 1;
            record_first = 0;
            motion = 256;
            area = 256;
            roi = 0;
            tick(5);
            rst_n = 1;
            tick(2);
        end
    endtask
    task target(input integer f, input integer r);
        begin
            frame_id = f;
            published = f;
            roi = r;
            bbox = 1;
            tick(1);
            bbox = 0;
            tick(6);
        end
    endtask
    task quota;
        integer i;
        begin
            for (i = 0; i < QUOTA; i = i + 1) target(i + 1, i % 4);
            ck(targets == QUOTA && patrols == 0, "quota setup");
        end
    endtask
    integer before_count, before_patrol, i;
    initial begin

        reset_case;
        quota;
        frame_id = 20;
        published = 20;
        roi = 3;
        motion = 1234;
        bbox = 1;
        force_inspect = 1;
        tick(1);
        bbox = 0;
        force_inspect = 0;
        tick(12);
        ck(targets == QUOTA + 1 && patrols == 1 && dropped == 0,
           "simultaneous due+bbox retained both requests");
        ck(seen_frame[QUOTA] == 20 && seen_motion[QUOTA] == 1234 && seen_roi[QUOTA] == 3,
           "target identity and motion retained");

        reset_case;
        quota;
        ready = 0;
        force_inspect = 1;
        tick(1);
        force_inspect = 0;
        tick(4);
        ck(dv && dm == 0, "waiting patrol prepared");
        before_count = targets;
        roi = 2;
        motion = 987;
        bbox = 1;
        ready = 1;
        tick(1);
        bbox = 0;
        tick(12);
        ck(targets == before_count + 1 && patrols == 1,
           "accepted patrol plus new target both survive");
        ck(seen_frame[QUOTA+1] == QUOTA && seen_motion[QUOTA+1] == 987 && seen_roi[QUOTA+1] == 2,
           "no payload cross-talk");

        reset_case;
        for (i = 0; i < QUOTA - 1; i = i + 1) target(i + 1, i % 4);
        ready = 0;
        force_inspect = 1;
        tick(1);
        force_inspect = 0;
        tick(4);
        ck(dv && dm == 0, "preempt setup");
        frame_id = 20;
        published = 20;
        roi = 3;
        bbox = 1;
        tick(1);
        bbox = 0;
        tick(4);
        ck(dv && dm != 0, "fresh fourth target replaces waiting patrol");
        record_first = 1;
        ready = 1;
        tick(12);
        record_first = 0;
        ck(first_new_kind == 1 && targets == QUOTA && patrols == 1,
           "fourth target first then retained patrol");

        reset_case;
        ready = 0;
        frame_id = 1;
        published = 1;
        for (i = 0; i < 4; i = i + 1) begin
            roi  = i;
            bbox = 1;
            tick(1);
        end
        bbox = 0;
        tick(1000);
        ck(dv && targets == 0, "held ready preserves descriptor");
        frame_id  = 2;
        published = 2;
        tick(12);
        ck(!dv && queued == 0, "overwritten frame fully evicted");
        frame_id = 3;
        published = 3;
        roi = 2;
        motion = 4321;
        bbox = 1;
        tick(1);
        bbox = 0;
        tick(4);
        drop = 1;
        drop_frame = 3;
        tick(1);
        drop = 0;
        tick(8);
        ck(!dv && queued == 0, "dropped frame fully evicted");
        frame_id = 4;
        published = 4;
        roi = 1;
        motion = 876;
        bbox = 1;
        tick(1);
        bbox = 0;
        tick(4);
        ready = 1;
        tick(10);
        ck(targets == 1 && seen_frame[0] == 4 && seen_motion[0] == 876,
           "fresh target recovers after long pressure and drops");

        reset_case;
        force_inspect = 1;
        tick(1);
        force_inspect = 0;
        tick(12);
        ck(patrols == 1 && targets == 0, "empty scene patrol preserved");

        ready = 0;
        target(2, 2);
        force_inspect = 1;
        tick(1);
        force_inspect = 0;
        reset_case;
        tick(12);
        ck(targets == 0 && patrols == 0 && !dv && queued == 0, "reset clears all pending work");
        target(1, 0);
        ck(targets == 1 && last_req == 1, "reset cleanly restarts request allocator");
        $display(
            "PASS SCHEDULER_EDGES burst=%0d checks=%0d one_cycle_collision ready_boundary priority_preemption drop_stale_backpressure reset static_coverage",
            BURST, checks);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "WATCHDOG");
    end
endmodule
