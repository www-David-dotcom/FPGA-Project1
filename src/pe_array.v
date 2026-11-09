`timescale 1ns / 1ps

module pe_array #(
    parameter integer OC_LANES = 8, // output channels
    parameter integer POS_LANES = 16 // output positions
)(
    input wire clk,
    input wire rst,

    input wire in_valid,
    input wire in_first,
    input wire in_last,

    input wire [OC_LANES - 1:0] in_channel_mask,
    input wire [POS_LANES - 1:0] in_position_mask,

    // flat input
    input wire [POS_LANES * 8 - 1 : 0] in_activations,
    input wire [OC_LANES * 8 - 1 : 0] in_weights,

    output reg out_valid,
    // output idx = channel * POS_LANES + position
    output wire [OC_LANES * POS_LANES * 32 - 1 : 0] out_sums
);
    genvar m, p;
    generate
        // create the PE arrays using a generate loop
        for(m = 0; m < OC_LANES; m = m + 1) begin: gen_channel
            for(p = 0; p < POS_LANES; p = p + 1) begin: gen_position
                wire signed [7:0] activation;
                wire signed [7:0] weight;
                wire signed [31:0] sum;
                wire lane_enable;

                assign activation = in_activations[8 * p +: 8];
                assign weight = in_weights[8 * m +: 8]; 
                assign lane_enable = in_channel_mask[m] & in_position_mask[p];

                // all pe with the same p share an activation
                // all pe with the same m share a weight
                // pe[m][p] = sum(activation[p] * weight[m])
                pe_mac u_pe(.clk(clk), .rst(rst), 
                            .in_valid(in_valid), .in_first(in_first), .in_enable(lane_enable), 
                            .in_activation(activation), .in_weight(weight), 
                            .out_sum(sum));
                assign out_sums[32 * (m * POS_LANES + p) +: 32] = sum;
            end
        end
    endgenerate

    reg valid_q;
    reg last_q;
    always @(posedge clk) begin
        if(rst) begin
            valid_q <= 1'b0;
            last_ <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            valid_q <= in_valid;
            last_q <= in_last;
            out_valid <= valid_q & last_q;
        end
    end 
endmodule