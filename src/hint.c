/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#include "warpd.h"

struct hint *hints;
struct hint matched[MAX_HINTS];

static size_t nr_hints;
static size_t nr_matched;

char last_selected_hint[32];

static void filter(screen_t scr, const char *s)
{
	size_t i;

	nr_matched = 0;
	for (i = 0; i < nr_hints; i++) {
		if (strstr(hints[i].label, s) == hints[i].label) {
			matched[nr_matched] = hints[i];
			matched[nr_matched++].typed = strlen(s);
		}
	}

	platform->screen_clear(scr);
	platform->hint_draw(scr, matched, nr_matched);
	draw_indicator(scr, "HINT");
	platform->commit();
}

/* Size of a hint box with a label of len characters when hint_spacing is set. */
static void get_spaced_hint_size(size_t len, int *w, int *h)
{
	const int spacing = config_get_int("hint_spacing");

	*h = spacing * 42 / 100;
	*w = *h * (43 * (int)len + 55) / 100;
}

static void get_hint_size(screen_t scr, int *w, int *h)
{
	int sw, sh;

	if (config_get_int("hint_spacing") > 0) {
		get_spaced_hint_size(2, w, h);
		return;
	}

	platform->screen_get_dimensions(scr, &sw, &sh);

	if (sw < sh) {
		int tmp = sw;
		sw = sh;
		sh = tmp;
	}

	*w = (sw * config_get_int("hint_size")) / 1000;
	*h = (sh * config_get_int("hint_size")) / 1000;
}

static struct cell {
	int x;
	int y;
	long dist;
	int three_letters;
} cells[MAX_HINTS];

static int cmp_cell_dist(const void *a, const void *b)
{
	const struct cell *ca = *(const struct cell **)a;
	const struct cell *cb = *(const struct cell **)b;

	return (ca->dist > cb->dist) - (ca->dist < cb->dist);
}

/*
 * Lay out hints hint_spacing points apart so that they are equally precise
 * on every screen regardless of its size. If there are more hints than can
 * be labelled with two characters, the last m characters of hint_chars are
 * reserved as prefixes for three character labels, which are given to the
 * hints furthest from the pointer. All labels are prefix free.
 */
static size_t generate_spaced_hints(screen_t scr, struct hint *hints)
{
	static struct cell *by_dist[MAX_HINTS];

	const char *chars = config_get("hint_chars");
	const size_t k = strlen(chars);
	int spacing = config_get_int("hint_spacing");
	int sw, sh, px, py;
	size_t nc, nr, n, n2, m, i;
	size_t next2 = 0, next3 = 0;

	platform->screen_get_dimensions(scr, &sw, &sh);
	platform->mouse_get_position(NULL, &px, &py);

	/* Widen the spacing if the screen would need more hints than we can hold or label. */
	while (1) {
		nc = (sw + spacing / 2) / spacing;
		nr = (sh + spacing / 2) / spacing;
		nc = nc ? nc : 1;
		nr = nr ? nr : 1;
		n = nc * nr;

		if (n <= MAX_HINTS && n <= k * k * k)
			break;

		spacing++;
	}

	m = n > k * k ? (n - k * k + (k * k - k) - 1) / (k * k - k) : 0;
	n2 = MIN((k - m) * k, n);

	for (i = 0; i < n; i++) {
		struct cell *c = &cells[i];
		const size_t col = i / nr;
		const size_t row = i % nr;

		c->x = (2 * col + 1) * sw / (2 * nc);
		c->y = (2 * row + 1) * sh / (2 * nr);
		c->dist = (long)(c->x - px) * (c->x - px) + (long)(c->y - py) * (c->y - py);
		c->three_letters = 1;
		by_dist[i] = c;
	}

	qsort(by_dist, n, sizeof by_dist[0], cmp_cell_dist);
	for (i = 0; i < n2; i++)
		by_dist[i]->three_letters = 0;

	/* Assign labels in column-major order so that labels sharing a prefix stay close together. */
	for (i = 0; i < n; i++) {
		struct hint *hint = &hints[i];
		size_t len;

		if (cells[i].three_letters) {
			const size_t idx = next3++;

			hint->label[0] = chars[k - m + idx / (k * k)];
			hint->label[1] = chars[(idx / k) % k];
			hint->label[2] = chars[idx % k];
			len = 3;
		} else {
			const size_t idx = next2++;

			hint->label[0] = chars[idx / k];
			hint->label[1] = chars[idx % k];
			len = 2;
		}

		hint->label[len] = 0;
		get_spaced_hint_size(len, &hint->w, &hint->h);
		hint->x = cells[i].x - hint->w / 2;
		hint->y = cells[i].y - hint->h / 2;
		hint->typed = 0;
	}

	return n;
}

