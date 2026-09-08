/* Waybar CFFI ABI 2: an in-process clock with a custom GTK calendar. */
#include <gtk/gtk.h>

typedef struct wbcffi_module wbcffi_module;
typedef struct {
    wbcffi_module *obj;
    const char *waybar_version;
    GtkContainer *(*get_root_widget)(wbcffi_module *);
    void (*queue_update)(wbcffi_module *);
} wbcffi_init_info;
typedef struct { const char *key, *value; } wbcffi_config_entry;
const size_t wbcffi_version = 2;

/* Keep the containing menu open while its navigation buttons are used. */
typedef struct { GtkMenuItem parent; } CalendarItem;
typedef struct { GtkMenuItemClass parent; } CalendarItemClass;
G_DEFINE_TYPE(CalendarItem, calendar_item, GTK_TYPE_MENU_ITEM)
static void calendar_item_class_init(CalendarItemClass *klass) {
    GTK_MENU_ITEM_CLASS(klass)->hide_on_activate = FALSE;
}
static void calendar_item_init(CalendarItem *item) { (void)item; }

typedef struct {
    GtkWidget *button, *clock, *popup, *heading, *previous, *current, *next;
    GtkWidget *days[42];
    guint timer;
    int year, month, today_year, today_month, today_day;
} Calendar;

static void add_class(GtkWidget *widget, const char *name) {
    gtk_style_context_add_class(gtk_widget_get_style_context(widget), name);
}

static void read_today(Calendar *cal) {
    GDateTime *now = g_date_time_new_now_local();
    cal->today_year = g_date_time_get_year(now);
    cal->today_month = g_date_time_get_month(now);
    cal->today_day = g_date_time_get_day_of_month(now);
    g_date_time_unref(now);
}

static void render_month(Calendar *cal) {
    GDate first;
    g_date_clear(&first, 1);
    g_date_set_dmy(&first, 1, cal->month, cal->year);
    int start = g_date_get_weekday(&first) % 7;
    int count = g_date_get_days_in_month(cal->month, cal->year);
    int rows = (start + count + 6) / 7;
    char title[64];
    g_snprintf(title, sizeof title, "%d年 %d月", cal->year, cal->month);
    gtk_label_set_text(GTK_LABEL(cal->heading), title);
    gtk_widget_set_sensitive(cal->previous, cal->year > 1 || cal->month > 1);
    gtk_widget_set_sensitive(cal->next, cal->year < 9999 || cal->month < 12);
    for (int i = 0; i < 42; i++) {
        int day = i - start + 1;
        char text[8] = "";
        if (day >= 1 && day <= count)
            g_snprintf(text, sizeof text, "%d", day);
        gtk_label_set_text(GTK_LABEL(cal->days[i]), text);
        GtkStyleContext *style = gtk_widget_get_style_context(cal->days[i]);
        gtk_style_context_remove_class(style, "today");
        if (cal->year == cal->today_year && cal->month == cal->today_month &&
            day == cal->today_day)
            gtk_style_context_add_class(style, "today");
        gtk_widget_set_visible(cal->days[i], i < rows * 7);
    }
}

static void navigate(GtkButton *button, gpointer data) {
    Calendar *cal = data;
    g_debug("calendar navigation");
    int offset = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "offset"));
    read_today(cal);
    if (!offset) {
        cal->year = cal->today_year;
        cal->month = cal->today_month;
    } else {
        int month = cal->year * 12 + cal->month - 1 + offset;
        if (month < 12 || month >= 10000 * 12) return;
        cal->year = month / 12;
        cal->month = month % 12 + 1;
    }
    render_month(cal);
}

static gboolean menu_click(GtkWidget *menu, GdkEventButton *event, gpointer data) {
    Calendar *cal = data;
    int event_x, event_y, menu_x, menu_y;
    gdk_window_get_origin(event->window, &event_x, &event_y);
    gdk_window_get_origin(gtk_widget_get_window(menu), &menu_x, &menu_y);
    int x = event_x + event->x - menu_x;
    int y = event_y + event->y - menu_y;
    if (x < 0 || y < 0 || x >= gtk_widget_get_allocated_width(menu) ||
        y >= gtk_widget_get_allocated_height(menu)) return FALSE;
    /* GtkMenu normally activates/dismisses its enclosing item before nested
     * buttons get the event. Route our navigation explicitly, keeping it open. */
    if (event->type == GDK_BUTTON_PRESS && event->button == 1) {
        GtkWidget *buttons[] = {cal->previous, cal->current, cal->next};
        for (int i = 0; i < 3; i++) {
            int bx, by;
            gtk_widget_translate_coordinates(buttons[i], menu, 0, 0, &bx, &by);
            if (x >= bx && y >= by && x < bx + gtk_widget_get_allocated_width(buttons[i]) &&
                y < by + gtk_widget_get_allocated_height(buttons[i]) &&
                gtk_widget_get_sensitive(buttons[i])) {
                navigate(GTK_BUTTON(buttons[i]), cal);
                break;
            }
        }
    }
    return TRUE;
}

