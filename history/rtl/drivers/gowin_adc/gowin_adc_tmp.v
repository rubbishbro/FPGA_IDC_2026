//Copyright (C)2014-2025 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12 (64-bit)
//Part Number: GW5AST-LV138FPG676AC1/I0
//Device: GW5AST-138
//Device Version: B
//Created Time: Wed Oct 14 19:20:38 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    Gowin_ADC your_instance_name(
        .adcrdy(adcrdy), //output adcrdy
        .adcvalue(adcvalue), //output [13:0] adcvalue
        .drstn(drstn), //input drstn
        .adcreqi(adcreqi), //input adcreqi
        .fscal_value(fscal_value), //input [9:0] fscal_value
        .offset_value(offset_value) //input [11:0] offset_value
    );

//--------Copy end-------------------
