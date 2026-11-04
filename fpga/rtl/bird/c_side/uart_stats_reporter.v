module uart_stats_reporter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        report_tick,
    input  wire [15:0] voltage_mv,
    input  wire [15:0] max_voltage_mv,
    input  wire [15:0] min_voltage_mv,
    input  wire [15:0] total_triggers,
    input  wire [ 4:0] current_hour,
    input  wire [15:0] current_hour_count,
    output reg  [ 7:0] tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,
    output reg         busy
);
    localparam LAST_INDEX = 7'd63;
    localparam IDLE = 2'd0, SEND = 2'd1, WAIT_BUSY = 2'd2, WAIT_READY = 2'd3;
    reg [1:0] state;
    reg [6:0] index;
    reg report_tick_d;
    reg [15:0] v_latch, max_latch, min_latch, trig_latch, hour_count_latch;
    reg [4:0] hour_latch;

    function [7:0] digit5;
        input [15:0] value;
        input [2:0] place;
        begin
            case (place)
                3'd0: digit5 = 8'd48 + (value / 10000) % 10;
                3'd1: digit5 = 8'd48 + (value / 1000)  % 10;
                3'd2: digit5 = 8'd48 + (value / 100)   % 10;
                3'd3: digit5 = 8'd48 + (value / 10)    % 10;
                default: digit5 = 8'd48 + value % 10;
            endcase
        end
    endfunction

    function [7:0] message_byte;
        input [6:0] p;
        begin
            if (p == 0) message_byte = "V";
            else if (p == 1) message_byte = "=";
            else if (p >= 2 && p <= 6) message_byte = digit5(v_latch, p - 2);
            else if (p == 7) message_byte = ",";
            else if (p == 8) message_byte = "M";
            else if (p == 9) message_byte = "A";
            else if (p == 10) message_byte = "X";
            else if (p == 11) message_byte = "=";
            else if (p >= 12 && p <= 16) message_byte = digit5(max_latch, p - 12);
            else if (p == 17) message_byte = ",";
            else if (p == 18) message_byte = "M";
            else if (p == 19) message_byte = "I";
            else if (p == 20) message_byte = "N";
            else if (p == 21) message_byte = "=";
            else if (p >= 22 && p <= 26) message_byte = digit5(min_latch, p - 22);
            else if (p == 27) message_byte = ",";
            else if (p == 28) message_byte = "T";
            else if (p == 29) message_byte = "R";
            else if (p == 30) message_byte = "I";
            else if (p == 31) message_byte = "G";
            else if (p == 32) message_byte = "=";
            else if (p >= 33 && p <= 37) message_byte = digit5(trig_latch, p - 33);
            else if (p == 38) message_byte = ",";
            else if (p == 39) message_byte = "H";
            else if (p == 40) message_byte = "O";
            else if (p == 41) message_byte = "U";
            else if (p == 42) message_byte = "R";
            else if (p == 43) message_byte = "=";
            else if (p == 44) message_byte = 8'd48 + (hour_latch / 10);
            else if (p == 45) message_byte = 8'd48 + (hour_latch % 10);
            else if (p == 46) message_byte = ",";
            else if (p == 47) message_byte = "H";
            else if (p == 48) message_byte = "O";
            else if (p == 49) message_byte = "U";
            else if (p == 50) message_byte = "R";
            else if (p == 51) message_byte = "_";
            else if (p == 52) message_byte = "T";
            else if (p == 53) message_byte = "R";
            else if (p == 54) message_byte = "I";
            else if (p == 55) message_byte = "G";
            else if (p == 56) message_byte = "=";
            else if (p >= 57 && p <= 61) message_byte = digit5(hour_count_latch, p - 57);
            else if (p == 62) message_byte = 8'h0d;
            else message_byte = 8'h0a;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 0;
            tx_data <= 0;
            tx_valid <= 0;
            busy <= 0;
            report_tick_d <= 0;
            v_latch <= 0;
            max_latch <= 0;
            min_latch <= 0;
            trig_latch <= 0;
            hour_latch <= 0;
            hour_count_latch <= 0;
        end else begin
            report_tick_d <= report_tick;
            tx_valid <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (report_tick && !report_tick_d) begin
                        v_latch <= voltage_mv;
                        max_latch <= max_voltage_mv;
                        min_latch <= min_voltage_mv;
                        trig_latch <= total_triggers;
                        hour_latch <= current_hour;
                        hour_count_latch <= current_hour_count;
                        index <= 0;
                        busy <= 1'b1;
                        state <= SEND;
                    end
                end
                SEND:
                if (tx_ready) begin
                    tx_data <= message_byte(index);
                    tx_valid <= 1'b1;
                    state <= WAIT_BUSY;
                end
                WAIT_BUSY: if (!tx_ready) state <= WAIT_READY;
                WAIT_READY:
                if (tx_ready) begin
                    if (index == LAST_INDEX) begin
                        busy  <= 1'b0;
                        state <= IDLE;
                    end else begin
                        index <= index + 1'b1;
                        state <= SEND;
                    end
                end
                default:   state <= IDLE;
            endcase
        end
    end
endmodule
