/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#ifndef EVLOOP_H
#define EVLOOP_H

#include "../../platform.h"
#include <ApplicationServices/ApplicationServices.h>
#include <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>
#include <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <pthread.h>

/*
 * NOTE: our API uses an upper left origin (ULO) coordinate system, while
 * most* of the macOS APIs use a lower left origin (LLO) coordinate system.
 * Translation between the coordinate systems should be done at the latest
 * point possible (i.e before the corresponding NS/CG calls). This is expected
 * to be understood implicitly when reading platform code.
 *
 * * To compound matters, it seems some of the CG APIs use an ULO coordinate
 * system :/. When in doubt, consult docs from the high tower.
 */

#define MAX_DRAWING_HOOKS 32
#define MAX_BOXES 32

struct box {
	int x;
	int y;
	int w;
	int h;

	struct screen *scr;
	NSColor *color;
};

struct drawing_hook {
	void (*hook)(void *arg, NSView *view);
	void *arg;
};

struct window {
	NSWindow *win;

	/* Whether the window should be visible (it may still be fading out). */
	int visible;
	/* Incremented on every show/hide, used to cancel stale fade outs. */
	unsigned int generation;

	size_t nr_hooks;
	struct drawing_hook hooks[MAX_DRAWING_HOOKS];
};

struct screen {
	/* LLO */
	int x;
	int y;

	int w;
	int h;

	struct hint hints[MAX_HINTS];
	size_t nr_hints;

	struct box boxes[MAX_BOXES];
	size_t nr_boxes;

	struct window *overlay;

	/* Display UUID, stable across reconnects. */
	char id[40];

	/* Area not covered by the menu bar or dock, relative to x,y (LLO). */
	NSRect visible_frame;

	struct {
		int x;
		int y;
		int size;
		NSColor *color;
	} cursor;

	/* Mode indicator, applied to hud_view on commit. */
	struct {
		int visible;
		char text[16];
		char position[16];
		int size;
		NSColor *color;
	} hud;
	NSVisualEffectView *hud_view;

	/* Hint layers (see hint.m), main thread only. */
	NSView *hint_view;
	CALayer *hint_root;
	size_t hints_shown;
	int hints_dirty;      /* Set by osx_hint_draw()/osx_screen_clear(). */
	CGPoint hints_center; /* Center of the shown hints (LLO). */
	int hint_animations; /* Number of hint animations still running. */
};


void window_show(struct window *win);
void window_hide(struct window *win);
void window_move(struct window *win, struct screen *scr, int x, int y);

void window_register_draw_hook(struct window *win,
			       void (*draw)(void *arg, NSView *view),
			       void *arg);

struct window *create_window(const char *color, size_t w, size_t h);
struct window *create_overlay_window(int x, int y, int w, int h);

void macos_init_input(void);
void macos_init_mouse(void);
void macos_init_screen(void);
void macos_sync_screens(void);

void macos_draw_box(struct screen *scr, NSColor *col, float x, float y, float w,
		    float h, float r);

int macos_is_dark(NSView *view);
NSFont *macos_get_font(const char *family, int w, int h, const char *s);
void macos_update_hud(struct screen *scr);
void macos_update_hints(struct screen *scr);
void macos_reset_hints(struct screen *scr);
void macos_flash_rect(struct screen *scr, CGRect rect);
int osx_snap_to_element(struct screen *scr, int *x, int *y, int radius);
int macos_screen_needs_overlay(struct screen *scr);
int macos_animations(void);
void osx_init_animations(int enabled);

void send_key(uint8_t code, int pressed);

NSColor *nscolor_from_hex(const char *str);
NSColor *macos_color(const char *str);

extern struct screen screens[MAX_SCREENS];
extern size_t nr_screens;
extern uint8_t active_mods;

void osx_input_grab_keyboard(void);
void osx_input_ungrab_keyboard(void);
struct input_event *osx_input_next_event(int timeout);
uint8_t osx_input_lookup_code(const char *name, int *shifted);
const char *osx_input_lookup_name(uint8_t code, int shifted);
struct input_event *osx_input_wait(struct input_event *events, size_t sz);
void osx_mouse_move(screen_t scr, int x, int y);
void osx_mouse_down(int btn);
void osx_mouse_up(int btn);
void osx_mouse_click(int btn);
void osx_mouse_get_position(screen_t *scr, int *x, int *y);
void osx_mouse_show(void);
void osx_mouse_hide(void);
void osx_screen_get_dimensions(screen_t scr, int *w, int *h);
void osx_screen_draw_box(screen_t scr, int x, int y, int w, int h, const char *color);
void osx_screen_clear(screen_t scr);
void osx_screen_draw_cursor(screen_t scr, int x, int y, int size, const char *color);
void osx_screen_draw_indicator(screen_t scr, const char *mode, const char *position, int size, const char *color);
void osx_screen_list(screen_t scr[MAX_SCREENS], size_t *n);
void osx_init_hint(const char *bg, const char *fg, int border_radius, const char *font_family);
void osx_hint_draw(struct screen *scr, struct hint *hints, size_t n);
void osx_scroll(int direction);
void osx_copy_selection(void);
void osx_monitor_file(const char *_path);
void osx_input_interrupt(void);
void osx_input_interrupt_screen_change(void);
void osx_input_set_paused(int paused);
const char *osx_screen_get_id(screen_t scr);
void osx_init_status_icon(int enabled);

/* The config file being monitored (if any). */
extern const char *macos_config_path;
void osx_commit(void);

#endif
