//
// CRTC
// version 1.31
//
// pc8001m https://github.com/radiojunkbox/pc8001m
//
// Orignal Auther	: kwhr0-san
// Modified 		: RJB
// Modified 		: Chiqlappe
// 
// 2020/07/12	Ver 1.12	 Chiqlappe-san modified PCG8200 mode and FDC
// 2020/08/01	Ver 1.2
//  + read & copy PCG data
//  + scanline (SW #1)
//  + upper & underline attribute
//  + DMA control
//  + reverse screen
//  + color pallette
// 2020/08/07	Ver 1.3
//  + DMAC start address & terminal count regs
// 2020/08/10	Ver 1.31
//  * fix reverse screen bug
//
// This Verilog HDL code is provided "AS IS", with NO WARRANTY.
//	NON-COMMERCIAL USE ONLY
//

module crtc(

	// DE0-CV switches
	input wire [9:0]		sw,// 9:SW_OC, 8:NA, 7:SW_ROM, 6:NA, 5:SW_PCG, 4:SW_MDL, 3:SW_FDC, 2:SW_CMT, 1:SW_SCL, 0:SW_GRN

	// Z80
	input wire				clk,
	input wire				reset,
	input wire				busack,
	input wire [7:0] 		ram_data,
	input wire [3:0]		cpu_adr,
	input wire [7:0] 		cpu_data_out,
	input wire				port00h_we,
	input wire				port10h_we,
	input wire				port30h_we,
	input wire				port50h_we,
	input wire				port60h_we,
	input wire				port90h_we,
	output wire 			busreq,
	output wire [16:0] 	ram_adr,

	// VIDEO
	output wire				vsync,

	// VGA
	input wire				clk2,
	output wire				vga_hs,
	output wire				vga_vs,
	output wire	[3:0] 	vga_b,
	output wire	[3:0]		vga_r,
	output wire	[3:0]		vga_g,

	// PCG
	output wire [7:0]		pcg_rdata,
	output wire [7:0]		pcg_cont_out
	);

	// Video
	parameter START_H = 192;
	parameter END_H = START_H + 640 + 8;
	parameter START_V = 40;
	parameter END_V = START_V + 200;
	parameter CHCNT_RESET_V = START_V - 1;
	parameter PIX_CLOCK_H  = 910;
	parameter PIX_CLOCK_V  = 262;
	parameter PIX_CLOCK_V2 = PIX_CLOCK_V * 2;

	// VGA
	parameter START_H2 = 200;
	parameter END_H2 = START_H2 + 640 + 8;
	parameter START_V2 = 80 + 1;
	parameter END_V2 = START_V2 + 400 + 1;

	//
	// PCG & Full Dot Color
	//
	reg [7:0] 	pcg_adr8;	// 00h
	reg [7:0] 	pcg_data;	// 01h
	reg [7:0] 	pcg_cont;	// 02h
	reg [7:0] 	pcg_slct;	// 03h

	wire [10:0] pcg_adr;
	wire 			pcg_we;
	wire 			pcg_on;
	wire 			pcg_cp;
	wire 			pcg_rd;
	wire [7:0] 	pcg_mode;

	reg [2:0] 	clr_plt[0:7];
	reg [1:0] 	fdc_cs;
	wire 			scanln_en;
	wire [2:0] 	plt;
	wire [2:0] 	bgcol;

	assign 		pcg_adr = { pcg_cont[2:0], pcg_adr8 };
	assign 		pcg_we = pcg_cont[4];
	assign 		pcg_cp = pcg_cont[5];// PCG copy signal = PORT 02h bit5
	assign 		pcg_rd = pcg_slct[7];// PCG read signal = PORT 03h bit7
	assign 		pcg_on = sw[5];
	assign 		pcg_mode = { sw[3], 1'b0, sw[4], pcg_slct[4:0] };
	assign 		scanln_en = hcnt2[0] & sw[1];
	assign 		pcg_cont_out = pcg_cont;
	assign 		plt = clr_plt[ {lb_out[2], lb_out[1], lb_out[0]} ];
	assign 		bgcol = clr_plt[0];
	assign 		vga_b = sw[0] ? 4'b0000 : fvga(plt[0], vsafe, lb_out[3], scanln_en, bgcol[0]);
	assign 		vga_r = sw[0] ? 4'b0000 : fvga(plt[1], vsafe, lb_out[3], scanln_en, bgcol[1]);
	assign 		vga_g = sw[0] ? vsafe & lb_out[3] & ( lb_out[2] | lb_out[1] | lb_out[0]) ? scanln_en ? { 1'b0, lb_out[2], lb_out[1], lb_out[0] } : { lb_out[2], lb_out[1], lb_out[0], 1'b1 } : 4'b0001
													: fvga(plt[2], vsafe, lb_out[3], scanln_en, bgcol[2]);

	//
	function [3:0] fvga;
		input plt;// palette color bit
		input vsafe;// valid display area
		input lumi;// luminance
		input scanln_en;// scanline
		input bgcol;// background color bit
			fvga = lumi ? {4{plt}} : {4{bgcol}};
			fvga = vsafe ? (scanln_en ? {1'b0, fvga[3:1]} : fvga) : 4'b0000;
	endfunction


	//
	// PCG I/O PORT
	//
	always @(posedge clk) begin
		if (reset) begin
			pcg_slct <= 8'h08;// PCG8100 mode
			clr_plt[0] <= 3'b000;
			clr_plt[1] <= 3'b001;
			clr_plt[2] <= 3'b010;
			clr_plt[3] <= 3'b011;
			clr_plt[4] <= 3'b100;
			clr_plt[5] <= 3'b101;
			clr_plt[6] <= 3'b110;
			clr_plt[7] <= 3'b111;
		end

		if (port00h_we) begin// PCG
			if (cpu_adr[3:0] == 4'h0) pcg_data <= cpu_data_out;
			if (cpu_adr[3:0] == 4'h1) pcg_adr8 <= cpu_data_out;
			if (cpu_adr[3:0] == 4'h2) pcg_cont <= cpu_data_out;
			if (cpu_adr[3:0] == 4'h3) pcg_slct <= cpu_data_out;
		end
		else if (port90h_we) begin// Full Dot Color
			if (cpu_adr[3]) begin
				fdc_cs <= cpu_data_out[1:0];
			end
			else begin
				clr_plt[cpu_adr[2:0]] <= cpu_data_out[2:0];
			end
		end
	end


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


	wire 			chlast, hvalid, vvalid, hsync;

	assign		vsync = (hcnt < 3);
	assign		chlast = (chcnt == lpc);
	assign		hvalid = (dotcnt >= START_H & dotcnt < END_H);
	assign		vvalid = (hcnt >= START_V & hcnt < END_V);
	assign		hsync = (dotcnt < 67);


	// VGA
	reg [9:0] 	dotcnt2 = 0;
	reg [9:0] 	hcnt2 = 0;
	wire 			hsync2, vsync2, vsafe;

	assign		vga_hs = ~hsync2;
	assign		vga_vs = ~vsync2;
	assign 		hvalid2 = (dotcnt2 >= START_H2 & dotcnt2 < END_H2);
	assign 		vvalid2 = (hcnt2 >= START_V2 & hcnt2 < END_V2);
	assign		hsync2 = (dotcnt2 < 109);
	assign		vsync2 = (hcnt2 < 2);
	assign		vsafe = (hvalid2 & vvalid2);


	//
	// CRTC register access
	//
	reg			width80 = 0, colormode = 0, dma_on = 1, rev_scrn = 0;
	reg [3:0]	lpc = 9;
	reg [6:0]	xcurs = 0;
	reg [4:0]	ycurs = 0;
	reg [2:0]	seq = 0;
	reg			dma_start_ff = 0;
	reg 			dma_size_ff = 0;
	reg			dma_reset = 0;

	always @(posedge clk) begin
		if (dma_reset) dma_reset <= 0;

		if (port30h_we) begin
			width80 <= cpu_data_out[0];
			colormode <= ~cpu_data_out[1];
		end

		if (port50h_we) begin
			if (cpu_adr[0]) begin
				if (cpu_data_out == 8'h00) begin
					seq <= 5;
					dma_on <= 0;
				end

				if (cpu_data_out == 8'h80) ycurs <= 31;
				if (cpu_data_out == 8'h81) seq <= 7;
				if (cpu_data_out[7:1] == 7'b0010000) begin // START DISPLAY command
					rev_scrn <= cpu_data_out[0];
					dma_on <= 1'b1;
					dma_start_ff <= 0;
					dma_size_ff <= 0;
					dma_reset <= 1'b1;
				end

			end
			else begin
				if (seq == 3) lpc <= cpu_data_out[3:0];
				if (seq == 6) ycurs <= cpu_data_out[4:0];
				if (seq == 7) xcurs <= cpu_data_out[6:0];
				if (seq) seq <= seq == 6 ? 0 : seq - 1;
			end
		end

		if (port60h_we) begin
			if (cpu_adr[3:0] == 4'h4) begin// set DMA address
				dma_start <= dma_start_ff ?  { cpu_data_out, dma_start[7:0]} : { dma_start[15:8], cpu_data_out };
				dma_start_ff <= ~dma_start_ff;
			end
			if (cpu_adr[3:0] == 4'h5) begin// set DMA terminal count
				dma_size <= dma_size_ff ? {cpu_data_out[5:0], dma_size[7:0]} : { dma_size[5:0], cpu_data_out };
				dma_size_ff <= ~dma_size_ff;
			end
		end
	
	end


	//
	// dot counter
	//
	reg [9:0] 	dotcnt = 0;
	reg [8:0] 	hcnt = 0;
	reg [6:0] 	vcnt = 0;
	reg [3:0] 	chcnt = 0;

	always @(posedge clk) begin
		if (dotcnt == PIX_CLOCK_H-1) begin
			dotcnt <= 0;

			if (hcnt == PIX_CLOCK_V-1) begin
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
	reg [15:0] 	dma_src_adr = DEF_VRAM_ADR;
	reg [2:0] 	state = 0;
	reg [6:0] 	dma_dst_adr = 0;
	reg [10:0] 	dma_delay_cnt = 0;
	reg [15:0]	dma_start = DEF_VRAM_ADR;
	reg [14:0]	dma_size = DEF_DMA_SIZE;
	reg [15:0]	dma_cnt = 0;
	reg			dma_wait = 0;
	
	parameter DEF_VRAM_ADR = 16'hf300;
	parameter DEF_DMA_SIZE = 25 * 120 - 1;// = 2999
	parameter VRAM_ROW = 120;
	parameter DMA_DELAY = 1600;

	always @(posedge clk) begin

		if (dma_reset) begin
			state <= 0;
			dma_wait <= 1;
		end
			
		case (state)
			0:begin
				if (dma_wait & hcnt == 0) begin
					dma_wait <= 0;
					dma_cnt <= 0;
					dma_src_adr <= dma_start;
				end
				else begin
					if (dotcnt == END_H) begin
						if (hcnt == CHCNT_RESET_V | (chlast & hcnt < (END_V - 1))) begin// omit last v-line
							state <= 1;
							dma_dst_adr <= 0;
							dma_delay_cnt <= DMA_DELAY;
						end
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
				state <= (dma_dst_adr == VRAM_ROW - 1) ? 4 : 2;

				if (dma_cnt == dma_size) begin
					dma_cnt <= 0;
					dma_src_adr <= dma_start;
				end
				else dma_cnt <= dma_cnt + 1;
			end
			4:begin
				dma_delay_cnt <= dma_delay_cnt - 1;
				if (dma_delay_cnt == 0) state <= 0;
			end

			default:;
			
		endcase
	end


	wire 			rowbuf_we;
	wire [6:0]	rowbuf_adr;

	assign		ram_adr = dma_src_adr;
	assign		busreq = (state != 0 & dma_on);
	assign		rowbuf_we = (state == 3);
	assign		rowbuf_adr = dotcnt[2] ? text_adr : { atr_adr, dotcnt[1] };


	//
	// ROW BUFFER
	//
	reg [7:0]	rowbuf[0:127];
	reg [7:0] 	text_data;

	always @(posedge clk) begin
		if (rowbuf_we) begin
			rowbuf[dma_dst_adr] <= ram_data;
		end
		text_data <= rowbuf[rowbuf_adr];
	end


	//
	// text
	//
	reg [6:0] 	text_adr = 0;
	reg [6:0] 	xcnt = 0;

	always @(posedge clk) begin
		if (hvalid & dotcnt[2:0] == 3'b111 & xcnt < 79) begin
			text_adr <= text_adr + 1;
			xcnt <= xcnt + 1;
		end
		if (dotcnt == PIX_CLOCK_H-1) begin
			text_adr <= 0;
			xcnt <= 0;
		end
	end


	//
	// attribute
	//
	reg [8:0] 	atr = 9'b001110000, atr0 = 9'b001110000;
	reg [14:0] 	atr_data = 0;
	reg [5:0] 	atr_adr = 0;
	reg [4:0] 	ycnt = 0;

	always @(posedge clk) begin
		if (dotcnt == 0) atr[8:7] <= 2'b00;
		if (dotcnt[2:0] == 3'b001) atr_data[14:8] <= text_data[6:0];
		if (dotcnt[2:0] == 3'b011) atr_data[7:0] <= text_data;
		if (hvalid & dotcnt[2:0] == 3'b110 & atr_data[14:8] == xcnt) begin
			atr_adr <= atr_adr + 1;

			if (colormode & atr_data[3]) atr[6:3] <= atr_data[7:4];
			else begin
				atr[2:0] <= atr_data[2:0];
				atr[8:7] <= atr_data[5:4];// set upper & underline flag
			end
			if (~colormode) atr[6:3] <= { 3'b111, atr_data[7] };
		end
		if (dotcnt == PIX_CLOCK_H-1) begin
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
	// CG ROM / PCG RAM
	//
	wire [7:0]	pcg_ram, pcg_ram1, pcg_ram2;
	wire [10:0]	radr, wadr;
	wire [7:0]	cg_rom;
	wire [10:0]	cg_adr;
	wire [10:0]	cg_adr2;
	wire [7:0]	pcg_data2;
	wire			wren, wren1, wren2;
	wire			ram_cs;
	wire [8:0]	seldata;
	wire [7:0] 	chrline_c, chrline_g;
	wire 			dotl, dotr;

	assign		dotl = sel2(chcnt[2:1], text_data[3:0]);
	assign		dotr = sel2(chcnt[2:1], text_data[7:4]);
	assign		cg_adr = {text_data, chcnt[2:0]};
	assign		wadr = {~pcg_adr[10], pcg_adr[9:0]};
	assign		wren  = (pcg_mode[5] == 0 | pcg_mode[4] == 0) ? pcg_we : 1'b0;
	assign		wren1 = fdc_cs[0] ? pcg_we : (pcg_mode[5] == 1 & pcg_mode[4] == 1) ? pcg_we : 1'b0;
	assign		wren2 = fdc_cs[1] ? pcg_we : 1'b0;
	assign		seldata = selpcg(pcg_on, cg_adr2[10], pcg_mode, cg_rom, pcg_ram, pcg_ram1);
	assign		chrline_c = seldata[7:0];
	assign		chrline_g = { dotl, dotl, dotl, dotl, dotr, dotr, dotr, dotr };
	assign		ram_cs = seldata[8];
	assign		pcg_data2 = pcg_cp ? cg_rom : pcg_data;
	assign		cg_adr2 = pcg_cp | pcg_rd ? wadr : cg_adr;
	assign		pcg_rdata = pcg_rd ? chrline_c : 8'h00;


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
		.address		( cg_adr2 		),
		.clock		( clk				),
		.q				( cg_rom			)
	);

	pcgram pcgram0 (
		.clock		( clk				),
		.data			( pcg_data2		),
		.rdaddress	( cg_adr2		),
		.wraddress	( wadr			),
		.wren			( wren			),
		.q				( pcg_ram		)
	);
	
	pcgram pcgram1 (
		.clock		( clk				),
		.data			( pcg_data2		),
		.rdaddress	( cg_adr2		),
		.wraddress	( wadr			),
		.wren			( wren1			),
		.q				( pcg_ram1		)
	);

	pcgram pcgram2 (
		.clock		( clk				),
		.data			( pcg_data2		),
		.rdaddress	( cg_adr2		),
		.wraddress	( wadr			),
		.wren			( wren2			),
		.q				( pcg_ram2		)
	);


	//
	// Video Out
	//
	wire			fdc_on;
	wire [2:0]	plt_sel;

	assign		fdc_on = pcg_on & pcg_mode[7];
	assign		plt_sel = { chrline_grn[7], chrline_red[7], chrline[7] };

	reg [7:0] 	chrline = 0;
	reg			qinh = 0, qrev = 0, qcurs = 0;
	reg 			qrev_scrn = 0;
	reg [2:0] 	color;
	reg [7:0]	chrline_red;
	reg [7:0]	chrline_grn;
	reg			ram_cs1;

	always @(posedge clk) begin
		if (dotcnt[2:0] == 3'b111 & (width80 | ~dotcnt[3])) begin
			if (hvalid & vvalid) begin
				if (~atr[3] & ((atr[7] & chcnt == 4'd0) | (atr[8] & chlast))) begin
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

			qinh <= atr[0] | (atr[1] & vcnt[6:5] == 2'b00) | ~dma_on;
			qrev <= atr[2] & hvalid & vvalid;
			qcurs <= vcnt[5] & hvalid & xcnt == xcurs & ycnt == ycurs;
			color <= atr[6:4];
			qrev_scrn <= rev_scrn & hvalid & vvalid;

		end
		else if (width80 | dotcnt[0]) begin
				chrline <= chrline << 1;
				chrline_red <= chrline_red << 1;
				chrline_grn <= chrline_grn << 1;
		end
	end


	wire			fdc_en, d0, y0;
	wire [2:0]	c0;

	assign		fdc_en = ram_cs1 & ~atr[3] & pcg_mode[7];
	assign		d0 = hsync ~^ vsync;
	assign		y0 = ~qinh & (( fdc_en ? |plt_sel : chrline[7]) ^ qrev ^ qcurs ^ qrev_scrn);
	assign		c0 = (fdc_en & ~&plt_sel) ? ((qrev | qrev_scrn | qcurs) ? color : plt_sel) : color;


	//
	// VGA SYNC
	//
	always @ (posedge clk2) begin
		if (dotcnt2 == PIX_CLOCK_H-1) begin
			dotcnt2 <= 0;
			if (hcnt2 == PIX_CLOCK_V2-1) begin
				hcnt2 <= 0;
			end
			else begin
				hcnt2 <= hcnt2 + 1;
			end
		end
		else dotcnt2 <= dotcnt2 + 1;
	end
	

	//
	// WRITE LINE BUFFER
	//
	reg [9:0]	lb_src_adr;
	reg [9:0]	lb_dst_adr;
	reg [3:0]	linebuf[0:2048];

	always @ (posedge clk) begin
		if (dotcnt == 0) lb_src_adr <= 0;
		if (hvalid) begin
			linebuf[ { hcnt[0], lb_src_adr }] <= { y0, c0 };
			lb_src_adr <= lb_src_adr + 1;
		end
	end


	//
	// READ LINE BUFFER
	//
	reg [3:0]	lb_out;

	always @ (posedge clk2) begin
		if (dotcnt2 == 0) lb_dst_adr <= 1;
		if (hvalid2) begin
			lb_out <= linebuf[ { ~hcnt[0], lb_dst_adr } ];
			lb_dst_adr <= lb_dst_adr + 1;
		end
	end

endmodule
