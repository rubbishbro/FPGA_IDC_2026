module lcd_wave (
    input       [9:0]   q_y,        // waveform y value 0..479
    input       [9:0]   pix_x,
    input       [9:0]   pix_y,

    output              wave_hit,
    output      [5:0]   wave_r,
    output      [5:0]   wave_g,
    output      [5:0]   wave_b
);

    // yellow line where pix_y hits the waveform
    assign wave_hit = (pix_y == q_y);
    assign wave_r = 6'h3F;
    assign wave_g = 6'h3F;
    assign wave_b = 6'h00;

endmodule