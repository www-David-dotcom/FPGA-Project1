`timescale 1ns / 1ps

// address generation unit
// generates reading addresses. the buffers receive these adresses and return the actual values
// one invocation handles one tile (OC_LANES output channels * POS_LANES output positions)
// the controller starts another tile after this one finishes

// data layout is:
// activation : in_channel -> y -> x
// weights : out_channel -> in_channel -> ky -> kx


module agu #(
    parameter integer OC_LANES = 8,
    parameter integer POS_LANES = 16,
    parameter integer ADDR_WIDTH = 18
)(
    input wire clk,
    input wire rst,
    input wire start, // configuration inputs are captured on this rising edge

    // layer configuration
    input wire [7:0] cfg_in_h,
    input wire [7:0] cfg_in_w,
    input wire [7:0] cfg_in_channels,
    input wire [7:0] cfg_out_channels,
    input wire [7:0] cfg_out_h,
    input wire [7:0] cfg_out_w,
    input wire [2:0] cfg_kernel,
    input wire [1:0] cfg_stride,
    input wire [2:0] cfg_padding,

    // starting address of the layer's input & weight data
    input wire [ADDR_WIDTH-1:0] cfg_input_base,
    input wire [ADDR_WIDTH-1:0] cfg_weight_base,
    // first output channel handled by this tile
    input wire [7:0] cfg_channel_base,
    //first output position handled by this tile
    input wire [7:0] cfg_tile_y,
    input wire [7:0] cfg_tile_x,

    output reg busy,
    output reg done, // the final read request was accepted

    // a request is accepted at a rising edge only when req_valid & req_ready == 1
    output wire req_valid,
    input wire req_ready, // comes from the buffer. It means that the read request can be accepted

    // first & final request
    output wire req_first,
    output wire req_last,

    // activation lane p index -> p * ADDR_WIDTH +: ADDRE_WIDTH
    // weight lane m index -> m * ADDR_WIDTH +: ADDR_WIDTH
    output reg [POS_LANES * ADDR_WIDTH - 1 : 0] req_act_addr,
    output reg [OC_LANES * ADDR_WIDTH - 1 : 0] req_wgt_addr,

    // if req_zero[p] = 1 then it means let the buffer return 0
    // handles padding
    output reg [POS_LANES - 1 : 0] req_zero,

    // masks identify actual output positions/channels
    output reg [POS_LANES - 1 : 0] position_mask,
    output reg [OC_LANES - 1 : 0] channel_mask
);
    integer h_q, w_q, cin_q, kernel_q;
    // current input channel, kernel row, and kernal column
    integer ic, ky, kx;

    // plane_q = input height * input width
    integer plane_q;
    // channel offset q = ic *plane_q
    integer channel_offset_q;
    // kernel offset q = ky * input_width + kx
    integer kernel_offset_q;

    // for output position (oy, ox)
    // (origin_y, origin_x) is where the input computation start
    // origin_y = oy * stride - padding
    // origin_x = ox * stride - padding
    // NOTE THESE TWO VALUES CAN BE NEGATIVE!
    // the current input coordinate is
    // iy = origin_y + ky
    // ix = origin_x + kx
    integer origin_y_q [0:POS_LANES - 1];
    integer origin_x_q [0:POS_LANES - 1];

    // precompute the flattened origin once once per tile
    integer input_start_q [0:POS_LANES - 1];
    // each output channel lane has its own weight address
    reg[ADDR_WIDTH - 1 : 0] weight_addr_q [0: OC_LANES - 1];

    assign req_valid = busy && (!rst);
    assign req_first = req_valid && (ic == 0) && (ky == 0) && (kx == 0);
    assign req_last = req_valid && (ic == cin_q - 1) && (ky == kernel_q - 1) && (kx == kernel_q - 1);

    //temporary variables used during tile setup
    integer p, m;
    integer row, col;
    integer width_value, stride_value, pad_value;
    integer out_h_value, out_w_value;
    integer channel_base_value, cout_value;
    integer y0, x0;
    integer weight_count, weight_start, input_base_value;

    // sequential logic: store state at rising clock edges
    always @(posedge clk) begin
        if(rst) begin
            busy <= 0;
            done <= 0;
            h_q <= 0;
            w_q <= 0;
            cin_q <= 0;
            kernel_q <= 0;
            ic <= 0;
            ky <= 0;
            kx <= 0;
            plane_q <= 0;
            channel_offset_q <= 0;
            kernel_offset_q <= 0;
            position_mask <= 0;
            channel_mask <= 0;
            for (p = 0; p < POS_LANES; p=p+1) begin
                origin_y_q[p] <= 0;
                origin_x_q[p] <= 0;
                input_start_q[p] <= 0;
            end
            for(m = 0; m < OC_LANES; m=m+1) weight_addr_q[m] <= 0;
        end else begin
            done <= 0;

            if (start && (!busy)) begin
                busy <= 1;

                // extend into positive 32-bit values
                h_q <= {24'd0, cfg_in_h};
                w_q <= {24'd0, cfg_in_w};
                cin_q <= {24'd0, cfg_in_channels};
                kernel_q <= {29'd0, cfg_kernel};

                ic <= 0;
                ky <= 0;
                kx <= 0;
                channel_offset_q <= 0;
                kernel_offset_q <= 0;

                plane_q <= {24'd0, cfg_in_h} * {24'd0, cfg_in_w};

                // convert configs to signed integers
                width_value = {24'd0, cfg_in_w};
                stride_value = {30'd0, cfg_stride};
                pad_value = {29'd0, cfg_padding};
                out_h_value = {24'd0, cfg_out_h};
                out_w_value = {24'd0, cfg_out_w};
                row = {24'd0, cfg_tile_y};
                col = {24'd0, cfg_tile_x};

                input_base_value = {{(32 - ADDR_WIDTH){1'b0}}, cfg_input_base};

                //prepare each position lane
                for(p = 0; p < POS_LANES; p=p+1)begin
                    position_mask[p] <= ((row < out_h_value) && (col < out_w_value));

                    y0 = row * stride_value - pad_value;
                    x0 = col * stride_value - pad_value;
                    origin_y_q[p] <= y0;
                    origin_x_q[p] <= x0;
                    input_start_q[p] <= input_base_value + y0 * width_value + x0;

                    // find the next output position
                    if(col == out_w_value - 1)begin
                        col = 0;
                        row = row + 1;
                    end else col = col + 1;
                end

                // every output channel owns cin * k * k consecutive weight bytes
                weight_count = {24'd0, cfg_in_channels} * {29'd0, cfg_kernel} * {29'd0, cfg_kernel};
                channel_base_value = {24'd0, cfg_channel_base};
                cout_value = {24'd0, cfg_out_channels};

                for(m = 0; m < OC_LANES; m=m+1) begin
                    channel_mask[m] <= (channel_base_value + m < cout_value);

                    weight_start = {{(32 - ADDR_WIDTH){1'b0}}, cfg_weight_base} + (channel_base_value + m) * weight_count;
                    weight_addr_q[m] <= weight_start[ADDR_WIDTH-1:0];
                end
                
            end else if(req_valid && req_ready) begin
                // the cycle is busy and the request is ok
                // the accepted request uses the current addresses
                // the following update prepare addresses for the next request
                for(m = 0; m < OC_LANES; m=m+1) weight_addr_q[m] <= weight_addr_q[m] + 1'b1;

                // for each input channel -> kernel row -> kernel col, issue one request
                if(kx == kernel_q - 1) begin
                    kx <= 0;

                    if (ky == kernel_q - 1) begin
                        ky <= 0;
                        kernel_offset_q <= 0;

                        if(ic == cin_q - 1) begin
                            // final request of thie tile was accepted
                            busy <= 0;
                            done <= 1;
                        end else begin
                            ic <= ic + 1;
                            // move to the next input channel's image plane
                            channel_offset_q <= channel_offset_q + plane_q;
                        end
                    end else begin
                        ky <= ky + 1;
                        // at the end of a kernel row
                        // old offset = ky * W + (K - 1)
                        // new offset = (ky + 1) * W
                        // difference = W - (K - 1)
                        kernel_offset_q <= kernel_offset_q + w_q - (kernel_q - 1);
                    end
                end else begin
                    kx <= kx + 1;
                    kernel_offset_q <= kernel_offset_q + 1;
                end
            end
        end
    end

    // combinational logic: turn current state into current read requests
    integer a, b;
    integer iy, ix, address_value;

    always @* begin // recompute whenever a reference input/state changes
        req_act_addr = 0;
        req_wgt_addr = 0;
        req_zero = {POS_LANES{1'b1}};

        iy = 0;
        ix = 0;
        address_value = 0;

        for(a = 0; a < POS_LANES; a= a+1) begin
            iy = origin_y_q[a] + ky;
            ix = origin_x_q[a] + kx;

            if(req_valid && position_mask[a] && 
                iy >= 0 && iy < h_q &&
                ix >= 0 && ix < w_q) begin
                    req_zero[a] = 0; // a valid memory, no need to let the buffer return 0
                    // should return input_base + channel_offset + kernel_offset
                    address_value = input_start_q[a] + channel_offset_q + kernel_offset_q;
                    req_act_addr[a*ADDR_WIDTH +: ADDR_WIDTH] = address_value[ADDR_WIDTH-1:0];
            end
        end

        for(b = 0; b < OC_LANES; b=b+1)begin
            if(req_valid && channel_mask[b]) req_wgt_addr[b * ADDR_WIDTH +: ADDR_WIDTH] = weight_addr_q[b];
        end
    end
endmodule