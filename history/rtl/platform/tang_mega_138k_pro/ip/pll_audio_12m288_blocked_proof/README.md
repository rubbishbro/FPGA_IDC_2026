# Evidence: exact-12.288 MHz PLL primitive is REJECTED by Gowin P&R

`GowinModGen -do` (the vendor primitive generator) produced
`gowin_pll_audio_12M288_mod.v` with the mathematically exact divider set for
12.288 MHz from 50 MHz:

    IDIV_SEL=5  FBDIV_SEL=1  MDIV_SEL=96  ODIV0_SEL=78  ODIV0_FRAC_SEL=1
    => Fpfd=10 MHz, VCO=960 MHz, Fout=960/(78+1/8)=12.288 MHz

It synthesises, but place & route rejects it:

    ERROR (PA2078): Invalid PFD frequency 'FCLKIN/IDIV_SEL' to 'PLL_inst'(PLL)
    set by module 'Gowin_PLL_audio_12M288_MOD', suitable range is from 19MHz to
    81.25MHz

This directory is **evidence only, NOT in sources.f**.  Do not build it.
