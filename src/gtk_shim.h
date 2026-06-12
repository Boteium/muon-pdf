/* Minimal GTK4/GLib declarations covering exactly the API surface muon-pdf
 * uses, standing in for <gtk/gtk.h>.
 *
 * Zig 0.16 replaced the Clang-based translate-c with a self-hosted one
 * (arocc) that cannot yet preprocess the real GTK/GLib headers
 * (https://codeberg.org/ziglang/translate-c/issues/328 and related), so
 * including <gtk/gtk.h> via @cImport fails. This header declares the same
 * names with the same ABI, which both Zig 0.15 and 0.16 translate fine.
 *
 * Prototypes were extracted from the GTK 4 headers with `gcc -aux-info`;
 * enum values were read out of a program compiled against the real headers.
 * Both are covered by GTK 4's ABI stability guarantee. If a future Zig can
 * translate the real headers again, this file can be dropped by switching
 * the @cInclude back to <gtk/gtk.h>.
 */
#ifndef MUON_PDF_GTK_SHIM_H
#define MUON_PDF_GTK_SHIM_H

#include <stddef.h>
#include <gdk/gdkkeysyms.h>

/* --- basic GLib scalar types --- */
typedef char gchar;
typedef int gint;
typedef int gboolean;
typedef unsigned int guint;
typedef unsigned long gulong;
typedef double gdouble;
typedef void *gpointer;
typedef const void *gconstpointer;
typedef size_t gsize;
typedef long gssize;
typedef long long gint64;

/* --- object types, all used through pointers only --- */
typedef struct _GApplication GApplication;
typedef struct _GBytes GBytes;
typedef struct _GClosure GClosure;
typedef struct _GError GError;
typedef struct _GFile GFile;
typedef struct _GObject GObject;
typedef struct _GParamSpec GParamSpec;
typedef struct _GdkDisplay GdkDisplay;
typedef struct _GdkPaintable GdkPaintable;
typedef struct _GdkTexture GdkTexture;
typedef struct _GtkAdjustment GtkAdjustment;
typedef struct _GtkApplication GtkApplication;
typedef struct _GtkBox GtkBox;
typedef struct _GtkButton GtkButton;
typedef struct _GtkCheckButton GtkCheckButton;
typedef struct _GtkCssProvider GtkCssProvider;
typedef struct _GtkDialog GtkDialog;
typedef struct _GtkEventController GtkEventController;
typedef struct _GtkEventControllerKey GtkEventControllerKey;
typedef struct _GtkFileChooser GtkFileChooser;
typedef struct _GtkFileChooserNative GtkFileChooserNative;
typedef struct _GtkGesture GtkGesture;
typedef struct _GtkGestureClick GtkGestureClick;
typedef struct _GtkGestureDrag GtkGestureDrag;
typedef struct _GtkGestureSingle GtkGestureSingle;
typedef struct _GtkGestureSwipe GtkGestureSwipe;
typedef struct _GtkGrid GtkGrid;
typedef struct _GtkLabel GtkLabel;
typedef struct _GtkMenuButton GtkMenuButton;
typedef struct _GtkNativeDialog GtkNativeDialog;
typedef struct _GtkOverlay GtkOverlay;
typedef struct _GtkPicture GtkPicture;
typedef struct _GtkPopover GtkPopover;
typedef struct _GtkScrolledWindow GtkScrolledWindow;
typedef struct _GtkStyleProvider GtkStyleProvider;
typedef struct _GtkWidget GtkWidget;
typedef struct _GtkWindow GtkWindow;

/* --- callback types --- */
typedef void (*GCallback) (void);
typedef gboolean (*GSourceFunc) (gpointer user_data);
typedef void (*GClosureNotify) (gpointer data, GClosure *closure);

