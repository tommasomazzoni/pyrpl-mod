/**
 * $Id: red_pitaya_pid_block.v 961 2014-01-21 11:40:39Z matej.oblak $
 *
 * @brief Red Pitaya PID controller.
 *
 * @Author Matej Oblak
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in Verilog hardware description language (HDL).
 * Please visit http://en.wikipedia.org/wiki/Verilog
 * for more details on the language used herein.
 */
/*
###############################################################################
#    pyrpl - DSP servo controller for quantum optics with the RedPitaya
#    Copyright (C) 2014-2016  Leonhard Neuhaus  (neuhaus@spectro.jussieu.fr)
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
############################################################################### 
*/


/*
 * GENERAL DESCRIPTION:
 *
 * Proportional-integral-derivative (PID) controller.
 *
 *
 *        /---\         /---\      /-----------\
 *   IN --| - |----+--> | P | ---> | SUM & SAT | ---> OUT
 *        \---/    |    \---/      \-----------/
 *          ^      |                   ^  ^
 *          |      |    /---\          |  |
 *   set ----      +--> | I | ---------   |
 *   point         |    \---/             |
 *                 |                      |
 *                 |    /---\             |
 *                 ---> | D | ------------
 *                      \---/
 *
 *
 * Proportional-integral-derivative (PID) controller is made from three parts. 
 *
 * Error which is difference between set point and input signal is driven into
 * propotional, integral and derivative part. Each calculates its own value which
 * is then summed and saturated before given to output.
 *
 * Integral part has also separate input to reset integrator value to 0.
 * 
 */

module red_pitaya_pid_block #(
   //parameters for gain control (binary points and total bitwidth)
   parameter     PSR = 12         ,
   parameter     ISR = 32         ,//official redpitaya: 18
   parameter     DSR = 8          ,//official redpitaya: 10
   parameter     GAINBITS = 24    ,
   
   //parameters for input pre-filter
   parameter     FILTERSTAGES = 4 ,
   parameter     FILTERSHIFTBITS = 5,
   parameter     FILTERMINBW = 10,
   
   //enable arbitrary output saturation or not
   parameter     ARBITRARY_SATURATION = 1
)
(
   // data
   input                 clk_i           ,  // clock
   input                 rstn_i          ,  // reset - active low
   input      [ 14-1: 0] dat_i           ,  // input data
   output     [ 14-1: 0] dat_o           ,  // output data

   // communication with PS
   input      [ 16-1: 0] addr,
   input                 wen,
   input                 ren,
   output reg   		 ack,
   output reg [ 32-1: 0] rdata,
   input      [ 32-1: 0] wdata
);

reg [ 14-1: 0] set_sp;   // set point
reg [ 16-1: 0] set_ival;   // integral value to set
reg            ival_write;
reg [ GAINBITS-1: 0] set_kp;   // Kp
reg [ GAINBITS-1: 0] set_ki;   // Ki
reg [ GAINBITS-1: 0] set_kd;   // Kd
reg [ 32-1: 0] set_filter;   // filter setting
// limits if arbitrary saturation is enabled
reg signed [ 14-1:0] out_max;
reg signed [ 14-1:0] out_min;
// reset i_val
reg unsigned [ 14-1: 0] reset_value;
reg			   reset_ival; 