static size_t generate_fullscreen_hints(screen_t scr, struct hint *hints)
{
	int sw, sh;
	int w, h;
	int i, j;
	size_t n = 0;

	const char *chars = config_get("hint_chars");

	if (config_get_int("hint_spacing") > 0 && strlen(chars) >= 2)
		return generate_spaced_hints(scr, hints);

	get_hint_size(scr, &w, &h);
	platform->screen_get_dimensions(scr, &sw, &sh);

	const int nr = strlen(chars);
	const int nc = strlen(chars);


	const int colgap = sw / nc - w;
	const int rowgap = sh / nr - h;

	const int x_offset = (sw - nc * w - (nc - 1) * colgap) / 2;
	const int y_offset = (sh - nr * h - (nr - 1) * rowgap) / 2;

	int x = x_offset;
	int y = y_offset;

	get_hint_size(scr, &w, &h);

	for (i = 0; i < nc; i++) {
		for (j = 0; j < nr; j++) {
			struct hint *hint = &hints[n++];

			hint->x = x;
			hint->y = y;

			hint->w = w;
			hint->h = h;

			hint->label[0] = chars[i];
			hint->label[1] = chars[j];
			hint->label[2] = 0;

			y += rowgap + h;
		}

		y = y_offset;
		x += colgap + w;
	}

	return n;
}

static int hint_selection(screen_t scr, struct hint *_hints, size_t _nr_hints)
{
	hints = _hints;
	nr_hints = _nr_hints;

	filter(scr, "");

	int rc = 0;
	char buf[32] = {0};
	platform->input_grab_keyboard();

	platform->mouse_hide();

	const char *keys[] = {
		"hint_exit",
		"hint_undo_all",
		"hint_undo",
	};

	config_input_whitelist(keys, sizeof keys / sizeof keys[0]);

	while (1) {
		struct input_event *ev;
		ssize_t len;

		ev = platform->input_next_event(0);

		/* NULL if interrupted (e.g config or display change). */
		if (!ev || !ev->pressed)
			continue;

		len = strlen(buf);

		if (config_input_match(ev, "hint_exit")) {
			rc = -1;
			break;
		} else if (config_input_match(ev, "hint_undo_all")) {
			buf[0] = 0;
		} else if (config_input_match(ev, "hint_undo")) {
			if (len)
				buf[len - 1] = 0;
		} else {
			const char *name = input_event_tostr(ev);

			if (!name || name[1])
				continue;

			buf[len++] = name[0];
		}

		filter(scr, buf);

		if (nr_matched == 1) {
			int nx, ny;
			struct hint *h = &matched[0];

			platform->screen_clear(scr);

			nx = h->x + h->w / 2;
			ny = h->y + h->h / 2;

			/*
			 * Wiggle the cursor a single pixel to accommodate
			 * text selection widgets which don't like spontaneous
			 * cursor warping.
			 */
			platform->mouse_move(scr, nx+1, ny+1);

			platform->mouse_move(scr, nx, ny);
			strcpy(last_selected_hint, buf);
			break;
		} else if (nr_matched == 0) {
			break;
		}
	}

	platform->input_ungrab_keyboard();
	platform->screen_clear(scr);
	platform->mouse_show();

	platform->commit();
	return rc;
}

