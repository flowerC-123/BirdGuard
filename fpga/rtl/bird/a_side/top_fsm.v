module top_fsm #(
    parameter MULTI_REQUEST = 0,
    parameter ALLOW_TIMEOUT_DEGRADE = 1,
    parameter [16:0] AREA_TH_L1 = 17'd200,
    parameter [16:0] AREA_TH_L2 = 17'd1000,
    parameter [31:0] L1_CYCLES = 32'd150_000_000,
    parameter [31:0] L2_CYCLES = 32'd300_000_000,
    parameter [31:0] L3_CYCLES = 32'd450_000_000,
    parameter [31:0] COOLDOWN_CYCLES = 32'd150_000_000,
    parameter [15:0] VOLT_LOW_MV = 16'd10500,
    parameter [15:0] VOLT_OK_MV = 16'd11000
) (
    input wire clk,
    input wire rst_n,

    input wire       matched,
    input wire [7:0] matched_decision,
    input wire [7:0] matched_confidence,
    input wire [7:0] matched_flags,
    input wire       confirmed_bird,
    input wire       timed_out,
    input wire       failed,

    input wire        desc_issue,
    input wire [16:0] motion_count,

    input  wire [16:0] authenticated_area,
    input  wire        authenticated_bird,
    input  wire        outstanding,
    output wire        cancel_inflight,

    input wire        voltage_valid,
    input wire [15:0] voltage_mv,

    output reg enable_level1,
    output reg enable_level2,
    output reg enable_level3,

    output wire [3:0] state_code,
    output wire       state_valid,
    output reg        unconfirmed,
    output wire [3:0] current_state
);

    localparam [3:0] S_IDLE     = 4'd0;
    localparam [3:0] S_DETECT   = 4'd1;
    localparam [3:0] S_DETER    = 4'd2;
    localparam [3:0] S_LEVEL1   = 4'd3;
    localparam [3:0] S_LEVEL2   = 4'd4;
    localparam [3:0] S_LEVEL3   = 4'd5;
    localparam [3:0] S_COOLDOWN = 4'd6;
    localparam [3:0] S_POWER    = 4'd7;

    localparam [3:0] D_STANDBY  = 4'd0;
    localparam [3:0] D_DETECT   = 4'd1;
    localparam [3:0] D_DETER    = 4'd2;
    localparam [3:0] D_COOL     = 4'd3;
    localparam [3:0] D_UNDERV   = 4'd4;

    reg [ 3:0] state;
    reg [31:0] timer;
    reg [16:0] area_latch;
    reg        degraded;
    reg [ 3:0] disp_code;
    reg        disp_valid;

    reg        request_pending;
    reg [16:0] request_area;
    reg        queued_bird;
    reg [16:0] queued_area;
    localparam [31:0] COOL_LOAD = (COOLDOWN_CYCLES > 0) ? COOLDOWN_CYCLES - 1 : 0;

    wire pending_now = MULTI_REQUEST ? outstanding : request_pending;
    wire [16:0] evidence_area = MULTI_REQUEST ? authenticated_area : request_area;

    assign cancel_inflight = MULTI_REQUEST &&
                             ((state==S_POWER) || (voltage_valid && voltage_mv<VOLT_LOW_MV));

    wire legacy_bird = request_pending && matched && confirmed_bird && !failed && !timed_out &&
                     (matched_decision == 8'd1) &&
                     (matched_confidence >= 8'd80) && (matched_confidence <= 8'd100) &&
                     (matched_flags == 8'd0);
    wire real_bird = MULTI_REQUEST ? (authenticated_bird && !cancel_inflight) : legacy_bird;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            timer           <= 32'd0;
            area_latch      <= 17'd0;
            degraded        <= 1'b0;
            enable_level1   <= 1'b0;
            enable_level2   <= 1'b0;
            enable_level3   <= 1'b0;
            unconfirmed     <= 1'b0;
            disp_code       <= D_STANDBY;
            disp_valid      <= 1'b0;
            request_pending <= 1'b0;
            request_area    <= 0;
            queued_bird     <= 1'b0;
            queued_area     <= 0;
        end else begin

            unconfirmed <= 1'b0;

            if (matched || timed_out || failed) request_pending <= 1'b0;
            if (desc_issue) begin
                request_pending <= 1'b1;
                request_area <= motion_count;
            end

            if(state!=S_COOLDOWN || (!MULTI_REQUEST && (desc_issue || matched || timed_out || failed)))
                queued_bird <= 1'b0;
            if (state == S_COOLDOWN && real_bird && (MULTI_REQUEST || !desc_issue)) begin
                queued_bird <= 1'b1;
                queued_area <= evidence_area;
            end

            case (state)

                S_IDLE: begin
                    disp_code <= D_STANDBY;

                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else if (real_bird) begin

                        area_latch <= evidence_area;
                        degraded <= 1'b0;
                        state <= S_DETER;
                        disp_code <= D_DETER;
                    end else if (desc_issue || (pending_now && (MULTI_REQUEST || (!matched && !timed_out && !failed)))) begin

                        degraded  <= 1'b0;
                        state     <= S_DETECT;
                        disp_code <= D_DETECT;
                    end
                end

                S_DETECT: begin
                    disp_code <= D_DETECT;

                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else if (real_bird) begin

                        area_latch <= evidence_area;
                        degraded   <= 1'b0;
                        disp_code  <= D_DETER;
                        state      <= S_DETER;
                    end else if (matched) begin

                        state <= (MULTI_REQUEST && outstanding) ? S_DETECT : S_IDLE;
                    end else if (timed_out) begin
                        if (ALLOW_TIMEOUT_DEGRADE) begin

                            area_latch <= evidence_area;
                            degraded   <= 1'b1;
                            disp_code  <= D_DETER;
                            state      <= S_DETER;
                        end else begin
                            degraded <= 1'b0;
                            state <= (MULTI_REQUEST && outstanding) ? S_DETECT : S_IDLE;
                        end
                    end else if (failed) begin

                        state <= (MULTI_REQUEST && outstanding) ? S_DETECT : S_IDLE;
                    end else if (MULTI_REQUEST && !outstanding && !desc_issue) begin

                        state <= S_IDLE;
                    end
                end

                S_DETER: begin
                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else if (degraded) begin

                        if (area_latch < AREA_TH_L1) begin
                            state <= S_IDLE;
                        end else if (area_latch < AREA_TH_L2) begin
                            enable_level1 <= 1'b1;
                            timer <= L1_CYCLES;
                            unconfirmed <= 1'b1;
                            state <= S_LEVEL1;
                        end else begin
                            enable_level2 <= 1'b1;
                            timer <= L2_CYCLES;
                            unconfirmed <= 1'b1;
                            state <= S_LEVEL2;
                        end
                    end else begin

                        if (area_latch < AREA_TH_L2) begin
                            enable_level2 <= 1'b1;
                            timer <= L2_CYCLES;
                            state <= S_LEVEL2;
                        end else begin
                            enable_level3 <= 1'b1;
                            timer <= L3_CYCLES;
                            state <= S_LEVEL3;
                        end
                    end
                end

                S_LEVEL1: begin
                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else begin
                        disp_code <= D_DETER;
                        if (timer == 32'd0) begin
                            enable_level1 <= 1'b0;
                            timer         <= COOL_LOAD;
                            disp_code     <= D_COOL;
                            state         <= S_COOLDOWN;
                        end else begin
                            timer <= timer - 1'b1;
                        end
                    end
                end

                S_LEVEL2: begin
                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else begin
                        disp_code <= D_DETER;
                        if (timer == 32'd0) begin
                            enable_level2 <= 1'b0;
                            timer         <= COOL_LOAD;
                            disp_code     <= D_COOL;
                            state         <= S_COOLDOWN;
                        end else begin
                            timer <= timer - 1'b1;
                        end
                    end
                end

                S_LEVEL3: begin
                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else begin
                        disp_code <= D_DETER;
                        if (timer == 32'd0) begin
                            enable_level3 <= 1'b0;
                            timer         <= COOL_LOAD;
                            disp_code     <= D_COOL;
                            state         <= S_COOLDOWN;
                        end else begin
                            timer <= timer - 1'b1;
                        end
                    end
                end

                S_COOLDOWN: begin
                    if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                        state <= S_POWER;
                    end else if (timer == 32'd0) begin
                        queued_bird <= 1'b0;

                        if(real_bird || (queued_bird && (MULTI_REQUEST || (!desc_issue && !matched && !timed_out && !failed))))begin
                            area_latch <= real_bird ? evidence_area : queued_area;
                            degraded <= 1'b0;
                            state <= S_DETER;
                            disp_code <= D_DETER;
                        end else if(desc_issue || (pending_now && (MULTI_REQUEST || (!matched && !timed_out && !failed))))begin
                            degraded <= 1'b0;
                            state <= S_DETECT;
                            disp_code <= D_DETECT;
                        end else begin
                            disp_code <= D_STANDBY;
                            state <= S_IDLE;
                        end
                    end else begin
                        disp_code <= D_COOL;
                        timer <= timer - 1'b1;
                    end
                end

                S_POWER: begin
                    disp_code <= D_UNDERV;

                    enable_level1 <= 1'b0;
                    enable_level2 <= 1'b0;
                    enable_level3 <= 1'b0;
                    queued_bird <= 1'b0;
                    request_pending <= 1'b0;
                    if (voltage_valid && voltage_mv > VOLT_OK_MV) begin
                        state <= S_IDLE;

                        request_pending <= desc_issue;
                    end
                end

                default: state <= S_IDLE;
            endcase

            if (voltage_valid && voltage_mv < VOLT_LOW_MV) begin
                enable_level1 <= 1'b0;
                enable_level2 <= 1'b0;
                enable_level3 <= 1'b0;
                queued_bird <= 1'b0;
                request_pending <= 1'b0;
            end
            disp_valid <= 1'b1;
        end
    end

    assign state_code = disp_code;
    assign state_valid = disp_valid;
    assign current_state = state;

endmodule