//  System bus connection
always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      set_sp <= 14'd0;
      set_ival <= 14'd0;
      set_kp <= {GAINBITS{1'b0}};
      set_ki <= {GAINBITS{1'b0}};
      set_kd <= {GAINBITS{1'b0}};
      set_filter <= 32'd0;
      ival_write <= 1'b0;
      out_min <= {1'b1,{14-1{1'b0}}};
      out_max <= {1'b0,{14-1{1'b1}}};
	  reset_value <= 14'd0;
	  reset_ival <= 1'b0;
   end
   else begin
      if (wen) begin
         if (addr==16'h100)   set_ival <= wdata[16-1:0];
         if (addr==16'h104)   set_sp  <= wdata[14-1:0];
         if (addr==16'h108)   set_kp  <= wdata[GAINBITS-1:0];
         if (addr==16'h10C)   set_ki  <= wdata[GAINBITS-1:0];
         if (addr==16'h110)   set_kd  <= wdata[GAINBITS-1:0];
         if (addr==16'h120)   set_filter  <= wdata;
         if (addr==16'h124)   out_min  <= wdata;
         if (addr==16'h128)   out_max  <= wdata;
		 if (addr==16'h130)   reset_value  <= wdata[14-1:0];
		 if (addr==16'h134)   reset_ival  <= wdata[0];
      end
      if (addr==16'h100 && wen)
         ival_write <= 1'b1;
      else
         ival_write <= 1'b0;

	  casez (addr)
	     16'h100 : begin ack <= wen|ren; rdata <= int_shr; end
	     16'h104 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},set_sp}; end
	     16'h108 : begin ack <= wen|ren; rdata <= {{32-GAINBITS{1'b0}},set_kp}; end
	     16'h10C : begin ack <= wen|ren; rdata <= {{32-GAINBITS{1'b0}},set_ki}; end
	     16'h110 : begin ack <= wen|ren; rdata <= {{32-GAINBITS{1'b0}},set_kd}; end
	     16'h120 : begin ack <= wen|ren; rdata <= set_filter; end
	     16'h124 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},out_min}; end
	     16'h128 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},out_max}; end
	     16'h130 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},reset_value}; end
	     16'h134 : begin ack <= wen|ren; rdata <= reset_ival; end

	     16'h200 : begin ack <= wen|ren; rdata <= PSR; end
	     16'h204 : begin ack <= wen|ren; rdata <= ISR; end
	     16'h208 : begin ack <= wen|ren; rdata <= DSR; end
	     16'h20C : begin ack <= wen|ren; rdata <= GAINBITS; end
	     16'h220 : begin ack <= wen|ren; rdata <= FILTERSTAGES; end
	     16'h224 : begin ack <= wen|ren; rdata <= FILTERSHIFTBITS; end
	     16'h228 : begin ack <= wen|ren; rdata <= FILTERMINBW; end
	     
	     default: begin ack <= wen|ren;  rdata <=  32'h0; end 
	  endcase	     
   end
end

//-----------------------------
// cascaded set of FILTERSTAGES low- or high-pass filters
wire signed [14-1:0] dat_i_filtered;
red_pitaya_filter_block #(
     .STAGES(FILTERSTAGES),
     .SHIFTBITS(FILTERSHIFTBITS),
     .SIGNALBITS(14),
     .MINBW(FILTERMINBW)
  )
  pidfilter
  (
  .clk_i(clk_i),
  .rstn_i(rstn_i),
  .set_filter(set_filter), 
  .dat_i(dat_i),
  .dat_o(dat_i_filtered)
  );

//---------------------------------------------------------------------------------
//  Set point error calculation - 1 cycle delay

reg  [ 15-1: 0] error        ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      error <= 15'h0 ;
   end
   else begin
      error <= $signed(dat_i_filtered) - $signed(set_sp) ;
   end
end


//---------------------------------------------------------------------------------
//  Proportional part - 1 cycle delay

reg   [15+GAINBITS-PSR-1: 0] kp_reg        ;
wire  [15+GAINBITS-1: 0] kp_mult       ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      kp_reg  <= {15+GAINBITS-PSR{1'b0}};
   end
   else begin
      kp_reg <= kp_mult[15+GAINBITS-1:PSR] ;
   end
end

assign kp_mult = $signed(error) * $signed(set_kp);

//---------------------------------------------------------------------------------
// Integrator - 2 cycles delay (but treat similar to proportional since it
// will become negligible at high frequencies where delay is important)

//formerly
//-localparam IBW = 64; //integrator bit-width. Over-represent the integral sum to record longterm drifts
//-reg   [15+GAINBITS-1: 0] ki_mult  ;
localparam IBW = ISR+16; //integrator bit-width. Over-represent the integral sum to record longterm drifts (overrepresented by 2 bits)
reg   [16+GAINBITS-1: 0] ki_mult ;
wire  [IBW  : 0] int_sum       ;
reg   [IBW-1: 0] int_reg       ;
wire  [IBW-ISR-1: 0] int_shr   ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      ki_mult  <= {15+GAINBITS{1'b0}};
      int_reg  <= {IBW{1'b0}};
   end
   else begin
      ki_mult <= $signed(error) * $signed(set_ki) ;
      if (ival_write)
         int_reg <= { {IBW-16-ISR{set_ival[16-1]}},set_ival[16-1:0],{ISR{1'b0}}};
       else if (int_sum[IBW+1-1:IBW+1-2] == 2'b01) //normal positive saturation
         int_reg <= {1'b0,{IBW-1{1'b1}}};
      else if (int_sum[IBW+1-1:IBW+1-2] == 2'b10) // negative saturation
         int_reg <= {1'b1,{IBW-1{1'b0}}};
	  else if ((reset_ival)&&(pid_out >= out_max)&&(-$signed(reset_value) > out_min))
	     int_reg <= {-$signed({2'b00,reset_value}),{ISR{1'b0}}};
	  else if ((reset_ival)&&(pid_out >= out_max)&&(-$signed(reset_value) <= out_min))
	     int_reg <= {{{16-14{out_min[13]}},out_min[13:0]}+{15'b0,1'b1},{ISR{1'b0}}};
	  else if ((reset_ival)&&(pid_out <= out_min)&&($signed(reset_value) < out_max))
	     int_reg <= {$signed({2'b00,reset_value}),{ISR{1'b0}}};
	  else if ((reset_ival)&&(pid_out <= out_min)&&($signed(reset_value) >= out_max))
	     int_reg <= {{{16-14{out_max[13]}},out_max[13:0]}-{15'b0,1'b1},{ISR{1'b0}}};
      else
         int_reg <= int_sum[IBW-1:0]; // use sum as it is
   end
end

assign int_sum = $signed(ki_mult) + $signed(int_reg) ;
assign int_shr = $signed(int_reg[IBW-1:ISR]) ;

//---------------------------------------------------------------------------------
//  Derivative - 2 cycles delay (but treat as 1 cycle because its not
//  functional at the moment

wire  [15+GAINBITS-1: 0] kd_mult;
reg   [15+GAINBITS-DSR-1: 0] kd_reg;
reg   [15+GAINBITS-DSR-1: 0] kd_reg_r;
reg   [15+GAINBITS-DSR  : 0] kd_reg_s;
always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
	  kd_reg   <= {15+GAINBITS-DSR{1'b0}};
	  kd_reg_r <= {15+GAINBITS-DSR{1'b0}};
	  kd_reg_s <= {15+GAINBITS-DSR+1{1'b0}};
   end
   else begin
	  kd_reg   <= kd_mult[15+GAINBITS-1:DSR] ;
	  kd_reg_r <= kd_reg;
	  kd_reg_s <= $signed(kd_reg) - $signed(kd_reg_r); //this is the end result
   end
end
assign kd_mult = $signed(error) * $signed(set_kd) ;


//---------------------------------------------------------------------------------
//  Sum together - saturate output - 1 cycle delay

localparam MAXBW = 17; //maximum possible bitwidth for pid_sum
wire        [   MAXBW-1: 0] pid_sum;
reg signed  [   14-1: 0] pid_out;

		always @(posedge clk_i) begin
		   if (rstn_i == 1'b0) begin
		      pid_out    <= 14'b0;
		   end
		   else begin
		      if ({pid_sum[MAXBW-1],|pid_sum[MAXBW-2:13]} == 2'b01) //positive overflow
		         pid_out <= 14'h1FFF;
		      else if ({pid_sum[MAXBW-1],&pid_sum[MAXBW-2:13]} == 2'b10) //negative overflow
		         pid_out <= 14'h2000;
		      else
		         pid_out <= pid_sum[14-1:0];
		   end
		end
assign pid_sum = $signed(kp_reg) + $signed(int_shr) + $signed(kd_reg_s);

generate 
	if (ARBITRARY_SATURATION == 0)
		assign dat_o = pid_out;
	else begin
		reg signed [ 14-1:0] out_buffer;
		always @(posedge clk_i) begin
			if (pid_out >= out_max)
				out_buffer <= out_max;
			else if (pid_out <= out_min)
				out_buffer <= out_min;
			else
				out_buffer <= pid_out;
		end
		assign dat_o = out_buffer; 
	end
endgenerate

endmodule
