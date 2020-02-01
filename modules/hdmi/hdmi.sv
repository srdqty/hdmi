// Implementation of HDMI Spec v1.4a
// By Sameer Puri https://github.com/sameer

module hdmi 
#(
    // Defaults to 640x480 which should be supported by almost if not all HDMI sinks.
    // See README.md or CEA-861-D for enumeration of video id codes.
    // README.md lists supported codes.
    // Pixel repetition, interlaced scans and other special output modes are not implemented (yet).
    parameter VIDEO_ID_CODE = 7'd1,

    // Defaults to minimum bit lengths required to represent positions.
    // Modify these parameters if you have alternate desired bit lengths.
    parameter BIT_WIDTH = VIDEO_ID_CODE < 4 ? 10 : VIDEO_ID_CODE == 4 ? 11 : 12,
    parameter BIT_HEIGHT = VIDEO_ID_CODE == 16 ? 11: 10,

    // A true HDMI signal can send auxiliary data (i.e. audio, preambles) which prevents it from being parsed by DVI signal sinks.
    // HDMI signal sinks are fortunately backwards-compatible with DVI signals.
    // Enable this flag if the output should be a DVI signal. You might want to do this to reduce logic cell usage or if you're only outputting video.
    parameter DVI_OUTPUT = 1'b0,

    // **All parameters below matter ONLY IF you plan on sending auxiliary data (DVI_OUTPUT == 1'b0)**

    // Refresh rate in Hz
    parameter VIDEO_REFRESH_RATE = 59.94,

    // As noted in Section 7.3, the minimal audio requirements are met: 16-bit to 24-bit L-PCM audio at 32 kHz, 44.1 kHz, or 48 kHz.
    // See Table 7-4 or README.md
    parameter AUDIO_RATE = 44100,

    // Defaults to 16-bit audio. Can be anywhere from 16-bit to 24-bit.
    parameter AUDIO_BIT_WIDTH = 16
)
(
    input logic clk_tmds,
    input logic clk_pixel,
    input logic clk_audio,
    input logic [23:0] rgb,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],

    output logic [2:0] tmds_p,
    output logic tmds_clock_p,
    output logic [2:0] tmds_n,
    output logic tmds_clock_n,
    output logic [BIT_WIDTH-1:0] cx = BIT_WIDTH'(0),
    output logic [BIT_HEIGHT-1:0] cy = BIT_HEIGHT'(0)
);

localparam NUM_CHANNELS = 3;

// All channels are initialized to the 0,0 control signal from 5.4.2.
// This gives time for the first pixel to be generated by the first clock.
logic [9:0] tmds_shift [NUM_CHANNELS-1:0] = '{10'b1101010100, 10'b1101010100, 10'b1101010100};

