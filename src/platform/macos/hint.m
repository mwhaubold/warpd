#include "macos.h"

static float border_radius;

/* nil means "auto": follow the system appearance. */
static NSColor *bgColor;
static NSColor *fgColor;
const char *font;

struct hint_style {
	NSColor *bg;
	NSColor *fg;
	NSColor *typed;
	NSColor *edge;
	NSColor *shadow;
};

static void get_style(NSView *view, struct hint_style *style)
{
	const int dark = macos_is_dark(view);

	if (dark) {
		style->bg = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.12 alpha:0.88];
		style->fg = [NSColor colorWithWhite:1 alpha:0.95];
		style->edge = [NSColor colorWithWhite:1 alpha:0.14];
		style->shadow = [NSColor colorWithWhite:0 alpha:0.35];
	} else {
		style->bg = [NSColor colorWithSRGBRed:0.99 green:0.99 blue:1 alpha:0.92];
		style->fg = [NSColor colorWithWhite:0 alpha:0.85];
		style->edge = [NSColor colorWithWhite:0 alpha:0.12];
		style->shadow = [NSColor colorWithWhite:0 alpha:0.10];
	}

	/* Explicitly configured colors win, but keep the shadow for legibility. */
	if (bgColor) {
		style->bg = bgColor;
		style->edge = nil;
	}

	if (fgColor)
		style->fg = fgColor;

	style->typed = [style->fg colorWithAlphaComponent:style->fg.alphaComponent * 0.35];
}

static void draw_hook(void *arg, NSView *view)
{
	size_t i;
	struct screen *scr = arg;
	struct hint_style style;

	get_style(view, &style);

	for (i = 0; i < scr->nr_hints; i++) {
		struct hint *h = &scr->hints[i];
		const float r = MIN(border_radius, h->h / 2.0);

		/*
		 * A cheap offset shadow rather than NSShadow, which is too
		 * slow to blur hundreds of hints on every keystroke.
		 */
		macos_draw_box(scr, style.shadow, h->x - 0.5, h->y + 0.5, h->w + 1, h->h + 0.5, r + 0.5);
		macos_draw_box(scr, style.bg, h->x, h->y, h->w, h->h, r);

		if (style.edge) {
			NSBezierPath *path = [NSBezierPath
			    bezierPathWithRoundedRect:NSMakeRect(h->x + 0.25, scr->h - h->y - h->h + 0.25,
								 h->w - 0.5, h->h - 0.5)
					      xRadius:r
					      yRadius:r];
			[style.edge setStroke];
			path.lineWidth = 0.5;
			[path stroke];
		}

		macos_draw_text(scr, style.fg, style.typed, font,
				h->x, h->y, h->w, h->h, h->label, h->typed);
	}
}

void osx_hint_draw(struct screen *scr, struct hint *hints, size_t n)
{
	scr->nr_hints = n;
	memcpy(scr->hints, hints, sizeof(struct hint)*n);

	window_register_draw_hook(scr->overlay, draw_hook, scr);
}

void osx_init_hint(const char *bg, const char *fg, int _border_radius,
	       const char *font_family)
{
	bgColor = macos_color(bg);
	fgColor = macos_color(fg);

	border_radius = (float)_border_radius;
	font = font_family;
}