static int sift(void)
{
	int gap = config_get_int("hint2_gap_size");
	int hint_sz = config_get_int("hint2_size");

	const char *chars = config_get("hint2_chars");
	size_t chars_len= strlen(chars);

	int grid_sz = config_get_int("hint2_grid_size");

	int x, y;
	int sh, sw;

	int col;
	int row;
	size_t n = 0;
	screen_t scr;

	struct hint hints[MAX_HINTS];

	platform->mouse_get_position(&scr, &x, &y);
	platform->screen_get_dimensions(scr, &sw, &sh);

	if (config_get_int("hint_spacing") > 0) {
		/* Cover a single first pass cell (plus some margin) on every screen. */
		const int pitch = config_get_int("hint_spacing") * 4 / (3 * grid_sz);

		gap = 2;
		hint_sz = pitch - gap;
	} else {
		gap = (gap * sh) / 1000;
		hint_sz = (hint_sz * sh) / 1000;
	}

	x -= ((hint_sz + (gap - 1)) * grid_sz) / 2;
	y -= ((hint_sz + (gap - 1)) * grid_sz) / 2;

	for (col = 0; col < grid_sz; col++)
		for (row = 0; row < grid_sz; row++) {
			size_t idx = (row * grid_sz) + col;

			if (idx < chars_len) {
				hints[n].x = x + (hint_sz + gap) * col;
				hints[n].y = y + (hint_sz + gap) * row;

				hints[n].w = hint_sz;
				hints[n].h = hint_sz;
				hints[n].label[0] = chars[idx];
				hints[n].label[1] = 0;

				n++;
			}
	}

	return hint_selection(scr, hints, n);
}

void init_hints(void)
{
	platform->init_hint(config_get("hint_bgcolor"),
			    config_get("hint_fgcolor"),
			    config_get_int("hint_border_radius"),
			    config_get("hint_font"));
}

int hintspec_mode(void)
{
	screen_t scr;
	int sw, sh;
	int w, h;

	int n = 0;
	struct hint hints[MAX_HINTS];

	platform->mouse_get_position(&scr, NULL, NULL);
	platform->screen_get_dimensions(scr, &sw, &sh);

	get_hint_size(scr, &w, &h);

	while (scanf("%15s %d %d",
		hints[n].label,
		&hints[n].x,
		&hints[n].y) == 3) {

		hints[n].w = w;
		hints[n].h = h;
		hints[n].x -= w/2;
		hints[n].y -= h/2;

		n++;
	}

	return hint_selection(scr, hints, n);
}

int full_hint_mode(int second_pass)
{
	int mx, my;
	screen_t scr;
	struct hint hints[MAX_HINTS];

	platform->mouse_get_position(&scr, &mx, &my);
	hist_add(mx, my);

	nr_hints = generate_fullscreen_hints(scr, hints);

	if (hint_selection(scr, hints, nr_hints))
		return -1;

	if (second_pass)
		return sift();
	else
		return 0;
}

int history_hint_mode(void)
{
	struct hint hints[MAX_HINTS];
	struct histfile_ent *ents;
	screen_t scr;
	int w, h;
	int sw, sh;
	size_t n, i;

	platform->mouse_get_position(&scr, NULL, NULL);
	platform->screen_get_dimensions(scr, &sw, &sh);

	n = histfile_read(&ents);

	get_hint_size(scr, &w, &h);

	for (i = 0; i < n; i++) {
		hints[i].w = w;
		hints[i].h = h;

		hints[i].x = ents[i].x - w/2;
		hints[i].y = ents[i].y - h/2;

		hints[i].label[0] = 'a'+i;
		hints[i].label[1] = 0;
	}

	return hint_selection(scr, hints, n);
}