/* --- enums; values verified against the real GTK 4 headers --- */
typedef enum { G_APPLICATION_FLAGS_NONE = 0 } GApplicationFlags;
typedef enum { G_CONNECT_DEFAULT = 0 } GConnectFlags;
typedef enum { GDK_SHIFT_MASK = 1 << 0 } GdkModifierType;
typedef enum { GDK_MEMORY_R8G8B8 = 7 } GdkMemoryFormat;
typedef enum {
  GTK_ALIGN_FILL = 0,
  GTK_ALIGN_START = 1,
  GTK_ALIGN_END = 2,
  GTK_ALIGN_CENTER = 3
} GtkAlign;
typedef enum { GTK_BUTTONS_CLOSE = 2 } GtkButtonsType;
typedef enum { GTK_DIALOG_MODAL = 1 << 0 } GtkDialogFlags;
typedef enum {
  GTK_EVENT_SEQUENCE_NONE = 0,
  GTK_EVENT_SEQUENCE_CLAIMED = 1
} GtkEventSequenceState;
typedef enum { GTK_FILE_CHOOSER_ACTION_OPEN = 0 } GtkFileChooserAction;
typedef enum { GTK_MESSAGE_ERROR = 3 } GtkMessageType;
typedef enum {
  GTK_ORIENTATION_HORIZONTAL = 0,
  GTK_ORIENTATION_VERTICAL = 1
} GtkOrientation;
typedef enum { GTK_PHASE_CAPTURE = 1 } GtkPropagationPhase;
typedef enum { GTK_RESPONSE_ACCEPT = -3 } GtkResponseType;

#define GTK_STYLE_PROVIDER_PRIORITY_APPLICATION 600

/* --- GLib / GObject / GIO --- */
extern void g_application_quit (GApplication *);
extern int g_application_run (GApplication *, int, char **);
extern GBytes *g_bytes_new (gconstpointer, gsize);
extern void g_bytes_unref (GBytes *);
extern gboolean g_file_get_contents (const gchar *, gchar **, gsize *, GError **);
extern char *g_file_get_path (GFile *);
extern gboolean g_file_set_contents (const gchar *, const gchar *, gssize, GError **);
extern void g_free (gpointer);
extern gint64 g_get_monotonic_time (void);
extern const gchar *g_getenv (const gchar *);
extern guint g_idle_add (GSourceFunc, gpointer);
extern gint g_mkdir_with_parents (const gchar *, gint);
extern void g_object_unref (gpointer);
extern void g_set_application_name (const gchar *);
extern void g_set_prgname (const gchar *);
extern gulong g_signal_connect_data (gpointer, const gchar *, GCallback, gpointer, GClosureNotify, GConnectFlags);
extern gboolean g_source_remove (guint);
extern guint g_timeout_add (guint, GSourceFunc, gpointer);

/* --- GDK --- */
extern GdkDisplay *gdk_display_get_default (void);
extern GdkTexture *gdk_memory_texture_new (int, int, GdkMemoryFormat, GBytes *, gsize);

