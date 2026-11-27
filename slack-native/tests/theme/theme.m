// The generated tokens, fonts and the CSS helpers.
#import "render/strings.h"
#import "theme/theme.h"
#import "test.h"

SN_TEST(ThemeTokensMatchTheDesignFiles) {
    SNExpect(SNColorBasePry == 0x1a1d21ff, "base-pry");
    SNExpect(SNThemeSurfInvSec == 0x10121499, "theme-surf-inv-sec");
    SNExpect(SNOverlayHover == 0xf8f8f814 && SNOverlayPressed == 0xf8f8f82e, "8% and 18% overlays");
    SNExpect(SNPaletteAubergine10 == 0x431349ff && SNPaletteAubergine0 == 0x200221ff, "aubergine palette");
    SNExpect(SNWindowConicStopCount == 5 && SNWindowRadialStops[1].color == 0x43134900, "background gradients");
    SNExpect(fabs(SNRadiusIaIcon(36) - 8) < 0.001 && SNRadiusIaIcon(16) == 4 && SNRadiusIaIcon(72) == 12, "tile radius rule");
    SNExpect(SNDuration80 == 0.08 && SNFontSizeBase == 15, "durations and sizes");
    float points[2];
    [SNEaseDefault() getControlPointAtIndex:1 values:points];
    SNExpect(fabsf(points[0] - 0.36f) < 1e-6 && fabsf(points[1] - 0.19f) < 1e-6, "default easing");
    SNExpect(SNShadowBase.count == 2 && SNShadowBase.shadows[1].spread == -1, "shadow stacks");
}

SN_TEST(ThemeColourMath) {
    SNExpect(SNColorWithAlpha(0xf8f8f8ff, 0.08) == 0xf8f8f814, "alpha");
    SNExpect(SNColorBrightness(0x431349ff, 0.9) == 0x3c1142ff, "brightness keeps alpha");
    // The search field's two layers make one colour.
    SNExpect(SNColorOver(SNThemeSurfInvPryHover, SNThemeSurfInvPry) == 0xefe1f54f, "source-over of two translucent layers");
    SNExpect(SNColorOver(0x00000000, 0x123456ff) == 0x123456ff, "clear over");
}

SN_TEST(ThemeFontsLoad) {
    struct { CGFloat weight; NSString *name; } faces[] = {
        {300, @"Lato-Light"}, {400, @"Lato-Regular"}, {500, @"Lato-Regular"}, {600, @"Lato-Bold"},
        {700, @"Lato-Bold"},  {800, @"Lato-Black"},   {900, @"Lato-Black"},   {100, @"Lato-Light"},
    };
    for (size_t i = 0; i < sizeof faces / sizeof *faces; i++) {
        NSFont *font = SNFont(15, faces[i].weight);
        SNExpect([font.fontName isEqualToString:faces[i].name], [NSString stringWithFormat:@"weight %g is %@ (got %@)", faces[i].weight, faces[i].name, font.fontName].UTF8String);
    }
    SNExpect([SNItalicFont(15, 700).fontName isEqualToString:@"Lato-BoldItalic"], "bold italic");
    SNExpect([SNMonoFont(13, 400).fontName isEqualToString:@"RobotoMono-Regular"], "Roboto Mono regular");
    SNExpect([SNMonoFont(13, 700).fontName isEqualToString:@"RobotoMono-Bold"], "Roboto Mono's weight axis");
    SNExpect(SNFont(15, 400) == SNFont(15, 400), "fonts are cached");
}

SN_TEST(ThemeLineBoxes) {
    // Lato's ascent and descent are 0.987 and 0.213 em: 15 pt rounds to 15 + 3, so a 22 pt line
    // has 2 pt of leading above the ascent.
    SNExpect(SNBaselineOffset(SNFont(15, 400), 22) == 17, "15/22 baseline");
    SNExpect(SNBaselineOffset(SNFont(11, 700), 12) == 10.5, "11/12: negative leading splits too");
}

SN_TEST(ThemeStringsFollowTheLanguage) {
    SNSetLanguage(@"pt-BR");
    SNExpect([SNLocalized(@"shell.rail.dms") isEqualToString:@"MDs"], "Portuguese");
    SNExpect([SNLocalizedFormat(@"shell.search.placeholder", @"Acme") isEqualToString:@"Pesquisar Acme"], "format");
    SNSetLanguage(@"xx-YY");
    SNExpect([SNLanguage() isEqualToString:@"en"] && [SNLocalized(@"shell.rail.dms") isEqualToString:@"DMs"], "unknown language falls back to English");
    SNExpect([SNLocalized(@"no.such.key") isEqualToString:@"no.such.key"], "missing key shows the key");
}
