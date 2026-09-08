#include "calendar.c"
static GtkContainer *root_widget(wbcffi_module *obj) { return GTK_CONTAINER(obj); }
int main(int argc, char **argv) {
    gtk_init(&argc, &argv);
    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    GtkWidget *root = gtk_event_box_new();
    gtk_container_add(GTK_CONTAINER(window), root);
    wbcffi_init_info info = { (wbcffi_module *)root, "test", root_widget, NULL };
    Calendar *cal = wbcffi_init(&info, NULL, 0);
    cal->year = 2024; cal->month = 2;
    cal->today_year = 2024; cal->today_month = 2; cal->today_day = 29;
    render_month(cal);
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(cal->days[4])), ==, "1");
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(cal->days[32])), ==, "29");
    g_assert_true(gtk_style_context_has_class(gtk_widget_get_style_context(cal->days[32]), "today"));
    g_assert_false(gtk_widget_get_visible(cal->days[35]));
    cal->year = 2026; cal->month = 12;
    navigate(GTK_BUTTON(cal->next), cal);
    g_assert_cmpint(cal->year, ==, 2027); g_assert_cmpint(cal->month, ==, 1);
    navigate(GTK_BUTTON(cal->previous), cal);
    g_assert_cmpint(cal->year, ==, 2026); g_assert_cmpint(cal->month, ==, 12);
    cal->year = 2026; cal->month = 8; render_month(cal);
    g_assert_true(gtk_widget_get_visible(cal->days[41]));
    g_assert_true(gtk_style_context_has_class(gtk_widget_get_style_context(cal->days[0]), "sunday"));
    g_assert_true(gtk_style_context_has_class(gtk_widget_get_style_context(cal->days[6]), "saturday"));
    cal->year = 1; cal->month = 1; render_month(cal);
    g_assert_false(gtk_widget_get_sensitive(cal->previous));
    wbcffi_deinit(cal);
    gtk_widget_destroy(window);
    g_print("Calendar: leap day, weekday alignment, five/six weeks, year rollover, styles, bounds and cleanup passed.\n");
}
