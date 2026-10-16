/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#include "macos.h"

int macos_is_dark(NSView *view)
{
	NSAppearanceName name = [view.effectiveAppearance
	    bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];

	return [name isEqualToString:NSAppearanceNameDarkAqua];
}

/*
 * Returns a font whose cap height fills roughly half of a box of height h,
 * shrunk if necessary so that s fits in w. The base font is cached by height
 * so labels of different lengths share the same text size.
 */
NSFont *macos_get_font(const char *family, int w, int h, const char *s)
{
	static NSFont *cached;
	static CGFloat cached_mwidth;
	static char cached_family[64];
	static int cached_h;

	const size_t len = strlen(s);

	if (!cached || strcmp(cached_family, family) || cached_h != h) {
		NSFont *font;

		if (!strcmp(family, "auto"))
			font = [NSFont monospacedSystemFontOfSize:h weight:NSFontWeightSemibold];
		else
			font = [NSFont fontWithName:[NSString stringWithUTF8String:family] size:h];

		if (!font) {
			fprintf(stderr, "ERROR: %s is not a valid font\n", family);
			exit(-1);
		}

		font = [NSFont fontWithDescriptor:font.fontDescriptor
					     size:h * 0.5 / (font.capHeight / font.pointSize)];

		cached = font;
		cached_mwidth = [@"m" sizeWithAttributes:@{NSFontAttributeName : font}].width;
		snprintf(cached_family, sizeof cached_family, "%s", family);
		cached_h = h;
	}

	/* Shrink to fit horizontally (with some padding), 'm' being one of the widest glyphs. */
	if (len * cached_mwidth > w * 0.8)
		return [NSFont fontWithDescriptor:cached.fontDescriptor
					     size:cached.pointSize * (w * 0.8) / (len * cached_mwidth)];

	return cached;
}

/* Draw s centered in the given (ULO) box, rendering the first typed characters with typed_col. */
void macos_draw_text(struct screen *scr, NSColor *col, NSColor *typed_col,
		     const char *font_family, int x, int y, int w, int h,
		     const char *s, size_t typed)
{
	NSFont *font = macos_get_font(font_family, w, h, s);
	NSString *str = [NSString stringWithUTF8String:s];
	NSMutableAttributedString *astr;
	CGFloat baseline;
	CGSize size;

	astr = [[NSMutableAttributedString alloc]
	    initWithString:str
		attributes:@{
			NSFontAttributeName : font,
			NSForegroundColorAttributeName : col,
			/* Labels are arbitrary letter pairs, never merge them (e.g "fi"). */
			NSLigatureAttributeName : @0,
		}];

	typed = MIN(typed, str.length);
	if (typed && typed_col)
		[astr addAttribute:NSForegroundColorAttributeName
			     value:typed_col
			     range:NSMakeRange(0, typed)];

	size = astr.size;

	/* Center the cap height vertically (LLO). */
	baseline = (scr->h - y - h / 2.0) - font.capHeight / 2;

	[astr drawAtPoint:NSMakePoint(x + (w - size.width) / 2, baseline + font.descender)];
}

void macos_draw_box(struct screen *scr, NSColor *col, float x, float y, float w, float h, float r)
{
	[col setFill];

	/* Convert to LLO */
	y = scr->h - y - h;

	NSBezierPath *path = [NSBezierPath
	    bezierPathWithRoundedRect:NSMakeRect((float)x, (float)y, (float)w,
						 (float)h)
			      xRadius:(float)r
			      yRadius:(float)r];
	[path fill];
}

/*
 * Like nscolor_from_hex(), but also understands "accent" (the system accent
 * color). Returns nil for "auto", leaving the choice to the caller.
 *
 * Colors are cached by name: they are assigned on the warpd thread on every
 * redraw while the main thread may still be drawing with the previous one,
 * so they must never be deallocated (and it saves an allocation per redraw).
 */
NSColor *macos_color(const char *str)
{
	static NSMutableDictionary<NSString *, NSColor *> *cache;
	NSString *key;
	NSColor *color;

	if (!strcmp(str, "auto"))
		return nil;

	@synchronized([NSColor class]) {
		if (!cache)
			cache = [NSMutableDictionary dictionary];

		key = [NSString stringWithUTF8String:str];
		if (!(color = cache[key])) {
			color = !strcmp(str, "accent") ? NSColor.controlAccentColor : nscolor_from_hex(str);
			cache[key] = color;
		}
	}

	return color;
}


