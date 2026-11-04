module roi_result_guard #(
    parameter integer CLOCK_HZ = 75000000,
    parameter integer REPLY_SECONDS = 6,
    parameter integer MIN_CONFIDENCE = 80
) (
    input wire clk,
    rst_n,
    arm,
    cancel,
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
    output reg busy,
    output reg waiting,
    output reg matched,
    confirmed_bird,
    output reg timed_out,
    failed,
    output reg [31:0] matched_frame_id,
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
    localparam integer LIMIT = CLOCK_HZ * REPLY_SECONDS;
    reg [31:0] sid, rid, fid, ticks;
    reg [15:0] roi;
    wire valid_semantics=(reply_flags & 8'hfe)==0 && reply_status<=5 &&
  ((reply_status==0 && ((reply_decision==1 && reply_confidence<=100) ||
                       (reply_decision==0 && reply_confidence==255))) ||
   (reply_status!=0 && reply_decision==255 && reply_confidence==255));
    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 0;
            waiting <= 0;
            matched <= 0;
            confirmed_bird <= 0;
            timed_out <= 0;
            failed <= 0;
            sid <= 0;
            rid <= 0;
            fid <= 0;
            roi <= 0;
            ticks <= 0;
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
        end else begin
            matched <= 0;
            confirmed_bird <= 0;
            timed_out <= 0;
            failed <= 0;
            matched_box_valid <= 0;
            matched_box_x <= 0;
            matched_box_y <= 0;
            matched_box_w <= 0;
            matched_box_h <= 0;
            if (cancel) begin
                busy <= 0;
                waiting <= 0;
            end else if (!busy) begin
                if (arm && session_id != 0 && request_id != 0) begin
                    busy <= 1;
                    waiting <= 0;
                    sid <= session_id;
                    rid <= request_id;
                    fid <= source_frame_id;
                    roi <= roi_id;
                    ticks <= 0;
                end
            end else if (!waiting) begin
                if (tx_wire_done) begin
                    waiting <= 1;
                    ticks   <= 0;
                end
            end else if (ticks >= LIMIT - 1) begin
                busy <= 0;
                waiting <= 0;
                timed_out <= 1;
                failed <= 1;
            end else begin
                ticks <= ticks + 1;
                if(reply_valid && reply_session==sid && reply_request==rid && valid_semantics) begin
                    busy <= 0;
                    waiting <= 0;
                    matched <= 1;
                    matched_frame_id <= fid;
                    matched_roi_id <= roi;
                    matched_status <= reply_status;
                    matched_decision <= reply_decision;
                    matched_confidence <= reply_confidence;
                    matched_flags <= reply_flags;
                    matched_processing_ms <= reply_processing_ms;
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
                    failed <= reply_status != 0;
                end
            end
        end
    end
endmodule
