/*
 * tls_shim.c
 *
 * Minimal server-side TLS (OpenSSL) for the feig http endpoint.
 *
 * OpenSSL is dlopen'd at runtime (tls_init), so the binary runs without
 * OpenSSL installed until -tls is actually used. All symbols used exist
 * in OpenSSL 1.1.0 and 3.x, so both are supported.
 *
 * The handshake runs on an already-accepted, blocking fd. The fd stays
 * owned by the caller (SSL_free does not close it).
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

struct ssl_ctx_st;
struct ssl_st;
struct ssl_method_st;

static struct ssl_ctx_st *(*p_SSL_CTX_new)(const struct ssl_method_st *meth);
static const struct ssl_method_st *(*p_TLS_server_method)(void);
static int (*p_SSL_CTX_use_certificate_file)(struct ssl_ctx_st *ctx, const char *file, int type);
static int (*p_SSL_CTX_use_PrivateKey_file)(struct ssl_ctx_st *ctx, const char *file, int type);
static int (*p_SSL_CTX_check_private_key)(struct ssl_ctx_st *ctx);
static struct ssl_st *(*p_SSL_new)(struct ssl_ctx_st *ctx);
static int (*p_SSL_set_fd)(struct ssl_st *ssl, int fd);
static int (*p_SSL_accept)(struct ssl_st *ssl);
static int (*p_SSL_read)(struct ssl_st *ssl, void *buf, int num);
static int (*p_SSL_write)(struct ssl_st *ssl, const void *buf, int num);
static void (*p_SSL_free)(struct ssl_st *ssl);
static int (*p_SSL_get_error)(const struct ssl_st *ssl, int ret);
static void (*p_SSL_CTX_free)(struct ssl_ctx_st *ctx);
static unsigned long (*p_ERR_get_error)(void);
static void (*p_ERR_error_string_n)(const unsigned long e, char *buf, size_t num);

static struct ssl_ctx_st *g_ctx;
static char g_err[256] = "no error";
static int g_last_err_code;

#define SSL_FILETYPE_PEM 1
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_SYSCALL 5

/*
 * Load OpenSSL and build the server context from cert/key PEM files.
 * Returns 0 on success, -1 on error (see tls_last_error).
 */
int tls_init(const char *cert_file, const char *key_file) {
    g_last_err_code = 0;
    void *h = dlopen("libssl.so.3", RTLD_NOW);
    if (!h) h = dlopen("libssl.so.1.1", RTLD_NOW);
    if (!h) h = dlopen("libssl.so", RTLD_NOW);
    if (!h) {
        const char *dlerr = dlerror();
        snprintf(g_err, sizeof g_err, "cannot load libssl: %s", dlerr ? dlerr : "unknown");
        return -1;
    }
#define RESOLVE(name) do { \
        p_##name = (typeof(p_##name)) dlsym(h, #name); \
        if (!p_##name) { \
            snprintf(g_err, sizeof g_err, "missing openssl symbol: %s", #name); \
            return -1; \
        } \
    } while (0)
    RESOLVE(SSL_CTX_new);
    RESOLVE(TLS_server_method);
    RESOLVE(SSL_CTX_use_certificate_file);
    RESOLVE(SSL_CTX_use_PrivateKey_file);
    RESOLVE(SSL_CTX_check_private_key);
    RESOLVE(SSL_new);
    RESOLVE(SSL_set_fd);
    RESOLVE(SSL_accept);
    RESOLVE(SSL_read);
    RESOLVE(SSL_write);
    RESOLVE(SSL_free);
    RESOLVE(SSL_get_error);
    RESOLVE(SSL_CTX_free);
    RESOLVE(ERR_get_error);
    RESOLVE(ERR_error_string_n);
#undef RESOLVE

    g_ctx = p_SSL_CTX_new(p_TLS_server_method());
    if (!g_ctx) {
        snprintf(g_err, sizeof g_err, "SSL_CTX_new failed");
        return -1;
    }
    if (p_SSL_CTX_use_certificate_file(g_ctx, cert_file, SSL_FILETYPE_PEM) != 1 ||
        p_SSL_CTX_use_PrivateKey_file(g_ctx, key_file, SSL_FILETYPE_PEM) != 1 ||
        p_SSL_CTX_check_private_key(g_ctx) != 1) {
        p_ERR_error_string_n(p_ERR_get_error(), g_err, sizeof g_err);
        p_SSL_CTX_free(g_ctx);
        g_ctx = NULL;
        return -1;
    }
    return 0;
}

/*
 * Run the server handshake on an accepted, blocking fd.
 * Returns the SSL handle on success, NULL on error (see tls_last_error).
 */
void *tls_accept(int fd) {
    g_last_err_code = 0;
    if (!g_ctx) {
        strcpy(g_err, "tls_init not called");
        return NULL;
    }
    struct ssl_st *ssl = p_SSL_new(g_ctx);
    if (!ssl) {
        strcpy(g_err, "SSL_new failed");
        return NULL;
    }
    if (p_SSL_set_fd(ssl, fd) != 1) {
        p_SSL_free(ssl);
        strcpy(g_err, "SSL_set_fd failed");
        return NULL;
    }
    if (p_SSL_accept(ssl) == 1) return ssl;
    g_last_err_code = p_SSL_get_error(ssl, 0);
    p_SSL_free(ssl);
    if (g_last_err_code == SSL_ERROR_SYSCALL) {
        strcpy(g_err, "handshake failed: connection closed or syscall error");
    } else {
        p_ERR_error_string_n(p_ERR_get_error(), g_err, sizeof g_err);
    }
    return NULL;
}

/*
 * Read/write over the TLS stream. Returns >0 for bytes transferred,
 * 0 for a clean peer close (read), negative on error. tls_last_err_code
 * then holds SSL_get_error(). The fd is blocking, so WANT_READ/WRITE do
 * not occur in practice.
 */
int tls_read(void *ssl, void *buf, int len) {
    int n = p_SSL_read((struct ssl_st *) ssl, buf, len);
    if (n <= 0) g_last_err_code = p_SSL_get_error((struct ssl_st *) ssl, n);
    return n;
}

int tls_write(void *ssl, const void *buf, int len) {
    int n = p_SSL_write((struct ssl_st *) ssl, buf, len);
    if (n <= 0) g_last_err_code = p_SSL_get_error((struct ssl_st *) ssl, n);
    return n;
}

void tls_free(void *ssl) {
    if (ssl) p_SSL_free((struct ssl_st *) ssl);
}

const char *tls_last_error(void) {
    return g_err;
}

int tls_last_err_code(void) {
    return g_last_err_code;
}