// TODO: Is this really Vivado? https://forums.xilinx.com/t5/Simulation-and-Verification/Predefined-constant-for-simulation/td-p/986901
`ifdef SYNTHESIS
    `ifndef ALTERA_RESERVED_QIS
    genvar l;
    generate
        for (l = 0; l < 3; l++)
        begin: obufds_gen
            OBUFDS obufds (.I(tmds_shift[l][0]), .O(tmds_p[l]), .OB(tmds_n[l]));
        end
    endgenerate
    OBUFDS OBUFDS_clock(.I(clk_pixel), .O(tmds_clock_p), .OB(tmds_clock_n));
    `endif
`else
// If Altera synthesis, a true differential buffer is built with altera_gpio_lite from the Intel IP Catalog.
// If simulation, a mocked signal inversion is used.
OBUFDS obufds(.din({tmds_shift[2][0], tmds_shift[1][0], tmds_shift[0][0], clk_pixel}), .pad_out({tmds_p, tmds_clock_p}), .pad_out_b({tmds_n,tmds_clock_n}));
`endif

// See CEA-861-D for more specifics formats described below.
logic [BIT_WIDTH-1:0] frame_width;
logic [BIT_HEIGHT-1:0] frame_height;
logic [BIT_WIDTH-1:0] screen_width;
logic [BIT_HEIGHT-1:0] screen_height;
logic [BIT_WIDTH-1:0] screen_start_x;
logic [BIT_HEIGHT-1:0] screen_start_y;
logic hsync;
logic vsync;

generate
    case (VIDEO_ID_CODE)
        1:
        begin
            assign frame_width = 800;
            assign frame_height = 525;
            assign screen_width = 640;
            assign screen_height = 480;
            assign hsync = ~(cx > 15 && cx <= 15 + 96);
            assign vsync = ~(cy < 2);
            end
        2, 3:
        begin
            assign frame_width = 858;
            assign frame_height = 525;
            assign screen_width = 720;
            assign screen_height = 480;
            assign hsync = ~(cx > 15 && cx <= 15 + 62);
            assign vsync = ~(cy > 5 && cy < 12);
            end
        4:
        begin
            assign frame_width = 1650;
            assign frame_height = 750;
            assign screen_width = 1280;
            assign screen_height = 720;
            assign hsync = cx > 109 && cx <= 109 + 40;
            assign vsync = cy < 5;
        end
        16:
        begin
            assign frame_width = 2200;
            assign frame_height = 1125;
            assign screen_width = 1920;
            assign screen_height = 1080;
            assign hsync = cx > 87 && cx <= 87 + 44;
            assign vsync = cy < 5;
        end
        17, 18:
        begin
            assign frame_width = 864;
            assign frame_height = 625;
            assign screen_width = 720;
            assign screen_height = 576;
            assign hsync = ~(cx > 11 && cx <= 11 + 64);
            assign vsync = ~(cy < 5);
        end
        19:
        begin
            assign frame_width = 1980;
            assign frame_height = 750;
            assign screen_width = 1280;
            assign screen_height = 720;
            assign hsync = cx > 439 && cx <= 439 + 40;
            assign vsync = cy < 5;
        end
    endcase
    assign screen_start_x = frame_width - screen_width;
    assign screen_start_y = frame_height - screen_height;
endgenerate

// Wrap-around pixel position counters indicating the pixel to be generated by the user in THIS clock and sent out in the NEXT clock.
always @(posedge clk_pixel)
begin
    cx <= cx == frame_width-1'b1 ? BIT_WIDTH'(0) : cx + 1'b1;
    cy <= cx == frame_width-1'b1 ? cy == frame_height-1'b1 ? BIT_HEIGHT'(0) : cy + 1'b1 : cy;
end

// See Section 5.2
logic video_data_period = 1;
always @(posedge clk_pixel)
    video_data_period <= cx >= screen_start_x && cy >= screen_start_y;

logic [2:0] mode = 3'd1;
logic [23:0] video_data = 24'd0;
logic [5:0] control_data = 6'd0;
logic [11:0] data_island_data = 12'd0;

generate
    if (!DVI_OUTPUT)
    begin: true_hdmi_output
        logic video_guard = 0;
        logic video_preamble = 0;
        always @(posedge clk_pixel)
        begin
            video_guard <= cx >= screen_start_x - 2 && cx < screen_start_x && cy >= screen_start_y;
            video_preamble <= cx >= screen_start_x - 10 && cx < screen_start_x - 2 && cy >= screen_start_y;
        end

        // See Section 5.2.3.1
        integer max_num_packets_alongside;
        logic [4:0] num_packets_alongside;
        assign max_num_packets_alongside = (screen_start_x /* VD period */ - 2 /* V guard */ - 8 /* V preamble */ - 12 /* 12px control period */ - 2 /* DI guard */ - 2 /* DI start guard */ - 8 /* DI premable */) / 32;
        assign num_packets_alongside = max_num_packets_alongside > 18 ? 5'd18 : 5'(max_num_packets_alongside);

        logic data_island_period_instantaneous;
        assign data_island_period_instantaneous = num_packets_alongside > 0 && cx >= 10 && cx < 10 + num_packets_alongside * 32;
        logic packet_enable;
        assign packet_enable = data_island_period_instantaneous && 5'(cx + 22) == 5'd0;

        logic data_island_guard = 0;
        logic data_island_preamble = 0;
        logic data_island_period = 0;
        always @(posedge clk_pixel)
        begin
            data_island_guard <= num_packets_alongside > 0 && ((cx >= 8 && cx < 10) || (cx >= 10 + num_packets_alongside * 32 && cx < 10 + num_packets_alongside * 32 + 2));
            data_island_preamble <= num_packets_alongside > 0 && /* cx >= 0 && */ cx < 8;
            data_island_period <= data_island_period_instantaneous;
        end

        // See Section 5.2.3.4
        logic [23:0] header;
        logic [55:0] sub [3:0];
        logic video_field_end;
        assign video_field_end = cx == frame_width - 1'b1 && cy == frame_height - 1'b1;
        logic [4:0] packet_pixel_counter;
        localparam VIDEO_RATE = (VIDEO_ID_CODE == 1 ? 25.2E6 : VIDEO_ID_CODE == 2 || VIDEO_ID_CODE == 3 ? 27.027E6 : VIDEO_ID_CODE == 4 ? 74.25E6 : VIDEO_ID_CODE == 16 ? 148.5E6 : VIDEO_ID_CODE == 17 || VIDEO_ID_CODE == 18 ? 27E6 : VIDEO_ID_CODE == 19 ? 74.25E6 : 0) * (VIDEO_REFRESH_RATE == 60 || (VIDEO_ID_CODE >= 17 && VIDEO_ID_CODE <= 19) ? 1 : 0.999);
        packet_picker #(.VIDEO_ID_CODE(VIDEO_ID_CODE), .VIDEO_RATE(VIDEO_RATE), .AUDIO_RATE(AUDIO_RATE), .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH)) packet_picker (.clk_pixel(clk_pixel), .clk_audio(clk_audio), .video_field_end(video_field_end), .packet_enable(packet_enable), .packet_pixel_counter(packet_pixel_counter), .audio_sample_word(audio_sample_word), .header(header), .sub(sub));
        logic [8:0] packet_data;
        packet_assembler packet_assembler (.clk_pixel(clk_pixel), .data_island_period(data_island_period), .header(header), .sub(sub), .packet_data(packet_data), .counter(packet_pixel_counter));


        always @(posedge clk_pixel)
        begin
            mode <= data_island_guard ? 3'd4 : data_island_period ? 3'd3 : video_guard ? 3'd2 : video_data_period ? 3'd1 : 3'd0;
            video_data <= rgb;
            control_data <= {{1'b0, data_island_preamble}, {1'b0, video_preamble || data_island_preamble}, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
            data_island_data[11:4] <= packet_data[8:1];
            data_island_data[3] <= cx != screen_start_x;
            data_island_data[2] <= packet_data[0];
            data_island_data[1:0] <= {vsync, hsync};
        end
    end
    else // DVI_OUTPUT = 1
    begin
        always @(posedge clk_pixel)
        begin
            mode <= video_data_period;
            video_data <= rgb;
            control_data <= {4'b0000, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
        end
    end
endgenerate

logic [9:0] tmds [NUM_CHANNELS-1:0];
genvar i;
generate
    for (i = 0; i < NUM_CHANNELS; i++)
    begin: tmds_gen
        tmds_channel #(.CN(i)) tmds_channel (.clk_pixel(clk_pixel), .video_data(video_data[i*8+7:i*8]), .data_island_data(data_island_data[i*4+3:i*4]), .control_data(control_data[i*2+1:i*2]), .mode(mode), .tmds(tmds[i]));
    end
endgenerate

// See Section 5.4.1
logic [3:0] tmds_counter = 4'd0;

generate
    for (i = 0; i < NUM_CHANNELS; i++)
    begin: tmds_shifting
        always @(posedge clk_tmds)
            tmds_shift[i] <=  tmds_counter == 4'd9 ? tmds[i] : {1'bX, tmds_shift[i][9:1]};
    end
endgenerate
always @(posedge clk_tmds)
    tmds_counter <= tmds_counter == 4'd9 ? 4'd0 : tmds_counter + 4'd1;

endmodule