/* --- GTK --- */
extern double gtk_adjustment_get_page_size (GtkAdjustment *);
extern double gtk_adjustment_get_upper (GtkAdjustment *);
extern double gtk_adjustment_get_value (GtkAdjustment *);
extern void gtk_adjustment_set_value (GtkAdjustment *, double);
extern GtkApplication *gtk_application_new (const char *, GApplicationFlags);
extern GtkWidget *gtk_application_window_new (GtkApplication *);
extern void gtk_box_append (GtkBox *, GtkWidget *);
extern GtkWidget *gtk_box_new (GtkOrientation, int);
extern GtkWidget *gtk_button_new_with_label (const char *);
extern gboolean gtk_check_button_get_active (GtkCheckButton *);
extern GtkWidget *gtk_check_button_new_with_label (const char *);
extern void gtk_css_provider_load_from_string (GtkCssProvider *, const char *);
extern GtkCssProvider *gtk_css_provider_new (void);
extern GtkWidget *gtk_event_controller_get_widget (GtkEventController *);
extern GtkEventController *gtk_event_controller_key_new (void);
extern void gtk_event_controller_set_propagation_phase (GtkEventController *, GtkPropagationPhase);
extern GFile *gtk_file_chooser_get_file (GtkFileChooser *);
extern GtkFileChooserNative *gtk_file_chooser_native_new (const char *, GtkWindow *, GtkFileChooserAction, const char *, const char *);
extern GtkGesture *gtk_gesture_click_new (void);
extern GtkGesture *gtk_gesture_drag_new (void);
extern gboolean gtk_gesture_set_state (GtkGesture *, GtkEventSequenceState);
extern void gtk_gesture_single_set_touch_only (GtkGestureSingle *, gboolean);
extern void gtk_grid_attach (GtkGrid *, GtkWidget *, int, int, int, int);
extern GtkWidget *gtk_grid_new (void);
extern void gtk_grid_set_column_spacing (GtkGrid *, guint);
extern void gtk_grid_set_row_spacing (GtkGrid *, guint);
extern GtkWidget *gtk_label_new (const char *);
extern void gtk_label_set_text (GtkLabel *, const char *);
extern GtkWidget *gtk_menu_button_new (void);
extern void gtk_menu_button_popdown (GtkMenuButton *);
extern void gtk_menu_button_set_icon_name (GtkMenuButton *, const char *);
extern void gtk_menu_button_set_popover (GtkMenuButton *, GtkWidget *);
extern GtkWidget *gtk_message_dialog_new (GtkWindow *, GtkDialogFlags, GtkMessageType, GtkButtonsType, const char *, ...);
extern void gtk_native_dialog_show (GtkNativeDialog *);
extern void gtk_overlay_add_overlay (GtkOverlay *, GtkWidget *);
extern GtkWidget *gtk_overlay_new (void);
extern void gtk_overlay_set_child (GtkOverlay *, GtkWidget *);
extern GtkWidget *gtk_picture_new (void);
extern void gtk_picture_set_can_shrink (GtkPicture *, gboolean);
extern void gtk_picture_set_paintable (GtkPicture *, GdkPaintable *);
extern GtkWidget *gtk_popover_new (void);
extern void gtk_popover_set_child (GtkPopover *, GtkWidget *);
extern GtkAdjustment *gtk_scrolled_window_get_hadjustment (GtkScrolledWindow *);
extern GtkAdjustment *gtk_scrolled_window_get_vadjustment (GtkScrolledWindow *);
extern GtkWidget *gtk_scrolled_window_new (void);
extern void gtk_scrolled_window_set_child (GtkScrolledWindow *, GtkWidget *);
extern void gtk_style_context_add_provider_for_display (GdkDisplay *, GtkStyleProvider *, guint);
extern void gtk_widget_add_controller (GtkWidget *, GtkEventController *);
extern void gtk_widget_add_css_class (GtkWidget *, const char *);
extern int gtk_widget_get_height (GtkWidget *);
extern int gtk_widget_get_width (GtkWidget *);
extern void gtk_widget_remove_css_class (GtkWidget *, const char *);
extern void gtk_widget_set_focusable (GtkWidget *, gboolean);
extern void gtk_widget_set_halign (GtkWidget *, GtkAlign);
extern void gtk_widget_set_hexpand (GtkWidget *, gboolean);
extern void gtk_widget_set_margin_bottom (GtkWidget *, int);
extern void gtk_widget_set_margin_end (GtkWidget *, int);
extern void gtk_widget_set_margin_start (GtkWidget *, int);
extern void gtk_widget_set_margin_top (GtkWidget *, int);
extern void gtk_widget_set_opacity (GtkWidget *, double);
extern void gtk_widget_set_sensitive (GtkWidget *, gboolean);
extern void gtk_widget_set_size_request (GtkWidget *, int, int);
extern void gtk_widget_set_valign (GtkWidget *, GtkAlign);
extern void gtk_widget_set_vexpand (GtkWidget *, gboolean);
extern void gtk_widget_set_visible (GtkWidget *, gboolean);
extern void gtk_widget_show (GtkWidget *);
extern void gtk_window_destroy (GtkWindow *);
extern void gtk_window_fullscreen (GtkWindow *);
extern gboolean gtk_window_is_fullscreen (GtkWindow *);
extern void gtk_window_present (GtkWindow *);
extern void gtk_window_set_child (GtkWindow *, GtkWidget *);
extern void gtk_window_set_default_size (GtkWindow *, int, int);
extern void gtk_window_set_title (GtkWindow *, const char *);
extern void gtk_window_unfullscreen (GtkWindow *);

#endif /* MUON_PDF_GTK_SHIM_H */