NSColor *nscolor_from_hex(const char *str)
{
	ssize_t len;
	uint8_t r, g, b, a;
#define X2B(c) ((c >= '0' && c <= '9') ? (c & 0xF) : (((c | 0x20) - 'a') + 10))

	if (str == NULL)
		return 0;

	str = (*str == '#') ? str + 1 : str;
	len = strlen(str);

	if (len != 6 && len != 8) {
		fprintf(stderr, "Failed to parse %s, paint it black!\n", str);
		return NSColor.blackColor;
	}

	r = X2B(str[0]);
	r <<= 4;
	r |= X2B(str[1]);

	g = X2B(str[2]);
	g <<= 4;
	g |= X2B(str[3]);

	b = X2B(str[4]);
	b <<= 4;
	b |= X2B(str[5]);

	a = 255;
	if (len == 8) {
		a = X2B(str[6]);
		a <<= 4;
		a |= X2B(str[7]);
	}

	return [NSColor colorWithSRGBRed:(float)r / 255
					 green:(float)g / 255
					  blue:(float)b / 255
					 alpha:(float)a / 255];
}

void osx_copy_selection(void)
{
	int shifted;

	send_key(osx_input_lookup_code("leftmeta", &shifted), 1);
	send_key(osx_input_lookup_code("c", &shifted), 1);
	send_key(osx_input_lookup_code("leftmeta", &shifted), 0);
	send_key(osx_input_lookup_code("c", &shifted), 0);
}

void osx_scroll(int direction)
{
	/* Called from the warpd thread, which never drains its own pool. */
	@autoreleasepool {
		int y = 0;
		int x = 0;

		switch (direction) {
		case SCROLL_UP:
			y = 1;
			break;
		case SCROLL_DOWN:
			y = -1;
			break;
		case SCROLL_RIGHT:
			x = -1;
			break;
		case SCROLL_LEFT:
			x = 1;
			break;
		}

		CGEventRef ev = CGEventCreateScrollWheelEvent(
		    NULL, kCGScrollEventUnitPixel, 2, y, x);
		CGEventPost(kCGHIDEventTap, ev);
		CFRelease(ev);
	}
}

void osx_commit(void)
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		size_t i;
		for (i = 0; i < nr_screens; i++) {
			struct window *win = screens[i].overlay;

			macos_update_hud(&screens[i]);

			if (win->nr_hooks || screens[i].hud.visible)
				window_show(win);
			else
				window_hide(win);
		}
	});
}

static void *mainloop(void *arg)
{
	int (*main)(struct platform *platform) = (int (*)(struct platform *platform)) arg;
	struct platform platform = {
		.commit = osx_commit,
		.copy_selection = osx_copy_selection,
		.hint_draw = osx_hint_draw,
		.init_hint = osx_init_hint,
		.input_grab_keyboard = osx_input_grab_keyboard,
		.input_lookup_code = osx_input_lookup_code,
		.input_lookup_name = osx_input_lookup_name,
		.input_next_event = osx_input_next_event,
		.input_ungrab_keyboard = osx_input_ungrab_keyboard,
		.input_wait = osx_input_wait,
		.mouse_click = osx_mouse_click,
		.mouse_down = osx_mouse_down,
		.mouse_get_position = osx_mouse_get_position,
		.mouse_hide = osx_mouse_hide,
		.mouse_move = osx_mouse_move,
		.mouse_show = osx_mouse_show,
		.mouse_up = osx_mouse_up,
		.screen_clear = osx_screen_clear,
		.screen_draw_box = osx_screen_draw_box,
		.screen_get_dimensions = osx_screen_get_dimensions,
		.screen_list = osx_screen_list,
		.scroll = osx_scroll,
		.monitor_file = osx_monitor_file,
		.screen_draw_cursor = osx_screen_draw_cursor,
		.screen_draw_indicator = osx_screen_draw_indicator,
		.screen_get_id = osx_screen_get_id,
		.init_status_icon = osx_init_status_icon,
	};

	main(&platform);
	exit(0);
}


void platform_run(int (*main)(struct platform *platform))
{
	pthread_t thread;

	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

	macos_init_input();
	macos_init_mouse();
	macos_init_screen();

	pthread_create(&thread, NULL, mainloop, (void *)main);

	[NSApp run];
}
