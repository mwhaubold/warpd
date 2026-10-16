/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#include "macos.h"

@interface MainView : NSView
@property struct window *win;
@end

@implementation MainView
/* Called by cocoa when the view needs to be redrawn. */
- (void)drawRect:(NSRect)dirtyRect
{
	size_t i;
	struct window *win = self.win;

	for (i = 0; i < win->nr_hooks; i++)
		win->hooks[i].hook(win->hooks[i].arg, self);
}
@end

/*
 * Wrap NSWindow in a nice C API, with a coordinate scheme based on the top
 * left, where God (and the X developers) intended it :). Drawing routines
 * are attached to the window with window_register_draw_hook() and run
 * in registration order when rendering. The usual NS/CG* routines
 * can be used for drawing operations.
 */

static const NSTimeInterval fade_in_duration = 0.08;
static const NSTimeInterval fade_out_duration = 0.12;

static int reduce_motion(void)
{
	return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

void window_show(struct window *win)
{
	if (!win->visible) {
		win->visible = 1;
		win->generation++; /* Cancel any pending fade out. */

		if (reduce_motion()) {
			win->win.alphaValue = 1;
		} else {
			/* Only fade in from scratch, otherwise resume from the current alpha. */
			if (!win->win.isVisible)
				win->win.alphaValue = 0;

			[NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
				ctx.duration = fade_in_duration;
				win->win.animator.alphaValue = 1;
			}];
		}
	}

	[win->win makeKeyAndOrderFront:nil];
	[[win->win contentView] setNeedsDisplay:TRUE];
}

void window_register_draw_hook(struct window *win, void (*draw)(void *arg, NSView *view), void *arg)
{
	assert(win->nr_hooks < MAX_DRAWING_HOOKS);
	struct drawing_hook *hook = &win->hooks[win->nr_hooks++];

	hook->hook = draw;
	hook->arg = arg;
}

void window_move(struct window *win, struct screen *scr, int x, int y)
{
	const int wh = win->win.frame.size.height;
	[win->win setFrameOrigin:NSMakePoint(scr->x + x, scr->y + scr->h - wh - y)];
}

void window_hide(struct window *win)
{
	unsigned int generation;

	if (!win->visible)
		return;

	win->visible = 0;
	generation = ++win->generation;

	if (reduce_motion()) {
		[win->win orderOut:nil];
		return;
	}

	[NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
		ctx.duration = fade_out_duration;
		win->win.animator.alphaValue = 0;
	} completionHandler:^{
		/* Don't hide the window if it was shown again in the meantime. */
		if (win->generation == generation)
			[win->win orderOut:nil];
	}];
}

/* A fixed position, transparent, borderless window with the given dimensions and offset. */
struct window *create_overlay_window(int x, int y, int w, int h)
{
	struct window *win = calloc(1, sizeof(struct window));

	NSWindow *nsWin = [[NSWindow alloc]
	    initWithContentRect:NSMakeRect((float)x, (float)y, (float)w, (float)h) // Initial size and position
		      styleMask:NSWindowStyleMaskBorderless
			backing:NSBackingStoreBuffered
			  defer:FALSE];

	/*
	 * Make our custom view the main content view for the window.
	 * Doing this will create an instance of the view and give it
	 * the the frame (bounds) to that of the window. We can then use
	 * our overloaded drawRect method to draw to the window using
	 * the implicitly provided graphics context.
	 */

	MainView *view = [[MainView alloc] init];
	view.win = win;

	[nsWin setContentView:view];

	[nsWin setBackgroundColor:[NSColor clearColor]];
	[nsWin setOpaque:NO];
	[nsWin setHasShadow:NO];
	[nsWin setLevel:NSMainMenuWindowLevel + 999];

	/* Never intercept the clicks we synthesize at the pointer position. */
	[nsWin setIgnoresMouseEvents:YES];

	/* Show up on every space, including those of fullscreen apps. */
	[nsWin setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
				     NSWindowCollectionBehaviorStationary |
				     NSWindowCollectionBehaviorFullScreenAuxiliary |
				     NSWindowCollectionBehaviorIgnoresCycle];

	/* Shown on demand by window_show(). */
	win->visible = 0;

	win->win = nsWin;

	return win;
}

struct window *create_window(const char *color, size_t w, size_t h)
{
	struct window *win = calloc(1, sizeof(struct window));
	NSRect rect = NSMakeRect(0, 0, (float)w, (float)h);

	NSWindow *nsWin = [[NSWindow alloc]
	    initWithContentRect:rect
		      styleMask:NSWindowStyleMaskBorderless
			backing:NSBackingStoreBuffered
			  defer:FALSE];

	[nsWin setBackgroundColor:nscolor_from_hex(color)];
	[nsWin setLevel:NSMainMenuWindowLevel + 9000];
	[nsWin makeKeyAndOrderFront:nil];

	win->win = nsWin;

	return win;
}