static void toggle(GtkButton *button, gpointer data) {
    (void)button;
    Calendar *cal = data;
    g_debug("calendar toggle: mapped=%d", gtk_widget_get_mapped(cal->popup));
    if (gtk_widget_get_mapped(cal->popup)) {
        gtk_menu_popdown(GTK_MENU(cal->popup));
    } else {
        read_today(cal);
        cal->year = cal->today_year;
        cal->month = cal->today_month;
        render_month(cal);
        gtk_widget_show(cal->popup);
        GdkEvent *event = gtk_get_current_event();
        /* The Waybar event box has its own GdkWindow. Its allocation offset
         * must not be added again when anchoring the popup. */
        GdkRectangle anchor = {0, 0, gtk_widget_get_allocated_width(cal->button),
                              gtk_widget_get_allocated_height(cal->button)};
        gtk_menu_popup_at_rect(GTK_MENU(cal->popup), gtk_widget_get_window(cal->button),
                              &anchor, GDK_GRAVITY_SOUTH, GDK_GRAVITY_NORTH, event);
        if (event) gdk_event_free(event);
    }
}

static gboolean tick(gpointer data) {
    Calendar *cal = data;
    GDateTime *now = g_date_time_new_now_local();
    char *text = g_date_time_format(now, " %Y-%m-%d %H:%M:%S");
    gtk_label_set_text(GTK_LABEL(cal->clock), text);
    g_free(text);
    int previous_day = cal->today_day;
    read_today(cal);
    if (previous_day != cal->today_day && gtk_widget_get_mapped(cal->popup))
        render_month(cal);
    g_date_time_unref(now);
    return G_SOURCE_CONTINUE;
}

void *wbcffi_init(const wbcffi_init_info *info,
                 const wbcffi_config_entry *entries, size_t count) {
    (void)entries;
    (void)count;
    Calendar *cal = g_new0(Calendar, 1);
    GtkContainer *root = info->get_root_widget(info->obj);
    cal->button = GTK_WIDGET(root);
    cal->clock = gtk_label_new("");
    gtk_widget_set_name(cal->clock, "clock");
    gtk_container_add(root, cal->clock);

    cal->popup = gtk_menu_new();
    gtk_menu_attach_to_widget(GTK_MENU(cal->popup), cal->button, NULL);
    gtk_menu_set_reserve_toggle_size(GTK_MENU(cal->popup), FALSE);
    g_signal_connect(cal->popup, "button-press-event", G_CALLBACK(menu_click), cal);
    g_signal_connect(cal->popup, "button-release-event", G_CALLBACK(menu_click), cal);
    gtk_widget_set_name(cal->popup, "calendar-popup");
    GtkWidget *item = g_object_new(calendar_item_get_type(), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(cal->popup), item);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    add_class(box, "calendar-content");
    gtk_container_add(GTK_CONTAINER(item), box);
    cal->heading = gtk_label_new("");
    add_class(cal->heading, "calendar-heading");
    gtk_box_pack_start(GTK_BOX(box), cal->heading, FALSE, FALSE, 0);

    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_column_homogeneous(GTK_GRID(grid), TRUE);
    gtk_grid_set_row_spacing(GTK_GRID(grid), 3);
    gtk_box_pack_start(GTK_BOX(box), grid, FALSE, FALSE, 0);
    const char *weekdays[] = {"日", "月", "火", "水", "木", "金", "土"};
    for (int column = 0; column < 7; column++) {
        GtkWidget *label = gtk_label_new(weekdays[column]);
        add_class(label, "weekday");
        if (column == 0) add_class(label, "sunday");
        if (column == 6) add_class(label, "saturday");
        gtk_grid_attach(GTK_GRID(grid), label, column, 0, 1, 1);
    }
    for (int i = 0; i < 42; i++) {
        cal->days[i] = gtk_label_new("");
        add_class(cal->days[i], "day");
        if (i % 7 == 0) add_class(cal->days[i], "sunday");
        if (i % 7 == 6) add_class(cal->days[i], "saturday");
        gtk_grid_attach(GTK_GRID(grid), cal->days[i], i % 7, i / 7 + 1, 1, 1);
        /* Waybar's show_all must not reveal unused week rows. */
        gtk_widget_set_no_show_all(cal->days[i], TRUE);
    }
    GtkWidget *navigation = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_set_homogeneous(GTK_BOX(navigation), TRUE);
    gtk_box_pack_start(GTK_BOX(box), navigation, FALSE, FALSE, 0);
    const char *labels[] = {"‹ 前月", "今月", "翌月 ›"};
    for (int i = 0; i < 3; i++) {
        GtkWidget *button = gtk_button_new_with_label(labels[i]);
        g_object_set_data(G_OBJECT(button), "offset", GINT_TO_POINTER(i - 1));
        g_signal_connect(button, "clicked", G_CALLBACK(navigate), cal);
        gtk_box_pack_start(GTK_BOX(navigation), button, TRUE, TRUE, 0);
        if (i == 0) cal->previous = button;
        if (i == 1) cal->current = button;
        if (i == 2) cal->next = button;
    }
    gtk_widget_show_all(item);
    gtk_widget_show_all(cal->button);
    tick(cal);
    cal->timer = g_timeout_add_seconds(1, tick, cal);
    return cal;
}

void wbcffi_deinit(void *instance) {
    Calendar *cal = instance;
    g_source_remove(cal->timer);
    g_signal_handlers_disconnect_by_data(cal->button, cal);
    gtk_widget_destroy(cal->popup);
    g_free(cal);
}

void wbcffi_doaction(void *instance, const char *action) {
    g_debug("calendar action: %s", action);
    if (g_str_equal(action, "toggle")) toggle(NULL, instance);
}
