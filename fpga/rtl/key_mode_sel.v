module key_mode_sel #(
    parameter CLK_HZ      = 74250000,
    parameter DEBOUNCE_MS = 20
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_n,
    output reg  [1:0] mode,
    output reg        mode_tick
);

    localparam integer DB_TICKS = CLK_HZ / 1000 * DEBOUNCE_MS;
    localparam integer CW = 24;

    reg [   1:0] sync;
    reg [CW-1:0] db_cnt;
    reg          armed;
    reg          pressed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync      <= 2'b11;
            db_cnt    <= {CW{1'b0}};
            mode      <= 2'd0;
            mode_tick <= 1'b0;
            armed     <= 1'b0;
            pressed   <= 1'b0;
        end else begin
            sync      <= {sync[0], key_n};
            mode_tick <= 1'b0;

            if (sync[1] != sync[0]) begin

                db_cnt <= {CW{1'b0}};
                armed  <= 1'b1;
            end else if (armed) begin
                if (db_cnt != DB_TICKS[CW-1:0]) begin
                    db_cnt <= db_cnt + 1'b1;
                end else begin

                    armed <= 1'b0;
                    if (sync[1] == 1'b0) begin
                        pressed <= 1'b1;
                    end else if (pressed) begin
                        pressed   <= 1'b0;
                        mode      <= {1'b0, ~mode[0]};
                        mode_tick <= 1'b1;
                    end
                end
            end

        end
    end

endmodule

module board_ui_outputs (
    input wire camera_diag,
    camera_done,
    hs_seen,
    blink,
    input wire buzzer_active,
    led_active,
    input wire [7:0] dig_data,
    sel_data,
    output wire buzzer_n,
    led_n,
    output wire [7:0] dig,
    sel
);
    wire camera_on = camera_done && (hs_seen || blink);
    assign buzzer_n = ~buzzer_active;

    assign led_n = (camera_diag ? camera_on : led_active);
    assign dig = camera_diag ? (camera_on ? 8'h00 : 8'hff) : dig_data;
    assign sel = camera_diag ? (camera_on ? 8'h00 : 8'hff) : sel_data;
endmodule

module board_display_keys #(
    parameter integer CLK_HZ = 75000000,
    DEBOUNCE_MS = 20
) (
    input wire clk,
    rst_n,
    input wire [3:0] key_n,
    input wire frame_vs,
    output reg [1:0] mode,
    output reg [3:0] click
);
    localparam integer SAMPLE_TICKS = CLK_HZ / 1000;
    localparam integer TW = SAMPLE_TICKS > 1 ? $clog2(SAMPLE_TICKS) : 1;
    localparam integer DW = DEBOUNCE_MS > 1 ? $clog2(DEBOUNCE_MS + 1) : 1;
    (* async_reg="true" *) reg [3:0] key_s1, key_s2;
    reg [TW-1:0] tick;
    reg [DW-1:0] count[0:3];
    reg [3:0] stable, pressed;
    reg [1:0] requested;
    reg vs_d;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_s1 <= 4'hf;
            key_s2 <= 4'hf;
            stable <= 4'hf;
            pressed <= 0;
            tick <= 0;
            mode <= 0;
            requested <= 0;
            click <= 0;
            vs_d <= 0;
            for (i = 0; i < 4; i = i + 1) count[i] <= 0;
        end else begin
            key_s1 <= key_n;
            key_s2 <= key_s1;
            click  <= 0;
            vs_d   <= frame_vs;
            if (tick == SAMPLE_TICKS - 1) begin
                tick <= 0;
                for (i = 0; i < 4; i = i + 1) begin
                    if (key_s2[i] == stable[i]) count[i] <= 0;
                    else if (count[i] == DEBOUNCE_MS - 1) begin
                        count[i]  <= 0;
                        stable[i] <= key_s2[i];
                        if (!key_s2[i]) pressed[i] <= 1;
                        else begin
                            click[i]   <= pressed[i];
                            pressed[i] <= 0;
                        end
                    end else count[i] <= count[i] + 1'b1;
                end
            end else tick <= tick + 1'b1;
            if (click[1]) requested <= 0;
            else if (click[2]) requested <= 1;
            else if (click[3]) requested <= 2;
            else if (click[0]) requested <= requested == 1 ? 0 : 1;
            if (frame_vs && !vs_d) mode <= requested;
        end
    end
    // synthesis translate_off
    initial
        if (CLK_HZ < 1000 || CLK_HZ % 1000 != 0 || DEBOUNCE_MS < 1)
            $fatal(1, "Invalid key debounce timing");
    // synthesis translate_on
endmodule

module board_controls #(
    parameter CLK_HZ = 75000000,
    DEBOUNCE_MS = 20,
    LONG_MS = 800
) (
    input wire clk,
    rst_n,
    input wire [3:0] key_n,
    input wire frame_vs,
    output reg [6:0] requested_cfg,
    output reg [1:0] view_mode,
    output reg [3:0] short_event,
    long_event
);
    localparam SAMPLE_TICKS = CLK_HZ / 1000, TW = $clog2(
        SAMPLE_TICKS + 1
    ), DW = $clog2(
        DEBOUNCE_MS + 1
    ), LW = $clog2(
        LONG_MS + 1
    );
    (* async_reg="true" *) reg [3:0] key_s1, key_s2;
    reg [TW-1:0] tick;
    reg [DW-1:0] count[0:3];
    reg [LW-1:0] held [0:3];
    reg [3:0] stable, armed, long_sent;
    reg [1:0] view_requested;
    reg vs_d;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_s1 <= 15;
            key_s2 <= 15;
            stable <= 15;
            armed <= 0;
            long_sent <= 0;
            tick <= 0;
            short_event <= 0;
            long_event <= 0;
            requested_cfg <= 7'h21;
            view_mode <= 0;
            view_requested <= 0;
            vs_d <= 0;
            for (i = 0; i < 4; i = i + 1) begin
                count[i] <= 0;
                held[i]  <= 0;
            end
        end else begin
            key_s1 <= key_n;
            key_s2 <= key_s1;
            short_event <= 0;
            long_event <= 0;
            vs_d <= frame_vs;
            if (tick == SAMPLE_TICKS - 1) begin
                tick <= 0;
                for (i = 0; i < 4; i = i + 1) begin
                    if (key_s2[i] == stable[i]) count[i] <= 0;
                    else if (count[i] == DEBOUNCE_MS - 1) begin
                        count[i]  <= 0;
                        stable[i] <= key_s2[i];
                        if (!key_s2[i]) begin
                            armed[i] <= 1;
                            long_sent[i] <= 0;
                            held[i] <= 0;
                        end else begin
                            short_event[i] <= armed[i] && !long_sent[i];
                            armed[i] <= 0;
                            held[i] <= 0;
                        end
                    end else count[i] <= count[i] + 1'b1;

                    if (armed[i] && !stable[i] && !key_s2[i] && !long_sent[i]) begin
                        if (held[i] == LONG_MS - 1) begin
                            long_sent[i]  <= 1;
                            long_event[i] <= 1;
                        end else held[i] <= held[i] + 1'b1;
                    end
                end
            end else tick <= tick + 1'b1;
            if (short_event[0] || short_event[2]) requested_cfg[1:0] <= requested_cfg[1:0] + 1'b1;
            if (short_event[1] || long_event[2])
                view_requested <= view_requested == 2 ? 0 : view_requested + 1'b1;
            if (short_event[3])
                requested_cfg[4:2] <= requested_cfg[4:2] == 5 ? 0 : requested_cfg[4:2] + 1'b1;
            if (long_event[3])
                requested_cfg[6:5] <= requested_cfg[6:5] == 2 ? 0 : requested_cfg[6:5] + 1'b1;
            if (frame_vs && !vs_d) view_mode <= view_requested;
        end
    end
    // synthesis translate_off
    initial
        if (CLK_HZ < 1000 || CLK_HZ % 1000 || DEBOUNCE_MS < 1 || LONG_MS <= DEBOUNCE_MS)
            $fatal(1, "Invalid key parameters");
    // synthesis translate_on
endmodule

module config_mailbox (
    input wire src_clk,
    src_rst_n,
    input wire [6:0] requested,
    output reg [6:0] applied,
    output wire waiting,
    input wire dst_clk,
    dst_rst_n,
    input wire frame_start,
    output wire [6:0] dst_cfg
);
    wire common_reset_n = src_rst_n && dst_rst_n;
    reg [6:0] hold_data, active;
    reg request, ack, seen_ack;
    (* async_reg="true" *) reg ack_s1, ack_s2, req_s1, req_s2;
    wire commit = frame_start && (req_s2 != ack);
    assign dst_cfg = commit ? hold_data : active;
    assign waiting = (requested != applied) || (request != ack_s2);
    always @(posedge src_clk or negedge common_reset_n) begin
        if (!common_reset_n) begin
            hold_data <= 7'h21;
            applied <= 7'h21;
            request <= 0;
            seen_ack <= 0;
            ack_s1 <= 0;
            ack_s2 <= 0;
        end else begin
            ack_s1 <= ack;
            ack_s2 <= ack_s1;
            if (ack_s2 != seen_ack) begin
                applied  <= hold_data;
                seen_ack <= ack_s2;
            end

            if (request == ack_s2 && seen_ack == ack_s2 && requested != hold_data) begin
                hold_data <= requested;
                request   <= ~request;
            end
        end
    end
    always @(posedge dst_clk or negedge common_reset_n) begin
        if (!common_reset_n) begin
            active <= 7'h21;
            ack <= 0;
            req_s1 <= 0;
            req_s2 <= 0;
        end else begin
            req_s1 <= request;
            req_s2 <= req_s1;
            if (commit) begin
                active <= hold_data;
                ack <= req_s2;
            end
        end
    end
endmodule
