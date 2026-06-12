/* Minimal MuPDF declarations covering exactly the API surface muon-pdf
 * uses, standing in for <mupdf/fitz.h>.
 *
 * Zig 0.16's self-hosted translate-c mis-translates some static inline
 * helpers in the real fitz headers (incrementing through a pointer to
 * int8_t or int16_t renders as invalid Zig), which breaks the whole
 * @cImport even though this app never calls them. See gtk_shim.h for the
 * same story with GTK.
 *
 * Prototypes were extracted from the MuPDF headers with `gcc -aux-info`.
 * fz_matrix and fz_rect are passed/returned by value, so their layouts
 * must match <mupdf/fitz/geometry.h> exactly. FZ_VERSION comes from the
 * real (self-contained) version header so the runtime version check in
 * fz_new_context_imp keeps tracking the installed library.
 */
#ifndef MUON_PDF_MUPDF_SHIM_H
#define MUON_PDF_MUPDF_SHIM_H

#include <stddef.h>
#include <mupdf/fitz/version.h>

typedef struct fz_alloc_context fz_alloc_context;
typedef struct fz_colorspace fz_colorspace;
typedef struct fz_context fz_context;
typedef struct fz_document fz_document;
typedef struct fz_locks_context fz_locks_context;
typedef struct fz_page fz_page;
typedef struct fz_pixmap fz_pixmap;

typedef struct
{
	float a, b, c, d, e, f;
} fz_matrix;

typedef struct
{
	float x0, y0;
	float x1, y1;
} fz_rect;

enum {
	FZ_STORE_UNLIMITED = 0,
	FZ_STORE_DEFAULT = 256 << 20
};

extern fz_rect fz_bound_page (fz_context *, fz_page *);
extern fz_matrix fz_concat (fz_matrix, fz_matrix);
extern int fz_count_pages (fz_context *, fz_document *);
extern fz_colorspace *fz_device_rgb (fz_context *);
extern void fz_drop_context (fz_context *);
extern void fz_drop_document (fz_context *, fz_document *);
extern void fz_drop_page (fz_context *, fz_page *);
extern void fz_drop_pixmap (fz_context *, fz_pixmap *);
extern fz_page *fz_load_page (fz_context *, fz_document *, int);
extern fz_context *fz_new_context_imp (const fz_alloc_context *, const fz_locks_context *, size_t, const char *);
extern fz_pixmap *fz_new_pixmap_from_page_number (fz_context *, fz_document *, int, fz_matrix, fz_colorspace *, int);
extern fz_document *fz_open_document (fz_context *, const char *);
extern int fz_pixmap_height (fz_context *, const fz_pixmap *);
extern unsigned char *fz_pixmap_samples (fz_context *, const fz_pixmap *);
extern int fz_pixmap_stride (fz_context *, const fz_pixmap *);
extern int fz_pixmap_width (fz_context *, const fz_pixmap *);
extern void fz_register_document_handlers (fz_context *);
extern fz_matrix fz_rotate (float);
extern fz_matrix fz_scale (float, float);

#define fz_new_context(alloc, locks, max_store) fz_new_context_imp(alloc, locks, max_store, FZ_VERSION)

#endif /* MUON_PDF_MUPDF_SHIM_H */
