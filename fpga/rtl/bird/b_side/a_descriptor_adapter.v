module a_descriptor_adapter #(
    parameter LEASE_TIMEOUT_CYCLES = 7500000,
    MAX_CAPTURE_CYCLES = 75000000
) (
    input wire clk,
    rst_n,
    cancel,
    input wire link_session_valid,
    input wire [31:0] link_session_id,
    input wire desc_valid,
    output wire desc_ready,
    input wire [31:0] session_id,
    request_id,
    input wire [159:0] crop_meta,
    input wire bbox_done,
    input wire [16:0] motion_count,
    output wire lease_valid,
    input wire lease_gnt,
    input wire [31:0] lease_frame_id,
    input wire [15:0] lease_width,
    lease_height,
    output reg lease_release,
    input wire reader_idle,
    output wire force_flush,
    output wire t_desc_valid,
    input wire t_desc_ready,
    output reg [31:0] t_session,
    t_request,
    input wire t_busy,
    output reg [159:0] t_meta,
    output wire t_lease_valid,
    output reg [31:0] held_frame,
    output reg [15:0] held_width,
    held_height,
    input wire t_lease_release,
    input wire t_error,
    output wire t_cancel,
    output reg captured,
    rejected,
    retired,
    output reg [3:0] error_code,
    output reg [31:0] origin_session,
    output reg [16:0] captured_motion,
    output reg motion_known,
    output wire busy
);
    localparam IDLE = 0, LEASE = 1, FORWARD = 2, ACTIVE = 3, DRAIN = 4;
    reg [2:0] state;
    reg held;
    reg [31:0] ticks, last_epoch, last_request;
    reg area_pending;
    reg [31:0] area_frame;
    reg [16:0] saved_motion;
    wire [15:0] sw=crop_meta[63:48],sh=crop_meta[79:64],x=crop_meta[95:80],y=crop_meta[111:96],w=crop_meta[127:112],h=crop_meta[143:128];
    wire [31:0] pixels = {16'd0, w} * {16'd0, h};
    wire geometry=sw>0 && sw<=4096 && sh>0 && sh<=4096 && w>0 && h>0 && (crop_meta[151:144]==1 || (w<=256 && h<=256)) &&
  ({1'b0,x}+{1'b0,w})<={1'b0,sw} && ({1'b0,y}+{1'b0,h})<={1'b0,sh};
    wire id_ok=session_id!=0 && request_id!=0 && (last_epoch!=link_session_id || request_id>last_request);
    wire epoch_changed = !link_session_valid || link_session_id != t_session;
    assign desc_ready=state==IDLE && t_desc_ready && reader_idle && link_session_valid && link_session_id!=0 && !cancel && !lease_gnt;
    assign lease_valid = state == LEASE && !cancel && !epoch_changed;
    assign t_desc_valid = state == FORWARD && !cancel && !epoch_changed;
    assign t_lease_valid = held;
    assign busy = state != IDLE || t_busy;
    assign t_cancel = cancel || state == DRAIN || (state != IDLE && epoch_changed);
    assign force_flush = state == DRAIN;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= DRAIN;
            held <= 0;
            ticks <= 0;
            last_epoch <= 0;
            last_request <= 0;
            lease_release <= 0;
            t_session <= 0;
            t_request <= 0;
            t_meta <= 0;
            held_frame <= 0;
            held_width <= 0;
            held_height <= 0;
            captured <= 0;
            rejected <= 0;
            retired <= 0;
            error_code <= 0;
            origin_session <= 0;
            captured_motion <= 0;
            motion_known <= 0;
            area_pending <= 0;
            area_frame <= 0;
            saved_motion <= 0;
        end else begin
            lease_release <= 0;
            captured <= 0;
            rejected <= 0;
            retired <= 0;

            if (bbox_done && desc_valid && !area_pending) begin
                area_pending <= 1;
                area_frame   <= crop_meta[31:0];
                saved_motion <= motion_count;
            end
            if (!desc_valid) area_pending <= 0;
            if (state != IDLE && state != DRAIN && (cancel || epoch_changed)) begin
                state <= DRAIN;
                rejected <= 1;
                retired <= 1;
                error_code <= 7;

                if (lease_gnt && state == LEASE) held <= 1;
            end else
                case (state)
                    IDLE: begin
                        if (lease_gnt) lease_release <= 1;
                        if (desc_valid && desc_ready) begin
                            t_meta <= crop_meta;
                            t_session <= link_session_id;
                            t_request <= request_id;
                            origin_session <= session_id;
                            captured_motion <= bbox_done ? motion_count : saved_motion;
                            motion_known<=bbox_done || (area_pending && area_frame==crop_meta[31:0]);
                            area_pending <= 0;
                            captured <= 1;
                            error_code <= 0;
                            ticks <= 0;
                            if (!id_ok) begin
                                rejected <= 1;
                                retired <= 1;
                                error_code <= 1;
                            end else begin
                                last_epoch   <= link_session_id;
                                last_request <= request_id;
                                if (!geometry) begin
                                    rejected <= 1;
                                    retired <= 1;
                                    error_code <= 2;
                                end
      else if((crop_meta[151:144]!=1 && pixels>5461) || pixels>131071)begin
                                    rejected <= 1;
                                    retired <= 1;
                                    error_code <= 3;
                                end
       
      else if((crop_meta[151:144]!=1 && crop_meta[151:144]!=2) || crop_meta[159:152]!=0)begin
                                    rejected <= 1;
                                    retired <= 1;
                                    error_code <= 4;
                                end else state <= LEASE;
                            end
                        end
                    end
                    LEASE: begin
                        if (lease_gnt) begin
                            held <= 1;
                            held_frame <= lease_frame_id;
                            held_width <= lease_width;
                            held_height <= lease_height;
                            if(lease_frame_id!=t_meta[31:0] || lease_width!=t_meta[63:48] || lease_height!=t_meta[79:64])begin
                                state <= DRAIN;
                                rejected <= 1;
                                retired <= 1;
                                error_code <= 5;
                            end else begin
                                state <= FORWARD;
                                ticks <= 0;
                            end
                        end else if (ticks >= LEASE_TIMEOUT_CYCLES - 1) begin
                            state <= DRAIN;
                            rejected <= 1;
                            retired <= 1;
                            error_code <= 6;
                        end else ticks <= ticks + 1'b1;
                    end
                    FORWARD:
                    if (t_desc_ready) begin
                        state <= ACTIVE;
                        ticks <= 0;
                    end else if (ticks >= LEASE_TIMEOUT_CYCLES - 1) begin
                        state <= DRAIN;
                        rejected <= 1;
                        retired <= 1;
                        error_code <= 6;
                    end else ticks <= ticks + 1'b1;
                    ACTIVE: begin
                        if (t_lease_release) begin
                            lease_release <= 1;
                            held <= 0;
                        end else if (held) begin
                            if (ticks >= MAX_CAPTURE_CYCLES - 1) begin
                                state <= DRAIN;
                                rejected <= 1;
                                retired <= 1;
                                error_code <= 9;
                            end else ticks <= ticks + 1'b1;
                        end
                        if (t_error) begin
                            rejected <= 1;
                            retired <= 1;
                            error_code <= 8;
                        end
                        if (!t_busy) state <= IDLE;
                    end
                    DRAIN: begin

                        if (lease_gnt) held <= 1;
                        if (reader_idle && !t_busy) begin
                            lease_release <= 1;
                            held <= 0;
                            state <= IDLE;
                        end
                    end
                    default: state <= DRAIN;
                endcase
        end
    end
endmodule
