module still_bird_timer #(
    parameter integer CLOCK_HZ  = 50000000,
    parameter integer FORCE_SEC = 5
) (
    input wire clk,
    rst_n,
    motion_candidate,
    busy,
    output reg candidate,
    forced,
    output reg [15:0] motion_count,
    forced_count,
    dropped_forced_count
);
    localparam integer CW = (CLOCK_HZ > 1) ? $clog2(CLOCK_HZ) : 1;
    reg [CW-1:0] tick;
    reg [  15:0] seconds;
    always @(posedge clk) begin
        if (!rst_n) begin
            tick <= 0;
            seconds <= 0;
            candidate <= 0;
            forced <= 0;
            motion_count <= 0;
            forced_count <= 0;
            dropped_forced_count <= 0;
        end else begin
            candidate <= 0;
            forced <= 0;
            if (motion_candidate && motion_count != 16'hffff) motion_count <= motion_count + 1'b1;
            if (tick == CLOCK_HZ - 1) begin
                tick <= 0;
                if (seconds == FORCE_SEC - 1) begin
                    seconds <= 0;
                    candidate <= 1;
                    forced <= 1;
                    if (forced_count != 16'hffff) forced_count <= forced_count + 1'b1;
                    if (busy && dropped_forced_count != 16'hffff)
                        dropped_forced_count <= dropped_forced_count + 1'b1;
                end else seconds <= seconds + 1'b1;
            end else tick <= tick + 1'b1;
        end
    end
    // synthesis translate_off
    initial
        if (CLOCK_HZ < 1 || FORCE_SEC < 1 || FORCE_SEC > 65535) $fatal(1, "Invalid patrol period");
    // synthesis translate_on
endmodule
