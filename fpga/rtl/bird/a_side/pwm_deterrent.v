module pwm_deterrent #(
    parameter [31:0] TONE_HALF_CYCLES = 32'd12500,
    parameter [31:0] SWEEP_PERIOD_CYCLES = 32'd75_000_000,
    parameter [31:0] BURST_ON_CYCLES = 32'd37_500_000,
    parameter [31:0] BURST_OFF_CYCLES = 32'd37_500_000,
    parameter [31:0] FLASH_HALF_CYCLES = 32'd7_500_000,
    parameter [31:0] FLASH_FAST_CYCLES = 32'd1_875_000,
    parameter [31:0] STEP_MAX = 32'd458130,
    parameter [31:0] STEP_MIN = 32'd114532
) (
    input  wire clk,
    rst_n,
    input  wire enable_level1,
    enable_level2,
    enable_level3,
    output reg  buzzer,
    audio_pwm,
    led_flash
);
    wire audio_en = enable_level2 || enable_level3;
    wire led_en = enable_level1 || audio_en;
    localparam [31:0] TONE_N = (TONE_HALF_CYCLES < 1) ? 1 : TONE_HALF_CYCLES;
    localparam [31:0] ON_N = (BURST_ON_CYCLES < 1) ? 1 : BURST_ON_CYCLES;
    localparam [31:0] OFF_N = (BURST_OFF_CYCLES < 1) ? 1 : BURST_OFF_CYCLES;
    localparam [31:0] SLOW_N = (FLASH_HALF_CYCLES < 1) ? 1 : FLASH_HALF_CYCLES;
    localparam [31:0] FAST_N = (FLASH_FAST_CYCLES < 1) ? 1 : FLASH_FAST_CYCLES;
    localparam [31:0] SWEEP_N = (SWEEP_PERIOD_CYCLES < 2) ? 2 : SWEEP_PERIOD_CYCLES;
    localparam [31:0] DOWN_N = SWEEP_N / 2;
    localparam [31:0] UP_N = SWEEP_N - DOWN_N;
    localparam [31:0] DELTA = STEP_MAX - STEP_MIN;

    localparam [31:0] DOWN_BASE = DELTA / DOWN_N, DOWN_REM = DELTA % DOWN_N;
    localparam [31:0] UP_BASE = DELTA / UP_N, UP_REM = DELTA % UP_N;
    reg [31:0] tone_acc, tone_step, sweep_count, sweep_error;
    reg sweep_down;
    wire [31:0] half_n = sweep_down ? DOWN_N : UP_N;
    wire [31:0] base_step = sweep_down ? DOWN_BASE : UP_BASE;
    wire [31:0] rem_step = sweep_down ? DOWN_REM : UP_REM;
    wire [32:0] error_sum = {1'b0, sweep_error} + {1'b0, rem_step};
    wire carry = error_sum >= {1'b0, half_n};
    wire [31:0] step_change = base_step + carry;
    reg [31:0] fixed_count;
    reg fixed_tone;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tone_acc <= 0;
            tone_step <= STEP_MAX;
            sweep_count <= 0;
            sweep_error <= 0;
            sweep_down <= 1;
            fixed_count <= 0;
            fixed_tone <= 0;
        end else begin
            if (enable_level3) begin
                tone_acc <= tone_acc + tone_step;
                if (sweep_count == half_n - 1'b1) begin
                    sweep_count <= 0;
                    sweep_error <= 0;
                    sweep_down  <= ~sweep_down;
                    tone_step   <= sweep_down ? STEP_MIN : STEP_MAX;
                end else begin
                    sweep_count <= sweep_count + 1'b1;
                    sweep_error <= carry ? (error_sum - {1'b0, half_n}) : error_sum;
                    tone_step <= sweep_down ? (tone_step - step_change) : (tone_step + step_change);
                end
            end else begin
                tone_acc <= 0;
                tone_step <= STEP_MAX;
                sweep_count <= 0;
                sweep_error <= 0;
                sweep_down <= 1;
            end
            if (enable_level2 && !enable_level3) begin
                if (fixed_count == TONE_N - 1'b1) begin
                    fixed_count <= 0;
                    fixed_tone  <= ~fixed_tone;
                end else fixed_count <= fixed_count + 1'b1;
            end else begin
                fixed_count <= 0;
                fixed_tone  <= 0;
            end
        end
    end
    reg [31:0] burst_cnt, flash_cnt;
    reg burst_on;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_cnt <= 0;
            burst_on  <= 1;
        end else if (!audio_en) begin
            burst_cnt <= 0;
            burst_on  <= 1;
        end else if (burst_cnt == ((burst_on ? ON_N : OFF_N) - 1'b1)) begin
            burst_cnt <= 0;
            burst_on  <= ~burst_on;
        end else burst_cnt <= burst_cnt + 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buzzer <= 0;
            audio_pwm <= 0;
            led_flash <= 0;
            flash_cnt <= 0;
        end else begin
            buzzer <= audio_en && burst_on;
            audio_pwm <= audio_en && burst_on && (enable_level3 ? tone_acc[31] : fixed_tone);
            if (!led_en) begin
                flash_cnt <= 0;
                led_flash <= 0;
            end else if (flash_cnt >= ((enable_level3 ? FAST_N : SLOW_N) - 1'b1)) begin
                flash_cnt <= 0;
                led_flash <= ~led_flash;
            end else flash_cnt <= flash_cnt + 1'b1;
        end
    end
endmodule
