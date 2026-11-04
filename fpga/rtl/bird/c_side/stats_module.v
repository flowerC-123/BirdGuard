module stats_module (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] voltage_mv,
    input  wire        voltage_valid,
    input  wire        trigger_event,
    input  wire [ 4:0] current_hour,
    output reg  [15:0] max_voltage_mv,
    output reg  [15:0] min_voltage_mv,
    output reg  [15:0] total_triggers,
    output reg  [15:0] current_hour_count
);
    reg [15:0] hour_trigger_count[0:23];
    always @(*) begin
        if (current_hour < 24) current_hour_count = hour_trigger_count[current_hour];
        else current_hour_count = 16'd0;
    end
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_voltage_mv <= 16'd0;
            min_voltage_mv <= 16'hffff;
            total_triggers <= 16'd0;
            for (i = 0; i < 24; i = i + 1) hour_trigger_count[i] <= 16'd0;
        end else begin
            if (voltage_valid) begin
                if (voltage_mv > max_voltage_mv) max_voltage_mv <= voltage_mv;
                if (voltage_mv < min_voltage_mv) min_voltage_mv <= voltage_mv;
            end
            if (trigger_event) begin
                total_triggers <= total_triggers + 16'd1;
                if (current_hour < 24)
                    hour_trigger_count[current_hour] <= hour_trigger_count[current_hour] + 16'd1;
            end
        end
    end
endmodule
