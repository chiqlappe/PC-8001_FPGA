//
// CRTC
// version 1.2
//
// Orignal Auther	: kwhr0-san
// Modified 		: RJB
// Modified 		: Chiqlappe (*1,*2)
// 
// 2020/7/12	Ver 1.12	 Chiqlappe-san modified PCG8200 mode and FDC *1
// 2020/8/1		Ver 1.2   *2
//  + read & copy PCG data
//  + scanline (SW #1)
//  + upper & underline attribute
//  + DMA control
//  + reverse screen
//  + color pallette
//
// This Verilog HDL code is provided "AS IS", with NO WARRANTY.
//	NON-COMMERCIAL USE ONLY
//


module crtc(
	input wire				clk,
	output wire [3:0] 	y_out,
	output wire [3:0] 	c_out,
	input wire				port30h_we,
	input wire				crtc_we,
	input wire				adr,
	input wire [7:0] 		data,

	output wire 			busreq,
	input wire				busack,
	output wire [16:0] 	ram_adr,
	input wire [7:0] 		ram_data,

	input wire				clk2,
	output [1:0] 			bw_out,
	output wire				vga_hs,
	output wire				vga_vs,
//	output wire [3:0]		vga_r,// REMOVED *2
//	output wire [3:0]		vga_g,// REMOVED *2
//	output wire [3:0]		vga_b,// REMOVED *2
	output wire	 			dot_b,// *2
	output wire				dot_r,// *2
	output wire				dot_g,// *2
	output wire				lumi,// *2
	output wire				vsafe,// *2
	output wire				scanln,// *2
	
	input wire [10:0]		pcg_adr,
	input wire [7:0]		pcg_data,
	input wire				pcg_we,
	input wire				pcg_cp,// *2
	input wire				pcg_rd,// *2
	input wire [7:0]		pcg_mode,
	input wire				pcg_on,	
	input wire [1:0]		fdc_cs,
//	input wire [2:0]		fdc_plt,// REMOVED *2
	output wire [7:0]		pcg_rdata,// PCG read *2
//	output wire [2:0]		plt_sel,// REMOVED *2
	output wire				vsync// *1
	);
	
	parameter START_H = 192;
	parameter END_H = START_H + 640 + 8;
	parameter START_V = 40;
	parameter END_V = START_V + 200;
	parameter CHCNT_RESET_V = START_V - 1;

	parameter START_H2 = 200;
	parameter END_H2 = START_H2 + 640 + 8;
	parameter START_V2 = 81;
	parameter END_V2 = START_V2 + 401;

	parameter DOT_CLOCK_H  = 910;// *2
	parameter DOT_CLOCK_V  = 262;// *2
	parameter DOT_CLOCK_V2 = DOT_CLOCK_V * 2;// *2

	//
	// function : sel2()
	//
	function sel2;
		input [1:0] s;
		input [3:0] a;
		case (s)
			2'b00: sel2 = a[0];
			2'b01: sel2 = a[1];
			2'b10: sel2 = a[2];
			2'b11: sel2 = a[3];
		endcase
	endfunction

	reg 			q0 = 0;
	reg [9:0] 	dotcnt = 0;
	reg [8:0] 	hcnt = 0;
	reg [3:0] 	chcnt = 0;
	reg [7:0] 	chrline = 0;
	reg [6:0] 	text_adr = 0;
	reg [5:0] 	atr_adr = 0;
	reg [6:0] 	xcnt = 0;
	reg [4:0] 	ycnt = 0;
	reg [8:0] 	atr = 9'b001110000, atr0 = 9'b001110000;// upper & underline *2
	reg [6:0] 	vcnt = 0;
	reg [11:0] 	dma_src_adr = 0;
	reg [6:0] 	dma_dst_adr = 0;
	reg [7:0] 	text_data;
	reg [2:0] 	state = 0;// 2bit -> 3bit DMA wait *2
	reg [6:0] 	xcurs = 0;
	reg [4:0] 	ycurs = 0;
	reg			qinh = 0, qrev = 0, qcurs = 0, width80 = 0, colormode = 0;
	reg [2:0] 	seq = 0;
	reg [3:0] 	lpc = 9;
	reg [14:0] 	atr_data = 0;
	reg 			rev_scrn = 0, qrev_scrn = 0;// reverse screen *2
	reg 			dma_on = 1;
	reg [15:0] 	dma_delay = 0;
	
	wire [7:0] 	chrline_c, chrline_g;
	wire 			chlast, dotl, dotr, rowbuf_we;
	wire			hvalid = dotcnt >= START_H & dotcnt < END_H;
	wire			vvalid = hcnt >= START_V & hcnt < END_V;
	wire 			burst = dotcnt >= 76 & dotcnt < 112;
	wire 			hsync = dotcnt < 67;

	assign		vsync = hcnt < 3;// *1
	assign		chlast = chcnt == lpc;

	// VGA
	reg [9:0] 	dotcnt2 = 0;
	reg [9:0] 	hcnt2 = 0;
	wire 			hsync2 = dotcnt2 < 109;
	wire 			vsync2 = hcnt2 < 2;
	assign 		hvalid2 = dotcnt2 >= START_H2 & dotcnt2 < END_H2;
	assign 		vvalid2 = hcnt2 >= START_V2 & hcnt2 < END_V2;
	
	//
	// register access
	//
	always @(posedge clk) begin
		if (port30h_we) begin
			width80 <= data[0];
			colormode <= ~data[1];
		end
		if (crtc_we) begin
			if (adr) begin
				if (data == 8'h00) begin
					seq <= 5;
					dma_on <= 0;// DMA switch
				end
				if (data == 8'h80) ycurs <= 31;
				if (data == 8'h81) seq <= 7;
				if (data[7:5] == 3'b001) rev_scrn <= data[0];// reverse screen *2
				if (data == 8'h20) dma_on <= 1;// DMA control
			end
			else begin
				if (seq == 3) lpc <= data[3:0];
				if (seq == 7) xcurs <= data[6:0];
				if (seq == 6) ycurs <= data[4:0];
				if (seq) seq <= seq == 6 ? 0 : seq - 1;
			end
		end
	end

	//
	always @(posedge clk) begin
		if (dotcnt == DOT_CLOCK_H-1) begin
			dotcnt <= 0;
			if (hcnt == DOT_CLOCK_V-1) begin
				hcnt <= 0;
				vcnt <= vcnt + 1;
			end
			else begin
				if (~vvalid | chlast) chcnt <= 4'b0000;
				else chcnt <= chcnt + 1;
				hcnt <= hcnt + 1;
			end
		end
		else dotcnt <= dotcnt + 1;
	end

	//
	// DMA state
	//
	always @(posedge clk) begin
		case (state)
			0:begin
				if (dotcnt == END_H) begin
					if (hcnt == 0) dma_src_adr <= 12'h300;
					if ((hcnt == CHCNT_RESET_V | chlast)) begin
						state <= 1;
						dma_dst_adr <= 0;
						dma_delay <= 1500;// DMA delay counter
					end
				end
			end
			1:begin
				if (busack) state <= 2;
			end
			2:begin
				dma_src_adr <= dma_src_adr + 1;
				state <= 3;
			end
			3:begin
				dma_dst_adr <= dma_dst_adr + 1;
				state <= (dma_dst_adr == 7'h77) ? 4 : 2;
			end
//			4:begin
			default:begin
				dma_delay <= dma_delay - 1;
				if (dma_delay == 0) state <= 0;
			end
		endcase
	end

	assign		ram_adr = { 5'h0f, dma_src_adr };
	assign		busreq = state != 0 & dma_on;// DMA control

	//
	// text
	//
	always @(posedge clk) begin
		if (hvalid & dotcnt[2:0] == 3'b111 & xcnt < 79) begin// fix xcnt range *2
			text_adr <= text_adr + 1;
			xcnt <= xcnt + 1;
		end
		if (dotcnt == DOT_CLOCK_H-1) begin
			text_adr <= 0;
			xcnt <= 0;
		end
	end

	//
	// attribute
	//
	always @(posedge clk) begin
		if (dotcnt == 0) atr[8:7] <= 2'b00;// reset upper & underline flag *2
		if (dotcnt[2:0] == 3'b001) atr_data[14:8] <= text_data[6:0];
		if (dotcnt[2:0] == 3'b011) atr_data[7:0] <= text_data;
		if (hvalid & dotcnt[2:0] == 3'b110 & atr_data[14:8] == xcnt) begin
			atr_adr <= atr_adr + 1;

			if (colormode & atr_data[3]) atr[6:3] <= atr_data[7:4];
			else begin
				atr[2:0] <= atr_data[2:0];
				atr[8:7] <= atr_data[5:4];// set upper & underline flag *2
			end
			if (~colormode) atr[6:3] <= { 3'b111, atr_data[7] };
		end
		if (dotcnt == DOT_CLOCK_H-1) begin
			if (hcnt == CHCNT_RESET_V) begin
				atr_adr <= 6'h28;
				ycnt <= 0;
			end
			else if (chlast) begin
				atr_adr <= 6'h28;
				atr0 <= atr;
				ycnt <= ycnt + 1;
			end
			else begin
				atr_adr <= 6'h28;
				atr <= atr0;
			end
		end
	end

	//
	// color
	//
	reg [2:0] 	color;
	wire [3:0] 	col;
	wire [2:0] 	ctmp;
	assign		ctmp[2] = ~burst & color[2];
	assign		ctmp[1] = ~burst & (color[2] ^ color[1]);
	assign		ctmp[0] = ~burst & (color[2] ^ color[0]);

	colordata colordata(
		.clk(clk),
		.adr({ burst, ctmp[1:0], ctmp[2] ^ dotcnt[1] ^ hcnt[0], dotcnt[0] }),
		.data(col)
	);

	//
	assign		rowbuf_we = state == 3;
	wire [6:0]	rowbuf_adr = dotcnt[2] ? text_adr : { atr_adr, dotcnt[1] };

	//
	// ROW BUFFER
	//
	reg [7:0]	rowbuf[0:127];
	
	always @(posedge clk) begin
		if (rowbuf_we) rowbuf[dma_dst_adr] <= ram_data;
		text_data <= rowbuf[rowbuf_adr];
	end
	
	//
	// CG ROM / PCG RAM
	//
	wire [7:0]	pcg_ram, pcg_ram1, pcg_ram2;
	wire [10:0]	radr, wadr;
	wire [7:0]	cg_rom;
	wire [10:0]	cg_adr;
	wire [10:0]	cg_adr2;// *2
	wire [7:0]	pcg_data2;// *2
	wire			wren, wren1, wren2;
	wire			ram_cs;
	wire [8:0]	seldata;
	
	assign		cg_adr = {text_data, chcnt[2:0]};
	assign		wadr = {~pcg_adr[10], pcg_adr[9:0]};// *1

	assign		wren  = (pcg_mode[5] == 0 | pcg_mode[4] == 0) ? pcg_we : 1'b0;
	assign		wren1 = fdc_cs[0] ? pcg_we : (pcg_mode[5] == 1 & pcg_mode[4] == 1) ? pcg_we : 1'b0;// remove FDC switch check *2
	assign		wren2 = fdc_cs[1] ? pcg_we : 1'b0;// *2
	assign		seldata = selpcg(pcg_on, cg_adr2[10], pcg_mode, cg_rom, pcg_ram, pcg_ram1);// *2
	assign		chrline_c = seldata[7:0];
	assign		ram_cs = seldata[8];
	
	assign		pcg_data2 = pcg_cp ? cg_rom : pcg_data;// PCG copy *2
	assign		cg_adr2 = pcg_cp | pcg_rd ? wadr : cg_adr;// PCG copy & read *2
	assign		pcg_rdata = pcg_rd ? chrline_c : 8'h00;// PCG read *2

	//
	// function : selpcg()
	//
	function [8:0] selpcg;
		input			pcg_on;
		input 		adr;
		input [7:0] mode;
		input [7:0] rom;
		input [7:0] ram0;
		input [7:0]	ram1;

		if (pcg_on) begin
			if (adr & mode[3]) begin
				selpcg[7:0] = mode[2] & mode[5] ? ram1 : ram0;
				selpcg[8] = 1'b1;
			end
			else if (~adr & mode[1] & mode[5]) begin
				selpcg[7:0] = mode[0] ? ram1 : ram0;
				selpcg[8] = 1'b1;
			end
			else begin
				selpcg[7:0] = rom;
				selpcg[8] = 1'b0;
			end		
		end
		else begin
			selpcg[7:0] = rom;
			selpcg[8] = 1'b0;
		end
	endfunction	


	cgrom cgrom (
		.address		( cg_adr2 		),// *2
		.clock		( clk			),
		.q				( cg_rom		)
	);

	pcgram pcgram0 (
		.clock		( clk				),
		.data			( pcg_data2		),// *2
		.rdaddress	( cg_adr2		),// *2
		.wraddress	( wadr			),
		.wren			( wren			),
		.q				( pcg_ram		)
	);
	
	pcgram pcgram1 (
		.clock		( clk				),
		.data			( pcg_data2		),// *2
		.rdaddress	( cg_adr2		),// *2
		.wraddress	( wadr			),
		.wren			( wren1			),
		.q				( pcg_ram1		)
	);

	pcgram pcgram2 (
		.clock		( clk				),
		.data			( pcg_data2		),// *2
		.rdaddress	( cg_adr2		),// *2
		.wraddress	( wadr			),
		.wren			( wren2			),
		.q				( pcg_ram2		)
	);

	//
	// Video Out
	//
	reg [7:0]	chrline_red;
	reg [7:0]	chrline_grn;
	reg			ram_cs1;
	wire			fdc_on = pcg_on & pcg_mode[7];
	wire [2:0]	plt_sel;
	
	assign		dotl = sel2(chcnt[2:1], text_data[3:0]);
	assign		dotr = sel2(chcnt[2:1], text_data[7:4]);
	assign		chrline_g = { dotl, dotl, dotl, dotl, dotr, dotr, dotr, dotr };
	assign		plt_sel = { chrline_grn[7], chrline_red[7], chrline[7] };

	// *2
	always @(posedge clk) begin
		if (dotcnt[2:0] == 3'b111 & (width80 | ~dotcnt[3])) begin
			if (hvalid & vvalid) begin
				if (~atr[3] & ((atr[7] & chcnt == 4'd0) | (atr[8] & chlast))) begin// upper & underline *2
					chrline 		<= 8'b11111111;
					chrline_red <= 8'b00000000;
					chrline_grn <= 8'b00000000;
				end
				else if (~chcnt[3]) begin
					chrline <= atr[3] ? chrline_g : chrline_c;
					chrline_grn <= pcg_ram1;
					chrline_red <= pcg_ram2;
					ram_cs1 <= ram_cs;
				end
				else begin
					chrline     <= 8'b00000000;
					chrline_red <= 8'b00000000;
					chrline_grn <= 8'b00000000;
				end
			end

			qinh <= atr[0] | (atr[1] & vcnt[6:5] == 2'b00) | ~dma_on;// DMA control
			qrev <= atr[2] & hvalid & vvalid;
			qcurs <= vcnt[5] & hvalid & xcnt == xcurs & ycnt == ycurs;
			color <= atr[6:4];
			qrev_scrn <= rev_scrn & hvalid & vvalid;// reverse screen  *2

		end
		else if (width80 | dotcnt[0]) begin
				chrline <= chrline << 1;
				chrline_red <= chrline_red << 1;
				chrline_grn <= chrline_grn << 1;
		end
	end


	// *1
	wire			fdc_en = ram_cs1 & ~atr[3] & pcg_mode[7];
	wire			d0 = hsync ~^ vsync;
	wire			y0 = ~qinh & (( fdc_en ? |plt_sel : chrline[7]) ^ qrev ^ qcurs ^ qrev_scrn);// *2
	wire [2:0]	c0 = (fdc_en & ~&plt_sel) ? ((qrev | qrev_scrn | qcurs) ? color : plt_sel) : color;// *2


	//
	// LINE BUFFER
	//
	reg [9:0]	lb_src_adr;
	reg [9:0]	lb_dst_adr;
	reg [3:0]	linebuf[0:2048];
	reg [3:0]	lb_out;
	
	// VGA SYNC
	always @ (posedge clk2) begin
		if (dotcnt2 == DOT_CLOCK_H-1) begin
			dotcnt2 <= 0;
			if (hcnt2 == DOT_CLOCK_V2-1) begin
				hcnt2 <= 0;
			end
			else begin
				hcnt2 <= hcnt2 + 1;
			end
		end
		else dotcnt2 <= dotcnt2 + 1;
	end
	
	always @ (posedge clk) begin
		if (dotcnt == 0) lb_src_adr <= 0;
		if (hvalid) begin
			linebuf[ { hcnt[0], lb_src_adr }] <= { y0, c0 };
			lb_src_adr <= lb_src_adr + 1;
		end
	end
	
	always @ (posedge clk2) begin
		if (dotcnt2 == 0) lb_dst_adr <= 1;
		if (hvalid2) begin
			lb_out <= linebuf[ { ~hcnt[0], lb_dst_adr } ];
			lb_dst_adr <= lb_dst_adr + 1;
		end
	end

	assign	vsafe = hvalid2 & vvalid2;// *2
	assign	lumi = lb_out[3];// *2
	assign	scanln = hcnt2[0];// *2
	assign	dot_b = lb_out[0];// *2
	assign	dot_r = lb_out[1];// *2
	assign	dot_g = lb_out[2];// *2
	assign	vga_hs = ~hsync2;
	assign	vga_vs = ~vsync2;

endmodule


module colordata(clk, adr, data);
	input clk;
	input [4:0] adr;
	output [3:0] data;

	reg [3:0]	data;

	always @ (posedge clk) begin
		case (adr)
			5'b00100: data = 4'h2;
			5'b00101: data = 4'h7;
			5'b00110: data = 4'he;
			5'b00111: data = 4'h9;
			5'b01000: data = 4'ha;
			5'b01001: data = 4'he;
			5'b01010: data = 4'h6;
			5'b01011: data = 4'h2;
			5'b01100: data = 4'h4;
			5'b01101: data = 4'hd;
			5'b01110: data = 4'hc;
			5'b01111: data = 4'h3;
			5'b10000: data = 4'he;
			5'b10001: data = 4'h8;
			5'b10010: data = 4'h2;
			5'b10011: data = 4'h8;
			default:  data = 4'h8;
		endcase
	end
endmodule
