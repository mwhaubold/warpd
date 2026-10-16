#include "warpd.h"

/*
 * Remembered pointer positions, one per screen, persisted in the data
 * directory so they survive restarts and one-shot invocations
 * (warpd --screen). Each line is: <screen id> <x> <y>
 */
static struct screen_pos {
	char id[64];
	int x;
	int y;
} positions[MAX_SCREENS];
static size_t nr_positions;

static const char *screen_id(screen_t scr, size_t idx)
{
	static char buf[16];

	if (platform->screen_get_id)
		return platform->screen_get_id(scr);

	/* No stable id available, fall back to the screen's position in the list. */
	snprintf(buf, sizeof buf, "#%zu", idx);
	return buf;
}

static void read_positions()
{
	FILE *fh = fopen(get_data_path("screen_positions"), "r");

	nr_positions = 0;
	if (!fh)
		return;

	while (nr_positions < MAX_SCREENS) {
		struct screen_pos *p = &positions[nr_positions];

		if (fscanf(fh, "%63s %d %d", p->id, &p->x, &p->y) != 3)
			break;

		nr_positions++;
	}

	fclose(fh);
}

static void write_positions()
{
	size_t i;
	FILE *fh = fopen(get_data_path("screen_positions"), "w");

	if (!fh)
		return;

	for (i = 0; i < nr_positions; i++)
		fprintf(fh, "%s %d %d\n", positions[i].id, positions[i].x, positions[i].y);

	fclose(fh);
}

static struct screen_pos *find_position(const char *id)
{
	size_t i;

	for (i = 0; i < nr_positions; i++)
		if (!strcmp(positions[i].id, id))
			return &positions[i];

	return NULL;
}

static void save_position(const char *id, int x, int y)
{
	struct screen_pos *p = find_position(id);

	if (!p) {
		/* Evict the oldest entry if full. */
		if (nr_positions == MAX_SCREENS) {
			memmove(positions, positions + 1, sizeof(positions[0]) * (MAX_SCREENS - 1));
			nr_positions--;
		}

		p = &positions[nr_positions++];
		snprintf(p->id, sizeof p->id, "%s", id);
	}

	p->x = x;
	p->y = y;
}

void screen_selection_mode()
{
	size_t i;
	size_t n;
	screen_t screens[MAX_SCREENS];
	struct input_event *ev;
	const char *screen_chars = config_get("screen_chars");
	const int remember = config_get_int("screen_remember_position");

	screen_t cur;
	int cx, cy;

	platform->screen_list(screens, &n);
	assert(strlen(screen_chars) >= n);

	platform->mouse_get_position(&cur, &cx, &cy);

	for (i = 0; i < n; i++) {
		struct hint hint;
		int w, h;
		platform->screen_get_dimensions(screens[i], &w, &h);

		hint.x = w / 2 - 25;
		hint.y = h / 2 - 25;
		hint.w = 50;
		hint.h = 50;

		hint.label[0] = screen_chars[i];
		hint.label[1] = 0;
		hint.typed = 0;

		platform->hint_draw(screens[i], &hint, 1);
	}

	platform->commit();

	platform->input_grab_keyboard();
	while (1) {
		ev = platform->input_next_event(0);
		if (ev && ev->pressed)
			break;
	}
	platform->input_ungrab_keyboard();

	for (i = 0; i < n; i++) {
		const char *key = input_event_tostr(ev);

		if (key[0] == screen_chars[i] && key[1] == 0) {
			int w, h;
			int x, y;
			struct screen_pos *p;

			platform->screen_get_dimensions(screens[i], &w, &h);

			x = w / 2;
			y = h / 2;

			/* Selecting the current screen keeps centering the pointer. */
			if (remember && screens[i] != cur) {
				size_t j;

				read_positions();

				for (j = 0; j < n; j++)
					if (screens[j] == cur)
						save_position(screen_id(cur, j), cx, cy);

				if ((p = find_position(screen_id(screens[i], i)))) {
					/* The resolution may have changed since. */
					x = MIN(p->x, w - 1);
					y = MIN(p->y, h - 1);
				}

				write_positions();
			}

			platform->mouse_move(screens[i], x, y);
		}
	}

	for (i = 0; i < n; i++)
		platform->screen_clear(screens[i]);

	platform->commit();
}
