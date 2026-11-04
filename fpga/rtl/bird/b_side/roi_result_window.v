// Match in-flight replies by session and request identity.
module roi_result_window #(
    parameter integer CLOCK_HZ = 50000000,
    REPLY_SECONDS = 6,
    parameter integer MAX_INFLIGHT = 4,
    MIN_CONFIDENCE = 80
) (
    input wire clk,
    rst_n,
    arm,
    cancel_all,
    abort_current,
    tx_wire_done,
    input wire [31:0] session_id,
    request_id,
    source_frame_id,
    input wire [15:0] roi_id,
    input wire reply_valid,
    input wire [31:0] reply_session,
    reply_request,
    input wire [7:0] reply_status,
    reply_decision,
    reply_confidence,
    reply_flags,
    input wire [31:0] reply_processing_ms,
    input wire reply_box_valid,
    input wire [15:0] reply_box_x,
    reply_box_y,
    reply_box_w,
    reply_box_h,
    output wire ready,
    output wire busy,
    output reg [2:0] pending_count,
    output reg matched,
    confirmed_bird,
    timed_out,
    failed,
    output reg [31:0] matched_session_id,
    matched_request_id,
    matched_frame_id,
    output reg [15:0] matched_roi_id,
    output reg [7:0] matched_status,
    matched_decision,
    matched_confidence,
    matched_flags,
    output reg [31:0] matched_processing_ms,
    output reg matched_box_valid,
    output reg [15:0] matched_box_x,
    matched_box_y,
    matched_box_w,
    matched_box_h
);

    localparam integer TICK_CYCLES = (CLOCK_HZ >= 1000) ? CLOCK_HZ / 1000 : 1;
    localparam integer DIV_W = (TICK_CYCLES > 1) ? $clog2(TICK_CYCLES) : 1;
    localparam integer DEADLINE_TICKS=(CLOCK_HZ*REPLY_SECONDS+TICK_CYCLES-1)/TICK_CYCLES+1;
    localparam integer AGE_W = (DEADLINE_TICKS > 1) ? $clog2(DEADLINE_TICKS + 1) : 1;
    localparam integer SLOT_W = (MAX_INFLIGHT > 1) ? $clog2(MAX_INFLIGHT) : 1;
    reg [DIV_W-1:0] divider;
    wire tick = divider == TICK_CYCLES - 1;
    reg [MAX_INFLIGHT-1:0] active, sent;
    reg [31:0] sid[0:MAX_INFLIGHT-1], rid[0:MAX_INFLIGHT-1], fid[0:MAX_INFLIGHT-1];
    reg [15:0] roi[0:MAX_INFLIGHT-1];
    reg [AGE_W-1:0] age[0:MAX_INFLIGHT-1];
    reg [SLOT_W-1:0] current_slot, free_slot, reply_slot, expired_slot;
    reg free_found, reply_found, expired_found, duplicate;

    wire retire_event = reply_found || expired_found;
    wire [SLOT_W-1:0] retire_slot = reply_found ? reply_slot : expired_slot;
    wire valid_semantics=(reply_flags & 8'hfe)==0 && reply_status<=5 &&
  ((reply_status==0 && ((reply_decision==1 && reply_confidence<=100) ||
                       (reply_decision==0 && reply_confidence==255))) ||
   (reply_status!=0 && reply_decision==255 && reply_confidence==255));
    integer k;
    always @* begin
        pending_count = 0;
        free_found = 0;
        reply_found = 0;
        expired_found = 0;
        duplicate = 0;
        free_slot = 0;
        reply_slot = 0;
        expired_slot = 0;
        for (k = 0; k < MAX_INFLIGHT; k = k + 1) begin
            if (active[k]) pending_count = pending_count + 1'b1;
            if (!active[k] && !free_found) begin
                free_found = 1;
                free_slot  = k;
            end
            if (active[k] && sid[k] == session_id && rid[k] == request_id) duplicate = 1;
            if(active[k] && sent[k] && age[k]!=0 && reply_valid && valid_semantics &&
      reply_session==sid[k] && reply_request==rid[k] && !reply_found)begin
                reply_found = 1;
                reply_slot  = k;
            end
            if (active[k] && sent[k] && age[k] == 0 && !expired_found) begin
                expired_found = 1;
                expired_slot  = k;
            end
        end
    end
    assign busy  = |active;

    assign ready = free_found && !(|(active & ~sent)) && !cancel_all;
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            divider <= 0;
            active <= 0;
            sent <= 0;
            current_slot <= 0;
            matched <= 0;
            confirmed_bird <= 0;
            timed_out <= 0;
            failed <= 0;
            matched_session_id <= 0;
            matched_request_id <= 0;
            matched_frame_id <= 0;
            matched_roi_id <= 0;
            matched_status <= 0;
            matched_decision <= 0;
            matched_confidence <= 0;
            matched_flags <= 0;
            matched_processing_ms <= 0;
            matched_box_valid <= 0;
            matched_box_x <= 0;
            matched_box_y <= 0;
            matched_box_w <= 0;
            matched_box_h <= 0;
            for (i = 0; i < MAX_INFLIGHT; i = i + 1) begin
                sid[i] <= 0;
                rid[i] <= 0;
                fid[i] <= 0;
                roi[i] <= 0;
                age[i] <= 0;
            end
        end else begin
            if (tick) divider <= 0;
            else divider <= divider + 1'b1;
            matched <= 0;
            confirmed_bird <= 0;
            timed_out <= 0;
            failed <= 0;
            matched_box_valid <= 0;
            matched_box_x <= 0;
            matched_box_y <= 0;
            matched_box_w <= 0;
            matched_box_h <= 0;
            if (cancel_all) begin
                active <= 0;
                sent   <= 0;
            end else begin
                for (i = 0; i < MAX_INFLIGHT; i = i + 1)
                if (tick && active[i] && sent[i] && age[i] != 0) age[i] <= age[i] - 1'b1;
                if(arm && ready && !duplicate && session_id!=0 && request_id!=0 && !abort_current)begin
                    active[free_slot] <= 1;
                    sent[free_slot] <= 0;
                    age[free_slot] <= 0;
                    current_slot <= free_slot;
                    sid[free_slot] <= session_id;
                    rid[free_slot] <= request_id;
                    fid[free_slot] <= source_frame_id;
                    roi[free_slot] <= roi_id;
                end
                if (active[current_slot] && !sent[current_slot]) begin
                    if (abort_current) begin
                        active[current_slot] <= 0;
                        sent[current_slot]   <= 0;
                    end else if (tx_wire_done) begin
                        sent[current_slot] <= 1;
                        age[current_slot]  <= DEADLINE_TICKS;
                    end
                end

                if (retire_event) begin
                    active[retire_slot] <= 0;
                    sent[retire_slot] <= 0;
                    matched_session_id <= sid[retire_slot];
                    matched_request_id <= rid[retire_slot];
                    matched_frame_id <= fid[retire_slot];
                    matched_roi_id <= roi[retire_slot];
                end
                if (reply_found) begin
                    matched <= 1;
                    matched_status <= reply_status;
                    matched_decision <= reply_decision;
                    matched_confidence <= reply_confidence;
                    matched_flags <= reply_flags;
                    matched_processing_ms <= reply_processing_ms;
                    failed <= reply_status != 0;
                    confirmed_bird<=reply_status==0 && reply_decision==1 && reply_confidence>=MIN_CONFIDENCE && reply_flags==0;
                    if(reply_box_valid && reply_status==0 && reply_decision==1 &&
        reply_confidence>=MIN_CONFIDENCE && reply_confidence<=100 && reply_flags==0 &&
        reply_box_w!=0 && reply_box_h!=0)begin
                        matched_box_valid <= 1;
                        matched_box_x <= reply_box_x;
                        matched_box_y <= reply_box_y;
                        matched_box_w <= reply_box_w;
                        matched_box_h <= reply_box_h;
                    end
                end else if (expired_found) begin
                    timed_out <= 1;
                    failed <= 1;
                    matched_status <= 8'd5;
                    matched_decision <= 8'hff;
                    matched_confidence <= 8'hff;
                    matched_flags <= 0;
                    matched_processing_ms <= 0;
                end
            end
        end
    end
endmodule
