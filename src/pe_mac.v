`timescale 1ns / 1ps

// output stationary
// each pe calculates one output value
// sum = activation[0] * weight[0] + activation[1] * weight[1] + ...

module pe_mac(
    input wire clk,
    input wire rst,

    // a beat is one set of input operands sampled at a posedge of a lock
    input wire in_valid, // whether input is sampled   
    input wire in_first, // whether this input is the first input
    input wire in_enable, // 0 disables unused array lanes

    // inputs & outputs
    input wire signed[7:0] in_activation,
    input wire signed[7:0] in_weight,
    output reg signed[7:0] out_sem
);
    wire signed[15:0] product = in_activation * in_weight;

    // _q means stored ina register
    reg signed[15:0] product_q;
    reg valid_q;
    reg first_q;

    // repeating the sign bit at first preserves the sign
    wire signed [31:0] extended_product = {{16{product_q[15]}}, product_q};

    always @(posedge clk) begin
        if(rst) begin
            product_q <= 16'sd0;
            valid_q <= 1'b0;
            first_q <= 1'b0;
            out_sum <= 32'sd0;
        end else begin
            // calculate & store a product
            valid_q <= in_valid;

            if(in_valid)begin
                product_q <= (in_enable ? product:16'sd0);
                first_q <= in_first;
            end

            // add the stored product to the sum
            // note that nonblocking assignments read old register values
            // so the below code uses things like valid_q, first_q, etc.
            // from the last clock cycle
            if (valid_q) begin
                if(first_q) out_sum <= extended_product;
                else out_sum <= out_sum + extended_product;
            end
        end
    end
endmodule
